import Darwin
import Foundation

enum RelaySecureFileIOError: Error {
    case notFound
    case inaccessible
    case notRegular
    case tooLarge
    case changedDuringRead
    case unsafeDirectory
}

/// Descriptor-based persistence for relay-owned files. It rejects symbolic
/// links and non-regular files, bounds reads, and replaces files atomically
/// from inside an owner-only directory.
enum RelaySecureFileIO {
    nonisolated static func read(
        from url: URL,
        maximumBytes: Int,
        requirePrivateOwner: Bool = true
    ) throws -> Data {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? RelaySecureFileIOError.notFound : .inaccessible
        }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size > 0 else {
            throw RelaySecureFileIOError.notRegular
        }
        guard UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw RelaySecureFileIOError.tooLarge
        }
        if requirePrivateOwner {
            guard before.st_uid == geteuid(),
                  (before.st_mode & mode_t(0o077)) == 0 else {
                throw RelaySecureFileIOError.notRegular
            }
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { throw RelaySecureFileIOError.tooLarge }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, min(raw.count, remaining))
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw RelaySecureFileIOError.inaccessible }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumBytes else { throw RelaySecureFileIOError.tooLarge }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw RelaySecureFileIOError.changedDuringRead
        }
        return data
    }

    nonisolated static func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw RelaySecureFileIOError.unsafeDirectory }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw RelaySecureFileIOError.unsafeDirectory
        }
    }

    nonisolated static func writePrivate(
        _ data: Data,
        to fileURL: URL,
        maximumBytes: Int
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RelaySecureFileIOError.tooLarge
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: directoryURL)
        let directory: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw RelaySecureFileIOError.unsafeDirectory }
        defer { _ = close(directory) }

        let name = fileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw RelaySecureFileIOError.inaccessible
        }
        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { temporary in
            openat(
                directory,
                temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw RelaySecureFileIOError.inaccessible }
        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = close(descriptor) }
            if temporaryExists {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw RelaySecureFileIOError.inaccessible
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RelaySecureFileIOError.inaccessible }
                written += count
            }
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw RelaySecureFileIOError.inaccessible
        }
        descriptorIsOpen = false
        let result = temporaryName.withCString { temporary in
            name.withCString { destination in
                renameat(directory, temporary, directory, destination)
            }
        }
        guard result == 0, fsync(directory) == 0 else {
            throw RelaySecureFileIOError.inaccessible
        }
        temporaryExists = false
    }
}
