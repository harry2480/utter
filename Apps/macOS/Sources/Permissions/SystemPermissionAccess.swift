import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid
import Speech
import UtterCore

/// macOS の権限 API による `PermissionAccess`。
///
/// - マイク: `AVCaptureDevice`
/// - 音声認識: `SFSpeechRecognizer`（用途説明が Info.plist にない間は要求しない）
/// - Accessibility: `AXIsProcessTrusted`。OS が「未確認」と「拒否」を区別しないため、要求したことを `PermissionDefaults` に覚えて分ける
/// - 入力監視: `IOHIDCheckAccess` / `IOHIDRequestAccess`
@MainActor
struct SystemPermissionAccess: PermissionAccess {
  let defaults: PermissionDefaults

  func currentSnapshot() -> PermissionSnapshot {
    PermissionSnapshot([
      .microphone: Self.microphoneStatus(),
      .speechRecognition: Self.speechRecognitionStatus(),
      .accessibility: AXIsProcessTrusted()
        ? .granted : (defaults.hasRequestedAccessibility ? .denied : .notDetermined),
      .inputMonitoring: Self.inputMonitoringStatus(),
    ])
  }

  func request(_ permission: AppPermission) async {
    switch permission {
    case .microphone:
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    case .speechRecognition:
      // 用途説明なしで要求するとアプリが終了する。使う STT が決まり用途説明を足すまで要求しない（#48）
      guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
      else {
        assertionFailure("音声認識を要件に入れたら Info.plist に NSSpeechRecognitionUsageDescription を足す")
        return
      }
      await withCheckedContinuation { continuation in
        // コールバックは別のキューから呼ばれるため、MainActor に隔離しない
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in continuation.resume() }
      }
    case .accessibility:
      defaults.hasRequestedAccessibility = true
      Self.promptAccessibility()
    case .inputMonitoring:
      _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
  }

  func openSystemSettings(for permission: AppPermission) {
    if permission == .accessibility {
      // システム設定の一覧から utter が消されていても載せ直されるよう、プロンプト付きで確かめてから開く
      Self.promptAccessibility()
    }
    let anchor =
      switch permission {
      case .microphone: "Privacy_Microphone"
      case .speechRecognition: "Privacy_SpeechRecognition"
      case .accessibility: "Privacy_Accessibility"
      case .inputMonitoring: "Privacy_ListenEvent"
      }
    guard
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private static func promptAccessibility() {
    // kAXTrustedCheckOptionPrompt は Swift 6 で並行性安全でないグローバル変数として見えるため、同じ値の文字列を使う
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  private static func microphoneStatus() -> PermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .notDetermined
    @unknown default: .notDetermined
    }
  }

  private static func speechRecognitionStatus() -> PermissionStatus {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: .granted
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .notDetermined
    @unknown default: .notDetermined
    }
  }

  private static func inputMonitoringStatus() -> PermissionStatus {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: .granted
    case kIOHIDAccessTypeDenied: .denied
    default: .notDetermined
    }
  }
}
