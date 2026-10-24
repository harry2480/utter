// Phase i0 検証用（#56, #53）の本体アプリ。本番コードではない。

import SwiftUI
import UIKit

@main
struct ProbeApp: App {
  @State private var model = AppProbeModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onOpenURL { model.handleOpenURL($0) }
    }
  }
}

/// 本体アプリの検証操作と記録。記録はメモリ上だけに持ち、ファイルやログには出さない。
@MainActor
@Observable
final class AppProbeModel {
  var selectedProtection: ProbeProtection = .completeUntilFirstUserAuthentication
  var text: String = ProbeConfig.dummyText
  var lockTestDelaySeconds: Int = 20
  private(set) var lockTestStatus: String = "未実行"
  private(set) var isLockTestRunning = false
  private(set) var outcomes: [ProbeOutcome] = []
  private(set) var events: [String] = []
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var lockTestTask: Task<Void, Never>?
  /// 画面表示用。保護データの通知・scenePhase の変化・ロック中テストの実行時に更新する。
  private(set) var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable

  /// バックグラウンド実行は通常30秒前後で打ち切られるため、待ち時間の上限はそれより短くする。
  static let lockTestDelayRange = 5...25

  func refreshProtectedDataAvailability() {
    protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
  }

  func protectedDataChanged(available: Bool) {
    refreshProtectedDataAvailability()
    appendEvent(
      available ? "保護データが利用可能になった（解除）" : "保護データが利用不可になる（ロック）")
  }

  // MARK: 共有コンテナ（#56）

  func writeSelected() {
    record(
      ProbeStore.write(
        fileName: selectedProtection.resultFileName, text: text, protection: selectedProtection,
        writer: "app"))
  }

  func writeAllClasses() {
    for protection in ProbeProtection.allCases {
      record(
        ProbeStore.write(
          fileName: protection.resultFileName, text: text, protection: protection, writer: "app"))
    }
  }

  func readAllClasses() {
    for protection in ProbeProtection.allCases {
      record(ProbeStore.read(fileName: protection.resultFileName).0)
    }
  }

  func readKeyboardWrite() {
    record(ProbeStore.read(fileName: ProbeConfig.keyboardWriteFileName).0)
  }

  func deleteAll() {
    record(ProbeStore.deleteAll())
  }

  // MARK: ロック中の読み書き（iOS-IPC-05）

  /// 指定秒数後に、全保護クラスの読み込みと新規ファイルへの書き込みを試す。
  /// 開始直後に端末をロックする。バックグラウンドの実行時間（通常30秒前後）を超えると打ち切られる。
  func startLockTest() {
    guard !isLockTestRunning else { return }
    isLockTestRunning = true
    for protection in ProbeProtection.allCases {
      _ = ProbeStore.delete(fileName: protection.lockTestFileName)
    }
    let delay = lockTestDelaySeconds
    lockTestStatus = "開始 \(ProbeTime.format(Date()))。すぐにロックし、\(delay)秒以上待ってから解除する"
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LockTest") { [weak self] in
      self?.finishLockTest(reason: "バックグラウンド実行時間が切れて打ち切られた")
    }
    lockTestTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return  // 打ち切り・再開始でキャンセルされた回は本体を実行しない
      }
      self?.runLockTestBody()
    }
  }

  private func runLockTestBody() {
    guard isLockTestRunning, !Task.isCancelled else { return }
    refreshProtectedDataAvailability()
    let remaining = UIApplication.shared.backgroundTimeRemaining
    let remainingText = remaining > 10_000 ? "前面" : String(format: "%.1f秒", remaining)
    appendEvent(
      "ロック中テスト実行: isProtectedDataAvailable=\(protectedDataAvailable)、残り実行時間 \(remainingText)")
    for protection in ProbeProtection.allCases {
      record(ProbeStore.read(fileName: protection.resultFileName, action: "ロック中テスト 読み込み").0)
    }
    for protection in ProbeProtection.allCases {
      record(
        ProbeStore.write(
          fileName: protection.lockTestFileName, text: ProbeConfig.dummyText,
          protection: protection, writer: "app-locktest", action: "ロック中テスト 新規書き込み"))
    }
    finishLockTest(reason: "完了")
  }

  private func finishLockTest(reason: String) {
    guard isLockTestRunning else { return }
    isLockTestRunning = false
    lockTestTask?.cancel()
    lockTestTask = nil
    lockTestStatus = "\(reason) \(ProbeTime.format(Date()))"
    appendEvent("ロック中テスト: \(reason)")
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  // MARK: 導線と復帰（#53）

  func handleOpenURL(_ url: URL) {
    let route =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "via" }?.value ?? "不明"
    appendEvent("URL から起動された（via=\(route)）")
  }

  func appendEvent(_ message: String) {
    events.insert("\(ProbeTime.format(Date())) \(message)", at: 0)
    if events.count > 200 { events.removeLast(events.count - 200) }
  }

  // MARK: 記録

  private func record(_ outcome: ProbeOutcome) {
    outcomes.insert(outcome, at: 0)
    if outcomes.count > 300 { outcomes.removeLast(outcomes.count - 300) }
  }

  /// 手順書へ転記するためのテキスト。パス・端末識別子は含めない。
  var reportText: String {
    var lines = ["[utter Keyboard Probe 本体アプリ]", "App Group: \(ProbeStore.containerStatus)"]
    lines.append("--- イベント（新しい順）")
    lines.append(contentsOf: events)
    lines.append("--- 操作結果（新しい順）")
    lines.append(contentsOf: outcomes.map(\.line))
    return lines.joined(separator: "\n")
  }

  func copyReport() {
    UIPasteboard.general.string = reportText
    appendEvent("記録をクリップボードにコピーした")
  }
}
