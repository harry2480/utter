import Testing
import UtterAI
import UtterCore
import UtterSpeech

/// Edit Mode の1回の流れと、録音のセッションとの調停（AC-14, AC-06, AC-12）。
/// 録音・STT・AX・パネル・クラウド AI は Stub に置き換え、ネットワークに出ない。
@MainActor
struct EditModeControllerTests {
  private static let target = InsertionTargetID(rawValue: "edited")
  private static let app = "com.example.editor"
  /// 「明日は会議です。」の「会議」（UTF-16 で 3〜4）を選択した入力欄
  private static let value = "明日は会議です。"
  private static let selected = FieldSnapshot.Selection(location: 3, length: 2)
  private static let instruction = "会議を打ち合わせにして"

  let log = InsertionLog()
  let field = FakeTextField(
    value: EditModeControllerTests.value, selection: EditModeControllerTests.selected)
  let inspector = StubInspector(
    targets: [
      FocusedInsertionTarget(
        id: EditModeControllerTests.target, app: EditModeControllerTests.app, secureField: .off)
    ],
    recorded: EditModeControllerTests.target)
  let permissions = StubPermissions()
  let presenter = StubEditPresenter()
  let clock: StubClock
  let editField: StubEditField
  let provider = StubAIProvider(behavior: .respond("打ち合わせ"), destination: .claude)
  let recorder = StubAudioRecorder()
  let recognizer = ScriptedSpeechRecognizer()
  let gate = StubEditModeSessionGate()

  init() {
    clock = StubClock(log: log)
    editField = StubEditField(field: field, target: Self.target, log: log)
  }

  private static var editSelectionGranted: ConsentState {
    var consent = ConsentState()
    consent.grant(.transmission(.editSelection(.claude)))
    return consent
  }

  private func controller(
    consent: ConsentState = EditModeControllerTests.editSelectionGranted,
    recognizerAvailable: Bool = true,
    gate: (any EditModeSessionGate)? = nil
  ) throws -> EditModeController {
    let coordinator = EditModeCoordinator(
      inspector: inspector,
      field: editField,
      permissions: permissions,
      presenter: presenter,
      clock: clock,
      router: try EditRouter(provider: provider),
      consent: { consent })
    return EditModeController(
      coordinator: coordinator, recorder: recorder,
      recognizer: recognizerAvailable ? recognizer : nil, gate: gate ?? self.gate,
      presenter: presenter)
  }

  /// 始めて録音が始まるのを待つ
  private func startListening(_ controller: EditModeController, run: Int = 0) async {
    controller.toggle()
    #expect(controller.phase == .listening)
    #expect(await eventually { recognizer.runCount == run + 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
  }

  /// 録音を止めて、認識の結果を渡す
  private func finishListening(
    _ controller: EditModeController, run: Int = 0, text: String = instruction
  ) {
    controller.toggle()
    #expect(controller.phase == .recognizing)
    recognizer.send(.completed(text), to: run)
  }

  // MARK: 流れ

  @Test("AC-14: ショートカット → 録音 → STT → 差分プレビュー → 確定 → 元に戻す、の順に進む")
  func completesEdit() async throws {
    let controller = try controller()

    await startListening(controller)
    #expect(gate.isSuspended)
    #expect(presenter.currentStatus == .listening)
    finishListening(controller)
    #expect(await eventually { controller.phase == .reviewing })

    #expect(!recorder.isRecording)
    #expect(presenter.proposals == ["打ち合わせ"])
    #expect(presenter.currentStatus == nil)
    let request = try #require(await provider.receivedEditRequests.first)
    #expect(request.selection == "会議")
    #expect(request.instruction == Self.instruction)
    #expect(field.value == Self.value)
    // 確認中も録音のセッションを止めたまま
    #expect(gate.isSuspended)

    await controller.commit()
    #expect(field.value == "明日は打ち合わせです。")
    #expect(controller.phase == .idle)
    #expect(controller.canUndo)
    #expect(!gate.isSuspended)
    #expect(gate.resumeCount == 1)

    await controller.undo()
    #expect(field.value == Self.value)
    #expect(!controller.canUndo)
    #expect(!gate.isSuspended)
    #expect(gate.resumeCount == 2)
  }

  @Test("AC-14: 確認中にもう一度押すと、同じ選択テキストへの音声指示をやり直す")
  func reinstructWhileReviewing() async throws {
    let controller = try controller()
    await startListening(controller)
    finishListening(controller)
    #expect(await eventually { controller.phase == .reviewing })
    await provider.setBehavior(.respond("面談"))

    await startListening(controller, run: 1)
    finishListening(controller, run: 1, text: "面談にして")
    #expect(await eventually { presenter.proposals.count == 2 })
    #expect(controller.phase == .reviewing)

    await controller.commit()
    #expect(field.value == "明日は面談です。")
  }

  @Test("AC-14: キャンセルすると録音を止めて送らず、選択範囲を変えずに録音のセッションを再開する")
  func cancelWhileListening() async throws {
    let controller = try controller()
    await startListening(controller)

    controller.cancel()

    #expect(controller.phase == .idle)
    #expect(await eventually { !recorder.isRecording })
    #expect(await provider.editCallCount == 0)
    #expect(field.value == Self.value)
    #expect(!gate.isSuspended)
    #expect(presenter.currentStatus == nil)
  }

  @Test("AC-14: 空の音声指示は送らず、Edit を終える")
  func emptyInstructionIsNotSent() async throws {
    let controller = try controller()
    await startListening(controller)
    finishListening(controller, text: "  ")

    #expect(await eventually { controller.phase == .idle })
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.notEdited(.emptyInstruction)])
    #expect(!gate.isSuspended)
  }

  @Test("AC-14: 認識に失敗したら送らず、選択範囲を変えずに Edit を終える")
  func recognitionFailed() async throws {
    let controller = try controller()
    await startListening(controller)
    controller.toggle()
    recognizer.send(.failed(.engineFailed), to: 0)

    #expect(await eventually { controller.phase == .idle })
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.instructionNotRecorded(.recognitionFailed)])
    #expect(field.value == Self.value)
    #expect(!gate.isSuspended)
  }

  // MARK: 始めない

  @Test("AC-14: 音声認識のエンジンが未選択なら「音声認識が設定されていません」を出し、選択範囲を読まない")
  func speechRecognitionNotConfigured() async throws {
    let controller = try controller(recognizerAvailable: false)

    controller.toggle()

    #expect(controller.phase == .idle)
    #expect(presenter.notices == [.speechRecognitionNotConfigured])
    #expect(EditModeMessage.text(for: .speechRecognitionNotConfigured) == "音声認識が設定されていません")
    #expect(inspector.focusQueries == 0)
    #expect(!gate.isSuspended)
    #expect(!recorder.isRecording)
  }

  @Test("AC-14: 録音のセッション中は Edit を始めず、選択範囲を読まない")
  func doesNotStartDuringSession() async throws {
    gate.isIdle = false
    let controller = try controller()

    controller.toggle()

    #expect(controller.phase == .idle)
    #expect(presenter.notices == [.sessionInProgress])
    #expect(inspector.focusQueries == 0)
    #expect(!recorder.isRecording)
    #expect(gate.resumeCount == 0)
  }

  @Test("7章, AC-12: パスワード欄では始めず、録音もしない")
  func sensitiveInputAtStart() async throws {
    inspector.targets = [FocusedInsertionTarget(id: Self.target, app: Self.app, secureField: .on)]
    let controller = try controller()

    controller.toggle()

    #expect(controller.phase == .idle)
    #expect(presenter.notices == [.couldNotStart(.sensitiveInput([.secureField]))])
    #expect(!recorder.isRecording)
    #expect(!gate.isSuspended)
  }

  // MARK: 送らない

  @Test("AC-06: 選択テキストの送信に同意していなければ、整形に同意していても送らない")
  func consentNotGranted() async throws {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    let controller = try controller(consent: consent)
    await startListening(controller)
    finishListening(controller)

    #expect(await eventually { controller.phase == .idle })
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.notEdited(.consentNotGranted)])
    #expect(field.value == Self.value)
    #expect(!gate.isSuspended)
  }

  @Test("7章, AC-12: 音声指示を送る時点で入力欄がパスワード欄になっていたら送らない")
  func sensitiveInputAtSubmit() async throws {
    let controller = try controller()
    await startListening(controller)
    editField.secure = .on
    finishListening(controller)

    #expect(await eventually { controller.phase == .idle })
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.notEdited(.sensitiveInputSuppressed)])
    #expect(field.value == Self.value)
  }

  // MARK: 録音のセッションとの調停

  @Test("AC-14: 録音のセッション中は Edit を始めず、Edit の間は録音のセッションを始めない")
  func coordinatesWithRecordingSession() async throws {
    let presenterHUD = StubHUDPresenter()
    let hud = HUDController(presenter: presenterHUD, scheduler: StubScheduler())
    let session = SessionCoordinator(
      recorder: recorder,
      recognizer: StubSpeechRecognizer(steps: [.confirmed("こんにちは")]),
      refiner: StubSessionRefiner(),
      inserter: StubSessionInserter(),
      hud: hud,
      deadlineScheduler: StubScheduler())
    let controller = try controller(gate: session)

    // 録音のセッション中は Edit を始めない
    session.startRecording()
    #expect(session.phase == .recording)
    #expect(await eventually { recorder.isRecording })
    controller.toggle()
    #expect(controller.phase == .idle)
    #expect(presenter.notices == [.sessionInProgress])
    session.cancel()
    #expect(session.phase == .idle)
    #expect(await eventually { !recorder.isRecording })

    // Edit の間は録音のセッションを始めない
    await startListening(controller)
    session.startRecording()
    #expect(session.phase == .idle)
    controller.cancel()
    #expect(await eventually { !recorder.isRecording })

    // Edit を終えたら録音のセッションを始められる
    session.startRecording()
    #expect(session.phase == .recording)
    session.cancel()
  }
}

/// 録音のセッションを止める口の Stub。
@MainActor
final class StubEditModeSessionGate: EditModeSessionGate {
  /// 録音のセッションが待機中か
  var isIdle = true
  private(set) var isSuspended = false
  private(set) var resumeCount = 0

  func suspendIfIdle() -> Bool {
    guard isIdle, !isSuspended else { return false }
    isSuspended = true
    return true
  }

  func resume() {
    isSuspended = false
    resumeCount += 1
  }
}
