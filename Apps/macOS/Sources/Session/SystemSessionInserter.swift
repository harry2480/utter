import UtterCore

/// `InsertionExecutor` を `SessionTextInserting` として見せる（INS-01〜07, AC-09）。
@MainActor
final class SystemSessionInserter: SessionTextInserting {
  private let executor: InsertionExecutor
  private let inspector: any InsertionTargetInspector

  init(executor: InsertionExecutor, inspector: any InsertionTargetInspector) {
    self.executor = executor
    self.inspector = inspector
  }

  func recordTarget() -> RecordedInsertionTarget {
    RecordedInsertionTarget(id: inspector.recordTarget(), app: inspector.focusedTarget()?.app)
  }

  func insert(_ text: String, into target: RecordedInsertionTarget) async -> InsertionReport {
    await executor.insert(text, recordedTarget: target.id)
  }

  func sensitiveInputContext(for target: RecordedInsertionTarget) -> SensitiveInputContext {
    Self.sensitiveInputContext(
      recorded: target.id, focused: inspector.focusedTarget(),
      secureEventInput: inspector.secureEventInput())
  }

  /// 録音開始時の入力対象のままでなければ（記録できなかった・フォーカスが移った・取れない）、挿入はプレビューへ退避する。
  /// 送信・保存の判定も、入力欄の属性とアプリを判定できない側（`unknown` / `nil`）に倒す
  static func sensitiveInputContext(
    recorded: InsertionTargetID?, focused: FocusedInsertionTarget?,
    secureEventInput: SensitiveSignal
  ) -> SensitiveInputContext {
    guard let recorded, let focused, focused.id == recorded else {
      return SensitiveInputContext(
        secureField: .unknown, secureEventInput: secureEventInput, app: nil)
    }
    return SensitiveInputContext(
      secureField: focused.secureField, secureEventInput: secureEventInput, app: focused.app)
  }
}
