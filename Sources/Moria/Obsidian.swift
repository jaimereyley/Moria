import AppKit

/// A vault open in Obsidian, which only reads and writes plain files. So Obsidian gets an unencrypted copy of the vault,
/// which Moria encrypts back into the vault as Obsidian changes it, and deletes once Obsidian quits or closes its window.
/// Until then, any app on this Mac can read the copy. It opens in an Obsidian of its own, whose app data (caches, search
/// index, file-recovery snapshots) sits beside the copy and is deleted with it, leaving your other vaults alone.
@MainActor final class Obsidian {
    static let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian")
    nonisolated let store: Store
    /// Holds the copy and Obsidian's app data. `.noindex` keeps Spotlight out of it, and Time Machine skips it.
    nonisolated let root: URL
    private var data: URL { root.appending(path: "App") }
    nonisolated private let changed: @Sendable () -> Void
    private let ended: () -> Void
    private let queue = DispatchQueue(label: "Moria.Obsidian")  // Encrypts changes one batch at a time.
    private var stream: FSEventStreamRef?
    private var timer: Timer?
    private var seenWindow = false

    /// The copy: the folder beside Obsidian's app data, named after the vault, since Obsidian shows that name.
    nonisolated private var copy: URL? {
        try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .first { $0.lastPathComponent != "App" && $0.hasDirectoryPath }
    }

    init(_ store: Store, changed: @escaping @Sendable () -> Void = {}, ended: @escaping () -> Void = {}) {
        (self.store, self.changed, self.ended) = (store, changed, ended)
        root = URL.applicationSupportDirectory.appending(path: "Moria/Obsidian.noindex/\(store.id)")
    }

    /// Decrypts the vault into a copy named `name`, and opens it in a new Obsidian.
    func open(as name: String) async throws {
        guard let app = Obsidian.app else { throw Failure(errorDescription: "Obsidian isn't installed.") }
        try close()  // A copy left by a crash, or by changes that couldn't be encrypted, goes back into the vault first.
        let (store, copy, parent) = (store, root.appending(path: name), root.deletingLastPathComponent())
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                var folder = parent
                try folder.setResourceValues(excluded)
                for entry in try store.entries().entries { try store.export(entry, to: copy.appending(path: entry.path)) }
                // Obsidian moves deleted notes to the Trash, unencrypted. This keeps them in the vault's .trash instead.
                let settings = copy.appending(path: ".obsidian/app.json")
                if !FileManager.default.fileExists(atPath: settings.path) {
                    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(#"{"trashOption":"local"}"#.utf8).write(to: settings)
                }
            }.value
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            // Starts on the Obsidian version this Mac already runs, not the older one inside the app, which would update.
            let normal = URL.applicationSupportDirectory.appending(path: "obsidian")
            if let update = (try? FileManager.default.contentsOfDirectory(atPath: normal.path))?.filter({ $0.hasPrefix("obsidian-") && $0.hasSuffix(".asar") })
                .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                try? FileManager.default.linkItem(at: normal.appending(path: update), to: data.appending(path: update))
            }
            // Opens the copy straight away. Written last, it also marks the copy as complete, for `close` to trust.
            let vaults = ["vaults": [store.id.lowercased(): ["path": copy.path, "ts": Int(Date.now.timeIntervalSince1970 * 1000), "open": true]]]
            try JSONSerialization.data(withJSONObject: vaults).write(to: data.appending(path: "obsidian.json"))
            let configuration = NSWorkspace.OpenConfiguration()
            (configuration.createsNewApplicationInstance, configuration.arguments) = (true, ["--user-data-dir=\(data.path)"])
            try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } catch {
            try? close()
            throw error
        }
        watch(copy)
    }

    /// Brings this Obsidian to the front.
    func activate() { instance.flatMap(NSRunningApplication.init)?.activate() }

    /// Quits this Obsidian, which saves as it goes, then encrypts its last changes into the vault and deletes the copy.
    /// If those changes can't all be encrypted, the copy stays for the next unlock to try again.
    func close() throws {
        timer?.invalidate()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        quit()
        // Without the vault list, Obsidian never opened it, so nothing in it is new.
        if FileManager.default.fileExists(atPath: data.appending(path: "obsidian.json").path), let copy {
            do { _ = try queue.sync { try store.sync(from: copy, deleting: true) } } catch {
                throw Failure(errorDescription: "Couldn't encrypt Obsidian's last changes, so their unencrypted copy is still in \(copy.path). "
                                                + "Moria will try again the next time you unlock. \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Encrypts changes as Obsidian saves them, and watches for it quitting or closing its window, which on a Mac
    /// leaves it running.
    private func watch(_ copy: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, Obsidian.pull, &context, [copy.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
        timer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let processes = self.processes, windows = processes.contains { $0.contains("--type=renderer") }
                if !processes.contains(where: Obsidian.isMain) || self.seenWindow && !windows { self.ended() }
                self.seenWindow = self.seenWindow || windows
            }
        }
    }

    /// Runs on `queue`. A failure, like a file changing as it's read, is retried with the next change, or by `close`.
    nonisolated private static let pull: FSEventStreamCallback = { _, info, _, _, _, _ in
        let session = Unmanaged<Obsidian>.fromOpaque(info!).takeUnretainedValue()
        if let copy = session.copy, (try? session.store.sync(from: copy, deleting: true)) == true { session.changed() }
    }

    /// Asks this Obsidian to quit, as ⌘Q does, until it has. One with a save pending can stay running without windows,
    /// so the ask repeats. One that's hung is forced after 15 seconds.
    private func quit() {
        guard let pid = instance, let app = NSRunningApplication(processIdentifier: pid) else { return }
        for tick in 0... {
            guard kill(pid, 0) == 0 else { return }
            _ = tick < 30 ? app.terminate() : app.forceTerminate()
            usleep(500_000)
        }
    }

    /// This Obsidian's processes, as `pgrep -lf` lists them: one per window, plus the app and its helpers.
    private var processes: [Substring] {
        ((try? sh("/usr/bin/pgrep", ["-lf", "--", "--user-data-dir=" + NSRegularExpression.escapedPattern(for: data.path)])) ?? "").split(separator: "\n")
    }
    private var instance: pid_t? { processes.first(where: Obsidian.isMain).flatMap { pid_t($0.prefix { $0 != " " }) } }
    private static func isMain(_ process: Substring) -> Bool { process.contains("MacOS/Obsidian --user-data-dir=") }
}
