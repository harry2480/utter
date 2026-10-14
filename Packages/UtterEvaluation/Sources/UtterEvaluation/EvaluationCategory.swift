/// 評価セットの区分（9章）。
public enum EvaluationCategory: String, Codable, Hashable, Sendable, CaseIterable {
  case japanese
  case mixedJapaneseEnglish
  case developerTerms
  case numbers
  case selfCorrection
  case noisy

  /// 結果の表に出す名前
  public var displayName: String {
    switch self {
    case .japanese: "日本語"
    case .mixedJapaneseEnglish: "日英混在"
    case .developerTerms: "開発用語"
    case .numbers: "数字"
    case .selfCorrection: "自己訂正"
    case .noisy: "騒音"
    }
  }
}
