// Compile-time contracts for the closed error surfaces used by IPC request decoding.
import Testing
@testable import DanTermProtocol

struct TypedThrowsContractTests {
    @Test("IPC decode parsers expose their closed error types")
    func ipcDecodeParsersExposeClosedErrorTypes() {
        let _: (String, JSONValue) throws(IpcRequestDecodeError) -> IpcRequest =
            IpcRequest.decode
        let _: (JSONValue?) throws(LaunchSpecParseError) -> LaunchSpec? =
            parseLaunchSpec
        let _: (PaneTapeStreamMode, Int?) throws(PaneTapeSyncPolicyError) -> PaneTapeSyncPolicy =
            paneTapeSyncPolicy
        let _: (JSONValue?) throws(PaneTapeSyncPolicyError) -> Int? =
            decodePaneTapeSyncHistoryBytes
        let _: ([String]) throws(KeyModsDecodeError) -> KeyMods =
            KeyMods.decode
    }
}
