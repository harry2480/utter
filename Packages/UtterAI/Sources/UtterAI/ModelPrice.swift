import Foundation

/// モデル1つ分の単価（AI-05）。100万トークンあたりの単価で持つ。
public struct ModelPrice: Hashable, Sendable {
  public let model: String
  public let inputPerMillionTokens: Decimal
  public let outputPerMillionTokens: Decimal

  public init(
    model: String,
    inputPerMillionTokens: Decimal,
    outputPerMillionTokens: Decimal
  ) throws(PricingError) {
    guard !model.isEmpty else {
      throw .emptyModelName
    }
    guard inputPerMillionTokens >= 0, outputPerMillionTokens >= 0 else {
      throw .negativePrice
    }
    self.model = model
    self.inputPerMillionTokens = inputPerMillionTokens
    self.outputPerMillionTokens = outputPerMillionTokens
  }
}
