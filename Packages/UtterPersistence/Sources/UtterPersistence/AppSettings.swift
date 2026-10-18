import Foundation
import UtterCore

/// アプリケーション設定（2.1節, 2.3節, 5章, 7章）。保存は `AppSettingsStore` が行う。
///
/// 壊れた値・型が合わない値は項目ごとに既定値へ戻し、未知の版はすべて既定値で復元する。
/// 同意状態は、読めなければ「すべて未同意」に倒す（AC-06）。
/// API キー・トークンを入れる項目は持たない（Keychain の責務）。項目を足すときも秘密情報を入れない。
public struct AppSettings: Hashable, Sendable {
  /// 現在の設定の版番号。保存形式を変えたら上げ、`init(from:)` の移行の入口に旧版からの読み替えを足す
  public static let currentVersion = 1

  /// 最大録音時間の既定値（秒）。REC-05（暫定5分）
  public static let defaultMaxRecordingDuration = Double(
    SessionConfiguration.defaultMaxRecordingDuration.components.seconds)

  /// 整形用モデル名の既定値（AI-07）
  public static let defaultRefinementModel = "claude-3-5-sonnet-20241022"

  /// 設定の版番号。常に `currentVersion`
  public var version: Int { Self.currentVersion }

  /// 最大録音時間（秒）。REC-05。0 以下・非有限の値は既定値に戻す
  public var maxRecordingDuration: Double {
    didSet { maxRecordingDuration = Self.normalizedMaxRecordingDuration(maxRecordingDuration) }
  }

  /// 整形の処理系（Local Basic / クラウド AI）。AI-03
  public var refinementEngine: RefinementEngine

  /// アプリ別のスタイル上書き（CTX-02）。キーは小文字に正規化した bundle ID（`AppStyleResolver` と同じ）
  public var appStyleOverrides: [String: RefinementStyle] {
    didSet { appStyleOverrides = Self.normalizedOverrides(appStyleOverrides) }
  }

  /// 整形用 AI モデル名（AI-07）。空白だけの値は既定値に戻す
  public var refinementModel: String {
    didSet { refinementModel = Self.normalizedModel(refinementModel) }
  }

  /// 単価表と更新日（AI-05）。既定は空（費用を推定できない）
  public var priceTable: PriceTableSetting

  /// 月次予算（AI-04, AI-05）。未設定なら `nil`
  public var monthlyBudget: MonthlyBudgetSetting?

  /// クラウド送信の同意状態（AC-06, AI-04）。既定はすべて未同意
  public var consentState: ConsentState

  /// 履歴の記録を有効にするか（既定: 無効, 7章）
  public var historyEnabled: Bool

  /// 利用者が指定した除外アプリ（7章, AC-12）。`SensitiveInputPolicy(excludedApps:)` に渡す。
  /// 表示のため入力した値をそのまま持ち、空白だけの値と重複は除く
  public var excludedApps: [String] {
    didSet { excludedApps = Self.normalizedExcludedApps(excludedApps) }
  }

  /// 既定値を使う設定を作成する
  public init(
    maxRecordingDuration: Double = AppSettings.defaultMaxRecordingDuration,
    refinementEngine: RefinementEngine = .localBasic,
    appStyleOverrides: [String: RefinementStyle] = [:],
    refinementModel: String = AppSettings.defaultRefinementModel,
    priceTable: PriceTableSetting = .empty,
    monthlyBudget: MonthlyBudgetSetting? = nil,
    consentState: ConsentState = ConsentState(),
    historyEnabled: Bool = false,
    excludedApps: [String] = []
  ) {
    self.maxRecordingDuration = Self.normalizedMaxRecordingDuration(maxRecordingDuration)
    self.refinementEngine = refinementEngine
    self.appStyleOverrides = Self.normalizedOverrides(appStyleOverrides)
    self.refinementModel = Self.normalizedModel(refinementModel)
    self.priceTable = priceTable
    self.monthlyBudget = monthlyBudget
    self.consentState = consentState
    self.historyEnabled = historyEnabled
    self.excludedApps = Self.normalizedExcludedApps(excludedApps)
  }

  private static func normalizedMaxRecordingDuration(_ value: Double) -> Double {
    value.isFinite && value > 0 ? value : defaultMaxRecordingDuration
  }

  /// 空の bundle ID を除き、小文字にそろえる。大文字・小文字だけが異なるキーは `AppStyleResolver` と同じく
  /// Unicode スカラー順で先のキーの値を採る
  private static func normalizedOverrides(
    _ overrides: [String: RefinementStyle]
  ) -> [String: RefinementStyle] {
    var result: [String: RefinementStyle] = [:]
    for key in overrides.keys.sorted() where !key.isEmpty {
      let normalizedKey = key.lowercased()
      if result[normalizedKey] == nil {
        result[normalizedKey] = overrides[key]
      }
    }
    return result
  }

  private static func normalizedModel(_ model: String) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultRefinementModel : model
  }

  private static func normalizedExcludedApps(_ apps: [String]) -> [String] {
    var seen: Set<String> = []
    return apps.filter { app in
      let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return !key.isEmpty && seen.insert(key).inserted
    }
  }
}

// MARK: - Codable

extension AppSettings: Codable {
  enum CodingKeys: String, CodingKey, CaseIterable {
    case version
    case maxRecordingDuration
    case refinementEngine
    case appStyleOverrides
    case refinementModel
    case priceTable
    case monthlyBudget
    case consentState
    case historyEnabled
    case excludedApps
  }

  /// 失敗しない。読めない値は項目ごとに既定値へ戻し、未知の版（現在より新しい・1 未満・数値でない）は
  /// すべて既定値で復元する。版番号がない保存値は版 1 として読む
  public init(from decoder: any Decoder) {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self.init()
      return
    }
    let version: Int?
    if container.contains(.version) {
      version = try? container.decode(Int.self, forKey: .version)
    } else {
      version = 1
    }

    // 移行の入口。版 2 を作るときは、旧版の値をここで現在の形に読み替える
    switch version {
    case 1:
      self.init(decodingVersion1From: container)
    default:
      self.init()
    }
  }

  private init(decodingVersion1From container: KeyedDecodingContainer<CodingKeys>) {
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
    self.init(
      maxRecordingDuration: value(Double.self, .maxRecordingDuration)
        ?? Self.defaultMaxRecordingDuration,
      refinementEngine: value(RefinementEngine.self, .refinementEngine) ?? .localBasic,
      appStyleOverrides: Self.decodeOverrides(from: container),
      refinementModel: value(String.self, .refinementModel) ?? Self.defaultRefinementModel,
      priceTable: value(PriceTableSetting.self, .priceTable) ?? .empty,
      monthlyBudget: value(MonthlyBudgetSetting.self, .monthlyBudget),
      // 読めない同意は未同意に倒す（AC-06）
      consentState: value(ConsentState.self, .consentState) ?? ConsentState(),
      historyEnabled: value(Bool.self, .historyEnabled) ?? false,
      excludedApps: Self.decodeExcludedApps(from: container))
  }

  /// 読めないスタイルの項目だけを除く
  private static func decodeOverrides(
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> [String: RefinementStyle] {
    let entries =
      (try? container.decodeIfPresent([String: LossyStyle].self, forKey: .appStyleOverrides)) ?? nil
    return (entries ?? [:]).compactMapValues(\.style)
  }

  /// 文字列でない要素だけを除く
  private static func decodeExcludedApps(
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> [String] {
    guard var items = try? container.nestedUnkeyedContainer(forKey: .excludedApps) else {
      return []
    }
    var apps: [String] = []
    while !items.isAtEnd {
      if let app = try? items.decode(String.self) {
        apps.append(app)
      } else if (try? items.decode(SkippedValue.self)) == nil {
        break
      }
    }
    return apps
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(maxRecordingDuration, forKey: .maxRecordingDuration)
    try container.encode(refinementEngine, forKey: .refinementEngine)
    try container.encode(appStyleOverrides, forKey: .appStyleOverrides)
    try container.encode(refinementModel, forKey: .refinementModel)
    try container.encode(priceTable, forKey: .priceTable)
    try container.encodeIfPresent(monthlyBudget, forKey: .monthlyBudget)
    try container.encode(consentState, forKey: .consentState)
    try container.encode(historyEnabled, forKey: .historyEnabled)
    try container.encode(excludedApps, forKey: .excludedApps)
  }
}

/// 読めないスタイルを `nil` にする
private struct LossyStyle: Decodable {
  let style: RefinementStyle?

  init(from decoder: any Decoder) throws {
    style = try? RefinementStyle(from: decoder)
  }
}

/// 整形の処理系（AI-03）。整形モード（Raw / Natural / Structured, TXT-01）とは別の設定
public enum RefinementEngine: String, Codable, Hashable, Sendable, CaseIterable {
  /// ローカルのルールベース整形（オフライン, AI-03）
  case localBasic
  /// クラウド AI による整形（Claude / ChatGPT, AI-01, AI-06）。送信には同意が要る（AC-06）
  case cloudAI
}
