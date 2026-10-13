import Foundation

/// トークン使用量から推定費用を計算する（AI-05）。ネットワークには出ない。
public struct CostEstimator: Sendable {
  public let priceTable: PriceTable

  public init(priceTable: PriceTable) {
    self.priceTable = priceTable
  }

  /// 推定費用を計算する。単価表にないモデルは推定不可として `unknownModel` を投げ、0 円にはしない。
  public func estimate(model: String, usage: TokenUsage) throws(CostEstimationError)
    -> EstimatedCost
  {
    guard usage.inputTokens >= 0, usage.outputTokens >= 0 else {
      throw .negativeTokenCount
    }
    guard let price = priceTable.price(for: model) else {
      throw .unknownModel(model)
    }
    let million = Decimal(1_000_000)
    let input = Decimal(usage.inputTokens) * price.inputPerMillionTokens / million
    let output = Decimal(usage.outputTokens) * price.outputPerMillionTokens / million
    return EstimatedCost(amount: input + output, currency: priceTable.currency)
  }
}

public enum CostEstimationError: Error, Hashable, Sendable {
  /// 単価表にないモデル。モデル名は利用者の設定値で、発話本文は含まない
  case unknownModel(String)
  case negativeTokenCount
}
