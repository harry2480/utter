import SwiftUI
import UtterPersistence
import UtteriOSKit

/// 待機セッションの開始・終了と設定（iOS-04・iOS-05）。
///
/// 待機を始めると、キーボードのマイクの操作で本体アプリへ移らずに録音できる。待機中もマイクは合図まで
/// ミュートされ、無操作が続くと自動で終わる。
struct StandbySection: View {
  let driver: StandbyDriver
  @State private var insertionMode: StandbyInsertionMode
  @State private var idleTimeoutMinutes: Int?
  private let preferences = StandbyPreferences()

  init(driver: StandbyDriver) {
    self.driver = driver
    let preferences = StandbyPreferences()
    _insertionMode = State(initialValue: preferences.insertionMode)
    _idleTimeoutMinutes = State(initialValue: preferences.idleTimeoutMinutes)
  }

  var body: some View {
    Section {
      Button {
        Task {
          if driver.isStandingBy {
            await driver.end()
          } else {
            await driver.start()
          }
        }
      } label: {
        Label(
          driver.isStandingBy ? "待機を終える" : "待機を始める",
          systemImage: driver.isStandingBy ? "stop.circle" : "mic.badge.plus")
      }
      if let message = statusMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Picker("停止後の挿入", selection: $insertionMode) {
        Text("自動で挿入").tag(StandbyInsertionMode.automatic)
        Text("プレビューして挿入").tag(StandbyInsertionMode.preview)
      }
      .onChange(of: insertionMode) { _, mode in preferences.insertionMode = mode }
      Picker("無操作で終える", selection: $idleTimeoutMinutes) {
        ForEach(StandbyPreferences.idleTimeoutChoices, id: \.self) { minutes in
          Text(minutes.map { "\($0) 分" } ?? "終えない").tag(minutes)
        }
      }
      .disabled(driver.isStandingBy)
      .onChange(of: idleTimeoutMinutes) { _, minutes in preferences.idleTimeoutMinutes = minutes }
    } header: {
      Text("キーボードで録音")
    } footer: {
      Text(
        "待機中は、キーボードのマイクの操作で本体アプリへ移らずに録音できます。待機中もマイクは使わず（入力はミュート）、録音を始めたときだけ使います。"
      )
    }
  }

  private var statusMessage: String? {
    if driver.startFailed { return "待機を始められませんでした。マイクを使えない状態です。" }
    let coordinator = driver.coordinator
    switch coordinator.hostPhase {
    case .off: return nil
    case .standby: return "待機中です。キーボードのマイクの操作で録音できます。"
    case .recording: return "録音中です。"
    case .processing: return "文字にしています。"
    case .done: return "結果をキーボードへ渡しました。"
    case .failed: return coordinator.failure.map(Self.message) ?? "録音を捨てました。"
    }
  }

  private static func message(for failure: StandbyFailure) -> String {
    switch failure {
    case .keyboardDismissed: "キーボードが閉じられたため、録音を捨てました。"
    case .keyboardHeartbeatLost: "キーボードの反応が途絶えたため、録音を捨てました。"
    case .captureLimitExceeded: "録音の上限を超えたため、録音を捨てました。"
    case .interrupted: "着信などで途切れたため、録音を捨てました。"
    case .supersededBySession: "別の録音が始まったため、前の録音を捨てました。"
    case .standbyEnded: "待機を終えたため、録音を捨てました。"
    case .noSpeech: "話した内容を認識できませんでした。"
    case .processingFailed: "文字にできませんでした。"
    }
  }
}
