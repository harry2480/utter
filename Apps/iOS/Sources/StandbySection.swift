import SwiftUI
import UtterPersistence
import UtteriOSKit

/// 待機セッションの開始・終了と設定（iOS-04・iOS-05）。
///
/// 待機を始めると、キーボードのマイクの操作で本体アプリへ移らずに録音できる。待機中もマイクは合図まで
/// ミュートされ、無操作が続くと自動で終わる。
struct StandbySection: View {
  let driver: StandbyDriver
  /// 本体アプリで録音中（または認識中）か。待機は録音が済んでから始める
  let isRecording: Bool
  @State private var insertionMode: StandbyInsertionMode
  @State private var idleTimeoutMinutes: Int
  private let preferences = StandbyPreferences()

  init(driver: StandbyDriver, isRecording: Bool) {
    self.driver = driver
    self.isRecording = isRecording
    let preferences = StandbyPreferences()
    _insertionMode = State(initialValue: preferences.insertionMode)
    _idleTimeoutMinutes = State(initialValue: preferences.idleTimeoutMinutes)
  }

  var body: some View {
    VStack(spacing: 20) {
      statusCard
      settingsCard
    }
  }

  /// 待機の状態と、始める・やめるボタン（設計: 待機していない／待機中）
  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        UtterStatusDot(color: driver.isStandingBy ? .utterAccent : .utterIdleDot)
        Text(driver.isStandingBy ? "待機中" : "待機していません")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(Color.utterText)
      }
      .accessibilityElement(children: .combine)
      Text(
        driver.isStandingBy
          ? (driver.coordinator.hostPhase == .standby
            ? "マイクは止めています。キーボードのマイクを押すまで、音は拾いません。"
            : (driver.coordinator.hostPhase == .recording
              ? "キーボードの操作で録音の途中です。終わると、また待機に戻ります。"
              : "認識と整形を行っています。結果は、キーボードの操作で確かめてください。"))
          : "待機を始めると、ほかのアプリを使いながら、キーボードのマイクで話して文章を入れられます。アプリの切り替えは要りません。"
      )
      .font(.system(size: 15))
      .lineSpacing(5)
      .foregroundStyle(Color.utterSecondary)
      if driver.isStandingBy {
        steps
        Button("待機をやめる") { Task { await driver.end() } }
          .buttonStyle(UtterOutlineButtonStyle())
      } else {
        Button("待機を始める") { Task { await driver.start() } }
          .buttonStyle(UtterFilledButtonStyle(height: 56))
          .disabled(isRecording)
        Text("何もしないまま \(idleTimeoutMinutes) 分たつと、自動で終わります。")
          .font(.system(size: 13))
          .lineSpacing(3)
          .foregroundStyle(Color.utterSecondary)
      }
      if let message = statusMessage {
        Text(message)
          .font(.system(size: 13))
          .foregroundStyle(Color.utterSecondary)
      }
    }
    .utterCard(padding: EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 10) {
      step(1, "文章を入れたいアプリに戻る")
      step(2, "utter キーボードの「話す」を押す")
      step(
        3,
        insertionMode == .preview
          ? "話し終えたら止める。確かめて「カーソルの位置に入れる」を押す" : "話し終えたら止める。文章が自動で入る")
    }
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(spacing: 12) {
      Text("\(number)")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Color.utterOnStrongFill)
        .frame(width: 26, height: 26)
        .background(Color.utterStrongFill, in: Circle())
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 15))
        .foregroundStyle(Color.utterText)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(number). \(text)")
  }

  /// 停止後の挿入のしかたと、無操作で終えるまでの時間
  private var settingsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      UtterSectionLabel("キーボードで録音")
      VStack(spacing: 0) {
        HStack {
          Text("入れ方").foregroundStyle(Color.utterText)
          Spacer()
          Picker("停止後の挿入", selection: $insertionMode) {
            Text("止めたら自動で挿入").tag(StandbyInsertionMode.automatic)
            Text("確かめてから挿入").tag(StandbyInsertionMode.preview)
          }
          .labelsHidden()
          .onChange(of: insertionMode) { _, mode in preferences.insertionMode = mode }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        Divider().overlay(Color.utterLine)
        HStack {
          Text("無操作で終える").foregroundStyle(Color.utterText)
          Spacer()
          Picker("無操作で終える", selection: $idleTimeoutMinutes) {
            ForEach(StandbyPreferences.idleTimeoutChoices, id: \.self) { minutes in
              Text("\(minutes) 分").tag(minutes)
            }
          }
          .labelsHidden()
          .disabled(driver.isStandingBy)
          .onChange(of: idleTimeoutMinutes) { _, minutes in
            preferences.idleTimeoutMinutes = minutes
          }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
      }
      .font(.system(size: 15))
      .background(Color.utterCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      Text("待機中もマイクは使わず（入力はミュート）、録音を始めたときだけ使います。")
        .font(.system(size: 13))
        .foregroundStyle(Color.utterSecondary)
        .padding(.horizontal, 4)
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
