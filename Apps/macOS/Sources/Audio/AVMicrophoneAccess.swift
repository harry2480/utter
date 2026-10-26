import AVFoundation
import UtterSpeech

/// macOS のマイクの使用許可（PERM-01）。`AVCaptureDevice` の音声の許可を使う。
///
/// 要求すると OS が Info.plist の `NSMicrophoneUsageDescription` を添えて利用者に尋ねる。
/// 尋ねるのは未確認のときの1回だけで、拒否された後はシステム設定で変えてもらう。
struct AVMicrophoneAccess: MicrophoneAccess {
  func authorization() async -> MicrophoneAuthorization {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .authorized
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    @unknown default: .denied
    }
  }

  func requestAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }
}
