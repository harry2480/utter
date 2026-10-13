/// クラウド送信の同意状態と、送信可否の判定（AC-06, AC-12, AI-04）。
///
/// 既定ではすべて未同意で、同意（`granted`）している対象だけを送信可と判定する。
/// 撤回すると次の判定から送信不可になる。値型なので、利用側は送信の直前に最新の状態で判定する。
public struct ConsentState: Hashable, Sendable {
  private var statuses: [ConsentScope: ConsentStatus] = [:]

  /// すべて未同意の状態を作る。
  public init() {}

  public func status(of scope: ConsentScope) -> ConsentStatus {
    statuses[scope] ?? .notGranted
  }

  public func isGranted(_ scope: ConsentScope) -> Bool {
    status(of: scope) == .granted
  }

  /// 同意を付与する。
  public mutating func grant(_ scope: ConsentScope) {
    statuses[scope] = .granted
  }

  /// 同意を撤回する。同意していない対象は未同意のまま変えない。
  public mutating func revoke(_ scope: ConsentScope) {
    guard isGranted(scope) else { return }
    statuses[scope] = .revoked
  }

  /// 送信してよいか（AC-06）。
  public func allows(_ transmission: CloudTransmission) -> Bool {
    isGranted(.transmission(transmission))
  }

  /// `source` での整形に失敗したとき、`destination` へ自動で切り替えて送信してよいか（AI-04）。
  ///
  /// 自動フォールバックへの同意に加えて、切り替え先への整形の送信にも同意している場合に限る。
  /// 同じプロバイダーへの再送は切り替えではないため許可しない。
  public func allowsFallback(from source: CloudAIProvider, to destination: CloudAIProvider) -> Bool
  {
    source != destination
      && isGranted(.crossProviderFallback)
      && allows(.textRefinement(destination))
  }
}
