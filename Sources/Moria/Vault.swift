import AppKit
import LocalAuthentication

/// An AES-256 encrypted APFS sparse bundle, mounted (hidden from Finder and Spotlight) only while unlocked.
@MainActor @Observable final class Vault {
    /// The selected vault, which may not exist yet while it's being created. Selecting another locks this one first.
    var bundle = UserDefaults.standard.url(forKey: "vault").flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } {
        willSet { if newValue?.path != bundle?.path { lock() } }
        didSet { UserDefaults.standard.set(bundle, forKey: "vault"); remember(); load() }
    }
    /// Paths of the vaults opened here, most recent first.
    private(set) var vaults = UserDefaults.standard.stringArray(forKey: "vaults") ?? [] {
        didSet { UserDefaults.standard.set(vaults, forKey: "vaults") }
    }
    private(set) var mount: URL?
    /// Where and when the vault was last backed up, kept as xattrs on the bundle so they travel with it.
    private(set) var remote: String?
    private(set) var lastBackup: Date?
    private(set) var busy = false
    private(set) var syncing = false
    var error: String?

    var name: String { bundle?.deletingPathExtension().lastPathComponent ?? "Moria" }
    var exists: Bool { bundle.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var hasSavedPassword: Bool { SecItemCopyMatching(keychainItem as CFDictionary, nil) == errSecSuccess }
    private static let log = URL.homeDirectory.appending(path: "Library/Logs/Moria.log")

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

    /// Creates the selected vault, which doesn't exist yet, and unlocks it.
    func create(password: String, remember: Bool) async {
        guard let bundle else { return }
        // hdiutil, because diskutil image can't set the band size: its 64 MiB bands make every backup re-upload
        // ~60 MB, while 1 MiB bands (2048 sectors) keep a typical one to a few MB.
        guard await run("/usr/bin/hdiutil", ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-encryption", "AES-256", "-stdinpass",
                                             "-size", "1t", "-imagekey", "sparse-band-size=2048", "-volname", name, bundle.path],
                        input: password) != nil else { return }
        await unlock(password, remember: remember)
    }

    func unlock(_ password: String, remember: Bool) async {
        guard let bundle else { return }
        // Mounting writes to the image, which would corrupt a backup still uploading it. A failed unlock restarts it.
        let cancelled = cancelBackup()
        let mountPoint = URL.temporaryDirectory.appending(path: "Moria-\(name)").path
        guard let out = await run("/usr/sbin/diskutil", ["image", "attach", "--plist", "--stdinpass", "--nobrowse",
                                                         "--mountPoint", mountPoint, bundle.path], input: password)
        else { if cancelled { sync() }; return }
        // If the image was already attached elsewhere, diskutil reports that mount point instead of ours.
        let info = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: [[String: Any]]]
        guard let path = info?["system-entities"]?.lazy.compactMap({ $0["mount-point"] as? String }).first
        else { error = "\(name) has no mountable volume."; return }
        mount = URL(filePath: path)
        savedPassword = remember ? password : nil
    }

    func unlockWithTouchID() async {
        guard let password = savedPassword,
              (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock “\(name)”")) == true
        else { return }
        await unlock(password, remember: true)
    }

    /// Synchronous on purpose: on quit, sleep and screen lock the image must be detached before we return.
    func lock() {
        guard let mount else { return }
        do {
            try sh("/usr/sbin/diskutil", ["eject", "force", mount.path])
            self.mount = nil
            sync()
        } catch { self.error = error.localizedDescription }
    }

    /// Links the vault to a fresh folder in `bucket`, so it never overwrites another vault's backup, and backs it up
    /// right away unless it's open.
    func link(_ bucket: String) {
        guard let bundle else { return }
        setRemote("gs://\(bucket)/\(name)-\(UUID().uuidString.prefix(6).lowercased())", of: bundle.path)
        if mount == nil { sync() }
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

    /// Puts the selected vault first in `vaults`, dropping any deleted since.
    private func remember() {
        let selected = bundle.map { [$0.path] } ?? []
        vaults = selected + vaults.filter { !selected.contains($0) && FileManager.default.fileExists(atPath: $0) }
    }

    private func load() {
        remote = bundle.flatMap { Vault.attribute("moria.remote", of: $0.path) }
        lastBackup = bundle.flatMap { Vault.attribute("moria.backed-up", of: $0.path) }.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    nonisolated static func attribute(_ name: String, of path: String) -> String? { try? sh("/usr/bin/xattr", ["-p", name, path]) }

    /// Mirrors the bundle to `remote`, stamping `moria.backed-up` on success. Only encrypted bands ever leave the Mac,
    /// and syncing after detach guarantees a consistent image. Not awaited, so a backup started on quit outlives the
    /// app. Resumable uploads are off because resuming a band that changed in between corrupts the cloud copy.
    private func sync() {
        guard let bundle, let remote else { return }
        let backup = Process()
        backup.executableURL = URL(filePath: "/bin/zsh")
        backup.arguments = ["-lc", #"{ date; CLOUDSDK_STORAGE_RESUMABLE_THRESHOLD=1000000000000 gcloud storage rsync -r --delete-unmatched-destination-objects "$0" "$1" && xattr -w moria.backed-up "$(date +%s)" "$0"; } > "$2" 2>&1"#,
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

    private func run(_ tool: String, _ args: [String], input: String) async -> String? {
        busy = true
        defer { busy = false }
        do { return try await Task.detached { try sh(tool, args, input: input) }.value }
        catch { self.error = error.localizedDescription; return nil }
    }

    /// Lives in the login keychain, whose ACL lets only Moria's code signature read it without asking you.
    private var savedPassword: String? {
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

struct Failure: LocalizedError { let errorDescription: String? }

/// Runs a tool to completion with `input` on stdin, returning its trimmed stdout or throwing its stderr on failure.
@discardableResult
nonisolated func sh(_ tool: String, _ args: [String], input: String = "") throws -> String {
    let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    // Buffer stdin before launch, so a child that exits early can never SIGPIPE us.
    try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
    try process.run()
    let read = { (pipe: Pipe) in
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let (out, err) = (read(stdout), read(stderr))
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure(errorDescription: err.isEmpty ? out : err) }
    return out
}
