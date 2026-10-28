import Testing

@testable import UtterCore

/// HUD の経過時間・音量・チップ・キーの案内・処理の段階・送信先・挿入完了の組み立て（REC-03, REC-05）。
struct HUDSessionInfoPresentationTests {
  private static let details = HUDSessionDetails(
    refinement: HUDRefinementSummary(mode: .natural, style: .concise), appName: "Slack",
    speechRecognition: .local)
  private static let hints = HUDKeyHints(stopKey: "⌥Space", cancelKey: "Esc")

  private func presentation(
    _ status: HUDStatus?, notices: [HUDNotice] = [], insertion: HUDInsertion? = nil,
    info: HUDSessionInfo = HUDSessionInfo()
  ) throws -> HUDPresentation {
    try #require(
      HUDPresentation(
        HUDContent(status: status, notices: notices, insertion: insertion), info: info))
  }

  @Test(
    "REC-05: 経過時間と最大録音時間を分:秒で出す",
    arguments: [
      (Duration.seconds(7), Duration.seconds(300) as Duration?, "0:07 / 5:00"),
      (.milliseconds(65_900), .seconds(300), "1:05 / 5:00"),
      (.seconds(400), .seconds(300), "5:00 / 5:00"),
      (.seconds(-1), .seconds(90), "0:00 / 1:30"),
      (.seconds(605), nil, "10:05"),
    ] as [(Duration, Duration?, String)])
  func recordingTimeText(elapsed: Duration, limit: Duration?, text: String) {
    #expect(HUDRecordingTime(elapsed: elapsed, limit: limit).text == text)
  }

  @Test(
    "REC-03: 入力音量はサンプルの実効値から点灯する本数にする",
    arguments: [
      ([Float](), 0),
      ([Float](repeating: 0, count: 160), 0),
      ([Float](repeating: 0.001, count: 160), 0),
      ([Float](repeating: 0.005, count: 160), 1),
      ([Float](repeating: -0.05, count: 160), 3),
      ([Float](repeating: 1, count: 160), 5),
      ([Float.nan, 1, -1, 1], 5),
    ] as [([Float], Int)])
  func inputLevel(samples: [Float], bars: Int) {
    #expect(HUDInputLevel(samples: samples).bars == bars)
  }

  @Test("REC-03: 点灯する本数は 0〜barCount に収める")
  func inputLevelIsClamped() {
    #expect(HUDInputLevel(bars: -1).bars == 0)
    #expect(HUDInputLevel(bars: HUDInputLevel.barCount + 1).bars == HUDInputLevel.barCount)
  }

  @Test("REC-03, REC-05: 録音中は経過時間・レベルメーター・チップ・停止とキャンセルのキーを出す")
  func recordingShowsSessionInfo() throws {
    let info = HUDSessionInfo(
      details: Self.details,
      recordingTime: HUDRecordingTime(elapsed: .seconds(7), limit: .seconds(300)),
      inputLevel: HUDInputLevel(bars: 3), keyHints: Self.hints)
    let recording = try presentation(.recording, info: info)

    #expect(recording.title == "録音中")
    #expect(recording.recordingTimeText == "0:07 / 5:00")
    #expect(recording.inputLevelBars == 3)
    #expect(recording.chips == ["Natural", "Slack：簡潔", "ローカルSTT"])
    let stop = HUDKeyHint(key: "⌥Space", action: "停止")
    let cancel = HUDKeyHint(key: "Esc", action: "キャンセル")
    #expect(recording.keyHints == [stop, cancel])
    #expect(recording.stage == nil)
    #expect(recording.destination == nil)
    // 録音中は読み上げない（音声がマイクに入るため）
    #expect(recording.announcement == nil)
  }

  @Test("REC-03: 音量がまだ届いていない録音中は、レベルメーターを0本で出す")
  func recordingWithoutLevelShowsEmptyMeter() throws {
    #expect(try presentation(.recording).inputLevelBars == 0)
  }

  @Test("REC-03: Raw はスタイルを使わないため、アプリ別スタイルのチップを出さない")
  func rawModeOmitsStyleChip() throws {
    let details = HUDSessionDetails(
      refinement: HUDRefinementSummary(mode: .raw, style: .concise), appName: "Slack",
      speechRecognition: .cloud)
    let recording = try presentation(.recording, info: HUDSessionInfo(details: details))
    #expect(recording.chips == ["Raw", "クラウドSTT"])
  }

  @Test("REC-03: 前面アプリの表示名が分からなければ、スタイルだけのチップにする")
  func styleChipWithoutAppName() throws {
    let details = HUDSessionDetails(
      refinement: HUDRefinementSummary(mode: .structured, style: .document), appName: nil,
      speechRecognition: .local)
    let recording = try presentation(.recording, info: HUDSessionInfo(details: details))
    #expect(recording.chips == ["Structured", "文書", "ローカルSTT"])
  }

  @Test("REC-02: Push-to-talk は「離して停止」と出す。使えないキーは出さない")
  func keyHintsFollowAvailableKeys() throws {
    let pushToTalk = try presentation(
      .recording,
      info: HUDSessionInfo(keyHints: HUDKeyHints(stopKey: "Fn", stopsOnRelease: true)))
    #expect(pushToTalk.keyHints == [HUDKeyHint(key: "Fn", action: "離して停止")])

    let none = try presentation(.recording)
    #expect(none.keyHints.isEmpty)
  }

  @Test(
    "REC-01, REC-03: 処理中は4段階のどこにいるかを出し、キャンセルが効く間だけキャンセルのキーを出す",
    arguments: [
      (HUDStatus.recognizing, HUDProcessingStage.recognition, true),
      (.refining, .refinement, true),
      (.inserting, .insertion, false),
    ] as [(HUDStatus, HUDProcessingStage, Bool)])
  func processingShowsStage(
    status: HUDStatus, stage: HUDProcessingStage, cancellable: Bool
  ) throws {
    let processing = try presentation(
      status,
      info: HUDSessionInfo(
        details: Self.details,
        recordingTime: HUDRecordingTime(elapsed: .seconds(7), limit: .seconds(300)),
        inputLevel: HUDInputLevel(bars: 3), keyHints: Self.hints))

    #expect(processing.stage == stage)
    let cancel = HUDKeyHint(key: "Esc", action: "キャンセル（挿入しません）")
    #expect(processing.keyHints == (cancellable ? [cancel] : []))
    // 録音中だけの情報は出さない
    #expect(processing.recordingTimeText == nil)
    #expect(processing.inputLevelBars == nil)
    #expect(processing.chips.isEmpty)
  }

  @Test("REC-03: 4段階の名前")
  func stageLabels() {
    #expect(HUDProcessingStage.allCases.map(\.label) == ["録音", "認識", "整形", "挿入"])
  }

  @Test("REC-01: 失敗の表示中は段階もキーの案内も出さない")
  func failureShowsNoStageOrHints() throws {
    let failed = try presentation(
      .failed(.recognition), info: HUDSessionInfo(keyHints: Self.hints))
    #expect(failed.stage == nil)
    #expect(failed.keyHints.isEmpty)
  }

  @Test("REC-03, AC-06: クラウド STT の認識中は送信先を出し、ローカルでは出さない")
  func cloudSpeechRecognitionDestination() throws {
    let cloud = HUDSessionDetails(
      refinement: HUDRefinementSummary(mode: .natural, style: .standard), appName: nil,
      speechRecognition: .cloud)
    let recognizing = try presentation(.recognizing, info: HUDSessionInfo(details: cloud))
    #expect(recognizing.destination == "OpenAI へ送信")
    #expect(recognizing.accessibilityLabel == "認識中。OpenAI へ送信")
    // 録音中はまだ送らない
    #expect(try presentation(.recording, info: HUDSessionInfo(details: cloud)).destination == nil)

    let local = try presentation(.recognizing, info: HUDSessionInfo(details: Self.details))
    #expect(local.destination == nil)
  }

  @Test(
    "REC-03, AC-06: クラウド整形を送ると決めた整形中だけ送信先を出す",
    arguments: [
      (CloudAIProviderKind.claude, "Claude へ送信"),
      (.chatGPT, "ChatGPT へ送信"),
    ] as [(CloudAIProviderKind, String)])
  func refinementDestination(destination: CloudAIProviderKind, text: String) throws {
    let info = HUDSessionInfo(refinementDestination: destination)
    #expect(try presentation(.refining, info: info).destination == text)
    #expect(try presentation(.inserting, info: info).destination == nil)
    #expect(try presentation(.refining).destination == nil)
  }

  @Test("REC-03: 挿入完了は挿入先のアプリ名を1行目に出し、読み上げる")
  func insertionCompleted() throws {
    let confirmed = try presentation(
      nil, insertion: HUDInsertion(appName: "Slack", isConfirmed: true))
    #expect(confirmed.indicator == .completed)
    #expect(confirmed.title == "Slack に挿入しました")
    #expect(confirmed.messages.isEmpty)
    #expect(confirmed.announcement == "Slack に挿入しました")
    #expect(confirmed.stage == nil)
    #expect(confirmed.keyHints.isEmpty)

    let unconfirmed = try presentation(
      nil, insertion: HUDInsertion(appName: "Slack", isConfirmed: false))
    #expect(unconfirmed.title == "Slack へ入力しました（反映を確認できません）")
  }

  @Test("REC-03, AC-16: 挿入完了に通知が重なれば2行目以降に出し、新しい1行目として読み上げる")
  func insertionCompletedWithNotice() throws {
    let notice = HUDNotice.refinementFellBack(.timeout)
    let inserting = try presentation(.inserting, notices: [notice])
    let completed = try presentation(
      nil, notices: [notice], insertion: HUDInsertion(appName: "Mail", isConfirmed: true))

    #expect(completed.title == "Mail に挿入しました")
    #expect(completed.messages == [HUDPresentation.text(for: notice)])
    #expect(completed.announcement(after: inserting) == completed.accessibilityLabel)
  }

  @Test("REC-03: 文字列表現にチップ（アプリ名）とキーの案内の中身を出さない")
  func descriptionOmitsChips() throws {
    let recording = try presentation(
      .recording, info: HUDSessionInfo(details: Self.details, keyHints: Self.hints))
    for text in [String(describing: recording), String(reflecting: recording)] {
      #expect(!text.contains("Slack"))
      #expect(!text.contains("⌥Space"))
    }
  }
}

/// `HUDState` の録音の経過時間と挿入完了（REC-03, REC-05）。
struct HUDStateSessionInfoTests {
  let t0 = ContinuousClock.now

  @Test("REC-05: 録音中だけ経過時間と最大録音時間を返し、次の1秒の区切りで更新を求める")
  func recordingTimeWhileRecording() {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    hud.update(from: machine, at: t0)

    #expect(
      hud.recordingTime(at: t0 + .milliseconds(7_400))
        == HUDRecordingTime(elapsed: .milliseconds(7_400), limit: .seconds(300)))
    #expect(hud.nextRecordingTimeUpdate(after: t0) == t0 + .seconds(1))
    #expect(hud.nextRecordingTimeUpdate(after: t0 + .milliseconds(7_400)) == t0 + .seconds(8))
    // 最大録音時間を超える区切りは求めない（期限で録音が止まる）
    #expect(hud.nextRecordingTimeUpdate(after: t0 + .seconds(300)) == nil)

    machine.stopRecording(at: t0 + .seconds(1))
    hud.update(from: machine, at: t0 + .seconds(1))
    #expect(hud.recordingTime(at: t0 + .seconds(1)) == nil)
    #expect(hud.nextRecordingTimeUpdate(after: t0 + .seconds(1)) == nil)
  }

  @Test("REC-03: 挿入先を知らされたら、挿入完了だけを completionDisplayDuration の間残す")
  func insertionLingersForCompletionDuration() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(3), limitNoticeDisplayDuration: .seconds(3),
      completionDisplayDuration: .seconds(1))
    var hud = HUDState(configuration: configuration)
    var machine = try machineInserting()
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id
    let insertion = HUDInsertion(appName: "Slack", isConfirmed: true)

    hud.recordInsertion(insertion, for: session)
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    #expect(
      hud.content(at: t0) == HUDContent(status: nil, notices: [], insertion: insertion))
    #expect(hud.noticeExpiry == t0 + .seconds(1))
    #expect(hud.content(at: t0 + .seconds(1)) == nil)
  }

  @Test("REC-03, REC-05: 通知も重なれば、挿入完了と通知を limitNoticeDisplayDuration の間残す")
  func insertionWithNoticeLingersForNoticeDuration() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(3), limitNoticeDisplayDuration: .seconds(3),
      completionDisplayDuration: .seconds(1))
    var hud = HUDState(configuration: configuration)
    var machine = try machineInserting(bufferLimit: true)
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id
    let insertion = HUDInsertion(appName: "Slack", isConfirmed: true)

    hud.recordInsertion(insertion, for: session)
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    #expect(
      hud.content(at: t0 + .seconds(2))
        == HUDContent(status: nil, notices: [.audioBufferLimitReached], insertion: insertion))
    #expect(hud.noticeExpiry == t0 + .seconds(3))
  }

  @Test("REC-03: 挿入中でない・別のセッションの挿入先は使わない")
  func insertionIgnoredOutsideInserting() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id
    let insertion = HUDInsertion(appName: "Slack", isConfirmed: true)

    // 録音中
    hud.recordInsertion(insertion, for: session)
    machine.stopRecording(at: t0)
    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0)
    // 別のセッション
    hud.recordInsertion(insertion, for: SessionID())
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    #expect(hud.content(at: t0) == nil)
  }

  @Test("REC-03: 失敗の表示を終えて待機に戻ったら挿入完了を残さず、次のセッションで消す")
  func insertionNotKeptAfterFailureOrNewSession() throws {
    var hud = HUDState()
    var machine = try machineInserting()
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id
    hud.recordInsertion(HUDInsertion(appName: "Slack", isConfirmed: true), for: session)
    _ = try machine.handle(event(machine, .failed))
    hud.update(from: machine, at: t0)
    machine.dismissError()
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == nil)

    var next = try machineInserting()
    hud.update(from: next, at: t0)
    let nextSession = try #require(next.activeSession).id
    hud.recordInsertion(HUDInsertion(appName: "Mail", isConfirmed: true), for: nextSession)
    _ = try next.handle(event(next, .insertionCompleted))
    hud.update(from: next, at: t0)
    next.start(at: t0 + .milliseconds(500))
    hud.update(from: next, at: t0 + .milliseconds(500))
    #expect(
      hud.content(at: t0 + .milliseconds(500)) == HUDContent(status: .recording, notices: []))
  }

  private func machineInserting(bufferLimit: Bool = false) throws -> SessionStateMachine {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    if bufferLimit {
      machine.stopRecordingAtBufferLimit()
    } else {
      machine.stopRecording(at: t0)
    }
    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    return machine
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}

/// `HUDController` がセッションの情報を集めて表示に添える（REC-03, REC-05）。
@MainActor
struct HUDControllerSessionInfoTests {
  let clock = ManualClock()
  let presenter = RecordingPresenter()
  let scheduler = ManualScheduler()

  private static let details = HUDSessionDetails(
    refinement: HUDRefinementSummary(mode: .natural, style: .concise), appName: "Slack",
    speechRecognition: .local)

  @Test("REC-05: 録音中は1秒ごとに更新を予約し、経過時間を進める")
  func recordingTimeTicks() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    let t0 = clock.now
    machine.start(at: t0)
    controller.update(from: machine)
    #expect(controller.presentation?.recordingTimeText == "0:00 / 5:00")
    #expect(scheduler.deadline == t0 + .seconds(1))

    clock.advance(by: .seconds(1))
    scheduler.fire()
    #expect(controller.presentation?.recordingTimeText == "0:01 / 5:00")
    #expect(scheduler.deadline == t0 + .seconds(2))

    machine.stopRecording(at: clock.now)
    controller.update(from: machine)
    #expect(controller.presentation?.recordingTimeText == nil)
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-03: 状態を反映する前に知らせたセッションの設定を、最初の表示から使う")
  func detailsBeforeFirstUpdate() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    let session = try #require(machine.activeSession).id

    controller.recordSessionDetails(Self.details, for: session)
    #expect(presenter.calls.isEmpty)
    controller.update(from: machine)

    #expect(presenter.calls.count == 1)
    #expect(controller.presentation?.chips == ["Natural", "Slack：簡潔", "ローカルSTT"])
  }

  @Test("REC-03: 別のセッションの設定・音量は使わない")
  func dropsInfoOfOtherSession() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let first = try #require(machine.activeSession).id
    controller.recordSessionDetails(Self.details, for: first)
    controller.updateInputLevel(HUDInputLevel(bars: 4), for: first)
    #expect(controller.presentation?.inputLevelBars == 4)

    _ = machine.cancel()
    controller.update(from: machine)
    machine.start(at: clock.now)
    controller.update(from: machine)
    controller.updateInputLevel(HUDInputLevel(bars: 2), for: first)

    #expect(controller.presentation?.chips.isEmpty == true)
    #expect(controller.presentation?.inputLevelBars == 0)
  }

  @Test("REC-03: 音量は点灯する本数が変わったときだけ表示を更新し、録音中でなければ無視する")
  func inputLevelUpdatesOnlyOnChange() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let session = try #require(machine.activeSession).id

    controller.updateInputLevel(HUDInputLevel(bars: 3), for: session)
    controller.updateInputLevel(HUDInputLevel(bars: 3), for: session)
    #expect(presenter.calls.count == 2)
    #expect(controller.presentation?.inputLevelBars == 3)

    machine.stopRecording(at: clock.now)
    controller.update(from: machine)
    let calls = presenter.calls
    controller.updateInputLevel(HUDInputLevel(bars: 5), for: session)
    #expect(presenter.calls == calls)
  }

  @Test("REC-03, AC-06: 送信先は整形中だけ受け付け、整形を終えたら出さない")
  func refinementDestinationOnlyWhileRefining() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let session = try #require(machine.activeSession).id

    // 録音中は受け付けない
    controller.recordRefinementDestination(.claude, for: session)
    machine.stopRecording(at: clock.now)
    _ = try machine.handle(event(machine, .recognitionCompleted))
    controller.update(from: machine)
    #expect(controller.presentation?.destination == nil)

    controller.recordRefinementDestination(.claude, for: SessionID())
    #expect(controller.presentation?.destination == nil)
    controller.recordRefinementDestination(.claude, for: session)
    #expect(controller.presentation?.destination == "Claude へ送信")

    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    #expect(controller.presentation?.stage == .insertion)
    #expect(controller.presentation?.destination == nil)
  }

  @Test("REC-01: 停止・キャンセルのキーはセッションによらず反映する")
  func keyHintsApplyToSessions() throws {
    let controller = makeController()
    controller.updateKeyHints(HUDKeyHints(stopKey: "⌥Space", cancelKey: "Esc"))
    #expect(presenter.calls.isEmpty)

    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    #expect(controller.presentation?.keyHints.map(\.key) == ["⌥Space", "Esc"])

    controller.updateKeyHints(HUDKeyHints(stopKey: "⌥Space"))
    #expect(controller.presentation?.keyHints.map(\.key) == ["⌥Space"])
  }

  @Test("REC-03: 挿入を終えたら挿入先のアプリ名を出し、表示時間が過ぎたら隠す")
  func insertionCompletedThenHides() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    machine.stopRecording(at: clock.now)
    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    let session = try #require(machine.activeSession).id

    controller.recordInsertion(HUDInsertion(appName: "Slack", isConfirmed: true), for: session)
    _ = try machine.handle(event(machine, .insertionCompleted))
    controller.update(from: machine)
    #expect(controller.presentation?.title == "Slack に挿入しました")
    #expect(controller.presentation?.indicator == .completed)
    let expiry = clock.now + HUDConfiguration.defaultCompletionDisplayDuration
    #expect(scheduler.deadline == expiry)

    clock.advance(by: HUDConfiguration.defaultCompletionDisplayDuration)
    scheduler.fire()
    #expect(controller.presentation == nil)
    #expect(presenter.calls.last == .hide)
  }

  private func makeController() -> HUDController {
    HUDController(presenter: presenter, scheduler: scheduler, now: { [clock] in clock.now })
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}
