import Foundation
import UtterPersistence

/// iOS の設定画面で選ぶ整形の処理系（AI-03, iOS-10）。保存は `AppSettings.refinementEngine` で行う。
///
/// クラウド AI の送信先は Claude API だけ（`CloudRefinement` が送るのは Claude だけのため）。
/// 送信には、ここでの選択に加えて同意・API キーが要る（AC-06, AC-12）。月次予算を設定したときは単価表も要る（AI-04）。
public enum RefinementProviderChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// ローカルのルールベース整形（オフライン, AI-03。既定）
  case localBasic
  /// Claude API による整形（AI-01）。送信には同意が要る（AC-06）
  case claude

  public var id: Self { self }

  /// 保存済みの処理系から選択肢を作る。クラウド AI は Claude を指す
  public init(engine: RefinementEngine) {
    switch engine {
    case .localBasic: self = .localBasic
    case .cloudAI: self = .claude
    }
  }

  /// 保存する処理系
  public var engine: RefinementEngine {
    switch self {
    case .localBasic: .localBasic
    case .claude: .cloudAI
    }
  }
}

/// iOS の整形・予算の設定画面の入力中の値（2.3節, AI-03, AI-04, AI-05, iOS-10）。
///
/// macOS の設定画面（Apps/macOS の `SettingsForm`）のうち、処理系・整形用モデル名・月次予算・単価表だけを扱う。
/// 金額は文字列のまま持ち、保存するとき（`applied(to:)`）にまとめて検証する。検証に通らない項目があれば
/// 何も保存せず、項目ごとの問題（`RefinementSettingsIssue`）を返す。
/// 画面が扱わない項目（同意状態・整形モードなど）は保存の基準にした設定の値をそのまま残す。
///
/// 金額は地域設定によらず、半角数字と小数点（`.`）だけを受け付ける（桁区切り・符号は使わない）。
public struct RefinementSettingsForm: Hashable, Sendable {
  /// 単価表の1行（AI-05）。100万トークンあたりの単価
  public struct PriceRow: Hashable, Sendable, Identifiable {
    public let id: Int
    public var model: String
    public var inputPerMillionTokens: String
    public var outputPerMillionTokens: String

    /// すべて空の行は保存しない（追加したまま入力しなかった行）
    public var isBlank: Bool {
      [model, inputPerMillionTokens, outputPerMillionTokens].allSatisfy {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
  }

  // MARK: 整形（2.3節, AI-03）

  public var provider: RefinementProviderChoice
  public var refinementModel: String

  // MARK: 予算と単価表（AI-04, AI-05）

  public var budgetEnabled: Bool
  public var budgetLimit: String
  /// 予算と単価表の通貨（ISO 4217）。異なる通貨の値を比べないよう、両方に同じ通貨を使う
  public var currencyCode: String
  public var priceUpdatedOn: CalendarDay?
  public var priceRows: [PriceRow]

  /// 行の識別子の採番。行を削除しても取り違えないよう、値ではなく識別子で行を指す
  private var nextRowID = 0

  /// 保存済みの設定から入力欄の値を作る
  public init(settings: AppSettings) {
    provider = RefinementProviderChoice(engine: settings.refinementEngine)
    refinementModel = settings.refinementModel
    budgetEnabled = settings.monthlyBudget != nil
    budgetLimit = settings.monthlyBudget.map { Self.text(amount: $0.limitAmount) } ?? ""
    // 単価表と予算の通貨は同じ欄で編集する。保存値で異なっていれば単価表の通貨を採る（保存すると両方そろう）
    currencyCode =
      settings.priceTable.currencyCode ?? settings.monthlyBudget?.currencyCode ?? ""
    priceUpdatedOn = settings.priceTable.updatedOn
    priceRows = []
    for price in settings.priceTable.prices {
      priceRows.append(
        PriceRow(
          id: makeRowID(), model: price.model,
          inputPerMillionTokens: Self.text(amount: price.inputPerMillionTokens),
          outputPerMillionTokens: Self.text(amount: price.outputPerMillionTokens)))
    }
  }

  // MARK: - 行の追加・削除

  public mutating func addPriceRow() {
    priceRows.append(
      PriceRow(id: makeRowID(), model: "", inputPerMillionTokens: "", outputPerMillionTokens: ""))
  }

  public mutating func removePriceRow(id: Int) {
    priceRows.removeAll { $0.id == id }
  }

  private mutating func makeRowID() -> Int {
    defer { nextRowID += 1 }
    return nextRowID
  }

  // MARK: - 案内

  /// 入力中の値について、保存はできるが利用者に知らせる事柄。並びは画面に出す順
  public var notices: [RefinementSettingsNotice] {
    guard provider == .claude else { return [] }
    guard budgetEnabled else { return [.budgetNotSet] }
    let model = refinementModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let listed = priceRows.contains {
      $0.model.trimmingCharacters(in: .whitespacesAndNewlines) == model
    }
    var notices: [RefinementSettingsNotice] = []
    if priceUpdatedOn == nil {
      notices.append(.priceUpdatedOnNotSet)
    }
    if !model.isEmpty, !listed {
      notices.append(.refinementModelNotInPriceTable)
    }
    return notices
  }

  // MARK: - 検証と保存する値

  /// 入力を検証し、`base` に画面の項目を反映した設定を返す。
  /// 問題があれば、見つかった問題をすべて `RefinementSettingsValidationError` で投げる（一部だけを反映しない）
  public func applied(
    to base: AppSettings
  ) throws(RefinementSettingsValidationError) -> AppSettings {
    var issues: [RefinementSettingsIssue] = []
    var settings = base

    settings.refinementEngine = provider.engine
    let model = refinementModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if model.isEmpty {
      issues.append(.refinementModelEmpty)
    } else {
      settings.refinementModel = model
    }
    applyCost(to: &settings, issues: &issues)

    guard issues.isEmpty else {
      throw RefinementSettingsValidationError(issues: issues)
    }
    return settings
  }

  private func applyCost(
    to settings: inout AppSettings, issues: inout [RefinementSettingsIssue]
  ) {
    let rows = priceRows.filter { !$0.isBlank }
    let trimmedCurrency = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
    // 正規化（大文字化）と形の検査は保存用の型に任せる
    let currency = PriceTableSetting(currencyCode: trimmedCurrency).currencyCode
    let currencyNeeded = budgetEnabled || !rows.isEmpty
    if currency == nil, !trimmedCurrency.isEmpty || currencyNeeded {
      issues.append(.currencyCode)
    }

    if budgetEnabled {
      let limit = Self.amount(budgetLimit)
      if limit == nil {
        issues.append(.budgetLimit)
      }
      if let limit, let currency {
        settings.monthlyBudget = MonthlyBudgetSetting(limitAmount: limit, currencyCode: currency)
      }
    } else {
      settings.monthlyBudget = nil
    }

    if !rows.isEmpty, priceUpdatedOn == nil {
      issues.append(.priceUpdatedOnMissing)
    }
    var prices: [ModelPriceSetting] = []
    var seenModels: Set<String> = []
    for row in rows {
      let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
      if model.isEmpty {
        issues.append(.priceModelEmpty(rowID: row.id))
      } else if !seenModels.insert(model).inserted {
        issues.append(.priceModelDuplicate(rowID: row.id))
      }
      guard let input = Self.amount(row.inputPerMillionTokens),
        let output = Self.amount(row.outputPerMillionTokens)
      else {
        issues.append(.priceAmount(rowID: row.id))
        continue
      }
      if let price = ModelPriceSetting(
        model: model, inputPerMillionTokens: input, outputPerMillionTokens: output)
      {
        prices.append(price)
      }
    }
    settings.priceTable = PriceTableSetting(
      currencyCode: currency, updatedOn: priceUpdatedOn, prices: prices)
  }

  // MARK: - 文字列と値の変換

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// 半角数字と小数点（`.`）だけの 0 以上の数。桁区切り・符号・指数表記・全角数字は受け付けない
  public static func amount(_ text: String) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil else { return nil }
    return Decimal(string: trimmed, locale: posix)
  }

  /// 地域設定によらず、小数点を `.` にした文字列
  public static func text(amount: Decimal) -> String {
    NSDecimalNumber(decimal: amount).description(withLocale: posix)
  }

  /// 日付選択の値を、その暦での年月日にする
  public static func calendarDay(of date: Date, in calendar: Calendar) -> CalendarDay? {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return nil }
    return CalendarDay(year: year, month: month, day: day)
  }

  /// 年月日を、その暦での日付選択の値にする
  public static func date(of day: CalendarDay, in calendar: Calendar) -> Date? {
    calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
  }
}

/// 設定を保存できない理由。利用者の入力値（モデル名・金額など）は含めず、項目と行の識別子だけを持つ
public struct RefinementSettingsValidationError: Error, Hashable, Sendable {
  public let issues: [RefinementSettingsIssue]
}

/// 入力の問題（項目ごと）
public enum RefinementSettingsIssue: Hashable, Sendable {
  /// 整形用モデル名が空（AI-07）
  case refinementModelEmpty
  /// 月次予算の上限が 0 以上の数でない（負の数・桁区切り・全角数字を含む, AI-04, AI-05）
  case budgetLimit
  /// 通貨コードが ISO 4217 の形でない、または予算・単価表があるのに空
  case currencyCode
  /// 単価があるのに更新日がない（AI-05）
  case priceUpdatedOnMissing
  case priceModelEmpty(rowID: Int)
  case priceModelDuplicate(rowID: Int)
  /// 単価が 0 以上の数でない
  case priceAmount(rowID: Int)

  /// 行に属する問題なら、その行の識別子
  public var rowID: Int? {
    switch self {
    case .priceModelEmpty(let id), .priceModelDuplicate(let id), .priceAmount(let id):
      id
    case .refinementModelEmpty, .budgetLimit, .currencyCode, .priceUpdatedOnMissing:
      nil
    }
  }

  /// 画面に出す文言。利用者の入力値は埋め込まない
  public var message: String {
    switch self {
    case .refinementModelEmpty:
      "整形用モデル名を入力してください。"
    case .budgetLimit:
      "月次予算は 0 以上の数を半角で入力してください（桁区切りなし）。"
    case .currencyCode:
      "通貨は USD・JPY のような英字3文字で入力してください（予算か単価を入れるときは必須）。"
    case .priceUpdatedOnMissing:
      "単価表の更新日を入力してください。"
    case .priceModelEmpty:
      "モデル名を入力してください。"
    case .priceModelDuplicate:
      "同じモデルの単価がほかの行にあります。"
    case .priceAmount:
      "単価は 0 以上の数を半角で入力してください（桁区切りなし）。"
    }
  }
}

/// 保存はできるが利用者に知らせる事柄
public enum RefinementSettingsNotice: Hashable, Sendable {
  /// Claude を選んでいるが、月次予算が未設定（AI-04）。上限なしで送信し、推定費用は記録しない
  case budgetNotSet
  /// 月次予算はあるが、単価表の更新日が未設定（AI-05）。費用を推定できない
  case priceUpdatedOnNotSet
  /// 月次予算はあるが、単価表に整形用モデルがない（AI-05）。費用を推定できない
  case refinementModelNotInPriceTable

  public var message: String {
    switch self {
    case .budgetNotSet:
      "月次予算が未設定のため、上限なしで Claude へ送信します。推定費用は記録しません。"
    case .priceUpdatedOnNotSet:
      "単価表の更新日が未設定のため、費用を推定できません。推定できない間は Claude へ送信しません。"
    case .refinementModelNotInPriceTable:
      "単価表に整形用モデルがないため、費用を推定できません。推定できない間は Claude へ送信しません。"
    }
  }
}
