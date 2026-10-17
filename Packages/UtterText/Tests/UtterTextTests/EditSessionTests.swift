import Testing
import UtterCore

@testable import UtterText

struct EditSessionTests {
  private static func session(_ selection: String = "会議は3時からです") -> EditSession {
    // 空でない選択なので失敗しない
    try! EditSession(selection: selection)
  }

  /// 各段階のセッションを作る。
  private static func session(in kind: EditSession.State.Kind) throws -> EditSession {
    var session = Self.session()
    switch kind {
    case .awaitingProposal:
      break
    case .reviewing:
      try session.propose("会議は4時からです")
    case .committed:
      try session.propose("会議は4時からです")
      _ = try session.commit()
    case .cancelled:
      try session.cancel()
    case .restored:
      try session.propose("会議は4時からです")
      _ = try session.commit()
      _ = try session.restore()
    }
    return session
  }

  /// 段階と操作の組み合わせが遷移として許されるか（期待値の表）。
  private static func isAllowed(_ action: EditSession.Action, in kind: EditSession.State.Kind)
    -> Bool
  {
    switch (action, kind) {
    case (.propose, .awaitingProposal), (.propose, .reviewing): true
    case (.commit, .reviewing): true
    case (.cancel, .awaitingProposal), (.cancel, .reviewing): true
    case (.restore, .committed): true
    case (.prepareCloudTransmission, .awaitingProposal),
      (.prepareCloudTransmission, .reviewing):
      true
    default: false
    }
  }

  private static func consent(granting transmissions: CloudTransmission...) -> ConsentState {
    var consent = ConsentState()
    for transmission in transmissions {
      consent.grant(.transmission(transmission))
    }
    return consent
  }

  /// 操作を行い、発生したエラーを返す。
  private static func perform(_ action: EditSession.Action, on session: inout EditSession)
    -> EditSessionError?
  {
    do throws(EditSessionError) {
      switch action {
      case .propose: try session.propose("編集案")
      case .commit: _ = try session.commit()
      case .cancel: try session.cancel()
      case .restore: _ = try session.restore()
      case .prepareCloudTransmission:
        _ = try session.cloudTransmission(
          to: .claude, consent: consent(granting: .editSelection(.claude)))
      }
      return nil
    } catch {
      return error
    }
  }

  @Test("AC-14: 空の選択では編集を始められない")
  func rejectsEmptySelection() {
    #expect(throws: EditSessionError.emptySelection) {
      try EditSession(selection: "")
    }
  }

  @Test("AC-14: 始めた直後は編集案を待つ")
  func startsAwaitingProposal() {
    let session = Self.session()

    #expect(session.state == .awaitingProposal)
    #expect(!session.isFinished)
  }

  @Test("AC-14: 編集案を受け取ると差分を求めて確認待ちになる")
  func proposalProducesDiff() throws {
    var session = Self.session()

    try session.propose("会議は4時からです")

    guard case .reviewing(let proposal) = session.state else {
      Issue.record("確認待ちになっていない")
      return
    }
    #expect(proposal.text == "会議は4時からです")
    #expect(proposal.diff.segments.map(\.kind) == [.unchanged, .deleted, .inserted, .unchanged])
    #expect(proposal.diff.originalText == "会議は3時からです")
  }

  @Test("AC-14: 確認中に別の編集案を受け取ると置き換える")
  func reproposalReplacesProposal() throws {
    var session = Self.session()
    try session.propose("会議は4時からです")

    try session.propose("会議は5時からです")

    guard case .reviewing(let proposal) = session.state else {
      Issue.record("確認待ちになっていない")
      return
    }
    #expect(proposal.text == "会議は5時からです")
  }

  @Test("AC-14: 確定すると編集案を返し、復元すると元の選択テキストを返す")
  func commitThenRestore() throws {
    var session = Self.session()
    try session.propose("会議は4時からです")

    let committed = try session.commit()
    #expect(committed == "会議は4時からです")
    #expect(session.state.kind == .committed)
    #expect(!session.isFinished)

    let restoration = try session.restore()
    #expect(restoration.expectedText == "会議は4時からです")
    #expect(restoration.replacement == "会議は3時からです")
    #expect(session.state == .restored)
    #expect(session.isFinished)
  }

  @Test("AC-14: 確認中にキャンセルすると確定しない")
  func cancelDuringReview() throws {
    var session = Self.session()
    try session.propose("会議は4時からです")

    try session.cancel()

    #expect(session.state == .cancelled)
    #expect(session.isFinished)
    #expect(throws: EditSessionError.invalidTransition(from: .cancelled, action: .commit)) {
      _ = try session.commit()
    }
  }

  @Test("AC-14: 空の編集案は選択テキストの削除として確認できる")
  func emptyProposalIsDeletion() throws {
    var session = Self.session("消す文")

    try session.propose("")

    guard case .reviewing(let proposal) = session.state else {
      Issue.record("確認待ちになっていない")
      return
    }
    #expect(proposal.diff.segments == [TextDiffSegment(kind: .deleted, text: "消す文")])
  }

  @Test(
    "AC-14: 段階ごとに許される操作だけを受け付け、それ以外は段階と操作を示すエラーにする",
    arguments: EditSession.State.Kind.allCases, EditSession.Action.allCases
  )
  func transitionTable(_ kind: EditSession.State.Kind, _ action: EditSession.Action) throws {
    var session = try Self.session(in: kind)
    let before = session

    let error = Self.perform(action, on: &session)

    if Self.isAllowed(action, in: kind) {
      #expect(error == nil)
    } else {
      #expect(error == .invalidTransition(from: kind, action: action))
      // 失敗した操作は状態を変えない
      #expect(session == before)
    }
  }

  @Test("AC-06: 選択テキストの送信には送信先への Edit 用の同意が必要")
  func cloudTransmissionRequiresEditConsent() throws {
    let session = Self.session()

    #expect(throws: EditSessionError.transmissionNotConsented(.claude)) {
      _ = try session.cloudTransmission(to: .claude, consent: ConsentState())
    }

    let transmission = try session.cloudTransmission(
      to: .claude, consent: Self.consent(granting: .editSelection(.claude)))
    #expect(transmission.provider == .claude)
    #expect(transmission.selection == "会議は3時からです")
  }

  @Test(
    "AC-06: 音声入力の整形への同意や別の送信先への同意では選択テキストを送れない",
    arguments: CloudAIProviderKind.allCases
  )
  func otherConsentsDoNotAllowEditTransmission(_ provider: CloudAIProviderKind) {
    let session = Self.session()
    let others = CloudTransmission.allCases.filter { $0 != .editSelection(provider) }
    var consent = ConsentState()
    for transmission in others {
      consent.grant(.transmission(transmission))
    }
    consent.grant(.crossProviderFallback)

    #expect(throws: EditSessionError.transmissionNotConsented(provider)) {
      _ = try session.cloudTransmission(to: provider, consent: consent)
    }
  }

  @Test("AC-06: 同意を撤回すると選択テキストを送れなくなる")
  func revokedConsentDeniesTransmission() {
    let session = Self.session()
    var consent = Self.consent(granting: .editSelection(.chatGPT))
    consent.revoke(.transmission(.editSelection(.chatGPT)))

    #expect(throws: EditSessionError.transmissionNotConsented(.chatGPT)) {
      _ = try session.cloudTransmission(to: .chatGPT, consent: consent)
    }
  }

  @Test("AC-14: 文字列表現・リフレクション・エラーに本文を出さない")
  func redactsText() throws {
    var session = Self.session("秘密の本文")
    try session.propose("公開する文")
    guard case .reviewing(let proposal) = session.state else {
      Issue.record("確認待ちになっていない")
      return
    }
    let transmission = try session.cloudTransmission(
      to: .claude, consent: Self.consent(granting: .editSelection(.claude)))
    _ = try session.commit()
    let restoration = try session.restore()

    let rendered: [String] = [
      String(describing: session), String(reflecting: session),
      String(describing: proposal), String(reflecting: proposal),
      String(describing: EditSession.State.reviewing(proposal)),
      String(describing: restoration), String(reflecting: restoration),
      String(describing: transmission), String(reflecting: transmission),
      String(describing: EditSessionError.invalidTransition(from: .restored, action: .commit)),
    ]
    for text in rendered {
      #expect(!text.contains("秘密"))
      #expect(!text.contains("公開"))
    }
  }
}
