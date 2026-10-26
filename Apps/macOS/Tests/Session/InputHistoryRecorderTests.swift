import Foundation
import Testing
import UtterCore
import UtterPersistence

/// 入力履歴への保存（7章, AC-12）と、機密入力の判定に使う入力先の状態。
@MainActor
struct InputHistoryRecorderTests {
  private static let safeInput = SensitiveInputContext(
    secureField: .off, secureEventInput: .off, app: "com.example.editor")

  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
  }

  private func recorder(
    enabled: Bool, enabledWhenWriting: Bool? = nil, excludedApps: [String] = []
  ) throws -> InputHistoryRecorder {
    let store = AppSettingsStore(defaults: suite.defaults)
    try store.save(AppSettings(historyEnabled: enabled, excludedApps: excludedApps))
    let database = database
    let whenWriting = enabledWhenWriting ?? enabled
    return InputHistoryRecorder(
      settingsStore: store, historyEnabled: { whenWriting }, database: { database },
      now: { RefinementSettings.now })
  }

  private func entries() throws -> [InputHistoryEntry] {
    try InputHistoryStore(database: database).entries()
  }

  @Test("7章, AC-12: 履歴が有効で機密入力でなければ保存する")
  func savesWhenEnabled() async throws {
    let session = SessionID()
    let outcome = try await recorder(enabled: true).save(
      "本文", session: session, sensitivity: { Self.safeInput })

    #expect(outcome == .saved)
    #expect(try entries().map(\.text) == ["本文"])
    #expect(try entries().map(\.sessionID) == [session])
  }

  @Test("7章: 履歴が無効（既定）なら保存しない")
  func skipsWhenDisabled() async throws {
    let outcome = try await recorder(enabled: false).save(
      "本文", session: SessionID(), sensitivity: { Self.safeInput })

    #expect(outcome == .skipped(.disabled))
    #expect(try entries().isEmpty)
  }

  @Test("7章: 書き込みの時点で無効になっていれば保存しない")
  func skipsWhenDisabledWhileWriting() async throws {
    let outcome = try await recorder(enabled: true, enabledWhenWriting: false).save(
      "本文", session: SessionID(), sensitivity: { Self.safeInput })

    #expect(outcome == .skipped(.disabled))
    #expect(try entries().isEmpty)
  }

  @Test(
    "AC-12: パスワード欄・セキュア入力・除外アプリ・判定できない入力先なら保存しない",
    arguments: [
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"),
      SensitiveInputContext(secureField: .off, secureEventInput: .on, app: "com.example.editor"),
      SensitiveInputContext(secureField: .unknown, secureEventInput: .off, app: nil),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.excluded"),
    ])
  func skipsSensitiveInput(_ input: SensitiveInputContext) async throws {
    let outcome = try await recorder(enabled: true, excludedApps: ["com.example.excluded"]).save(
      "本文", session: SessionID(), sensitivity: { input })

    #expect(outcome == .skipped(.sensitiveInput))
    #expect(try entries().isEmpty)
  }

  @Test("7章: データベースを開けなくてもセッションを止めず、保存しない")
  func failsWithoutDatabase() async throws {
    let store = AppSettingsStore(defaults: suite.defaults)
    try store.save(AppSettings(historyEnabled: true))
    let recorder = InputHistoryRecorder(
      settingsStore: store, historyEnabled: { true }, database: { throw CancellationError() })

    let outcome = await recorder.save("本文", session: SessionID(), sensitivity: { Self.safeInput })

    #expect(outcome == .failed)
  }

  // MARK: 入力先の状態

  nonisolated private static let field = InsertionTargetID(rawValue: "field")

  @Test("AC-12: 録音開始時の入力対象のままなら、入力欄の属性・アプリ・セキュア入力をそのまま使う")
  func contextOfSameTarget() {
    let context = SystemSessionInserter.sensitiveInputContext(
      recorded: Self.field,
      focused: FocusedInsertionTarget(id: Self.field, app: "com.example.editor", secureField: .on),
      secureEventInput: .off)

    #expect(
      context
        == SensitiveInputContext(
          secureField: .on, secureEventInput: .off, app: "com.example.editor"))
  }

  @Test(
    "AC-12, INS-01: 入力対象を記録できなかった・フォーカスが移った・取れないなら、判定できない状態にする",
    arguments: [
      (nil, FocusedInsertionTarget(id: field, app: "com.example.editor", secureField: .off)),
      (
        field,
        FocusedInsertionTarget(
          id: InsertionTargetID(rawValue: "other"), app: "com.example.editor", secureField: .off)
      ),
      (field, nil),
    ] as [(InsertionTargetID?, FocusedInsertionTarget?)])
  func contextIsUndeterminedWhenTargetChanged(
    _ recorded: InsertionTargetID?, _ focused: FocusedInsertionTarget?
  ) {
    let context = SystemSessionInserter.sensitiveInputContext(
      recorded: recorded, focused: focused, secureEventInput: .off)

    #expect(
      context == SensitiveInputContext(secureField: .unknown, secureEventInput: .off, app: nil))
    #expect(!SensitiveInputPolicy().decide(context).allowsCloudTransmission)
  }
}
