import Foundation

/// 保存する単価表（AI-05, AI-07）。UtterAI の `PriceTable` に変換して使う。
///
/// 単価はコードに固定せず、利用者が設定する。既定は空で、通貨も未設定。
/// UtterAI に依存しないよう、金額は `Decimal`、通貨は ISO 4217 の3文字コードで持つ。
///
/// 空のとき・通貨が未設定のとき・モデルが載っていないときは、そのモデルの費用を推定できない。
/// 呼び出し側は推定費用を 0 として扱わず、予算判定で送信を止める（UtterAI の `CostEstimator` / `MonthlyBudget`）。
public struct PriceTableSetting: Hashable, Sendable {
  /// 単価の通貨コード（ISO 4217 の英字3文字）。前後の空白を除いて大文字にそろえる。未設定・形が違うなら `nil`
  public let currencyCode: String?
  /// 単価を最後に更新した日。未設定なら `nil`
  public let updatedOn: CalendarDay?
  /// モデルごとの単価。同じモデル名が複数あると、どれが正しいか決められないため、そのモデルの単価をすべて除く
  public let prices: [ModelPriceSetting]

  /// 空の単価表（既定値）
  public static let empty = PriceTableSetting()

  public init(
    currencyCode: String? = nil,
    updatedOn: CalendarDay? = nil,
    prices: [ModelPriceSetting] = []
  ) {
    self.currencyCode = currencyCode.flatMap(Self.normalizedCurrencyCode)
    self.updatedOn = updatedOn
    self.prices = Self.removingDuplicateModels(prices)
  }

  /// 単価表にあるモデルの単価。通貨が未設定なら推定に使えないため `nil`
  public func price(for model: String) -> ModelPriceSetting? {
    guard currencyCode != nil else { return nil }
    return prices.first { $0.model == model }
  }

  /// 前後の空白を除いて大文字にそろえる。ISO 4217 の形（英字3文字）でなければ `nil`。
  /// 使用量の保存（`MonthlyUsageStore`）が受け付ける形とそろえる
  static func normalizedCurrencyCode(_ code: String) -> String? {
    let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized.count == 3,
      normalized.allSatisfy({ $0.isASCII && $0.isLetter && $0.isUppercase })
    else {
      return nil
    }
    return normalized
  }

  private static func removingDuplicateModels(_ prices: [ModelPriceSetting]) -> [ModelPriceSetting]
  {
    var counts: [String: Int] = [:]
    for price in prices {
      counts[price.model, default: 0] += 1
    }
    return prices.filter { counts[$0.model] == 1 }
  }
}

extension PriceTableSetting: Codable {
  enum CodingKeys: String, CodingKey {
    case currencyCode
    case updatedOn
    case prices
  }

  /// 壊れた項目は既定値（未設定・空）に戻す。単価の行は壊れた行だけを除く
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let currencyCode = (try? container.decodeIfPresent(String.self, forKey: .currencyCode)) ?? nil
    let updatedOn = (try? container.decodeIfPresent(CalendarDay.self, forKey: .updatedOn)) ?? nil
    var prices: [ModelPriceSetting] = []
    if var items = try? container.nestedUnkeyedContainer(forKey: .prices) {
      while !items.isAtEnd {
        if let price = try? items.decode(ModelPriceSetting.self) {
          prices.append(price)
        } else if (try? items.decode(SkippedValue.self)) == nil {
          break
        }
      }
    }
    self.init(currencyCode: currencyCode, updatedOn: updatedOn, prices: prices)
  }
}

/// 1モデル分の単価（AI-05）。100万トークンあたりの単価で持つ。
public struct ModelPriceSetting: Hashable, Sendable {
  public let model: String
  public let inputPerMillionTokens: Decimal
  public let outputPerMillionTokens: Decimal

  /// モデル名が空、単価が負・非数のときは `nil`
  public init?(model: String, inputPerMillionTokens: Decimal, outputPerMillionTokens: Decimal) {
    guard !model.isEmpty,
      !inputPerMillionTokens.isNaN, inputPerMillionTokens >= 0,
      !outputPerMillionTokens.isNaN, outputPerMillionTokens >= 0
    else {
      return nil
    }
    self.model = model
    self.inputPerMillionTokens = inputPerMillionTokens
    self.outputPerMillionTokens = outputPerMillionTokens
  }
}

extension ModelPriceSetting: Codable {
  enum CodingKeys: String, CodingKey {
    case model
    case inputPerMillionTokens
    case outputPerMillionTokens
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let price = ModelPriceSetting(
        model: try container.decode(String.self, forKey: .model),
        inputPerMillionTokens: try container.decode(Decimal.self, forKey: .inputPerMillionTokens),
        outputPerMillionTokens: try container.decode(Decimal.self, forKey: .outputPerMillionTokens))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .model, in: container, debugDescription: "Invalid model price")
    }
    self = price
  }
}

/// 単価表の更新日など、日付の値（AI-05）。時刻・タイムゾーンを持たない。暦の妥当性（2月30日など）までは検査しない。
public struct CalendarDay: Hashable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  /// 月が 1〜12、日が 1〜31 の範囲外なら `nil`
  public init?(year: Int, month: Int, day: Int) {
    guard (1...12).contains(month), (1...31).contains(day) else {
      return nil
    }
    self.year = year
    self.month = month
    self.day = day
  }
}

extension CalendarDay: Codable {
  enum CodingKeys: String, CodingKey {
    case year
    case month
    case day
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let day = CalendarDay(
        year: try container.decode(Int.self, forKey: .year),
        month: try container.decode(Int.self, forKey: .month),
        day: try container.decode(Int.self, forKey: .day))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .month, in: container, debugDescription: "Invalid calendar day")
    }
    self = day
  }
}

/// 月次予算の上限（AI-04, AI-05）。UtterAI の `MonthlyBudget` に変換して使う。
///
/// 上限 0 は「クラウド AI に費用をかけない」設定として有効。
public struct MonthlyBudgetSetting: Hashable, Sendable {
  public let limitAmount: Decimal
  /// 通貨コード（ISO 4217 の英字3文字）。前後の空白を除いて大文字にそろえる
  public let currencyCode: String

  /// 上限が負・非数、または通貨コードが ISO 4217 の形（英字3文字）でないときは `nil`
  public init?(limitAmount: Decimal, currencyCode: String) {
    guard !limitAmount.isNaN, limitAmount >= 0,
      let currencyCode = PriceTableSetting.normalizedCurrencyCode(currencyCode)
    else {
      return nil
    }
    self.limitAmount = limitAmount
    self.currencyCode = currencyCode
  }
}

extension MonthlyBudgetSetting: Codable {
  enum CodingKeys: String, CodingKey {
    case limitAmount
    case currencyCode
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let budget = MonthlyBudgetSetting(
        limitAmount: try container.decode(Decimal.self, forKey: .limitAmount),
        currencyCode: try container.decode(String.self, forKey: .currencyCode))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .limitAmount, in: container, debugDescription: "Invalid monthly budget")
    }
    self = budget
  }
}

/// 壊れた要素を読み飛ばすための値。どんな値からも復号に成功する
struct SkippedValue: Decodable {
  init(from decoder: any Decoder) throws {}
}
