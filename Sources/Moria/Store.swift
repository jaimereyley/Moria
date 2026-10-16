import AppleArchive
import CommonCrypto
import CryptoKit
import Foundation
import Synchronization
import System
import UniformTypeIdentifiers

/// A file or folder in a vault.
struct Entry: Identifiable, Hashable, Sendable {
    var path: String  // Relative to the vault, like "Taxes/2024/return.pdf".
    var blob: String?  // Its archive in files/. Folders that only exist because files are inside them have none.
    var isFolder = false
    var size = 0
    var date = Date.now

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
    var type: UTType { isFolder ? .folder : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data }
    var kind: String { (type.localizedDescription ?? "").prefix(1).uppercased() + (type.localizedDescription ?? "").dropFirst() }
    func contains(_ other: Entry) -> Bool { other.path == path || other.path.hasPrefix(path + "/") }
}

/// An unlocked vault on disk. `key.aea` holds a random key, encrypted with your stretched password (see `secret`), and
/// `files/` one archive per file or folder, encrypted with that key and recording its path. Files are decrypted only
/// into this process's memory, or wherever you export them. Everything is Apple Encrypted Archive and PBKDF2, so
/// Recover.app, or `openssl`, `aea` and `aa` in Terminal, can open a vault without Moria.
struct Store: Sendable {
    let root: URL
    let key: SymmetricKey
    private var files: URL { root.appending(path: "files") }
    private static var data: ArchiveHeader.FieldKey { .init("DAT") }
    private static let rounds = 10_000_000

    /// Makes a new, empty vault at `root`, returning it and its secret.
    static func create(_ root: URL, password: String) throws -> (Store, secret: String) {
        let store = Store(root: root, key: SymmetricKey(size: .bits256))
        let salt = (0..<8).map { _ in UInt8.random(in: .min ... .max) }  // 8 bytes, the most `openssl enc -S` takes.
        try FileManager.default.createDirectory(at: store.files, withIntermediateDirectories: true)
        try "pbkdf2-sha256 \(rounds) \(hex(salt))\n".write(to: root.appending(path: "key.kdf"), atomically: true, encoding: .utf8)
        let secret = stretch(password, salt: salt, rounds: rounds)
        try seal(root.appending(path: "key.aea"), with: .password(secret)) { stream in
            _ = try store.key.withUnsafeBytes { try stream.write(from: $0) }
        }
        return (store, secret)
    }

    /// Your password, stretched by the PBKDF2-SHA256 in `key.kdf` (10 million rounds take about a second) into what
    /// `openssl enc -pbkdf2 -P` prints as its key, so it can be recomputed without Moria. It's the password of `key.aea`,
    /// whose scrypt adds a memory-hard step, so each guess at a short password costs an attacker that much. Touch ID
    /// keeps it instead of your password.
    static func secret(for password: String, in root: URL) throws -> String {
        let fields = try String(contentsOf: root.appending(path: "key.kdf"), encoding: .utf8).split(separator: " ")
        guard fields.count == 3, fields[0] == "pbkdf2-sha256", let rounds = Int(fields[1]) else { throw Failure(errorDescription: "The vault's key.kdf is damaged.") }
        let salt = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return stretch(password, salt: stride(from: 0, to: salt.count, by: 2).compactMap { UInt8(salt.dropFirst($0).prefix(2), radix: 16) }, rounds: rounds)
    }

    private static func stretch(_ password: String, salt: [UInt8], rounds: Int) -> String {
        var key = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, key.count)
        return hex(key)
    }

    /// Names this vault's working files outside it, the same wherever the vault moves, without revealing anything.
    var id: String { hex(Array(SHA256.hash(data: key.withUnsafeBytes { Data($0) }).prefix(8))) }

    static func open(_ root: URL, secret: String) throws -> Store {
        let key = try unseal(root.appending(path: "key.aea"), with: .password(secret)) { stream in
            var bytes = [UInt8](repeating: 0, count: 32)
            guard try bytes.withUnsafeMutableBytes({ try stream.read(into: $0) }) == 32 else { throw Failure(errorDescription: "The vault's key is damaged.") }
            return SymmetricKey(data: bytes)
        }
        let store = Store(root: root, key: key)
        // Half-written archives left by a crash. Nothing else is writing yet.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: store.files.path)) ?? [] where name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: store.files.appending(path: name))
        }
        return store
    }

    /// Every entry, read from the archives' headers, and how many archives couldn't be decrypted.
    func entries() throws -> (entries: [Entry], unreadable: Int) {
        let blobs = try FileManager.default.contentsOfDirectory(atPath: files.path).filter { $0.hasSuffix(".aea") }
        let found = Mutex([Entry]())
        DispatchQueue.concurrentPerform(iterations: blobs.count) { i in
            guard let entry = try? unseal(blobs[i], { _, header in Entry(blob: blobs[i], header: header) }) else { return }
            found.withLock { $0.append(entry) }
        }
        let entries = found.withLock { $0 }
        return (entries, blobs.count - entries.count)
    }

    /// Encrypts the file or folder at `source`, with everything in it, into the vault as `path`.
    func add(_ source: URL, as path: String) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let entry = Entry(path: path, blob: Store.newBlob, isFolder: values.isDirectory == true, size: values.fileSize ?? 0,
                          date: values.contentModificationDate ?? .now)
        guard entry.isFolder else {
            let file = try FileHandle(forReadingFrom: source)
            return try seal(entry) { archive in
                var left = entry.size  // Exactly what the header promises, even if the file grows meanwhile.
                while left > 0 {
                    guard let chunk = try file.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty else {
                        throw Failure(errorDescription: "“\(source.lastPathComponent)” changed while it was being encrypted.")
                    }
                    try chunk.withUnsafeBytes { try archive.writeBlob(key: Store.data, from: $0) }
                    left -= chunk.count
                }
            }
        }
        try seal(entry)
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where child.lastPathComponent != ".DS_Store" {
            try add(child, as: path + "/" + child.lastPathComponent)
        }
    }

    func makeFolder(_ path: String) throws { try seal(Entry(path: path, blob: Store.newBlob, isFolder: true)) }

    /// Makes the vault match `folder`: encrypts what's new or changed there and, with `deleting`, removes what's gone
    /// from it. Returns whether anything changed.
    func sync(from folder: URL, deleting: Bool) throws -> Bool {
        try _ = folder.checkResourceIsReachable()  // A missing folder would look empty, deleting everything.
        var old = Dictionary(grouping: try entries().entries, by: \.path), changed = false, failure: Error?
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, errorHandler: { failure = $1; return false })!
        where url.lastPathComponent != ".DS_Store" {
            let values = try url.resourceValues(forKeys: Set(keys)), path = String(url.path.dropFirst(folder.path.count + 1))
            let stale = old.removeValue(forKey: path) ?? []
            if let entry = stale.first, stale.count == 1, entry.isFolder == values.isDirectory,
               entry.isFolder || entry.size == values.fileSize && abs(entry.date.timeIntervalSince(values.contentModificationDate ?? .distantPast)) < 1e-5 { continue }
            if values.isDirectory == true { try makeFolder(path) } else { try add(url, as: path) }
            for entry in stale { try remove(entry) }
            changed = true
        }
        if let failure { throw failure }
        guard deleting else { return changed }
        for entry in old.values.joined() { try remove(entry) }
        return changed || !old.isEmpty
    }

    /// Re-encrypts an entry under a new path, since its path is inside its archive.
    func move(_ entry: Entry, to path: String) throws {
        guard entry.blob != nil else { return }
        var moved = entry
        (moved.path, moved.blob) = (path, Store.newBlob)
        try seal(moved) { archive in try read(entry) { try archive.writeBlob(key: Store.data, from: $0) } }
        try remove(entry)
    }

    func remove(_ entry: Entry) throws {
        if let blob = entry.blob { try FileManager.default.removeItem(at: files.appending(path: blob)) }
    }

    func contents(of entry: Entry) throws -> Data {
        var data = Data(capacity: entry.size)
        try read(entry) { data.append(contentsOf: $0) }
        return data
    }

    /// Decrypts an entry to `url`, where the copy isn't encrypted.
    func export(_ entry: Entry, to url: URL) throws {
        guard !entry.isFolder else { return try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        let file = try FileHandle(forWritingTo: url)
        try read(entry) { try file.write(contentsOf: $0) }
        try file.close()
        try FileManager.default.setAttributes([.modificationDate: entry.date], ofItemAtPath: url.path)
    }

    /// Puts a fresh Recover.app and Read Me in the vault, replacing any copies something may have tampered with.
    func installRecovery() {
        for name in ["Recover.app", "Read Me.txt"] {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            try? FileManager.default.removeItem(at: root.appending(path: name))
            try? FileManager.default.copyItem(at: source, to: root.appending(path: name))
        }
    }

    // MARK: Archives

    private static var newBlob: String { UUID().uuidString + ".aea" }

    /// Decrypts an entry's data a chunk at a time.
    private func read(_ entry: Entry, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard let blob = entry.blob, !entry.isFolder else { return }
        try unseal(blob) { archive, _ in
            var buffer = [UInt8](repeating: 0, count: 1 << 20), left = entry.size
            while left > 0 {
                let chunk = min(left, buffer.count)
                try buffer.withUnsafeMutableBytes { try archive.readBlob(key: Store.data, into: .init(rebasing: $0[..<chunk])) }
                try buffer.withUnsafeBytes { try body(.init(rebasing: $0[..<chunk])) }
                left -= chunk
            }
        }
    }

    /// Writes an entry's archive: a header like `aa` writes, then whatever `body` writes as the file's data.
    private func seal(_ entry: Entry, _ body: (ArchiveStream) throws -> Void = { _ in }) throws {
        try Store.seal(files.appending(path: entry.blob!), with: .key(key)) { stream in
            let archive = try unwrap(ArchiveStream.encodeStream(writingTo: stream))
            let header = ArchiveHeader()
            header.append(.uint(key: .init("TYP"), value: UInt64((entry.isFolder ? ArchiveHeader.EntryType.directory : .regularFile).rawValue)))
            header.append(.string(key: .init("PAT"), value: entry.path))
            header.append(.uint(key: .init("MOD"), value: entry.isFolder ? 0o755 : 0o644))
            let time = entry.date.timeIntervalSince1970, seconds = time.rounded(.down)
            header.append(.timespec(key: .init("MTM"), value: timespec(tv_sec: Int(seconds), tv_nsec: Int((time - seconds) * 1e9))))
            if !entry.isFolder { header.append(.blob(key: Store.data, size: UInt64(entry.size))) }
            try archive.writeHeader(header)
            try body(archive)
            try archive.close()
        }
    }

    /// Opens an entry's archive, for `body` to read its header and data.
    private func unseal<T>(_ blob: String, _ body: (ArchiveStream, ArchiveHeader) throws -> T) throws -> T {
        try Store.unseal(files.appending(path: blob), with: .key(key)) { stream in
            let archive = try unwrap(ArchiveStream.decodeStream(readingFrom: stream, threadCount: 1))
            defer { archive.cancel() }
            return try body(archive, try unwrap(archive.readHeader()))
        }
    }

    // MARK: Encryption

    private enum Secret { case password(String), key(SymmetricKey) }

    /// Encrypts what `body` writes into a new file at `url`, which only appears once it's complete.
    private static func seal(_ url: URL, with secret: Secret, _ body: (ArchiveByteStream) throws -> Void) throws {
        let context: ArchiveEncryptionContext
        switch secret {
        case .password(let password):
            context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .none)
            try context.setPassword(password)
        case .key(let key):
            context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none, compressionAlgorithm: .lzfse)
            try context.setSymmetricKey(key)
        }
        let temporary = url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try unwrap(ArchiveByteStream.fileStream(path: FilePath(temporary.path), mode: .writeOnly, options: [.create, .truncate],
                                                           permissions: [.ownerReadWrite]))
        let stream = try unwrap(ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context))
        try body(stream)
        try stream.close()
        try file.close()
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private static func unseal<T>(_ url: URL, with secret: Secret, _ body: (ArchiveByteStream) throws -> T) throws -> T {
        let file = try unwrap(ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [], permissions: []))
        defer { try? file.close() }
        let context = try unwrap(ArchiveEncryptionContext(from: file))
        let wrong = Failure(errorDescription: "Wrong password.")
        switch secret {
        case .password(let password): do { try context.setPassword(password) } catch { throw wrong }
        case .key(let key): try context.setSymmetricKey(key)
        }
        guard let stream = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context, threadCount: 1) else { throw wrong }
        defer { stream.cancel() }
        return try body(stream)
    }
}

private extension Entry {
    init?(blob: String, header: ArchiveHeader) {
        guard let path = header.entryPath?.string else { return nil }
        self.init(path: path, blob: blob, isFolder: header.entryType == .directory)
        if case .blob(_, let size, _) = header.field(forKey: .init("DAT")) { self.size = Int(size) }
        if case .timespec(_, let time) = header.field(forKey: .init("MTM")) {
            date = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
    }
}

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure(errorDescription: "The vault's encryption failed.") }
    return value
}
