// The one place the running product creates a file or a directory. Every writer in `app/`,
// `lib/`, and `cli/` routes here, so the mode an artifact is born with is a property of this
// file rather than of whatever umask the process happened to inherit. What it does NOT hold:
// where anything lives (DanTermInstancePaths owns that), what goes in it (each caller owns
// that), and the umask-default artifacts the user edits directly -- the config file and the
// CLI symlink say so at their own call sites instead of routing through here.
import Darwin
import Foundation

/// Creates files and directories no other user can reach, and finishes stating the mode
/// before the artifact is nameable at the path a reader would use.
///
/// It exists because the alternative -- every writer passing a mode of its own -- lets the
/// next writer reintroduce a world-readable scrollback file by simply omitting one. Here
/// privacy is what a caller gets by default, and there is nothing to omit.
///
/// Every create goes `open`/`mkdir` with the mode, then `fchmod`/`chmod` to pin it: the mode
/// argument is masked by the umask, so the syscall alone can only make the artifact narrower
/// than intended, never broader, and the second step then states it exactly.
enum PrivateFile {
    /// Owner read/write. Everything the product writes either holds terminal content or
    /// names something that does.
    static let fileMode: mode_t = 0o600
    /// Owner read/write/search, so a private file can never be reached through a public parent.
    static let directoryMode: mode_t = 0o700

    /// Create `url` and any missing parent, and narrow `url` itself if it already exists.
    ///
    /// Only the named directory is narrowed. Its ancestors are the user's own tree -- an
    /// Application Support root, a temporary root -- and this seam has no business changing
    /// the mode of a directory it did not create.
    static func createDirectory(at url: URL) throws {
        try makeDirectory(at: url, narrowingExisting: true)
    }

    /// Create `url` fresh, fill it, and flush it. Fails if anything already occupies the path.
    ///
    /// This is also the staging step of `writeAtomically`, which is what keeps an atomic
    /// write's temporary sibling private for its whole life. A failure part-way through
    /// removes the file, so a partial artifact is never left under a name a reader can find.
    static func createFile(_ data: Data, at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
        guard descriptor >= 0 else { throw privateFileError() }
        do {
            guard fchmod(descriptor, fileMode) == 0 else { throw privateFileError() }
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw privateFileError() }
        } catch {
            // The descriptor is closed exactly once on every path. A second close would
            // release a number another thread may already have reopened.
            Darwin.close(descriptor)
            Darwin.unlink(url.path)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            let error = privateFileError()
            Darwin.unlink(url.path)
            throw error
        }
    }

    /// Replace `url` with `data` in one step: stage a private sibling, then rename it over
    /// the destination.
    ///
    /// This is the private replacement for `Data.write(options: .atomic)`, and it exists
    /// because that call cannot be made private after the fact: it renames a umask-default
    /// sibling into place, so both the sibling and the final path are readable by everyone
    /// before any `chmod` could run. A reader still sees either the previous complete file
    /// or this one, and a failure leaves the previous file and no sibling.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let staged = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        try createFile(data, at: staged)
        guard rename(staged.path, url.path) == 0 else {
            let error = privateFileError()
            Darwin.unlink(staged.path)
            throw error
        }
    }

    /// Open `url` for appending, creating it when it is absent and narrowing it when it is
    /// not. The caller owns the descriptor and closes it.
    ///
    /// This is the shape a log takes: one open, many writes, and no chance to restate the
    /// mode later. A file found at a broader mode is narrowed here, because a log written by
    /// a previous build is never recreated -- it is only appended to.
    static func openForAppending(at url: URL) throws -> Int32 {
        try openNarrowed(at: url.path, flags: O_WRONLY | O_CREAT | O_APPEND)
    }

    /// Open `url` read/write so the caller can hold an advisory lock on it, creating it when
    /// it is absent.
    ///
    /// A lock file is opened, not replaced: two instances racing for the same resource have
    /// to reach the same inode, so nothing here truncates or renames.
    static func openForLocking(at url: URL) throws -> Int32 {
        try openNarrowed(at: url.path, flags: O_RDWR | O_CREAT)
    }

    /// Create the empty file at `path`, or narrow and empty the one already there.
    ///
    /// A marker file is a zero-byte existence flag, so there is no content for an atomic
    /// stage-and-rename to protect and nothing to fsync. It takes a path rather than a URL
    /// because its one caller writes markers from a benchmark's draw path, where building a
    /// `URL` was itself measurable.
    static func createEmptyFile(atPath path: String) throws {
        let descriptor = try openNarrowed(at: path, flags: O_WRONLY | O_CREAT | O_TRUNC)
        Darwin.close(descriptor)
    }

    /// Create the Unix socket node at `url` and hand back a bound descriptor that has not yet
    /// listened.
    ///
    /// Binding and moding are one step here because they cannot be safely two: a socket node
    /// takes its mode from the umask at `bind`, and a `chmod` afterwards leaves a window in
    /// which the path is already reachable at whatever the umask allowed. Since this returns
    /// before `listen`, no peer can connect during that window, and a caller cannot reach the
    /// descriptor without the mode already being on the node.
    static func bindSocket(at url: URL) throws -> Int32 {
        var address = try unixSocketAddress(for: url)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw privateFileError() }
        do {
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw privateFileError() }
            guard chmod(url.path, fileMode) == 0 else { throw privateFileError() }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Opens a path with `flags`, then states the mode on the descriptor rather than the name,
    /// so an existing file is narrowed and no other path can be moded by mistake.
    private static func openNarrowed(at path: String, flags: Int32) throws -> Int32 {
        let descriptor = Darwin.open(path, flags, fileMode)
        guard descriptor >= 0 else { throw privateFileError() }
        guard fchmod(descriptor, fileMode) == 0 else {
            let error = privateFileError()
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Creates one directory, recursing into a missing parent first. `narrowingExisting`
    /// separates the directory the caller named from the ancestors made on the way to it.
    private static func makeDirectory(at url: URL, narrowingExisting: Bool) throws {
        let path = url.path
        if mkdir(path, directoryMode) == 0 {
            guard chmod(path, directoryMode) == 0 else { throw privateFileError() }
            return
        }
        switch errno {
        case ENOENT:
            let parent = url.deletingLastPathComponent()
            guard parent.path != path else { throw privateFileError() }
            try makeDirectory(at: parent, narrowingExisting: false)
            try makeDirectory(at: url, narrowingExisting: narrowingExisting)
        case EEXIST:
            var status = stat()
            guard stat(path, &status) == 0 else { throw privateFileError() }
            guard status.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
            guard narrowingExisting else { return }
            guard chmod(path, directoryMode) == 0 else { throw privateFileError() }
        default:
            throw privateFileError()
        }
    }

    /// Writes every byte, since one `write` may take fewer than it was offered and an
    /// interrupted one takes none at all.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw privateFileError()
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }
}

/// Builds the Darwin address while enforcing `sockaddr_un.sun_path` capacity. It lives with
/// the socket creator rather than with the listener because binding is where the length limit
/// is discovered, and `ControlSocketListener`'s liveness probe borrows it from here.
func unixSocketAddress(for url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard url.path.utf8.count < maximumLength else {
        throw CocoaError(.fileWriteInvalidFileName)
    }
    url.path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            let destination = UnsafeMutableRawPointer(pathPointer)
                .assumingMemoryBound(to: CChar.self)
            strncpy(destination, source, maximumLength - 1)
        }
    }
    return address
}

/// Captures errno before a close or an unlink on the failure path can overwrite it.
private func privateFileError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
