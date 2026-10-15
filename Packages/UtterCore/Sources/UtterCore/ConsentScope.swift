/// 利用者が個別に同意・撤回する対象（AC-06, AC-12, AI-04）。
public enum ConsentScope: Hashable, Sendable, CaseIterable, Codable {
  /// クラウドへの送信
  case transmission(CloudTransmission)
  /// クラウド AI の整形が失敗したとき、別のクラウド AI へ自動で切り替えて送信すること（AI-04）
  case crossProviderFallback

  public static var allCases: [ConsentScope] {
    CloudTransmission.allCases.map(Self.transmission) + [.crossProviderFallback]
  }
}
