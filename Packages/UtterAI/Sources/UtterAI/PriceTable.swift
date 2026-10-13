/// 利用者が設定する単価表（AI-05, AI-07）。
///
/// コードには単価を固定せず、更新日つきの設定として渡す。単価表にないモデルは推定不可として扱う。
public struct PriceTable: Hashable, Sendable {
  public let currency: CostCurrency
  /// 単価を最後に更新した日
  public let updatedOn: CivilDate
  public let prices: [ModelPrice]
  private let pricesByModel: [String: ModelPrice]

  public init(
    currency: CostCurrency,
    updatedOn: CivilDate,
    prices: [ModelPrice]
  ) throws(PricingError) {
    var pricesByModel: [String: ModelPrice] = [:]
    for price in prices {
      guard pricesByModel.updateValue(price, forKey: price.model) == nil else {
        throw .duplicateModel(price.model)
      }
    }
    self.currency = currency
    self.updatedOn = updatedOn
    self.prices = prices
    self.pricesByModel = pricesByModel
  }

  public func price(for model: String) -> ModelPrice? {
    pricesByModel[model]
  }
}
