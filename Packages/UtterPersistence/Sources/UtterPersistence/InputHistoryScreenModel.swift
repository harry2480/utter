import Foundation
import Observation
import UtterCore

/// 入力履歴の画面の状態（7章, AC-12）。有効化・無効化・一覧・個別削除・全削除を扱う。
///
/// 履歴は初期無効のオプトインで、画面で `enable()` を呼んだときだけ有効になる。無効にすると保存済みの履歴をすべて削除する
/// （`InputHistoryStore` の順序どおり、設定を先に無効にしてから削除する）。無効のまま画面を開いたときも、
/// 無効化の際に削除できず残った履歴があれば削除する。
///
/// 設定（`AppSettingsStore`）は `Sendable` でないため、この型はメインアクターに隔離する。データベースの読み書きは
/// メインスレッドを避けて行う。画面を閉じたら `close()` を呼び、一覧の本文を手放す。閉じた後に終わった読み込みの結果は捨てる。
/// 閉じた時点で途中の操作があると、開き直した後の操作と並んで走りうるため、画面を開くたびに新しく作る。
/// 履歴への記録（セッション完了時の `InputHistoryStore.record`）はこの型の責務ではない。
@MainActor
@Observable
public final class InputHistoryScreenModel {
  /// 画面の状態
  public enum Phase: Hashable, Sendable {
    /// 開いていない、または読み込み中
    case closed
    /// 履歴は無効（既定）
    case disabled
    /// 履歴は有効
    case enabled
  }

  public private(set) var phase: Phase = .closed
  /// 新しい順の履歴。有効のときだけ持つ
  public private(set) var entries: [InputHistoryEntry] = []
  /// 直近の操作の失敗。次の操作を始めると消す
  public private(set) var failure: InputHistoryScreenFailure?
  /// 操作の途中か。途中の間はほかの操作を受け付けない
  public private(set) var isBusy = false

  private let settingsStore: AppSettingsStore
  private let historyStore: InputHistoryStore
  /// `close()` のたびに進める。閉じる前に始まった操作の結果を画面に反映しないために使う
  private var generation = 0

  public init(settingsStore: AppSettingsStore, historyStore: InputHistoryStore) {
    self.settingsStore = settingsStore
    self.historyStore = historyStore
  }

  /// 設定と履歴を読み込む。画面を開いたとき・更新するときに呼ぶ
  public func load() async {
    await perform { (generation: Int) async throws(InputHistoryScreenFailure) in
      if self.settingsStore.load().historyEnabled {
        // 読み込みに失敗しても、有効の画面（再読み込みの操作）を出す
        self.show(.enabled, generation: generation)
        try await self.reloadEntries(generation: generation, failure: .historyNotLoaded)
      } else {
        self.show(.disabled, generation: generation)
        // 無効化の際に削除できず残った履歴を削除する
        try await self.removeAllEntries()
      }
    }
  }

  /// 履歴を有効にする。利用者が説明を読んで明示的に選んだときだけ呼ぶ
  public func enable() async {
    await perform { (generation: Int) async throws(InputHistoryScreenFailure) in
      try self.saveHistoryEnabled(true)
      self.show(.enabled, generation: generation)
      try await self.reloadEntries(generation: generation, failure: .historyNotLoaded)
    }
  }

  /// 履歴を無効にし、保存済みの履歴をすべて削除する
  public func disable() async {
    await perform { (generation: Int) async throws(InputHistoryScreenFailure) in
      try self.saveHistoryEnabled(false)
      self.show(.disabled, generation: generation)
      try await self.removeAllEntries()
    }
  }

  /// セッションの履歴を削除する
  public func remove(session: SessionID) async {
    await perform { (generation: Int) async throws(InputHistoryScreenFailure) in
      try await Self.run(self.historyStore, failure: .historyNotRemoved) {
        try $0.remove(session: session)
      }
      try await self.reloadEntries(generation: generation, failure: .historyNotLoaded)
    }
  }

  /// 履歴をすべて削除する。履歴は有効のまま
  public func removeAll() async {
    await perform { (generation: Int) async throws(InputHistoryScreenFailure) in
      try await self.removeAllEntries()
      try await self.reloadEntries(generation: generation, failure: .historyNotLoaded)
    }
  }

  /// 画面を閉じたときに呼ぶ。一覧の本文を手放し、途中の操作の結果を捨てる（削除・設定の保存は取り消さない）
  public func close() {
    generation += 1
    phase = .closed
    entries = []
    failure = nil
    isBusy = false
  }

  // MARK: - 内部

  /// 操作を1つずつ行い、失敗を画面に反映する
  private func perform(
    _ operation: (Int) async throws(InputHistoryScreenFailure) -> Void
  ) async {
    guard !isBusy else { return }
    let generation = generation
    isBusy = true
    failure = nil
    do {
      try await operation(generation)
    } catch {
      if generation == self.generation { failure = error }
    }
    if generation == self.generation { isBusy = false }
  }

  private func show(_ phase: Phase, generation: Int) {
    guard generation == self.generation else { return }
    self.phase = phase
    if phase != .enabled { entries = [] }
  }

  /// 最新の設定に履歴の有効・無効だけを書き込む（ほかの画面で変えた項目を上書きしない）
  private func saveHistoryEnabled(_ enabled: Bool) throws(InputHistoryScreenFailure) {
    var settings = settingsStore.load()
    settings.historyEnabled = enabled
    do {
      try settingsStore.save(settings)
    } catch {
      throw .settingsNotSaved
    }
  }

  private func reloadEntries(
    generation: Int, failure: InputHistoryScreenFailure
  ) async throws(InputHistoryScreenFailure) {
    let entries: [InputHistoryEntry]
    do {
      entries = try await Self.run(historyStore, failure: failure) { try $0.entries() }
    } catch {
      // 削除した本文を古い一覧のまま表示・コピーさせない
      if generation == self.generation { self.entries = [] }
      throw error
    }
    guard generation == self.generation else { return }
    phase = .enabled
    self.entries = entries
  }

  private func removeAllEntries() async throws(InputHistoryScreenFailure) {
    try await Self.run(historyStore, failure: .historyNotRemoved) { try $0.removeAll() }
  }

  /// データベースの読み書きをメインスレッド以外で行う。失敗の詳細（SQL など）は画面に出さず、種類だけを返す
  private static func run<T: Sendable>(
    _ store: InputHistoryStore, failure: InputHistoryScreenFailure,
    _ body: @escaping @Sendable (InputHistoryStore) throws -> T
  ) async throws(InputHistoryScreenFailure) -> T {
    do {
      return try await Task.detached { try body(store) }.value
    } catch {
      throw failure
    }
  }
}

/// 入力履歴の画面の操作の失敗。本文や内部のエラーの詳細は持たない
public enum InputHistoryScreenFailure: Error, Hashable, Sendable {
  /// 設定を保存できなかった（有効・無効は変わっていない）
  case settingsNotSaved
  /// 履歴を読み込めなかった
  case historyNotLoaded
  /// 履歴を削除できなかった
  case historyNotRemoved
}
