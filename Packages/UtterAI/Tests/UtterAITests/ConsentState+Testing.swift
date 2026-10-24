import UtterCore

extension ConsentState {
  /// `destination` への整形の送信だけに同意した状態
  static func refinementGranted(_ destination: CloudAIProviderKind = .claude) -> ConsentState {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(destination)))
    return consent
  }
}
