import Foundation
import UtterCore

/// アプリケーション設定（2.1節, 2.2節, 2.3節, 5章, 6章, 7章）。保存は `AppSettingsStore` が行う。
///
/// 壊れた値・型が合わない値は項目ごとに既定値へ戻し、未知の版はすべて既定値で復元する。
/// 同意状態は、読めなければ「すべて未同意」に倒す（AC-06）。
/// API キー・トークンを入れる項目は持たない（Keychain の責務）。項目を足すときも秘密情報を入れない。
public struct AppSettings: Hashable, Sendable {
  /// 現在の設定の版番号。保存形式を変えたら上げ、`init(from:)` の移行の入口に旧版からの読み替えを足す。
  ///
  /// - 版 1：#119 時点の形式。それ以前の #76 の形式も版 1 を名乗るが、アプリが未リリースで利用者データが
  ///   ないため移行しない（読める項目だけ復元し、ほかは既定値になる）
  /// - 版 2：録音の操作方式・録音ショートカット・入力モード・整形モード・モデル保持モード、
  ///   サイト単位の識別の許可とサイト別のスタイル上書き（CTX-02）を追加。
  ///   版 1 の項目はそのまま引き継ぎ（旧既定の整形用モデル名だけ新しい既定値に置き換える）、追加した項目は既定値で補う。
  ///   サイト別の項目は版 2 のリリース前に足した。ない保存値は既定値（許可なし・上書きなし）で読むため、版を分けない
  public static let currentVersion = 2

  /// 最大録音時間の既定値（秒）。REC-05（暫定5分）
  public static let defaultMaxRecordingDuration = Double(
    SessionConfiguration.defaultMaxRecordingDuration.components.seconds)

  /// 最大録音時間として受け付ける範囲（秒）。REC-05。`Duration` へ変換して `SessionConfiguration` に渡せる範囲に限る
  /// （極端に大きい値は変換時に停止し、極端に小さい値は 0 に丸められて拒否されるため）。上限 1 時間は暫定
  public static let maxRecordingDurationRange: ClosedRange<Double> = 1...3600

  /// 整形用モデル名の既定値（AI-07: 低遅延の小型モデル）。Claude Haiku 5.5。
  /// 廃止・改名されたら既定値をここで直し、旧既定値のまま保存された設定は版の移行で新しい既定値に置き換える
  public static let defaultRefinementModel = "claude-haiku-5-5"

  /// 版 1 の整形用モデル名の既定値。提供終了しており、AI-07（低遅延の小型モデル）にも合わない。
  /// 版 1 は利用者が選ばなくても既定値を保存するため、この値は既定値のまま保存されたものとみなして移行する
  static let version1DefaultRefinementModel = "claude-3-5-sonnet-20241022"

  /// 設定の版番号。常に `currentVersion`
  public var version: Int { Self.currentVersion }

  /// 最大録音時間（秒）。REC-05。`maxRecordingDurationRange` の外・非有限の値は既定値に戻す
  public var maxRecordingDuration: Double {
    didSet { maxRecordingDuration = Self.normalizedMaxRecordingDuration(maxRecordingDuration) }
  }

  /// 録音の操作方式（Toggle / Push-to-talk）。REC-01, REC-02。既定は Toggle（1章: 初期録音操作は Toggle）
  public var recordingTrigger: ShortcutTriggerMode

  /// 録音ショートカット（REC-01, REC-02）。既定は未設定（`nil`）。
  ///
  /// 保存時は割り当てられるかを判定しない。修飾キー単独を使えるか・競合・Esc の予約は、
  /// 利用時に `ShortcutValidator`（`ShortcutCapabilities`）で判定する
  public var recordingShortcut: KeyCombination?

  /// 入力モード（2.2節）。既定は Instant（MVP 標準）
  public var inputMode: InputMode

  /// 整形モード（Raw / Natural / Structured, TXT-01）。既定は Natural
  public var refinementMode: RefinementModeSetting

  /// 整形の処理系（Local Basic / クラウド AI）。AI-03
  public var refinementEngine: RefinementEngine

  /// アプリ別のスタイル上書き（CTX-02）。キーは小文字に正規化した bundle ID（`AppStyleResolver` と同じ）
  public var appStyleOverrides: [String: RefinementStyle] {
    didSet { appStyleOverrides = Self.normalizedOverrides(appStyleOverrides) }
  }

  /// Web サイト単位の識別を許可しているか（CTX-02）。既定は無効（明示的許可制）。
  /// 許可を外してもサイト別の上書きは消さない（`SiteStyleResolver` と同じ）
  public var siteIdentificationAllowed: Bool

  /// サイト別のスタイル上書き（CTX-02）。キーは `SiteHost(host:)` で正規化したホスト名で、正規化できないキーは除く。
  /// ホスト名は閲覧先を表すため、ログに出さない・クラウドへ送らない（CTX-03）
  public var siteStyleOverrides: [String: RefinementStyle] {
    didSet { siteStyleOverrides = Self.normalizedSiteOverrides(siteStyleOverrides) }
  }

  /// 整形用 AI モデル名（AI-07）。前後の空白を除いて持ち、空になれば既定値に戻す
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

  /// STT モデルの保持モード（6章）。既定はバランスモード（標準）
  public var modelRetentionMode: ModelRetentionModeSetting

  /// 高速モードでのモデル保持を利用者が許可したか（6章）。既定は未許可。
  /// 許可がなければ、高速モードを選んでいてもバランスモードとして扱う（UtterSpeech の `ModelRetentionPolicy`）
  public var performanceRetentionAllowed: Bool

  /// 利用者が指定した除外アプリ（7章, AC-12）。`SensitiveInputPolicy(excludedApps:)` に渡す。
  /// 表示のため入力した値をそのまま持ち、空白だけの値と重複は除く
  public var excludedApps: [String] {
    didSet { excludedApps = Self.normalizedExcludedApps(excludedApps) }
  }

  /// 既定値を使う設定を作成する
  public init(
    maxRecordingDuration: Double = AppSettings.defaultMaxRecordingDuration,
    recordingTrigger: ShortcutTriggerMode = .toggle,
    recordingShortcut: KeyCombination? = nil,
    inputMode: InputMode = .instant,
    refinementMode: RefinementModeSetting = .natural,
    refinementEngine: RefinementEngine = .localBasic,
    appStyleOverrides: [String: RefinementStyle] = [:],
    siteIdentificationAllowed: Bool = false,
    siteStyleOverrides: [String: RefinementStyle] = [:],
    refinementModel: String = AppSettings.defaultRefinementModel,
    priceTable: PriceTableSetting = .empty,
    monthlyBudget: MonthlyBudgetSetting? = nil,
    consentState: ConsentState = ConsentState(),
    historyEnabled: Bool = false,
    modelRetentionMode: ModelRetentionModeSetting = .balanced,
    performanceRetentionAllowed: Bool = false,
    excludedApps: [String] = []
  ) {
    self.maxRecordingDuration = Self.normalizedMaxRecordingDuration(maxRecordingDuration)
    self.recordingTrigger = recordingTrigger
    self.recordingShortcut = recordingShortcut
    self.inputMode = inputMode
    self.refinementMode = refinementMode
    self.refinementEngine = refinementEngine
    self.appStyleOverrides = Self.normalizedOverrides(appStyleOverrides)
    self.siteIdentificationAllowed = siteIdentificationAllowed
    self.siteStyleOverrides = Self.normalizedSiteOverrides(siteStyleOverrides)
    self.refinementModel = Self.normalizedModel(refinementModel)
    self.priceTable = priceTable
    self.monthlyBudget = monthlyBudget
    self.consentState = consentState
    self.historyEnabled = historyEnabled
    self.modelRetentionMode = modelRetentionMode
    self.performanceRetentionAllowed = performanceRetentionAllowed
    self.excludedApps = Self.normalizedExcludedApps(excludedApps)
  }

  /// 前面アプリとサイトからスタイルを選ぶ判定器（CTX-01, CTX-02）。
  /// アプリ別の上書きは既定の対応表に重ね、サイト別の上書きは許可があるときだけ使う
  public var contextStyleResolver: ContextStyleResolver {
    ContextStyleResolver(
      app: AppStyleResolver(overrides: appStyleOverrides),
      site: SiteStyleResolver(
        isSiteIdentificationAllowed: siteIdentificationAllowed, overrides: siteStyleOverrides))
  }

  private static func normalizedMaxRecordingDuration(_ value: Double) -> Double {
    maxRecordingDurationRange.contains(value) ? value : defaultMaxRecordingDuration
  }

  /// `AppStyleResolver` と同じ規則でキーを正規化する
  private static func normalizedOverrides(
    _ overrides: [String: RefinementStyle]
  ) -> [String: RefinementStyle] {
    AppStyleResolver.normalizedKeys(overrides)
  }

  /// `SiteStyleResolver` と同じ規則でキーを正規化する。正規化できないキーは除き、
  /// 正規化後に重なるキーは Unicode スカラー順で先のキーの値を採る
  private static func normalizedSiteOverrides(
    _ overrides: [String: RefinementStyle]
  ) -> [String: RefinementStyle] {
    var result: [String: RefinementStyle] = [:]
    for key in overrides.keys.sorted() {
      guard let host = SiteHost(host: key), result[host.rawValue] == nil else { continue }
      result[host.rawValue] = overrides[key]
    }
    return result
  }

  private static func normalizedModel(_ model: String) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultRefinementModel : trimmed
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
    case recordingTrigger
    case recordingShortcut
    case inputMode
    case refinementMode
    case refinementEngine
    case appStyleOverrides
    case siteIdentificationAllowed
    case siteStyleOverrides
    case refinementModel
    case priceTable
    case monthlyBudget
    case consentState
    case historyEnabled
    case modelRetentionMode
    case performanceRetentionAllowed
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

    // 移行の入口。版を上げるときは、旧版の値をここで現在の形に読み替える
    switch version {
    case 1:
      self.init(decodingVersion1From: container)
      // 旧既定のモデル名だけ新しい既定値に置き換える（AI-07）。版 2 で利用者が選んだ値は書き換えない
      if refinementModel == Self.version1DefaultRefinementModel {
        refinementModel = Self.defaultRefinementModel
      }
    case 2:
      self.init(decodingVersion2From: container)
    default:
      self.init()
    }
  }

  /// 版 1 の項目だけを読み、版 2 で追加した項目は既定値にする
  private init(decodingVersion1From container: KeyedDecodingContainer<CodingKeys>) {
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      Self.decodedValue(type, key, in: container)
    }
    self.init(
      maxRecordingDuration: value(Double.self, .maxRecordingDuration)
        ?? Self.defaultMaxRecordingDuration,
      refinementEngine: value(RefinementEngine.self, .refinementEngine) ?? .localBasic,
      appStyleOverrides: Self.decodeOverrides(from: container, forKey: .appStyleOverrides),
      refinementModel: value(String.self, .refinementModel) ?? Self.defaultRefinementModel,
      priceTable: value(PriceTableSetting.self, .priceTable) ?? .empty,
      monthlyBudget: value(MonthlyBudgetSetting.self, .monthlyBudget),
      // 読めない同意は未同意に倒す（AC-06）
      consentState: value(ConsentState.self, .consentState) ?? ConsentState(),
      historyEnabled: value(Bool.self, .historyEnabled) ?? false,
      excludedApps: Self.decodeExcludedApps(from: container))
  }

  /// 版 1 の項目に、版 2 で追加した項目を加えて読む。読めない項目は既定値にする
  private init(decodingVersion2From container: KeyedDecodingContainer<CodingKeys>) {
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      Self.decodedValue(type, key, in: container)
    }
    // 版 1 の項目を読む。版 2 で追加した項目はここで既定値になり、読めなければその既定値を残す
    self.init(decodingVersion1From: container)
    recordingTrigger =
      value(ShortcutTriggerMode.self, .recordingTrigger) ?? recordingTrigger
    // 読めないショートカットは未設定に戻す（割り当てを推測で作らない）
    recordingShortcut = value(KeyCombination.self, .recordingShortcut)
    inputMode = value(InputMode.self, .inputMode) ?? inputMode
    refinementMode = value(RefinementModeSetting.self, .refinementMode) ?? refinementMode
    modelRetentionMode =
      value(ModelRetentionModeSetting.self, .modelRetentionMode) ?? modelRetentionMode
    // 読めない許可は未許可に倒す
    performanceRetentionAllowed =
      value(Bool.self, .performanceRetentionAllowed) ?? performanceRetentionAllowed
    // 読めないサイト単位の識別の許可は未許可に倒す（CTX-02）
    siteIdentificationAllowed =
      value(Bool.self, .siteIdentificationAllowed) ?? siteIdentificationAllowed
    // 初期化子の中では didSet が呼ばれないため、ここで正規化する
    siteStyleOverrides = Self.normalizedSiteOverrides(
      Self.decodeOverrides(from: container, forKey: .siteStyleOverrides))
  }

  /// 読めない・型が合わない値は `nil`
  private static func decodedValue<T: Decodable>(
    _ type: T.Type, _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
  ) -> T? {
    (try? container.decodeIfPresent(type, forKey: key)) ?? nil
  }

  /// 読めないスタイルの項目だけを除く
  private static func decodeOverrides(
    from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) -> [String: RefinementStyle] {
    let entries =
      (try? container.decodeIfPresent(
        [String: Lossy<RefinementStyle>].self, forKey: key)) ?? nil
    return (entries ?? [:]).compactMapValues(\.value)
  }

  /// 文字列でない要素だけを除く
  private static func decodeExcludedApps(
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> [String] {
    let items = (try? container.decodeIfPresent([Lossy<String>].self, forKey: .excludedApps)) ?? nil
    return (items ?? []).compactMap(\.value)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(maxRecordingDuration, forKey: .maxRecordingDuration)
    try container.encode(recordingTrigger, forKey: .recordingTrigger)
    try container.encodeIfPresent(recordingShortcut, forKey: .recordingShortcut)
    try container.encode(inputMode, forKey: .inputMode)
    try container.encode(refinementMode, forKey: .refinementMode)
    try container.encode(refinementEngine, forKey: .refinementEngine)
    try container.encode(appStyleOverrides, forKey: .appStyleOverrides)
    try container.encode(siteIdentificationAllowed, forKey: .siteIdentificationAllowed)
    try container.encode(siteStyleOverrides, forKey: .siteStyleOverrides)
    try container.encode(refinementModel, forKey: .refinementModel)
    try container.encode(priceTable, forKey: .priceTable)
    try container.encodeIfPresent(monthlyBudget, forKey: .monthlyBudget)
    try container.encode(consentState, forKey: .consentState)
    try container.encode(historyEnabled, forKey: .historyEnabled)
    try container.encode(modelRetentionMode, forKey: .modelRetentionMode)
    try container.encode(performanceRetentionAllowed, forKey: .performanceRetentionAllowed)
    try container.encode(excludedApps, forKey: .excludedApps)
  }
}

/// 整形の処理系（AI-03）。整形モード（Raw / Natural / Structured, TXT-01）とは別の設定
public enum RefinementEngine: String, Codable, Hashable, Sendable, CaseIterable {
  /// ローカルのルールベース整形（オフライン, AI-03）
  case localBasic
  /// クラウド AI による整形（Claude / ChatGPT, AI-01, AI-06）。送信には同意が要る（AC-06）
  case cloudAI
}

/// 入力モード（2.2節）。
///
/// Realtime Direct（実験機能）と Edit（v1.1）は MVP 外（1.1節）のため、まだ持たない
public enum InputMode: String, Codable, Hashable, Sendable, CaseIterable {
  /// 録音中に可能な範囲で STT を進め、停止後に最終認識・整形して一括挿入する（MVP 標準）
  case instant
  /// HUD で確定済みと暫定のテキストを区別して表示し、入力欄へは停止後に一括挿入する
  case realtimePreview
}

/// 保存する整形モード（TXT-01）。UtterAI の `RefinementMode` に変換して使う（UtterAI に依存しないため別の型にする）
public enum RefinementModeSetting: String, Codable, Hashable, Sendable, CaseIterable {
  case raw
  case natural
  case structured
}

/// 保存する STT モデルの保持モード（6章）。UtterSpeech の `ModelRetentionMode` に変換して使う
/// （UtterSpeech に依存しないため別の型にする）
public enum ModelRetentionModeSetting: String, Codable, Hashable, Sendable, CaseIterable {
  /// 推論後に原則モデルを解放する（省電力モード）
  case powerSaving
  /// 推論後に短時間保持し、メモリ圧迫・低バッテリーで解放する（標準）
  case balanced
  /// 利用者の許可とメモリの範囲でモデルを保持する（高速モード）
  case performance
}
