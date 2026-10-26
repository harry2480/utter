import Foundation
import UtterCore
import UtterPersistence

/// 設定画面の入力中の値（2.1〜2.3節, 5章, 6章, 7章, AC-05, AC-12）。
///
/// 数値・通貨・単価・bundle ID・サイトは文字列のまま持ち、保存するとき（`applied(to:)`）にまとめて検証する。
/// 検証に通らない項目があれば何も保存せず、項目ごとの問題（`SettingsIssue`）を返す。
/// 画面が扱わない項目（同意状態・履歴・録音ショートカット）は保存の基準にした設定の値をそのまま残す。
///
/// 金額と秒数は地域設定によらず、半角数字と小数点（`.`）だけを受け付ける（桁区切りは使わない）。
struct SettingsForm: Hashable, Sendable {
  /// 単価表の1行（AI-05）。100万トークンあたりの単価
  struct PriceRow: Hashable, Sendable, Identifiable {
    let id: Int
    var model: String
    var inputPerMillionTokens: String
    var outputPerMillionTokens: String

    /// すべて空の行は保存しない（追加したまま入力しなかった行）
    var isBlank: Bool {
      [model, inputPerMillionTokens, outputPerMillionTokens].allSatisfy {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
  }

  /// アプリ別・サイト別のスタイル上書きの1行（CTX-02）。`key` は bundle ID またはサイト（ホスト名・URL）
  struct StyleOverrideRow: Hashable, Sendable, Identifiable {
    let id: Int
    var key: String
    var style: RefinementStyle

    /// キーが空の行は保存しない
    var isBlank: Bool {
      key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// 除外アプリの1行（7章, AC-12）
  struct ExcludedAppRow: Hashable, Sendable, Identifiable {
    let id: Int
    var bundleID: String

    /// 空の行は保存しない
    var isBlank: Bool {
      bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  // MARK: 録音・入力（2.1節, 2.2節, 6章）

  var recordingTrigger: ShortcutTriggerMode
  var inputMode: InputMode
  /// 最大録音時間（秒, REC-05）
  var maxRecordingSeconds: String
  var modelRetentionMode: ModelRetentionModeSetting
  var performanceRetentionAllowed: Bool

  // MARK: 整形（2.3節, 5章）

  var provider: RefinementProviderChoice
  var refinementMode: RefinementModeSetting
  var refinementModel: String

  // MARK: 予算と単価表（AI-04, AI-05）

  var budgetEnabled: Bool
  var budgetLimit: String
  /// 予算と単価表の通貨（ISO 4217）。異なる通貨の値を比べないよう、両方に同じ通貨を使う
  var currencyCode: String
  var priceUpdatedOn: CalendarDay?
  var priceRows: [PriceRow]

  // MARK: スタイル（CTX-01, CTX-02）

  var appStyleRows: [StyleOverrideRow]
  var siteIdentificationAllowed: Bool
  var siteStyleRows: [StyleOverrideRow]

  // MARK: 除外アプリ（7章, AC-12）

  /// 利用者が指定した除外アプリ。保存した順に並べる
  var excludedAppRows: [ExcludedAppRow]

  /// 行の識別子の採番。画面の行を並べ替え・削除しても取り違えないよう、値ではなく識別子で行を指す
  private var nextRowID = 0

  /// 保存済みの設定から入力欄の値を作る
  init(settings: AppSettings) {
    recordingTrigger = settings.recordingTrigger
    inputMode = settings.inputMode
    maxRecordingSeconds = Self.text(seconds: settings.maxRecordingDuration)
    modelRetentionMode = settings.modelRetentionMode
    performanceRetentionAllowed = settings.performanceRetentionAllowed

    provider = RefinementProviderChoice(engine: settings.refinementEngine)
    refinementMode = settings.refinementMode
    refinementModel = settings.refinementModel

    budgetEnabled = settings.monthlyBudget != nil
    budgetLimit = settings.monthlyBudget.map { Self.text(amount: $0.limitAmount) } ?? ""
    // 単価表と予算の通貨は同じ欄で編集する。保存値で異なっていれば単価表の通貨を採る（保存すると両方そろう）
    currencyCode =
      settings.priceTable.currencyCode ?? settings.monthlyBudget?.currencyCode ?? ""
    priceUpdatedOn = settings.priceTable.updatedOn
    priceRows = []
    appStyleRows = []
    siteIdentificationAllowed = settings.siteIdentificationAllowed
    siteStyleRows = []
    excludedAppRows = []

    for price in settings.priceTable.prices {
      priceRows.append(
        PriceRow(
          id: makeRowID(), model: price.model,
          inputPerMillionTokens: Self.text(amount: price.inputPerMillionTokens),
          outputPerMillionTokens: Self.text(amount: price.outputPerMillionTokens)))
    }
    for (bundleID, style) in settings.appStyleOverrides.sorted(by: { $0.key < $1.key }) {
      appStyleRows.append(StyleOverrideRow(id: makeRowID(), key: bundleID, style: style))
    }
    for (host, style) in settings.siteStyleOverrides.sorted(by: { $0.key < $1.key }) {
      siteStyleRows.append(StyleOverrideRow(id: makeRowID(), key: host, style: style))
    }
    for bundleID in settings.excludedApps {
      excludedAppRows.append(ExcludedAppRow(id: makeRowID(), bundleID: bundleID))
    }
  }

  // MARK: - 行の追加・削除

  mutating func addPriceRow() {
    priceRows.append(
      PriceRow(id: makeRowID(), model: "", inputPerMillionTokens: "", outputPerMillionTokens: ""))
  }

  mutating func removePriceRow(id: Int) {
    priceRows.removeAll { $0.id == id }
  }

  mutating func addAppStyleRow() {
    appStyleRows.append(StyleOverrideRow(id: makeRowID(), key: "", style: .standard))
  }

  mutating func removeAppStyleRow(id: Int) {
    appStyleRows.removeAll { $0.id == id }
  }

  mutating func addSiteStyleRow() {
    siteStyleRows.append(StyleOverrideRow(id: makeRowID(), key: "", style: .standard))
  }

  mutating func removeSiteStyleRow(id: Int) {
    siteStyleRows.removeAll { $0.id == id }
  }

  mutating func addExcludedAppRow() {
    excludedAppRows.append(ExcludedAppRow(id: makeRowID(), bundleID: ""))
  }

  /// 起動中のアプリなどから bundle ID を指定して追加する。bundle ID の形でない・すでに一覧にある
  /// （大文字・小文字の違いは同じアプリとみなす）ときは追加せず `false` を返す
  @discardableResult
  mutating func addExcludedApp(bundleID: String) -> Bool {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isPlausibleBundleID(trimmed), !containsExcludedApp(trimmed) else { return false }
    excludedAppRows.append(ExcludedAppRow(id: makeRowID(), bundleID: trimmed))
    return true
  }

  mutating func removeExcludedAppRow(id: Int) {
    excludedAppRows.removeAll { $0.id == id }
  }

  /// 一覧に同じアプリ（大文字・小文字・前後の空白の違いを除く）があるか
  func containsExcludedApp(_ bundleID: String) -> Bool {
    let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return excludedAppRows.contains {
      $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
    }
  }

  private mutating func makeRowID() -> Int {
    defer { nextRowID += 1 }
    return nextRowID
  }

  // MARK: - 案内

  /// 入力中の値について、保存はできるが利用者に知らせる事柄。並びは画面に出す順
  var notices: [SettingsNotice] {
    var notices: [SettingsNotice] = []
    if modelRetentionMode == .performance, !performanceRetentionAllowed {
      notices.append(.performanceRetentionNotAllowed)
    }
    if provider == .claude {
      if !budgetEnabled {
        notices.append(.budgetNotSet)
      } else {
        let model = refinementModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = priceRows.contains {
          $0.model.trimmingCharacters(in: .whitespacesAndNewlines) == model
        }
        if !model.isEmpty, !listed {
          notices.append(.refinementModelNotInPriceTable)
        }
      }
    }
    return notices
  }

  // MARK: - 検証と保存する値

  /// 入力を検証し、`base` に画面の項目を反映した設定を返す。
  /// 問題があれば、見つかった問題をすべて `SettingsValidationError` で投げる（一部だけを反映しない）
  func applied(to base: AppSettings) throws(SettingsValidationError) -> AppSettings {
    var issues: [SettingsIssue] = []
    var settings = base

    settings.recordingTrigger = recordingTrigger
    settings.inputMode = inputMode
    settings.modelRetentionMode = modelRetentionMode
    settings.performanceRetentionAllowed = performanceRetentionAllowed
    if let seconds = Self.amount(maxRecordingSeconds),
      AppSettings.maxRecordingDurationRange.contains(seconds.doubleValue)
    {
      settings.maxRecordingDuration = seconds.doubleValue
    } else {
      issues.append(.maxRecordingDuration)
    }

    if let engine = provider.engine {
      settings.refinementEngine = engine
    } else {
      issues.append(.providerUnavailable)
    }
    settings.refinementMode = refinementMode
    let model = refinementModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if model.isEmpty {
      issues.append(.refinementModelEmpty)
    } else {
      settings.refinementModel = model
    }

    applyCost(to: &settings, issues: &issues)
    applyStyles(to: &settings, issues: &issues)
    applyExcludedApps(to: &settings, issues: &issues)

    guard issues.isEmpty else {
      throw SettingsValidationError(issues: issues)
    }
    return settings
  }

  private func applyCost(to settings: inout AppSettings, issues: inout [SettingsIssue]) {
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

  private func applyStyles(to settings: inout AppSettings, issues: inout [SettingsIssue]) {
    var appOverrides: [String: RefinementStyle] = [:]
    for row in appStyleRows where !row.isBlank {
      let bundleID = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isPlausibleBundleID(bundleID) else {
        issues.append(.appBundleID(rowID: row.id))
        continue
      }
      // 大文字・小文字の違いは同じアプリとみなす（`AppStyleResolver` と同じ）
      guard appOverrides.updateValue(row.style, forKey: bundleID.lowercased()) == nil else {
        issues.append(.appBundleIDDuplicate(rowID: row.id))
        continue
      }
    }
    settings.appStyleOverrides = appOverrides

    var siteOverrides: [String: RefinementStyle] = [:]
    for row in siteStyleRows where !row.isBlank {
      // 保存時（`AppSettings`）にも `SiteHost(host:)` で正規化されるため、同じ正規化を通した値で重複を判定する
      // （`www.www.example.com` のように、正規化を重ねると変わる値で行が黙って消えないように）
      guard let input = SiteHost(userInput: row.key), let host = SiteHost(host: input.rawValue)
      else {
        issues.append(.siteHost(rowID: row.id))
        continue
      }
      // `www.` の有無・スキーム・パスの違いは同じサイトとみなす（`SiteHost` の正規化）
      guard siteOverrides.updateValue(row.style, forKey: host.rawValue) == nil else {
        issues.append(.siteHostDuplicate(rowID: row.id))
        continue
      }
    }
    settings.siteIdentificationAllowed = siteIdentificationAllowed
    settings.siteStyleOverrides = siteOverrides
  }

  private func applyExcludedApps(to settings: inout AppSettings, issues: inout [SettingsIssue]) {
    var apps: [String] = []
    var seen: Set<String> = []
    for row in excludedAppRows where !row.isBlank {
      let bundleID = row.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isPlausibleBundleID(bundleID) else {
        issues.append(.excludedAppBundleID(rowID: row.id))
        continue
      }
      // 大文字・小文字の違いは同じアプリとみなす（`SensitiveInputPolicy` と同じ）
      guard seen.insert(bundleID.lowercased()).inserted else {
        issues.append(.excludedAppDuplicate(rowID: row.id))
        continue
      }
      apps.append(bundleID)
    }
    settings.excludedApps = apps
  }

  // MARK: - 文字列と値の変換

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// 半角数字と小数点（`.`）だけの 0 以上の数。桁区切り・符号・指数表記・全角数字は受け付けない
  static func amount(_ text: String) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil else { return nil }
    return Decimal(string: trimmed, locale: posix)
  }

  /// 地域設定によらず、小数点を `.` にした文字列
  static func text(amount: Decimal) -> String {
    NSDecimalNumber(decimal: amount).description(withLocale: posix)
  }

  static func text(seconds: Double) -> String {
    text(amount: Decimal(seconds))
  }

  /// bundle ID として入力ミスでないか。ASCII の英数字・`.`・`-`・`_` だけからなる
  static func isPlausibleBundleID(_ text: String) -> Bool {
    !text.isEmpty
      && text.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII
          && (CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar))
      }
  }

  /// 日付選択の値を、その暦での年月日にする
  static func calendarDay(of date: Date, in calendar: Calendar) -> CalendarDay? {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return nil }
    return CalendarDay(year: year, month: month, day: day)
  }

  /// 年月日を、その暦での日付選択の値にする
  static func date(of day: CalendarDay, in calendar: Calendar) -> Date? {
    calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
  }
}

extension Decimal {
  fileprivate var doubleValue: Double {
    NSDecimalNumber(decimal: self).doubleValue
  }
}

/// 設定を保存できない理由。利用者の入力値（bundle ID・サイト・モデル名など）は含めず、項目と行の識別子だけを持つ
struct SettingsValidationError: Error, Hashable, Sendable {
  let issues: [SettingsIssue]
}

/// 入力の問題（項目ごと）
enum SettingsIssue: Hashable, Sendable {
  /// 最大録音時間が数でない、または範囲外（REC-05）
  case maxRecordingDuration
  /// 選べない処理系（ChatGPT）が選ばれている（AC-05）
  case providerUnavailable
  /// 整形用モデル名が空（AI-07）
  case refinementModelEmpty
  /// 月次予算の上限が数でない（AI-04, AI-05）
  case budgetLimit
  /// 通貨コードが ISO 4217 の形でない、または予算・単価表があるのに空
  case currencyCode
  /// 単価があるのに更新日がない（AI-05）
  case priceUpdatedOnMissing
  case priceModelEmpty(rowID: Int)
  case priceModelDuplicate(rowID: Int)
  /// 単価が数でない
  case priceAmount(rowID: Int)
  case appBundleID(rowID: Int)
  case appBundleIDDuplicate(rowID: Int)
  /// ホスト名・URL として読めない（CTX-02）
  case siteHost(rowID: Int)
  case siteHostDuplicate(rowID: Int)
  /// 除外アプリの bundle ID の形でない（7章, AC-12）
  case excludedAppBundleID(rowID: Int)
  case excludedAppDuplicate(rowID: Int)

  /// 行に属する問題なら、その行の識別子
  var rowID: Int? {
    switch self {
    case .priceModelEmpty(let id), .priceModelDuplicate(let id), .priceAmount(let id),
      .appBundleID(let id), .appBundleIDDuplicate(let id), .siteHost(let id),
      .siteHostDuplicate(let id), .excludedAppBundleID(let id), .excludedAppDuplicate(let id):
      id
    default:
      nil
    }
  }

  /// 画面に出す文言。利用者の入力値は埋め込まない
  var message: String {
    switch self {
    case .maxRecordingDuration:
      let range = AppSettings.maxRecordingDurationRange
      return "最大録音時間は \(Int(range.lowerBound))〜\(Int(range.upperBound)) 秒の数で入力してください。"
    case .providerUnavailable:
      return "ChatGPT はまだ選べません。Local Basic か Claude を選んでください。"
    case .refinementModelEmpty:
      return "整形用モデル名を入力してください。"
    case .budgetLimit:
      return "月次予算は 0 以上の数を半角で入力してください（桁区切りなし）。"
    case .currencyCode:
      return "通貨は USD・JPY のような英字3文字で入力してください（予算か単価を入れるときは必須）。"
    case .priceUpdatedOnMissing:
      return "単価表の更新日を入力してください。"
    case .priceModelEmpty:
      return "モデル名を入力してください。"
    case .priceModelDuplicate:
      return "同じモデルの単価がほかの行にあります。"
    case .priceAmount:
      return "単価は 0 以上の数を半角で入力してください（桁区切りなし）。"
    case .appBundleID:
      return "bundle ID は英数字・ピリオド・ハイフン・アンダースコアで入力してください（例: com.apple.mail）。"
    case .appBundleIDDuplicate:
      return "同じアプリの上書きがほかの行にあります。"
    case .siteHost:
      return "サイトはホスト名か URL で入力してください（例: mail.example.com）。"
    case .siteHostDuplicate:
      return "同じサイトの上書きがほかの行にあります（www. の有無は同じサイトとみなします）。"
    case .excludedAppBundleID:
      return "bundle ID は英数字・ピリオド・ハイフン・アンダースコアで入力してください（例: com.example.app）。"
    case .excludedAppDuplicate:
      return "同じアプリがほかの行にあります（大文字・小文字の違いは同じアプリとみなします）。"
    }
  }
}

/// 保存はできるが利用者に知らせる事柄
enum SettingsNotice: Hashable, Sendable {
  /// 高速モードを選んでいるが、モデル保持を許可していない（6章）。バランスモードとして扱う
  case performanceRetentionNotAllowed
  /// クラウド AI を選んでいるが、月次予算が未設定（AI-04）
  case budgetNotSet
  /// 月次予算はあるが、単価表に整形用モデルがない（AI-05）。費用を推定できない
  case refinementModelNotInPriceTable

  var message: String {
    switch self {
    case .performanceRetentionNotAllowed:
      "高速モードでのモデル保持を許可していないため、バランスモードとして扱います。"
    case .budgetNotSet:
      "月次予算が未設定です。クラウド AI の推定費用に上限を設けるには、予算を設定してください。"
    case .refinementModelNotInPriceTable:
      "単価表に整形用モデルがないため、費用を推定できません。予算の判定では、推定できない送信は行いません。"
    }
  }
}
