import Foundation

/// App-owned data only. An external SQLite store contributes its exact files
/// and its own host directory; its parent directory is never removed.
@MainActor
enum RelayAppReset {
    private struct Intent: Codable { let version: Int; let stores: [URL] }
    static func marker(in directory: URL) -> URL { directory.appendingPathComponent("purge-pending-v1.json") }
    static func isPending(in directory: URL) -> Bool { FileManager.default.fileExists(atPath: marker(in: directory).path) }

    static func begin(in directory: URL, stores: [URL]) throws {
        try RelaySecureFileIO.ensurePrivateDirectory(at: directory)
        let paths = Array(Set(stores.map(\.standardizedFileURL)))
        guard paths.count <= 32, paths.allSatisfy({ $0.isFileURL && $0.pathExtension == "sqlite" }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try RelaySecureFileIO.writePrivate(JSONEncoder().encode(Intent(version: 1, stores: paths)),
            to: marker(in: directory), maximumBytes: 64 * 1024)
    }

    static func complete(in directory: URL, clearSecrets: () throws -> Void,
                         clearPreferences: () -> Void) throws {
        let intent = try JSONDecoder().decode(Intent.self,
            from: RelaySecureFileIO.read(from: marker(in: directory), maximumBytes: 64 * 1024))
        guard intent.version == 1, intent.stores.count <= 32,
              intent.stores.allSatisfy({ $0.isFileURL && $0.pathExtension == "sqlite" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var failure: Error?
        do { try clearSecrets() } catch { failure = error }
        for store in intent.stores {
            let base = store.deletingPathExtension()
            let files = [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm"),
                         URL(fileURLWithPath: store.path + "-journal"), base.appendingPathExtension("opaque-routes.nwstate"),
                         base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-noctweb-host")]
            for file in files {
                do { try remove(file) } catch { failure = error }
            }
            do {
                let prefix = "." + base.appendingPathExtension("opaque-routes.nwstate").lastPathComponent + "."
                for file in try FileManager.default.contentsOfDirectory(at: store.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                    let name = file.lastPathComponent
                    if name.hasPrefix(prefix), name.hasSuffix(".tmp"),
                       UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil {
                        try remove(file)
                    }
                }
            } catch { failure = error }
        }
        do {
            try RelaySecureFileIO.ensurePrivateDirectory(at: directory)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.standardizedFileURL != marker(in: directory).standardizedFileURL {
                try remove(file)
            }
        } catch { failure = error }
        if let failure { throw failure }
        clearPreferences()
        try FileManager.default.removeItem(at: marker(in: directory))
    }

    private static func remove(_ url: URL) throws {
        // FileManager unlinks a symlink itself and does not traverse its target.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
