import UtterCore
import UtterText

@testable import UtterAI

extension ConsentState {
  /// `destination` への Edit の選択テキストの送信だけに同意した状態
  static func editSelectionGranted(_ destination: CloudAIProviderKind = .claude) -> ConsentState {
    var consent = ConsentState()
    consent.grant(.transmission(.editSelection(destination)))
    return consent
  }
}

extension EditRequest {
  /// `EditSession` から同意を確認して作った Edit の入力
  static func make(
    selection: String = "明日の会議は10時からです。",
    instruction: String = "丁寧な言い方にして",
    dictionaryTerms: [String] = [],
    destination: CloudAIProviderKind = .claude
  ) throws -> EditRequest {
    let session = try EditSession(selection: selection)
    let transmission = try session.cloudTransmission(
      to: destination, consent: .editSelectionGranted(destination))
    return EditRequest(transmission, instruction: instruction, dictionaryTerms: dictionaryTerms)
  }
}
