/// 単価表・推定費用・予算の値が不正なときのエラー（AI-05）。
public enum PricingError: Error, Hashable, Sendable {
  case emptyCurrencyCode
  case emptyModelName
  case negativePrice
  case negativeAmount
  case duplicateModel(String)
  case invalidDate
  case invalidMonth
  case currencyMismatch
}
