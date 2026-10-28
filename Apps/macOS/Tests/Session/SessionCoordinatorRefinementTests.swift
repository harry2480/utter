import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// セッションの調停と整形・入力履歴の結線（AI-01, AC-06, AC-12, AC-16, 7章）。
/// 録音・認識・挿入・HUD は Stub、Claude API への送信は数えるだけの送信部に置き換える。
@MainActor
struct SessionCoordinatorRefinementTests {
  private static let transcript = "えーと明日の会議は10時からです"

  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let inserter = StubSessionInserter()
  let reporter = StubRefinementReporter()
  let retention = StubAudioRetention()
  let hud: HUDController
  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: StubScheduler(), now: { clock.now })
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func coordinator(
    _ settings: AppSettings, transport: CountingTransport, recorder: StubAudioRecorder,
    historyEnabledWhenWriting: Bool = true
  ) throws -> SessionCoordinator {
    try store.save(settings)
    let database = database
    let clock = clock
    return SessionCoordinator(
      recorder: recorder,
      recognizer: StubSpeechRecognizer(steps: [.confirmed(Self.transcript)]),
      refiner: SessionRefinementPipeline(
        settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
        database: { database },
        makeProvider: { configuration, keys in
          ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: transport)
        },
        now: { RefinementSettings.now }, calendar: RefinementSettings.calendar),
      refinementReporter: reporter,
      inserter: inserter,
      history: InputHistoryRecorder(
        settingsStore: store, historyEnabled: { historyEnabledWhenWriting },
        database: { database }, now: { RefinementSettings.now }),
      hud: hud,
      deadlineScheduler: StubScheduler(),
      audioRetention: retention,
      now: { clock.now })
  }

  /// 録音して止め、待機へ戻るまで進める
  /// - Parameter whileRecording: 録音中に1回呼ぶ。録音の開始時の入力先が機密入力なら録音を始めないため、
  ///   送信・保存の直前の判定を確かめるテストは、ここで入力先を変える
  private func runSession(
    _ session: SessionCoordinator, recorder: StubAudioRecorder,
    whileRecording: () -> Void = {}
  ) async {
    session.toggle()
    #expect(await eventually { recorder.isRecording })
    whileRecording()
    session.toggle()
    #expect(await eventually { session.phase == .idle })
    // 履歴の保存は一時音声の差し込み口に終わりを伝える前に終わる
    #expect(await eventually { retention.events.contains(where: Self.isEnd) })
  }

  /// 1行目・通知・段階が同じ表示か（チップ・送信先などを除いて比べる）
  private static func sameText(_ lhs: HUDPresentation, _ rhs: HUDPresentation) -> Bool {
    lhs.title == rhs.title && lhs.messages == rhs.messages && lhs.stage == rhs.stage
  }

  private static func isEnd(_ event: StubAudioRetention.Event) -> Bool {
    if case .end = event { true } else { false }
  }

  private func historyTexts() throws -> [String] {
    try InputHistoryStore(database: database).entries().map(\.text)
  }

  // MARK: 整形

  @Test("AI-01, AC-06: 条件がそろえば Claude の整形結果を挿入し、経路を知らせる")
  func insertsCloudRefinement() async throws {
    let transport = CountingTransport()
    let recorder = StubAudioRecorder()
    let session = try coordinator(
      RefinementSettings.ready(), transport: transport, recorder: recorder)

    await runSession(session, recorder: recorder)

    #expect(transport.count == 1)
    #expect(inserter.inserted.map(\.text) == ["明日の会議は10時からです。"])
    #expect(reporter.routes == [.cloud])
  }

  @Test("AC-06, AI-03: 同意がなければ送らず（送信 0 件）、Local Basic の結果を挿入する")
  func insertsLocalBasicWithoutConsent() async throws {
    var settings = RefinementSettings.ready()
    settings.consentState = ConsentState()
    let transport = CountingTransport()
    let recorder = StubAudioRecorder()
    let session = try coordinator(settings, transport: transport, recorder: recorder)

    await runSession(session, recorder: recorder)

    #expect(transport.count == 0)
    #expect(
      inserter.inserted.map(\.text) == [
        LocalBasicRefiner().refine(RefinementRequest(text: Self.transcript, mode: .natural))
      ])
    #expect(reporter.routes == [.localOnly(.consentNotGranted)])
  }

  @Test("AC-12: 録音中に挿入先が機密入力になったら送らない（送信 0 件）。判定は送る直前の入力先で行う")
  func sensitiveTargetIsNotSent() async throws {
    let transport = CountingTransport()
    let recorder = StubAudioRecorder()
    let session = try coordinator(
      RefinementSettings.ready(), transport: transport, recorder: recorder)

    await runSession(session, recorder: recorder) {
      inserter.sensitiveContext = SensitiveInputContext(
        secureField: .on, secureEventInput: .off, app: "com.example.editor")
    }

    #expect(transport.count == 0)
    #expect(inserter.sensitiveContextRequests >= 1)
    #expect(reporter.routes == [.localOnly(.sensitiveInput)])
  }

  @Test("AC-16: クラウド整形が失敗したら退避した経路を知らせ、ローカル整形の結果を挿入する")
  func reportsFallback() async throws {
    let transport = CountingTransport(.status(500))
    let recorder = StubAudioRecorder()
    let session = try coordinator(
      RefinementSettings.ready(), transport: transport, recorder: recorder)

    await runSession(session, recorder: recorder)

    #expect(transport.count == 1)
    guard case .cloudFallback(let reason) = reporter.routes.first else {
      Issue.record("退避を知らせていない: \(reporter.routes)")
      return
    }
    #expect(inserter.inserted.count == 1)
    // HUD: 整形中から退避の通知を出し、挿入完了後も通知だけを残す
    let notice = HUDNotice.refinementFellBack(RefinementFallbackNotice(reason: reason))
    let refining = try #require(HUDPresentation(HUDContent(status: .refining, notice: notice)))
    let inserting = try #require(HUDPresentation(HUDContent(status: .inserting, notice: notice)))
    #expect(presenter.shown.contains { Self.sameText($0, refining) })
    #expect(presenter.shown.contains { Self.sameText($0, inserting) })
    #expect(presenter.current == HUDPresentation(HUDContent(status: nil, notice: notice)))
    // 送ると決めた整形中は送信先を出す（REC-03）
    #expect(presenter.shown.contains { $0.title == "整形中" && $0.destination == "Claude へ送信" })
  }

  @Test("AC-16: 送らなかったとき（同意なし）・クラウド整形が通ったときは、退避の通知を出さない")
  func noFallbackNoticeWithoutFallback() async throws {
    for consented in [false, true] {
      presenter.reset()
      var settings = RefinementSettings.ready()
      if !consented { settings.consentState = ConsentState() }
      let recorder = StubAudioRecorder()
      let session = try coordinator(settings, transport: CountingTransport(), recorder: recorder)

      await runSession(session, recorder: recorder)

      #expect(!presenter.shown.isEmpty)
      let shown = presenter.shown
      #expect(shown.allSatisfy { $0.messages.isEmpty })
      #expect(presenter.current == nil)
      // 送信先は送ったときだけ出す（REC-03, AC-06）
      let destinations = shown.compactMap(\.destination)
      #expect(destinations == (consented ? ["Claude へ送信"] : []))
    }
  }

  // MARK: 入力履歴

  @Test("7章, AC-12: 履歴が有効で機密入力でなければ、挿入した本文を履歴に保存する")
  func recordsHistory() async throws {
    var settings = RefinementSettings.ready(historyEnabled: true)
    settings.refinementEngine = .localBasic
    let recorder = StubAudioRecorder()
    let session = try coordinator(settings, transport: CountingTransport(), recorder: recorder)

    await runSession(session, recorder: recorder)

    let inserted = try #require(inserter.inserted.first?.text)
    #expect(try historyTexts() == [inserted])
  }

  enum HistorySkip: String, CaseIterable, Sendable {
    /// 設定で無効（既定）
    case disabled
    /// 書き込みの時点で無効になった
    case disabledWhileWriting
    /// 入力先が機密入力
    case sensitiveInput
    /// 入力先を判定できない
    case undetermined
    /// プレビューへ退避した
    case preview
  }

  @Test("7章, AC-12: 履歴が無効・機密入力・判定不能・プレビューへの退避なら保存しない", arguments: HistorySkip.allCases)
  func skipsHistory(_ skip: HistorySkip) async throws {
    var settings = RefinementSettings.ready(historyEnabled: skip != .disabled)
    settings.refinementEngine = .localBasic
    // 機密入力・判定不能は、録音の開始時なら録音を始めないため、録音中に入力先が変わった場合で確かめる
    var contextWhileRecording: SensitiveInputContext?
    switch skip {
    case .disabled, .disabledWhileWriting:
      break
    case .sensitiveInput:
      contextWhileRecording = SensitiveInputContext(
        secureField: .off, secureEventInput: .on, app: "com.example.editor")
    case .undetermined:
      contextWhileRecording = SensitiveInputContext(
        secureField: .unknown, secureEventInput: .off, app: nil)
    case .preview:
      inserter.outcome = .preview(.plan(.targetChanged))
    }
    let recorder = StubAudioRecorder()
    let session = try coordinator(
      settings, transport: CountingTransport(), recorder: recorder,
      historyEnabledWhenWriting: skip != .disabledWhileWriting)

    await runSession(session, recorder: recorder) {
      if let contextWhileRecording { inserter.sensitiveContext = contextWhileRecording }
    }

    #expect(inserter.inserted.count == 1)
    #expect(try historyTexts().isEmpty)
  }
}
