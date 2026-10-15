import Foundation
import UtterCore

/// アプリケーション設定（2.1節, 2.3節, 5章, 7章）。
///
/// UserDefaults に保存可能で、壊れた値や未知の版でも起動できるようにする。
/// API キー・トークンは保存できない型になっている（Keychain の責務）。
public struct AppSettings: Codable, Sendable {
  /// 設定の版番号。移行の入口とする
  public let version: Int

  /// 最大録音時間（秒）。REC-05
  public var maxRecordingDuration: Double

  /// 整形の処理モード（LocalBasic / CloudAI）
  public var refinementMode: RefinementMode

  /// アプリ別のスタイル上書き（CTX-02）
  public var appStyleOverrides: [InsertionTargetID: RefinementStyle]

  /// 整形用 AI モデル名（AI-07）
  public var refinementModel: String

  /// 単価表（ドル/1000トークン）
  public var pricePerMillionTokens: [String: Double]

  /// 単価表の更新日時
  public var priceTableUpdatedAt: Date

  /// 月次予算（ドル）
  public var monthlyBudget: Double

  /// クラウド送信の同意状態（AC-06, AI-04）
  public var consentState: ConsentState

  /// 履歴の記録を有効にするか（既定: 無効, 7章）
  public var historyEnabled: Bool

  /// 既定値を使う設定を作成する
  public init(
    maxRecordingDuration: Double = 300,
    refinementMode: RefinementMode = .localBasic,
    appStyleOverrides: [InsertionTargetID: RefinementStyle] = [:],
    refinementModel: String = "claude-3-5-sonnet-20241022",
    pricePerMillionTokens: [String: Double] = [:],
    priceTableUpdatedAt: Date = Date(timeIntervalSince1970: 0),
    monthlyBudget: Double = 10.0,
    consentState: ConsentState = ConsentState(),
    historyEnabled: Bool = false
  ) {
    self.version = 1
    self.maxRecordingDuration =
      maxRecordingDuration.isFinite && maxRecordingDuration > 0 ? maxRecordingDuration : 300
    self.refinementMode = refinementMode
    self.appStyleOverrides = appStyleOverrides
    self.refinementModel = refinementModel
    self.pricePerMillionTokens = pricePerMillionTokens
    self.priceTableUpdatedAt = priceTableUpdatedAt
    self.monthlyBudget = monthlyBudget.isFinite && monthlyBudget > 0 ? monthlyBudget : 10.0
    self.consentState = consentState
    self.historyEnabled = historyEnabled
  }

  // MARK: - Codable

  enum CodingKeys: String, CodingKey {
    case version
    case maxRecordingDuration
    case refinementMode
    case appStyleOverrides
    case refinementModel
    case pricePerMillionTokens
    case priceTableUpdatedAt
    case monthlyBudget
    case consentState
    case historyEnabled
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

    switch version {
    case 1:
      self.version = version
      self.maxRecordingDuration =
        try container.decodeIfPresent(
          Double.self, forKey: .maxRecordingDuration) ?? 300
      self.refinementMode =
        try container.decodeIfPresent(
          RefinementMode.self, forKey: .refinementMode) ?? .localBasic
      self.appStyleOverrides =
        try container.decodeIfPresent(
          [InsertionTargetID: RefinementStyle].self, forKey: .appStyleOverrides) ?? [:]
      self.refinementModel =
        try container.decodeIfPresent(
          String.self, forKey: .refinementModel) ?? "claude-3-5-sonnet-20241022"
      self.pricePerMillionTokens =
        try container.decodeIfPresent(
          [String: Double].self, forKey: .pricePerMillionTokens) ?? [:]
      self.priceTableUpdatedAt =
        try container.decodeIfPresent(
          Date.self, forKey: .priceTableUpdatedAt) ?? Date(timeIntervalSince1970: 0)
      self.monthlyBudget =
        try container.decodeIfPresent(
          Double.self, forKey: .monthlyBudget) ?? 10.0
      self.consentState =
        try container.decodeIfPresent(
          ConsentState.self, forKey: .consentState) ?? ConsentState()
      self.historyEnabled =
        try container.decodeIfPresent(
          Bool.self, forKey: .historyEnabled) ?? false

    default:
      // 未知の版は既定値で復元
      self = AppSettings()
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(maxRecordingDuration, forKey: .maxRecordingDuration)
    try container.encode(refinementMode, forKey: .refinementMode)
    try container.encode(appStyleOverrides, forKey: .appStyleOverrides)
    try container.encode(refinementModel, forKey: .refinementModel)
    try container.encode(pricePerMillionTokens, forKey: .pricePerMillionTokens)
    try container.encode(priceTableUpdatedAt, forKey: .priceTableUpdatedAt)
    try container.encode(monthlyBudget, forKey: .monthlyBudget)
    try container.encode(consentState, forKey: .consentState)
    try container.encode(historyEnabled, forKey: .historyEnabled)
  }
}

/// 整形の処理モード
public enum RefinementMode: String, Codable, Hashable, Sendable {
  /// ローカルルールベース整形（オフライン, AI-03）
  case localBasic
  /// クラウド AI による整形（Claude / ChatGPT, AI-01, AI-06）
  case cloudAI
}
