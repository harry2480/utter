import Testing
import UtterCore
import UtterSpeech
import UtterText

/// 入力の履歴への保存を記録する。本文は比較にだけ使う
@MainActor
private final class RecordingHistory: SessionHistoryRecording {
  private(set) var texts: [String] = []

  func record(
    _ text: String, session: SessionID,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext
  ) async {
    texts.append(text)
  }
}

/// クラウド STT を選んだ状態。認識はテストのイベントで進める（送信しない）
@MainActor
private final class SelectedCloudRecognition: SessionCloudSpeechRecognizing {
  private let recognizer: any SpeechRecognizer

  init(recognizer: any SpeechRecognizer) {
    self.recognizer = recognizer
  }

  var isSelected: Bool { true }

  func prepareRecognizer() async -> CloudSpeechRecognitionPreparation {
    .ready(recognizer)
  }
}

/// Realtime Direct（2.2節, AC-15。実験機能）の録音のセッションへの結線。
/// 認識はテストのイベント、入力欄は Stub（`FakeTextField`）で進め、書き込みは本物の `RealtimeDirectWriter` で行う。
@MainActor
struct SessionRealtimeDirectTests {
  private static let fieldID = InsertionTargetID(rawValue: "field")
  private static let app = "com.example.editor"
  private static let unsupportedNotice = "この入力先は Realtime Direct に対応していないため、停止後にまとめて入力します"

  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let hudScheduler = StubScheduler()
  let inserter = StubSessionInserter()
  let recorder = StubAudioRecorder()
  let recognizer = ScriptedSpeechRecognizer()
  let log = InsertionLog()
  /// 録音開始時の入力欄。「メモ: 」の後ろにカーソルがある
  let field = FakeTextField(value: "メモ: ")
  let inspector: StubInspector
  let hud: HUDController

  init() {
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: hudScheduler, now: { clock.now })
    // 挿入の Stub（`StubSessionInserter`）が記録する入力対象と同じ入力欄にフォーカスがある
    inspector = StubInspector(
      targets: [FocusedInsertionTarget(id: Self.fieldID, app: Self.app, secureField: .off)],
      recorded: Self.fieldID)
  }

  private func writer(
    allowlist: RealtimeDirectAllowlist? = nil, excludedApps: Set<String> = []
  ) -> RealtimeDirectWriter {
    RealtimeDirectWriter(
      inspector: inspector,
      field: StubFieldAccess(field: field, target: Self.fieldID, log: log),
      preview: StubPreview(log: log),
      allowlist: allowlist ?? RealtimeDirectAllowlist().adding([Self.app]),
      sensitivePolicy: { SensitiveInputPolicy(excludedApps: excludedApps) })
  }

  private func coordinator(
    writer: RealtimeDirectWriter?,
    inputMode: SessionInputMode = .realtimeDirect,
    history: (any SessionHistoryRecording)? = nil,
    cloudRecognition: (any SessionCloudSpeechRecognizing)? = nil
  ) -> SessionCoordinator {
    let clock = clock
    return SessionCoordinator(
      recorder: recorder,
      recognizer: recognizer,
      refiner: StubSessionRefiner(),
      inputMode: inputMode,
      inserter: inserter,
      history: history,
      hud: hud,
      deadlineScheduler: StubScheduler(),
      cloudRecognition: cloudRecognition,
      realtimeDirect: writer,
      now: { clock.now })
  }

  /// 録音を始め、認識が始まるのを待つ
  private func start(_ session: SessionCoordinator, run: Int = 0) async {
    session.toggle()
    #expect(await eventually { recognizer.runCount == run + 1 && recorder.isRecording })
  }

  /// HUD に一度でも `text` の通知を出したか
  private func showedNotice(_ text: String) -> Bool {
    presenter.shown.contains { ([$0.title] + $0.messages).contains(text) }
  }

  // MARK: - 書き込み

  @Test("AC-15: 確定済みチャンクを入力欄へ逐次書き込み、停止後に整形・一括挿入をしない")
  func writesConfirmedChunksDirectly() async {
    let history = RecordingHistory()
    let session = coordinator(writer: writer(), history: history)
    await start(session)

    recognizer.send(.partial("こんに"), to: 0)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    #expect(await eventually { field.value == "メモ: こんにちは。" })
    // 暫定の結果は書き込まず、HUD にも認識テキストを出さない
    #expect(log.sentInsertions.count == 1)
    #expect(presenter.current?.transcript == nil)

    session.toggle()
    recognizer.send(.confirmed("今日は"), to: 0)
    recognizer.send(.completed("こんにちは。今日は"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(field.value == "メモ: こんにちは。今日は")
    #expect(inserter.inserted.isEmpty)
    #expect(log.previews.isEmpty)
    #expect(history.texts == ["こんにちは。今日は"])
    #expect(presenter.shown.allSatisfy { $0.transcript == nil && $0.messages.isEmpty })
  }

  @Test("AC-15: 全体を書き込んで終えたら、元に戻すで書き込んだテキストだけを取り除く（一度だけ）")
  func undoRevertsWrittenText() async {
    let session = coordinator(writer: writer())
    #expect(session.undoRealtimeDirect() == nil)
    await start(session)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(session.canUndoRealtimeDirect)

    #expect(session.undoRealtimeDirect() == .reverted)
    #expect(field.value == "メモ: ")
    #expect(!session.canUndoRealtimeDirect)
    #expect(session.undoRealtimeDirect() == nil)
  }

  @Test("AC-15: 完了後に別の入力欄へフォーカスがあれば取り消さず、戻ってから取り消せる")
  func undoWaitsForFocus() async {
    let session = coordinator(writer: writer())
    await start(session)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })

    let other = InsertionTargetID(rawValue: "other")
    inspector.targets = [FocusedInsertionTarget(id: other, app: Self.app, secureField: .off)]
    #expect(session.undoRealtimeDirect() == .unavailable(.targetChanged))
    #expect(session.canUndoRealtimeDirect)
    #expect(field.value == "メモ: こんにちは。")

    inspector.targets = [FocusedInsertionTarget(id: Self.fieldID, app: Self.app, secureField: .off)]
    #expect(session.undoRealtimeDirect() == .reverted)
    #expect(field.value == "メモ: ")
  }

  @Test("AC-15, REC-01: キャンセルで書き込んだテキストを取り除き、挿入しない")
  func cancelRevertsWrittenText() async {
    let session = coordinator(writer: writer())
    await start(session)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    #expect(await eventually { field.value == "メモ: こんにちは。" })

    session.cancel()

    #expect(session.phase == .idle)
    #expect(field.value == "メモ: ")
    #expect(!session.canUndoRealtimeDirect)
    // キャンセルしたセッションの遅れたイベントは書き込まない
    recognizer.send(.confirmed("今日は"), to: 0)
    await Task.yield()
    #expect(field.value == "メモ: ")
    #expect(inserter.inserted.isEmpty)
  }

  // MARK: - 自動で無効にする

  @Test("AC-15: 許可リストにないアプリ（既定は全アプリ）では入力欄に触れず、停止後に一括挿入して HUD で知らせる")
  func unsupportedAppFallsBackToInstant() async {
    let session = coordinator(writer: writer(allowlist: .verified))
    await start(session)
    #expect(presenter.current?.messages == [Self.unsupportedNotice])

    recognizer.send(.confirmed("こんにちは。"), to: 0)
    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(log.events.isEmpty)
    #expect(inserter.inserted.map(\.text) == ["こんにちは。"])
    #expect(!session.canUndoRealtimeDirect)
    // 挿入を終えた後も、しばらく通知を残す
    #expect(presenter.current?.title == Self.unsupportedNotice)
  }

  @Test(
    "7章, AC-15: パスワード欄・除外アプリでは入力欄の値を読まず、停止後に一括挿入（挿入側の判定に任せる）する",
    arguments: [true, false])
  func sensitiveInputFallsBackToInstant(secureField: Bool) async {
    if secureField {
      inspector.targets = [
        FocusedInsertionTarget(id: Self.fieldID, app: Self.app, secureField: .on)
      ]
    }
    let session = coordinator(writer: writer(excludedApps: secureField ? [] : [Self.app]))
    await start(session)
    #expect(presenter.current?.messages == ["入力先が機密入力のため、Realtime Direct を使いません"])

    recognizer.send(.confirmed("秘密"), to: 0)
    session.toggle()
    recognizer.send(.completed("秘密"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(log.events.isEmpty)
    #expect(inserter.inserted.map(\.text) == ["秘密"])
  }

  @Test("AC-15: 何も書き込まないうちに書き込めなくなったら、停止後に一括挿入して HUD で知らせる")
  func stopBeforeWritingFallsBackToInstant() async {
    let session = coordinator(writer: writer())
    field.axSettable = false
    await start(session)
    #expect(presenter.current?.messages.isEmpty == true)

    recognizer.send(.confirmed("こんにちは。"), to: 0)
    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(field.value == "メモ: ")
    #expect(log.previews.isEmpty)
    #expect(inserter.inserted.map(\.text) == ["こんにちは。"])
    #expect(showedNotice("入力欄の変更などを検知したため、Realtime Direct をやめて停止後にまとめて入力します"))
  }

  @Test("AC-15, AC-09: 書き込んだ後に範囲外を編集されたら書き込みを残し、全体をプレビューに出して一括挿入しない")
  func stopAfterWritingShowsPreview() async {
    let session = coordinator(writer: writer())
    await start(session)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    #expect(await eventually { field.value == "メモ: こんにちは。" })

    // 利用者が先頭に書き足した（カーソルも同じだけずれる）
    field.value = "追記" + field.value
    field.selection = FieldSnapshot.Selection(location: 12, length: 0)
    recognizer.send(.confirmed("今日は"), to: 0)
    session.toggle()
    recognizer.send(.completed("こんにちは。今日は"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(field.value == "追記メモ: こんにちは。")
    #expect(inserter.inserted.isEmpty)
    #expect(
      log.previews == [
        .preview("こんにちは。今日は", .realtimeDirectStopped(.fieldChanged, wroteText: true))
      ])
    #expect(showedNotice("入力欄の変更などを検知したため、Realtime Direct の入力を途中でやめました"))
    // 範囲を確かめられないため、取り消しは出さない
    #expect(!session.canUndoRealtimeDirect)
  }

  @Test("AC-15, #188: クラウド STT では確定済みチャンクが届かないため使わず、停止後に一括挿入して HUD で知らせる")
  func cloudSpeechRecognitionFallsBackToInstant() async {
    let session = coordinator(
      writer: writer(), cloudRecognition: SelectedCloudRecognition(recognizer: recognizer))
    await start(session)
    #expect(
      presenter.current?.messages == [
        "クラウド音声認識では Realtime Direct を使えないため、停止後にまとめて入力します"
      ])

    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(log.events.isEmpty)
    #expect(inserter.inserted.map(\.text) == ["こんにちは。"])
  }

  // MARK: - 入力モード

  @Test("2.2節: Instant（既定）では書き込まず、設定で選んだ Realtime Direct は次のセッションから使う")
  func inputModeChangeAppliesToNextSession() async {
    let session = coordinator(writer: writer(), inputMode: .instant)
    await start(session)
    session.useSettings(SessionSettings(inputMode: .realtimeDirect))

    recognizer.send(.confirmed("前の発話"), to: 0)
    session.toggle()
    recognizer.send(.completed("前の発話"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(log.events.isEmpty)
    #expect(inserter.inserted.map(\.text) == ["前の発話"])

    await start(session, run: 1)
    recognizer.send(.confirmed("次の発話"), to: 1)
    #expect(await eventually { field.value == "メモ: 次の発話" })
    session.cancel()
    #expect(field.value == "メモ: ")
  }

  @Test("AC-15: 書き込みの部品がなければ、Realtime Direct を選んでいても使えない扱いにして一括挿入する")
  func missingWriterFallsBackToInstant() async {
    let session = coordinator(writer: nil)
    await start(session)
    #expect(presenter.current?.messages == [Self.unsupportedNotice])

    session.toggle()
    recognizer.send(.completed("こんにちは。"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(inserter.inserted.map(\.text) == ["こんにちは。"])
  }
}
