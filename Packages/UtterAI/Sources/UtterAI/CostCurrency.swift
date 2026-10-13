/// 単価表と予算が使う通貨コード（AI-05）。
///
/// 通貨は単価表ごとに利用者が指定し、為替換算は行わない。
/// そのため円かドルかの方針をコードで決めず、異なる通貨の値を足し算しないことだけを保証する。
public struct CostCurrency: Hashable, Sendable {
  public let code: String

  public init(code: String) throws(PricingError) {
    guard !code.isEmpty else {
      throw .emptyCurrencyCode
    }
    self.code = code
  }
}
