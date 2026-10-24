import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

/// テストごとに専用の suite を使い、終わったら消す
private final class TestDefaults {
  let suiteName: String
  let defaults: UserDefaults

  init(_ name: String) throws {
    suiteName = "utter.tests.InputHistoryScreenModel.\(name)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

/// 機密でない入力先の判定
private let allowedInput = SensitiveInputPolicy().decide(
  SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.editor"))

@MainActor
struct InputHistoryScreenModelTests {
  private let suite: TestDefaults
  private let settingsStore: AppSettingsStore
  private let database: UtterDatabase
  private let historyStore: InputHistoryStore
  private let model: InputHistoryScreenModel
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    suite = try TestDefaults(UUID().uuidString)
    settingsStore = AppSettingsStore(defaults: suite.defaults)
    // 一時 DB（メモリ上）
    database = try UtterDatabase.inMemory()
    historyStore = InputHistoryStore(database: database)
    model = InputHistoryScreenModel(settingsStore: settingsStore, historyStore: historyStore)
  }

  /// 保存済みの設定に従って記録する（録音から挿入までの結線と同じ読み方）
  @discardableResult
  private func record(
    _ text: String, session: SessionID = SessionID(), after seconds: TimeInterval = 0
  ) throws -> InputHistorySkipReason? {
    let enabled = settingsStore.load().historyEnabled
    return try historyStore.record(
      text, session: session, at: createdAt.addingTimeInterval(seconds),
      historyEnabled: { enabled }, sensitivity: { allowedInput })
  }

  /// 設定を無視して直接書き込む（無効化の際に削除できず残った履歴の再現）
  private func recordIgnoringSettings(_ text: String) throws {
    try historyStore.record(
      text, session: SessionID(), at: createdAt,
      historyEnabled: { true }, sensitivity: { allowedInput })
  }

  @Test("7章, AC-12: 既定では履歴は無効で、開いても一覧は空・記録もされない")
  func disabledByDefault() async throws {
    await model.load()

    #expect(model.phase == .disabled)
    #expect(model.entries.isEmpty)
    #expect(model.failure == nil)
    #expect(try record("明日の会議は10時からです。") == .disabled)
    #expect(try historyStore.entries().isEmpty)
  }

  @Test("7章, AC-12: 有効にすると設定に保存され、記録した履歴が新しい順に一覧される")
  func enableShowsEntries() async throws {
    await model.load()
    await model.enable()

    #expect(model.phase == .enabled)
    #expect(settingsStore.load().historyEnabled)
    #expect(model.entries.isEmpty)

    try record("一件目", after: 0)
    try record("二件目", after: 1)
    await model.load()

    #expect(model.entries.map(\.text) == ["二件目", "一件目"])
  }

  @Test("7章, AC-12: 有効・無効の切り替えは、ほかの設定項目を上書きしない")
  func togglingKeepsOtherSettings() async throws {
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    let original = AppSettings(
      maxRecordingDuration: 120, consentState: consentState, excludedApps: ["com.example.secret"])
    try settingsStore.save(original)

    await model.enable()
    var expected = original
    expected.historyEnabled = true
    #expect(settingsStore.load() == expected)

    await model.disable()
    #expect(settingsStore.load() == original)
  }

  @Test("7章, AC-12: 無効にすると設定が無効になり、保存済みの履歴をすべて削除する")
  func disableRemovesAllEntries() async throws {
    await model.enable()
    try record("一件目")
    try record("二件目")
    await model.load()
    #expect(model.entries.count == 2)

    await model.disable()

    #expect(model.phase == .disabled)
    #expect(model.entries.isEmpty)
    #expect(model.failure == nil)
    #expect(!settingsStore.load().historyEnabled)
    #expect(try historyStore.entries().isEmpty)
    #expect(try record("無効にした後の入力") == .disabled)
  }

  @Test("7章, AC-12: 無効のまま開いたとき、残っていた履歴を削除する")
  func loadWhileDisabledRemovesLeftovers() async throws {
    try recordIgnoringSettings("削除できずに残った履歴")

    await model.load()

    #expect(model.phase == .disabled)
    #expect(try historyStore.entries().isEmpty)
  }

  @Test("7章: 個別に削除すると、その履歴だけが消える")
  func removeSingleEntry() async throws {
    await model.enable()
    let kept = SessionID()
    let removed = SessionID()
    try record("残す", session: kept, after: 0)
    try record("消す", session: removed, after: 1)
    await model.load()

    await model.remove(session: removed)

    #expect(model.entries.map(\.sessionID) == [kept])
    #expect(try historyStore.entries().map(\.sessionID) == [kept])
    #expect(model.phase == .enabled)
  }

  @Test("7章: すべて削除すると一覧は空になり、履歴は有効のまま")
  func removeAllKeepsEnabled() async throws {
    await model.enable()
    try record("一件目")
    try record("二件目", after: 1)
    await model.load()

    await model.removeAll()

    #expect(model.entries.isEmpty)
    #expect(model.phase == .enabled)
    #expect(settingsStore.load().historyEnabled)
    #expect(try historyStore.entries().isEmpty)
    #expect(try record("削除後の入力") == nil)
  }

  @Test("7章: 画面を閉じると一覧の本文を手放し、履歴そのものは残す")
  func closeReleasesEntries() async throws {
    await model.enable()
    try record("一件目")
    await model.load()
    #expect(model.entries.count == 1)

    model.close()

    #expect(model.phase == .closed)
    #expect(model.entries.isEmpty)
    #expect(try historyStore.entries().count == 1)

    await model.load()
    #expect(model.phase == .enabled)
    #expect(model.entries.count == 1)
  }

  /// 履歴の表を消して、読み書きを失敗させる
  private func breakHistoryTable() throws {
    try database.writer.write { try $0.execute(sql: "DROP TABLE inputHistory") }
  }

  @Test("7章: 有効のまま開いて読み込みに失敗したら、有効の画面で失敗を示す")
  func loadFailureShowsEnabledScreen() async throws {
    try settingsStore.save(AppSettings(historyEnabled: true))
    try breakHistoryTable()

    await model.load()

    #expect(model.phase == .enabled)
    #expect(model.entries.isEmpty)
    #expect(model.failure == .historyNotLoaded)
    #expect(!model.isBusy)
  }

  @Test("7章: 削除後の読み込みに失敗したら、古い一覧を残さない")
  func reloadFailureClearsEntries() async throws {
    await model.enable()
    try record("一件目")
    await model.load()
    #expect(model.entries.count == 1)
    try breakHistoryTable()

    await model.load()

    #expect(model.failure == .historyNotLoaded)
    #expect(model.entries.isEmpty)
  }

  @Test("7章, AC-12: 無効にした後に削除で失敗しても、設定は無効のままで失敗を示す")
  func disableKeepsDisabledWhenRemovalFails() async throws {
    await model.enable()
    try breakHistoryTable()

    await model.disable()

    #expect(model.phase == .disabled)
    #expect(model.failure == .historyNotRemoved)
    #expect(!settingsStore.load().historyEnabled)
  }

  @Test("7章: 読み込みの途中で閉じたら、終わった読み込みの結果を画面に戻さない")
  func closeDuringLoadDiscardsResult() async throws {
    try settingsStore.save(AppSettings(historyEnabled: true))
    try record("一件目")

    // データベースを書き込みで押さえ、読み込みが読み取りを待つ間に閉じる
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let database = database
    let holder = Task.detached {
      try database.writer.write { _ in
        locked.signal()
        release.wait()
      }
    }
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        locked.wait()
        continuation.resume()
      }
    }
    let loading = Task { await model.load() }
    while !model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    model.close()
    release.signal()
    await loading.value
    try await holder.value

    #expect(model.phase == .closed)
    #expect(model.entries.isEmpty)
    #expect(!model.isBusy)
  }
}
