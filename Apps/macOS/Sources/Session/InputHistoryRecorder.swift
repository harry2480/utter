import Foundation
import UtterCore
import UtterPersistence

/// 挿入した本文を入力履歴に保存する（7章, AC-12）。MVP 外の先行実装で、履歴は既定で無効。
///
/// 設定で履歴が有効で、保存の直前の入力先が機密入力でない（判定できる）ときだけ `InputHistoryStore.record` で保存する。
/// 履歴の有効・無効は `InputHistoryStore` の書き込みの中でもう一度読むため、無効化と全削除の後に書き込まれることはない。
/// データベースは履歴が有効なときだけ開く。保存に失敗してもセッションには影響させず、本文はログに出さない。
@MainActor
final class InputHistoryRecorder: SessionHistoryRecording {
  private let settingsStore: AppSettingsStore
  private let historyEnabled: @Sendable () -> Bool
  private let database: @MainActor () async throws -> UtterDatabase
  private let now: @Sendable () -> Date

  /// - Parameters:
  ///   - settingsStore: 除外アプリと履歴の有効・無効を読む保存先。入力履歴の画面と同じものを渡す
  ///   - historyEnabled: 保存の書き込みの中で最新の「履歴が有効か」を読む。`settingsStore` と同じ保存先を読む
  ///   - database: 入力履歴を保存するデータベース。入力履歴の画面と同じものを渡す
  ///   - now: 保存日時
  init(
    settingsStore: AppSettingsStore,
    historyEnabled: @escaping @Sendable () -> Bool,
    database: @escaping @MainActor () async throws -> UtterDatabase,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.settingsStore = settingsStore
    self.historyEnabled = historyEnabled
    self.database = database
    self.now = now
  }

  /// `UserDefaults.standard` の設定を読む本番の構成。除外アプリと履歴の有効・無効を同じ保存先から読む
  static func standard(
    database: @escaping @MainActor () async throws -> UtterDatabase
  ) -> InputHistoryRecorder {
    InputHistoryRecorder(
      settingsStore: AppSettingsStore(defaults: .standard),
      // 書き込みの中で最新の設定を読む（UserDefaults の読み取りはスレッドを問わない）
      historyEnabled: { AppSettingsStore(defaults: .standard).load().historyEnabled },
      database: database)
  }

  func record(
    _ text: String, session: SessionID,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext
  ) async {
    _ = await save(text, session: session, sensitivity: sensitivity)
  }

  /// 保存した結果。本文は含まない
  enum Outcome: Hashable, Sendable {
    case saved
    case skipped(InputHistorySkipReason)
    /// データベースを開けない・書き込めない
    case failed
  }

  /// 本文を保存し、保存したか・しなかった理由を返す
  func save(
    _ text: String, session: SessionID,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext
  ) async -> Outcome {
    let settings = settingsStore.load()
    guard settings.historyEnabled else { return .skipped(.disabled) }
    // `record` は書き込みのキューの中で同期的に判定を求めるため、保存の直前のここで判定した値を渡す
    let decision = SensitiveInputPolicy(excludedApps: Set(settings.excludedApps))
      .decide(sensitivity())
    guard decision.allowsHistory else { return .skipped(.sensitiveInput) }
    guard let database = try? await database() else { return .failed }
    let store = InputHistoryStore(database: database)
    let historyEnabled = historyEnabled
    let date = now()
    return await Task.detached { () -> Outcome in
      do {
        let skipped = try store.record(
          text, session: session, at: date, historyEnabled: historyEnabled,
          sensitivity: { decision })
        return skipped.map(Outcome.skipped) ?? .saved
      } catch {
        return .failed
      }
    }.value
  }
}
