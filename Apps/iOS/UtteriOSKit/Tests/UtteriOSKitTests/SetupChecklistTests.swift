import Foundation
import Testing
import UtterCore
import UtterSpeech

@testable import UtteriOSKit

/// セットアップの各手順の状態の判定（#200）。
struct SetupChecklistTests {
  private static let reportedAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func checklist(
    sharesWithKeyboard: Bool = true,
    report: KeyboardSetupReport? = nil,
    marks: SetupMarks = SetupMarks(),
    microphone: MicrophonePermissionStatus = .undetermined,
    hasSpeechModel: Bool = true,
    speechModel: UtterSpeech.SpeechModelAvailability? = .notInstalled
  ) -> SetupChecklist {
    SetupChecklist(
      sharesWithKeyboard: sharesWithKeyboard, keyboardReport: report, marks: marks,
      microphone: microphone, hasSpeechModel: hasSpeechModel, speechModel: speechModel)
  }

  @Test("#200: 何もしていなければ、最初の手順はキーボードの追加で、どれも済んでいない")
  func initialState() {
    let list = checklist()

    #expect(list.currentStep == .addKeyboard)
    #expect(!list.isRequiredComplete)
    for step in SetupStep.allCases {
      #expect(list.state(of: step) == .pending)
    }
    #expect(list.progress.settled == 0)
    #expect(list.progress.total == 5)
  }

  @Test("#200: 手順はキーボード → フルアクセス → マイク → モデル → 整形の実行先の順")
  func order() {
    let expected: [SetupStep] = [
      .addKeyboard, .fullAccess, .microphone, .speechModel, .refinementDestination,
    ]
    #expect(SetupStep.allCases == expected)
  }

  @Test("#200: キーボードからの報告が届けば、キーボードの追加は済んだことにする")
  func keyboardReportMarksKeyboardAdded() {
    let list = checklist(
      report: KeyboardSetupReport(observedAt: Self.reportedAt, hasFullAccess: false))

    #expect(list.state(of: .addKeyboard) == .done(.keyboardReport))
  }

  @Test("#200: 報告が届かなくても、利用者が「済んだ」を押せばキーボードの追加は済む")
  func manualKeyboardAdded() {
    let list = checklist(marks: SetupMarks(keyboardAddedAt: Self.reportedAt))

    #expect(list.state(of: .addKeyboard) == .done(.user))
    #expect(list.currentStep == .fullAccess)
  }

  @Test("#200: フルアクセスがオンと報告されれば済む。オフと報告されれば直すよう求める")
  func fullAccessFromReport() {
    let on = checklist(
      report: KeyboardSetupReport(observedAt: Self.reportedAt, hasFullAccess: true))
    let off = checklist(
      report: KeyboardSetupReport(observedAt: Self.reportedAt, hasFullAccess: false))

    #expect(on.state(of: .fullAccess) == .done(.keyboardReport))
    #expect(off.state(of: .fullAccess) == .needsAttention)
  }

  @Test("#200: フルアクセスは報告と「済んだ」の新しい方を使う")
  func fullAccessUsesNewer() {
    let off = KeyboardSetupReport(observedAt: Self.reportedAt, hasFullAccess: false)
    let markedAfter = checklist(
      report: off, marks: SetupMarks(fullAccessAllowedAt: Self.reportedAt.addingTimeInterval(1)))
    let markedBefore = checklist(
      report: off, marks: SetupMarks(fullAccessAllowedAt: Self.reportedAt.addingTimeInterval(-1)))
    let manualOnly = checklist(marks: SetupMarks(fullAccessAllowedAt: Self.reportedAt))

    #expect(markedAfter.state(of: .fullAccess) == .done(.user))
    #expect(markedBefore.state(of: .fullAccess) == .needsAttention)
    #expect(manualOnly.state(of: .fullAccess) == .done(.user))
  }

  @Test("#56: App Group でキーボードと共有しないビルドでは、フルアクセスは要らず、報告も使わない")
  func fullAccessNotApplicableWithoutSharing() {
    let list = checklist(
      sharesWithKeyboard: false,
      report: KeyboardSetupReport(observedAt: Self.reportedAt, hasFullAccess: true))

    #expect(list.state(of: .fullAccess) == .notApplicable)
    #expect(list.state(of: .addKeyboard) == .pending)
  }

  @Test(
    "#200: マイクは許可で済み、拒否なら直すよう求め、未確認なら済んでいない",
    arguments: [
      (MicrophonePermissionStatus.granted, SetupStepState.done(.system)),
      (.denied, .needsAttention),
      (.undetermined, .pending),
    ])
  func microphone(status: MicrophonePermissionStatus, expected: SetupStepState) {
    #expect(checklist(microphone: status).state(of: .microphone) == expected)
  }

  @Test(
    "#200: モデルは取得済みで済み、使えない端末なら要らず、未取得・取得中・未確認なら済んでいない",
    arguments: [
      (.installed, .done(.system)),
      (.unsupported, .notApplicable),
      (.notInstalled, .pending),
      (.downloading, .pending),
      (nil, .pending),
    ] as [(UtterSpeech.SpeechModelAvailability?, SetupStepState)])
  func speechModel(
    availability: UtterSpeech.SpeechModelAvailability?, expected: SetupStepState
  ) {
    #expect(checklist(speechModel: availability).state(of: .speechModel) == expected)
  }

  @Test("#54: 取得するモデルがない STT エンジンでは、モデルの手順は要らない")
  func speechModelNotApplicableWithoutModel() {
    let list = checklist(hasSpeechModel: false, speechModel: nil)

    #expect(list.state(of: .speechModel) == .notApplicable)
  }

  @Test("#200: 整形の実行先は飛ばせて、飛ばさなくても必須の手順が済めばセットアップは済む")
  func refinementIsSkippable() {
    let required = SetupMarks(
      keyboardAddedAt: Self.reportedAt, fullAccessAllowedAt: Self.reportedAt)
    let undecided = checklist(marks: required, microphone: .granted, speechModel: .installed)
    var skippedMarks = required
    skippedMarks.refinement = .skipped
    let skipped = checklist(marks: skippedMarks, microphone: .granted, speechModel: .installed)

    #expect(SetupStep.refinementDestination.isSkippable)
    #expect(SetupStep.allCases.filter(\.isSkippable) == [.refinementDestination])
    #expect(undecided.isRequiredComplete)
    #expect(undecided.currentStep == .refinementDestination)
    #expect(skipped.state(of: .refinementDestination) == .skipped)
    #expect(skipped.currentStep == nil)
    #expect(skipped.progress.settled == 5)
  }

  @Test("#200: 拒否された手順があれば、セットアップは済んでいない")
  func deniedBlocksCompletion() {
    let list = checklist(
      marks: SetupMarks(keyboardAddedAt: Self.reportedAt, fullAccessAllowedAt: Self.reportedAt),
      microphone: .denied, speechModel: .installed)

    #expect(!list.isRequiredComplete)
    #expect(list.currentStep == .microphone)
  }
}
