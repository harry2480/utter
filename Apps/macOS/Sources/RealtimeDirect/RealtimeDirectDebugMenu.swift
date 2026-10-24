#if DEBUG
  import Observation
  import SwiftUI
  import UtterCore
  import UtterSpeech
  import UtterText

  /// Realtime Direct を実機で確かめるための Debug ビルド専用の操作（AC-15）。
  ///
  /// 録音・STT との結線は別 PR のため、Stub の認識イベント列（`StubSpeechRecognizer`）を `RealtimeDirectWriter` に流す。
  /// 許可リストは空のため、起動引数 `-UtterRealtimeDirectDebugApps <bundle ID>` で試すアプリを足す。
  /// メニューを選んだ後、試す入力欄にフォーカスを戻す時間（`focusDelay`）を待ってから入力対象を記録する。
  @MainActor
  @Observable
  final class RealtimeDirectDebugRunner {
    /// 流す認識イベント列。完了時の全体の確定テキストは、書き込み済みの途中を直す差分も試すため連結と変える
    static let steps: [StubSpeechRecognizer.Step] = [
      .partial("こんに"),
      .delay(.milliseconds(500)),
      .confirmed("こんにちは。"),
      .delay(.milliseconds(800)),
      .partial("今日は"),
      .delay(.milliseconds(500)),
      .confirmed("今日はいい"),
      .delay(.milliseconds(800)),
      .confirmed("天気です。"),
      .delay(.milliseconds(800)),
      .completed("こんにちは。今日は良い天気です。"),
    ]
    static let focusDelay = Duration.seconds(3)

    /// 直近の操作の結果。文字列の中身は含めない
    private(set) var status = "未実行"
    private(set) var isRunning = false
    @ObservationIgnored private let target: AccessibilityInsertionTarget
    @ObservationIgnored private let writer: RealtimeDirectWriter
    @ObservationIgnored private let allowlist: RealtimeDirectAllowlist

    init(
      target: AccessibilityInsertionTarget = AccessibilityInsertionTarget(),
      preview: any InsertionPreviewPresenting = InsertionPreviewPanel(),
      allowlist: RealtimeDirectAllowlist = .launchConfigured()
    ) {
      self.target = target
      self.allowlist = allowlist
      writer = RealtimeDirectWriter.system(target: target, preview: preview, allowlist: allowlist)
    }

    /// 許可リストに入っているアプリ（表示用）
    var allowedApps: String {
      allowlist.apps.isEmpty ? "なし（起動引数で追加）" : allowlist.apps.sorted().joined(separator: ", ")
    }

    func run() {
      guard !isRunning else { return }
      isRunning = true
      status = "入力欄にフォーカスを戻してください…"
      Task {
        defer { isRunning = false }
        try? await Task.sleep(for: Self.focusDelay)
        let session = SessionID()
        let recorded = target.recordTarget()
        if let failure = writer.begin(
          sessionID: session, recordedTarget: recorded, isEnabled: true)
        {
          status = "開始できません: \(failure)"
          return
        }
        status = "書き込み中…"
        let recognizer = StubSpeechRecognizer(steps: Self.steps)
        let audio = AsyncStream<AudioChunk> { $0.finish() }
        for await event in recognizer.recognize(audio, session: session) {
          writer.handle(event)
        }
        status = "終了: \(writer.session.map { "\($0.state)" } ?? "なし")"
      }
    }

    func undo() {
      status = "取り消し: \(writer.undo())"
    }
  }

  /// メニューバーの Debug 用の項目。
  struct RealtimeDirectDebugMenu: View {
    let runner: RealtimeDirectDebugRunner

    var body: some View {
      Menu("Realtime Direct（Debug）") {
        Text("許可リスト: \(runner.allowedApps)")
        Text("状態: \(runner.status)")
        Divider()
        Button("Stub の認識列を書き込む（3秒後に開始）") { runner.run() }
          .disabled(runner.isRunning)
        Button("書き込みを取り消す") { runner.undo() }
          .disabled(runner.isRunning)
      }
    }
  }
#endif
