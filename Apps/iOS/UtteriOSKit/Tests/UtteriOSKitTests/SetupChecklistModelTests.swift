import Foundation
import Synchronization
import Testing
import UtterCore
import UtterSpeech

@testable import UtteriOSKit

/// マイクの権限の代わり。求めると `grants` の結果になる
final class FakeMicrophonePermission: MicrophonePermissionAccess {
  private let state: Mutex<(status: MicrophonePermissionStatus, requests: Int)>
  let grants: Bool

  init(status: MicrophonePermissionStatus = .undetermined, grants: Bool = true) {
    state = Mutex((status, 0))
    self.grants = grants
  }

  var requestCount: Int { state.withLock { $0.requests } }

  func status() -> MicrophonePermissionStatus {
    state.withLock { $0.status }
  }

  func request() async -> Bool {
    let grants = grants
    state.withLock {
      $0.requests += 1
      $0.status = grants ? .granted : .denied
    }
    return grants
  }
}

/// キーボード拡張からの報告の代わり
final class FakeKeyboardSetupReportReader: KeyboardSetupReportReading {
  struct ReadFailure: Error {}

  private let report: KeyboardSetupReport?
  private let fails: Bool

  init(_ report: KeyboardSetupReport?, fails: Bool = false) {
    self.report = report
    self.fails = fails
  }

  func load() async throws -> KeyboardSetupReport? {
    if fails { throw ReadFailure() }
    return report
  }
}

/// セットアップ画面の状態と操作（#200）。
@MainActor
struct SetupChecklistModelTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let temporaryDefaults: TemporaryDefaults

  init() throws {
    temporaryDefaults = try TemporaryDefaults()
  }

  private var store: SetupMarksStore { SetupMarksStore(defaults: temporaryDefaults.defaults) }

  private func makeModel(
    reportReader: (any KeyboardSetupReportReading)? = nil,
    sharesWithKeyboard: Bool = true,
    microphone: FakeMicrophonePermission = FakeMicrophonePermission()
  ) -> SetupChecklistModel {
    let now = Self.now
    return SetupChecklistModel(
      store: store, reportReader: reportReader, sharesWithKeyboard: sharesWithKeyboard,
      microphone: microphone, now: { now })
  }

  @Test("#200: キーボードからの報告を読み、キーボードの追加とフルアクセスを済んだことにする")
  func readsKeyboardReport() async {
    let report = KeyboardSetupReport(observedAt: Self.now, hasFullAccess: true)
    let model = makeModel(reportReader: FakeKeyboardSetupReportReader(report))

    await model.refresh()

    let list = model.checklist(hasSpeechModel: false, speechModel: nil)
    #expect(model.keyboardReport == report)
    #expect(list.state(of: .addKeyboard) == .done(.keyboardReport))
    #expect(list.state(of: .fullAccess) == .done(.keyboardReport))
  }

  @Test("#200: 報告を読めなければ届いていないものとして扱い、「済んだ」で進められる")
  func unreadableReportFallsBackToManual() async {
    let model = makeModel(reportReader: FakeKeyboardSetupReportReader(nil, fails: true))

    await model.refresh()
    #expect(model.keyboardReport == nil)
    #expect(
      model.checklist(hasSpeechModel: false, speechModel: nil).state(of: .addKeyboard) == .pending)

    model.markDone(.addKeyboard)

    #expect(
      model.checklist(hasSpeechModel: false, speechModel: nil).state(of: .addKeyboard)
        == .done(.user))
  }

  @Test("#56: キーボードと共有しないビルドでは報告を読まない")
  func ignoresReportWithoutSharing() async {
    let report = KeyboardSetupReport(observedAt: Self.now, hasFullAccess: true)
    let model = makeModel(
      reportReader: FakeKeyboardSetupReportReader(report), sharesWithKeyboard: false)

    await model.refresh()

    #expect(model.keyboardReport == nil)
  }

  @Test("#200: 「済んだ」・整形の実行先の決定と飛ばしたこと・閉じたことは保存し、次に開いたときも使う")
  func marksAreSaved() {
    let model = makeModel()
    #expect(model.presentsOnLaunch)

    model.markDone(.addKeyboard)
    model.markDone(.fullAccess)
    model.skip(.refinementDestination)
    model.dismiss()

    let saved = store.load()
    #expect(saved.keyboardAddedAt == Self.now)
    #expect(saved.fullAccessAllowedAt == Self.now)
    #expect(saved.refinement == .skipped)
    #expect(saved.dismissedAt == Self.now)
    let reopened = makeModel()
    #expect(reopened.marks == saved)
    #expect(!reopened.presentsOnLaunch)
  }

  @Test("#200: 飛ばせない手順は飛ばせず、OS の状態で決まる手順は「済んだ」で済まない")
  func cannotSkipOrMarkSystemSteps() {
    let model = makeModel()

    model.skip(.microphone)
    model.markDone(.microphone)
    model.markDone(.speechModel)

    let list = model.checklist(hasSpeechModel: true, speechModel: .notInstalled)
    #expect(list.state(of: .microphone) == .pending)
    #expect(list.state(of: .speechModel) == .pending)
    #expect(model.marks == SetupMarks())
  }

  @Test("#200: マイクは押したときだけ求め、結果を手順に反映する。求めた後はもう求めない")
  func requestsMicrophoneOnce() async {
    let microphone = FakeMicrophonePermission(grants: false)
    let model = makeModel(microphone: microphone)
    #expect(microphone.requestCount == 0)

    await model.requestMicrophone()
    await model.requestMicrophone()

    #expect(microphone.requestCount == 1)
    #expect(model.microphone == .denied)
    #expect(
      model.checklist(hasSpeechModel: false, speechModel: nil).state(of: .microphone)
        == .needsAttention)
  }

  @Test("#200: 前面に戻ったときに読み直すと、設定アプリで変えたマイクの権限を反映する")
  func refreshReadsMicrophone() async {
    let microphone = FakeMicrophonePermission(status: .undetermined)
    let model = makeModel(microphone: microphone)
    _ = await microphone.request()

    await model.refresh()

    #expect(model.microphone == .granted)
  }
}
