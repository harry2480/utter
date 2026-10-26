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
}
