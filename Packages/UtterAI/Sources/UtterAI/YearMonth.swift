/// 予算と累計の期間（AI-05）。月ごとに累計をリセットする。
public struct YearMonth: Hashable, Sendable {
  public let year: Int
  public let month: Int

  public init(year: Int, month: Int) throws(PricingError) {
    guard (1...12).contains(month) else {
      throw .invalidMonth
    }
    self.year = year
    self.month = month
  }
}
