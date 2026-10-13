import Foundation

/// 推定費用（AI-05）。
///
/// トークン使用量と利用者の単価表から計算した**推定値**であり、API クレジット残高や実際の請求額ではない。
/// 金額は `Decimal` で持ち、浮動小数の誤差を出さない。
public struct EstimatedCost: Hashable, Sendable {
  public let amount: Decimal
  public let currency: CostCurrency

  /// 同じ通貨の推定費用を足す。通貨が異なる場合は足さない。
  public func adding(_ other: EstimatedCost) throws(PricingError) -> EstimatedCost {
    guard currency == other.currency else {
      throw .currencyMismatch
    }
    return EstimatedCost(amount: amount + other.amount, currency: currency)
  }
}

// 文字列表現には金額と通貨だけを出す（発話本文や利用者の情報は持たない）。
extension EstimatedCost: CustomStringConvertible {
  public var description: String {
    "EstimatedCost(amount: \(amount), currency: \(currency.code))"
  }
}
