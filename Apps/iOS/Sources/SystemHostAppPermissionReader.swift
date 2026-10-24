import AVFoundation
import Speech
import UtteriOSKit

/// OS の権限の状態を読む（iAC-07）。読むだけで、権限は求めない（求めるのは `AudioEngineRecorder`）。
struct SystemHostAppPermissionReader: HostAppPermissionReader {
  func isMicrophoneDenied() -> Bool {
    AVAudioApplication.shared.recordPermission == .denied
  }

  func isSpeechRecognitionDenied() -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .denied, .restricted: true
    case .authorized, .notDetermined: false
    @unknown default: false
    }
  }
}
