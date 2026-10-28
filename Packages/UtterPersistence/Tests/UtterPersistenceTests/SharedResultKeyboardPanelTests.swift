import Foundation
import Testing

@testable import UtterPersistence

struct SharedResultKeyboardPanelTests {
  private static let expiresAt = Date(timeIntervalSince1970: 1_800_000_600)

  /// 有効期限の `seconds` 秒前
  private static func before(_ seconds: TimeInterval) -> Date {
    expiresAt.addingTimeInterval(-seconds)
  }

  @Test(
    "iOS-IPC-02: 残り時間は分に切り上げて出す",
    arguments: [
      (600.0, 10), (599, 10), (541, 10), (540, 9), (61, 2), (60, 1), (30, 1), (0.5, 1),
    ])
  func remainingMinutesRoundUp(_ seconds: TimeInterval, _ expected: Int) {
    let panel = SharedResultKeyboardPanel(
      .insertable(text: "本文", expiresAt: Self.expiresAt), at: Self.before(seconds))

    #expect(panel.remainingMinutes == expected)
    #expect(!panel.isExpired)
  }

  @Test("iOS-05: 挿入できる結果には「挿入」と「消す」を出す")
  func insertableActions() {
    let panel = SharedResultKeyboardPanel(
      .insertable(text: "本文", expiresAt: Self.expiresAt), at: Self.before(300))

    #expect(panel.actions == [.insert, .discard])
    #expect(panel.remainingMinutes == 5)
  }

  @Test(
    "iOS-IPC-02: 表示している間に期限を過ぎたら、挿入を出さず「消す」だけを残す",
    arguments: [0.0, -1, -600])
  func expiredWhileShown(_ seconds: TimeInterval) {
    let panel = SharedResultKeyboardPanel(
      .insertable(text: "本文", expiresAt: Self.expiresAt), at: Self.before(seconds))

    #expect(panel.actions == [.discard])
    #expect(panel.remainingMinutes == nil)
    #expect(panel.isExpired)
  }

  @Test("iOS-IPC-03: 挿入を確認できない結果には「入っていた」「もう一度入れる」「消す」を出し、挿入は出さない")
  func needsConfirmationActions() {
    let panel = SharedResultKeyboardPanel(
      .needsConfirmation(text: "本文", expiresAt: Self.expiresAt), at: Self.before(120))

    #expect(panel.actions == [.confirmInserted, .reinsert, .discard])
    #expect(!panel.actions.contains(.insert))
    #expect(panel.remainingMinutes == 2)
  }

  @Test("iOS-IPC-03: 挿入を確認できないまま期限を過ぎたら、「もう一度入れる」は出さない")
  func needsConfirmationAfterExpiry() {
    let panel = SharedResultKeyboardPanel(
      .needsConfirmation(text: "本文", expiresAt: Self.expiresAt), at: Self.before(-1))

    #expect(panel.actions == [.confirmInserted, .discard])
    #expect(panel.remainingMinutes == nil)
    #expect(panel.isExpired)
  }

  @Test(
    "iOS-IPC-02: 結果がない・挿入できない結果には操作も残り時間も出さない",
    arguments: [
      SharedResultPreview.notFound, .notInsertable(.expired), .notInsertable(.consumed),
      .notInsertable(.inProgress), .notInsertable(.invalidTimestamp),
    ])
  func noActionsWithoutText(_ preview: SharedResultPreview) {
    let panel = SharedResultKeyboardPanel(preview, at: Self.before(300))

    #expect(panel.actions.isEmpty)
    #expect(panel.remainingMinutes == nil)
    #expect(!panel.isExpired)
  }

  @Test("iOS-IPC-02: 期限が極端に先の壊れた値でも停止せず、上限で止める")
  func farFutureExpiryDoesNotTrap() {
    let panel = SharedResultKeyboardPanel(
      .insertable(text: "本文", expiresAt: .distantFuture), at: Self.expiresAt)
    #expect(panel.remainingMinutes != nil)

    let farFuture = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)
    let minutes = SharedResultKeyboardPanel.minutesRemaining(until: farFuture, at: Self.expiresAt)
    #expect(minutes == Int.max)
  }
}
