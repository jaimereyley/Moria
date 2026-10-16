import AppKit
import LocalAuthentication

/// The selected vault. Nothing is ever mounted: while it's unlocked, its key and the files you open live only in this
/// process, so other apps, and agents running as you, only ever see encrypted archives. Unless you open it in Obsidian.
@MainActor @Observable final class Vault {
    /// The selected vault, which may not exist yet while it's being created. Selecting another locks this one first.
    var bundle = UserDefaults.standard.url(forKey: "vault").flatMap { Vault.isVault($0.path) ? $0 : nil } {
        willSet { if newValue?.path != bundle?.path { lock() } }
        didSet { UserDefaults.standard.set(bundle, forKey: "vault"); remember(); load() }
    }
    /// Paths of the vaults opened here, most recent first.
    private(set) var vaults = UserDefaults.standard.stringArray(forKey: "vaults") ?? [] {
        didSet { UserDefaults.standard.set(vaults, forKey: "vaults") }
    }
    /// The open vault. Nil while locked.
    private(set) var store: Store?
    /// Everything in the open vault by path, including folders that only exist because files are inside them.
    private(set) var entries: [String: Entry] = [:]
    /// The open vault's unencrypted copy in Obsidian, while it's open there.
    private(set) var obsidian: Obsidian?
    /// Where and when the vault was last backed up, kept as xattrs on the bundle so they travel with it.
    private(set) var remote: String?
    private(set) var lastBackup: Date?
    private(set) var busy = false
    private(set) var working = 0
    private(set) var syncing = false
    var error: String?

    var name: String { bundle?.deletingPathExtension().lastPathComponent ?? "Moria" }
    var exists: Bool { bundle.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var hasSavedSecret: Bool { SecItemCopyMatching(keychainItem as CFDictionary, nil) == errSecSuccess }
    private static let log = URL.homeDirectory.appending(path: "Library/Logs/Moria.log")
    nonisolated static func isVault(_ path: String) -> Bool { path.hasSuffix(".moria") && FileManager.default.fileExists(atPath: path) }

    init() {
        remember()
        load()
        for (center, event) in [
            (NotificationCenter.default, NSApplication.willTerminateNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ] {
            center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
    }

    /// Creates the selected vault, which doesn't exist yet, and opens it.
    func create(password: String, remember: Bool) async {
        await open(remember: remember) { try Store.create($0, password: password) }
    }

    func unlock(_ password: String, remember: Bool) async {
        await open(remember: remember) { root in
            let secret = try Store.secret(for: password, in: root)
            return (try Store.open(root, secret: secret), secret)
        }
    }

    func unlockWithTouchID() async {
        guard let secret = savedSecret,
              (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock “\(name)”")) == true
        else { return }
        await open(remember: true) { (try Store.open($0, secret: secret), secret) }
    }

    private func open(remember: Bool, with make: @escaping @Sendable (URL) throws -> (Store, secret: String)) async {
        guard let bundle else { return }
        // A backup uploading the vault while it changes could leave a muddled copy. Locking backs it up again.
        let cancelled = cancelBackup()
        busy = true
        defer { busy = false }
        do {
            let (store, secret) = try await Task.detached { let opened = try make(bundle); opened.0.installRecovery(); return opened }.value
            guard bundle == self.bundle else { return }
            self.store = store
            savedSecret = remember ? secret : nil
            do { try Obsidian(store).close() } catch { self.error = error.localizedDescription }  // A copy left by a crash.
            await reload(warn: true)
        } catch {
            self.error = error.localizedDescription
            if cancelled { sync() }
        }
    }

    func lock() {
        closeObsidian()
        guard store != nil else { return }
        (store, entries) = (nil, [:])
        sync()
    }

    // MARK: Files

    func children(of folder: String) -> [Entry] { entries.values.filter { $0.parent == folder } }

    /// Encrypts dropped files and folders into `folder`. With `move`, deletes the originals, so only encrypted copies remain.
    func add(_ urls: [URL], to folder: String, move: Bool) {
        var names = Set(children(of: folder).map(\.name))
        let targets = urls.map { url in
            let name = unique(url.lastPathComponent, taken: names.contains)
            names.insert(name)
            return (url, (folder as NSString).appendingPathComponent(name))
        }
        change { store in
            for (url, path) in targets {
                try store.add(url, as: path)
                if move { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Makes an empty folder in `folder`, returning its path.
    func newFolder(in folder: String) -> String {
        let path = (folder as NSString).appendingPathComponent(unique("untitled folder", taken: Set(children(of: folder).map(\.name)).contains))
        change { try $0.makeFolder(path) }
        return path
    }

    func rename(_ path: String, to name: String) {
        guard let item = entries[path], !name.isEmpty, !name.contains("/"), name != item.name else { return }
        let target = (item.parent as NSString).appendingPathComponent(name)
        guard entries[target] == nil else { return error = "There's already an item named “\(name)” here." }
        let moving = entries.values.filter(item.contains)
        change { store in for entry in moving { try store.move(entry, to: target + entry.path.dropFirst(path.count)) } }
    }

    func delete(_ paths: Set<String>) {
        let items = paths.compactMap { entries[$0] }
        let doomed = entries.values.filter { entry in items.contains { $0.contains(entry) } }
        change { store in for entry in doomed { try store.remove(entry) } }
    }

    /// Decrypts items, with everything in them, into `folder`, where the copies aren't encrypted.
    func export(_ paths: Set<String>, to folder: URL) {
        let items = paths.compactMap { entries[$0] }, all = Array(entries.values)
        change(reloading: false) { store in
            for item in items {
                let copy = folder.appending(path: unique(item.name) { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) })
                for entry in all where item.contains(entry) {
                    try store.export(entry, to: entry.path == item.path ? copy : copy.appending(path: String(entry.path.dropFirst(item.path.count + 1))))
                }
            }
        }
    }

    /// Opens the vault in Obsidian, or brings it to the front if it's open there already.
    func openInObsidian() async {
        if let obsidian { return obsidian.activate() }
        guard let store else { return }
        let session = Obsidian(store, changed: { [weak self] in Task { await self?.reload() } }, ended: { [weak self] in self?.closeObsidian() })
        obsidian = session
        working += 1
        defer { working -= 1 }
        do { try await session.open(as: name) } catch {
            obsidian = nil
            self.error = "Couldn't open “\(name)” in Obsidian. \(error.localizedDescription)"
        }
    }

    /// Quits Obsidian, encrypting its last changes, and deletes the unencrypted copy.
    func closeObsidian() {
        guard let obsidian else { return }
        self.obsidian = nil
        do { try obsidian.close() } catch { self.error = error.localizedDescription }
        Task { await reload() }
    }

    func contents(of entry: Entry) async throws -> Data {
        guard let store else { throw CancellationError() }
        return try await Task.detached { try store.contents(of: entry) }.value
    }

    /// Runs file work off the main thread, then re-reads the vault, since what's on disk is the only truth.
    private func change(reloading: Bool = true, _ work: @escaping @Sendable (Store) throws -> Void) {
        guard let store else { return }
        working += 1
        Task {
            do { try await Task.detached { try work(store) }.value } catch { self.error = error.localizedDescription }
            working -= 1
            if reloading { await reload() }
        }
    }

    private func reload(warn: Bool = false) async {
        guard let store else { return }
        do {
            let (found, unreadable) = try await Task.detached { try store.entries() }.value
            guard store.root == self.store?.root else { return }
            entries = [:]
            for entry in found {
                entries[entry.path] = entry
                var parent = entry.parent
                while !parent.isEmpty && entries[parent] == nil {
                    entries[parent] = Entry(path: parent, isFolder: true, date: entry.date)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            if warn && unreadable > 0 { error = "\(unreadable) of this vault's items couldn't be decrypted." }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Cloud

    /// Links the vault to a fresh folder in `bucket`, so it never overwrites another vault's backup, and backs it up
    /// right away unless it's open.
    func link(_ bucket: String) {
        guard let bundle else { return }
        setRemote("gs://\(bucket)/\(name)-\(UUID().uuidString.prefix(6).lowercased())", of: bundle.path)
        if store == nil { sync() }
    }

    /// Stops every vault here that backs up to `remote` from doing so. The cloud copy is left alone.
    func unlink(_ remote: String) {
        for path in vaults where Vault.attribute("moria.remote", of: path) == remote { setRemote(nil, of: path) }
    }

    /// Selects a vault just downloaded from `remote`. It stays linked, and matches the cloud copy as of now.
    func restored(_ url: URL, from remote: String) {
        setRemote(remote, of: url.path, backedUp: .now)
        bundle = url
    }

    /// Forgets a vault (it stays on disk).
    func forget(_ path: String) {
        if path == bundle?.path { bundle = nil }
        vaults.removeAll { $0 == path }
    }

    private func setRemote(_ remote: String?, of path: String, backedUp: Date? = nil) {
        do {
            _ = try? sh("/usr/bin/xattr", ["-d", "moria.backed-up", path])
            try sh("/usr/bin/xattr", remote.map { ["-w", "moria.remote", $0, path] } ?? ["-d", "moria.remote", path])
            if let backedUp { try sh("/usr/bin/xattr", ["-w", "moria.backed-up", String(Int(backedUp.timeIntervalSince1970)), path]) }
        } catch { self.error = error.localizedDescription }
        load()
    }

    /// Puts the selected vault first in `vaults`, dropping any deleted since, and vaults in Moria's old format.
    private func remember() {
        let selected = bundle.map { [$0.path] } ?? []
        vaults = selected + vaults.filter { !selected.contains($0) && Vault.isVault($0) }
    }

    private func load() {
        remote = bundle.flatMap { Vault.attribute("moria.remote", of: $0.path) }
        lastBackup = bundle.flatMap { Vault.attribute("moria.backed-up", of: $0.path) }.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    nonisolated static func attribute(_ name: String, of path: String) -> String? { try? sh("/usr/bin/xattr", ["-p", name, path]) }

    /// Mirrors the bundle to `remote`, stamping `moria.backed-up` on success. Only encrypted archives ever leave the
    /// Mac. Not awaited, so a backup started on quit outlives the app. Resumable uploads are off because resuming a file
    /// that changed in between corrupts the cloud copy, and POSIX attributes are kept so Recover.app stays runnable.
    private func sync() {
        guard let bundle, let remote else { return }
        let backup = Process()
        backup.executableURL = URL(filePath: "/bin/zsh")
        backup.arguments = ["-lc", #"{ date; CLOUDSDK_STORAGE_RESUMABLE_THRESHOLD=1000000000000 gcloud storage rsync -r -P --delete-unmatched-destination-objects "$0" "$1" && xattr -w moria.backed-up "$(date +%s)" "$0"; } > "$2" 2>&1"#,
                            bundle.path, remote, Vault.log.path]
        backup.terminationHandler = { [weak self] process in
            let (reason, status) = (process.terminationReason, process.terminationStatus)
            Task { @MainActor in self?.backupEnded(reason, status) }
        }
        syncing = (try? backup.run()) != nil
    }

    private func backupEnded(_ reason: Process.TerminationReason, _ status: Int32) {
        syncing = false
        load()
        guard reason == .exit, status != 0 else { return }  // Killed by a signal means cancelled, not failed.
        let log = try? String(contentsOf: Vault.log, encoding: .utf8)
        error = "Cloud backup failed. " + (log?.split(separator: "\n").last { $0.hasPrefix("ERROR") }.map(String.init) ?? "See \(Vault.log.path).")
    }

    /// Stops any backup of this vault, even one left running by an earlier launch, along with all of gcloud's workers.
    /// Each backup runs in its own process group, so signalling the group gets them all.
    private func cancelBackup() -> Bool {
        guard let bundle, let pids = try? sh("/usr/bin/pgrep", ["-f", "storage rsync .*" + NSRegularExpression.escapedPattern(for: bundle.path)])
        else { return false }
        for pid in pids.split(separator: "\n").compactMap({ pid_t($0) }) where getpgid(pid) > 1 { kill(-getpgid(pid), SIGTERM) }
        return true
    }

    /// Your stretched password (never the password itself), in the login keychain, whose ACL lets only Moria's code
    /// signature read it without asking you.
    private var savedSecret: String? {
        get {
            var data: CFTypeRef?
            SecItemCopyMatching(keychainItem.merging([kSecReturnData: true]) { $1 } as CFDictionary, &data)
            return (data as? Data).map { String(decoding: $0, as: UTF8.self) }
        }
        set {
            SecItemDelete(keychainItem as CFDictionary)
            if let newValue { SecItemAdd(keychainItem.merging([kSecValueData: Data(newValue.utf8)]) { $1 } as CFDictionary, nil) }
        }
    }

    private var keychainItem: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "Moria", kSecAttrAccount: bundle?.path ?? ""]
    }
}

/// `name 2.ext`, `name 3.ext`… like Finder, so nothing is ever overwritten.
func unique(_ name: String, taken: (String) -> Bool) -> String {
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    var candidate = name, n = 1
    while taken(candidate) {
        n += 1
        candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
    }
    return candidate
}

struct Failure: LocalizedError { let errorDescription: String? }

/// Runs a tool to completion, returning its trimmed stdout or throwing its stderr on failure.
@discardableResult
nonisolated func sh(_ tool: String, _ args: [String]) throws -> String {
    let process = Process(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    (process.standardInput, process.standardOutput, process.standardError) = (FileHandle.nullDevice, stdout, stderr)
    try process.run()
    let read = { (pipe: Pipe) in
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let (out, err) = (read(stdout), read(stderr))
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure(errorDescription: err.isEmpty ? out : err) }
    return out
}
