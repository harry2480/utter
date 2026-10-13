/// 誤りの件数と分母。率は複数の発話を合算してから求める（発話ごとの率の平均にしない）。
public struct ErrorCount: Hashable, Sendable {
  /// 誤りの件数（CER では編集距離、用語では誤った用語の数）
  public var errors: Int
  /// 分母（CER では正規化後の正解の文字数、用語では正解に含まれる用語の数）
  public var total: Int

  public init(errors: Int, total: Int) {
    self.errors = errors
    self.total = total
  }

  public static let zero = ErrorCount(errors: 0, total: 0)

  /// 誤り率。分母が 0 のときは `nil`。CER では挿入により 1 を超えることがある
  public var errorRate: Double? {
    total == 0 ? nil : Double(errors) / Double(total)
  }

  /// 正答率（1 − 誤り率）。分母が 0 のときは `nil`
  public var accuracy: Double? {
    errorRate.map { 1 - $0 }
  }

  public static func + (lhs: ErrorCount, rhs: ErrorCount) -> ErrorCount {
    ErrorCount(errors: lhs.errors + rhs.errors, total: lhs.total + rhs.total)
  }
}
