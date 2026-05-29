// Placeholder so the DanTermSupport target has a source file to compile -- an empty
// SwiftPM target fails `swift build`/`swift test`, which would break the green
// invariant every phase must preserve. Phases 2-4 replace this with the real portable
// side effects (IpcConnection, Debouncer, CLIPathInstaller, RecoveryStore); delete this
// file when the first of them lands. No behavior -- it exists only to give the module
// a body, and its unique name avoids colliding when compiled same-module into the app.
enum DanTermSupportModulePlaceholder {}
