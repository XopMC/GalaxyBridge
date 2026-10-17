import Foundation
import Network
@main struct DiagnosticSpec {
 static func main() {
  let secret = "private-payload-should-never-escape"
  let samples: [(Error,String)] = [
   (NativeMediaFailure.capacity,"native_capacity"),
   (NativeMediaFailure.invalidSize,"native_invalid_size"),
   (NativeMediaFailure.nativeCleanup(111),"native_cleanup_111"),
   (NativeMediaFailure.cleanupIncomplete,"native_cleanup_incomplete"),
   (NativeMediaFailure.codec(secret),"native_codec"),
   (ShellCapabilityBridgeFailure.unavailable,"shell_unavailable"),
   (ShellCapabilityBridgeFailure.invalidResult,"shell_invalid_result"),
   (ShellCapabilityBridgeFailure.sessionChanged,"shell_session_changed"),
   (ShellCapabilityBridgeFailure.timeout,"shell_timeout"),
   (ShellCapabilityBridgeFailure.operationFailed,"shell_operation_failed"),
   (ShellCapabilityBridgeFailure.capacity,"shell_capacity"),
   (NWError.posix(.ECONNRESET),"network_posix_54"),
   (NWError.tls(-9806),"network_tls_-9806"),
   (QuicBackendError(status:103),"quic_status_103"),
   (ScrcpyDeviceMessageError.unknownType(255),"device_message_type_255"),
   (ScrcpyDeviceMessageError.invalidClipboardLength(8192),"device_message_length"),
   (ScrcpySessionError.invalidPreamble,"scrcpy_invalid_preamble"),
   (ScrcpySessionError.serverNotFound,"scrcpy_server_missing"),
   (ScrcpySessionError.serverChecksumMismatch,"scrcpy_server_integrity"),
   (ScrcpyReverseTunnelError.listenerFailed(secret),"reverse_listener_failed"),
   (ScrcpyReverseTunnelError.listenerTimeout,"reverse_listener_timeout"),
   (ScrcpyReverseTunnelError.connectionTimeout,"reverse_connection_timeout"),
   (ScrcpyControlSocketError.closed,"control_socket_closed"),
   (ADBClientError.commandFailed(code:17,message:secret),"adb_command_17"),
   (ADBClientError.executableNotFound,"adb_missing"),
   (ADBClientError.bundledExecutableNotFound,"adb_bundle_missing"),
   (CancellationError(),"cancelled"),
   (NSError(domain:secret,code:37,userInfo:[NSLocalizedDescriptionKey:secret]),"other")]
  for (error,expected) in samples {
   let actual = MediaFailureDiagnostics.reason(error)
   precondition(actual == expected, "Unexpected bounded error classification")
   precondition(!actual.contains(secret))
  }
  precondition(MediaFailureDiagnostics.component(secret) == "other")
  precondition(MediaFailureDiagnostics.component("Video socket") == "video_socket")
  precondition(MediaFailureDiagnostics.stopResult(available:true,state:"stopped",errorCode:"",streams:0) == "available=1 state=stopped error=none streams=0")
  precondition(MediaFailureDiagnostics.stopResult(available:false,state:secret,errorCode:secret,streams:1) == "available=0 state=other error=other streams=1")
  print("PASS bounded media failure classification, shell stop metadata and payload redaction")
 }
}
