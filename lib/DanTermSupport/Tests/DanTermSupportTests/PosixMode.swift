// The mode reader this target's suites share. It lives in a file of its own because the
// suite that used to own it moved out with the seam, and a test helper does not cross a
// package boundary -- so lib/PrivateFile's suite keeps a copy of exactly this.
import Darwin
import Foundation
import Testing

/// Reads the permission bits an artifact actually carries, without following a symlink.
/// Asked in several suites here -- the recovery store, the audit log, the control socket --
/// and `FileManager` attribute dictionaries answer it far less directly.
func posixMode(of url: URL) throws -> mode_t {
    var status = stat()
    try #require(lstat(url.path, &status) == 0, "\(url.path) should exist")
    return status.st_mode & 0o777
}
