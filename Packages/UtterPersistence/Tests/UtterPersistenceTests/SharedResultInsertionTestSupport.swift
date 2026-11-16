import UtterCore
import UtterPersistence

extension SharedResultInsertionCoordinator {
  /// 表示し直しを扱わないテスト用に、表示が続いているものとして挿入する
  func insert(
    sessionID: SessionID, confirmedReinsertion: Bool = false
  ) async throws -> SharedResultInsertionOutcome {
    try await insert(
      sessionID: sessionID, confirmedReinsertion: confirmedReinsertion, isStillTarget: { true })
  }
}
