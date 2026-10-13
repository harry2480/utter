/// 単価表の更新日など、日付の値（AI-05）。暦の妥当性（2月30日など）までは検査しない。
public struct CivilDate: Hashable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) throws(PricingError) {
    guard (1...12).contains(month), (1...31).contains(day) else {
      throw .invalidDate
    }
    self.year = year
    self.month = month
    self.day = day
  }
}
