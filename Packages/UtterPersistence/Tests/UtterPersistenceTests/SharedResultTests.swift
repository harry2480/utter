import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct SharedResultTests {
  private let sessionID = SessionID()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func result(text: String = "明日の会議は10時からです。") -> SharedResult {
    SharedResult(sessionID: sessionID, text: text, createdAt: createdAt)
  }

  private func after(_ seconds: TimeInterval) -> Date {
    createdAt.addingTimeInterval(seconds)
  }

  /// 挿入を始めた結果
  private func inserting(at seconds: TimeInterval = 1) throws -> SharedResult {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(seconds))
    return result
  }

  /// 挿入結果が不明な結果
  private func unknown() throws -> SharedResult {
    var result = try inserting()
    try result.markInsertionUnknown()
    return result
  }

  @Test("iOS-IPC-01: 共有結果は sessionID・createdAt・expiresAt・status・text・consumedAt を持つ")
  func holdsRequiredFields() {
    let result = result()

    #expect(result.sessionID == sessionID)
    #expect(result.createdAt == createdAt)
    #expect(result.expiresAt == after(600))
    #expect(result.status == .ready)
    #expect(result.text == "明日の会議は10時からです。")
    #expect(result.consumedAt == nil)
    #expect(result.revision == 0)
  }

  @Test("iOS-IPC-01: 保存済みの値から同じ内容に復元できる")
  func restoresFromStoredValues() throws {
    var original = try inserting()
    try original.markConsumed(at: after(2))

    let restored = try SharedResult(
      sessionID: original.sessionID, createdAt: original.createdAt,
      expiresAt: original.expiresAt, status: original.status, text: original.text,
      revision: original.revision)

    #expect(restored == original)
    #expect(restored.consumedAt == after(2))
  }

  @Test("iOS-IPC-01: 有効期限が作成時刻以前の保存値は矛盾として拒否する", arguments: [0.0, -1])
  func rejectsInconsistentStoredValue(_ offset: TimeInterval) {
    #expect(throws: SharedResultError.inconsistentStoredValue) {
      try SharedResult(
        sessionID: sessionID, createdAt: createdAt, expiresAt: after(offset), status: .ready,
        text: "本文", revision: 0)
    }
  }

  @Test("iOS-IPC-01: 状態が変わるたびに revision が増え、変わらない操作では増えない")
  func revisionIncreasesOnTransition() throws {
    var result = try unknown()
    #expect(result.revision == 2)

    try result.markInsertionUnknown()
    #expect(result.revision == 2)

    try result.beginInsertionAfterConfirmation(for: sessionID, at: after(10))
    try result.markInsertionUnknown()
    // 不明 → 再挿入 → 不明と一周しても revision で区別できる（保存層の比較交換で ABA を防ぐ）
    #expect(result.status == .insertionUnknown)
    #expect(result.revision == 4)

    try result.markConsumed(at: after(11))
    try result.markConsumed(at: after(12))
    #expect(result.revision == 5)
  }

  @Test("iOS-IPC-02: 有効期限の既定は10分で、設定で変えられる")
  func expiryIsConfigurable() throws {
    let defaults = SharedResultConfiguration()
    #expect(defaults.timeToLive == .seconds(600))
    #expect(defaults.insertionGracePeriod == SharedResultConfiguration.defaultInsertionGracePeriod)

    let configuration = try SharedResultConfiguration(timeToLive: .milliseconds(1500))
    let result = SharedResult(
      sessionID: sessionID, text: "本文", createdAt: createdAt, configuration: configuration)

    #expect(result.expiresAt == after(1.5))
  }

  @Test(
    "iOS-IPC-02: 有効期限・挿入の猶予時間が0以下の設定は拒否する",
    arguments: [Duration.zero, .seconds(-1)]
  )
  func rejectsNonPositiveDurations(_ duration: Duration) {
    #expect(throws: SharedResultConfigurationError.nonPositiveTimeToLive) {
      try SharedResultConfiguration(timeToLive: duration)
    }
    #expect(throws: SharedResultConfigurationError.nonPositiveInsertionGracePeriod) {
      try SharedResultConfiguration(insertionGracePeriod: duration)
    }
  }

  @Test("iOS-IPC-02: 期限内で同じセッションの未消費の結果は挿入可能")
  func insertableWithinExpiry() {
    #expect(result().insertability(for: sessionID, at: createdAt) == .insertable)
    #expect(result().insertability(for: sessionID, at: after(599.999)) == .insertable)
  }

  @Test("iOS-IPC-02: 期限切れの結果は挿入可能と判定しない", arguments: [600.0, 601, 86_400])
  func expiredIsNotInsertable(_ seconds: TimeInterval) {
    #expect(result().insertability(for: sessionID, at: after(seconds)) == .expired)
  }

  @Test("iOS-IPC-02: セッションID が一致しない結果は、どの状態でも挿入可能と判定しない")
  func sessionMismatchIsNotInsertable() throws {
    let other = SessionID()

    #expect(result().insertability(for: other, at: after(1)) == .sessionMismatch)
    #expect(try unknown().insertability(for: other, at: after(2)) == .sessionMismatch)
    var unknown = try unknown()
    #expect(throws: SharedResultError.notInsertable(.sessionMismatch)) {
      try unknown.beginInsertionAfterConfirmation(for: other, at: after(2))
    }
  }

  @Test("iOS-IPC-02: 端末の時刻が作成時より前なら挿入可能と判定しない")
  func clockBeforeCreationIsNotInsertable() {
    #expect(result().insertability(for: sessionID, at: after(-1)) == .invalidTimestamp)
  }

  @Test("iOS-IPC-02: 消費済みの結果は挿入可能と判定しない")
  func consumedIsNotInsertable() throws {
    var result = try inserting()
    try result.markConsumed(at: after(2))

    #expect(result.insertability(for: sessionID, at: after(3)) == .consumed)
  }

  @Test("iOS-IPC-03: 挿入中は、連打やキーボード再生成による2回目の挿入を拒否する")
  func rejectsSecondInsertionWhileInserting() throws {
    var result = try inserting()

    #expect(result.status == .inserting(startedAt: after(1)))
    #expect(throws: SharedResultError.notInsertable(.inProgress)) {
      try result.beginInsertion(for: sessionID, at: after(1))
    }
  }

  @Test("iOS-IPC-03: 挿入中（猶予時間内）は、確認を経由しても2回目の挿入を拒否する", arguments: [1.0, 15, 31])
  func rejectsConfirmationWhileInProgress(_ seconds: TimeInterval) throws {
    var result = try inserting()

    #expect(result.insertability(for: sessionID, at: after(seconds)) == .inProgress)
    #expect(throws: SharedResultError.notInsertable(.inProgress)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(seconds))
    }
  }

  @Test("iOS-IPC-03: 猶予時間を過ぎても挿入中のまま（拡張の強制終了）なら確認に回し、自動では再挿入しない")
  func abandonedInsertionNeedsConfirmation() throws {
    var result = try inserting()

    #expect(result.insertability(for: sessionID, at: after(31.001)) == .needsConfirmation)
    #expect(result.insertability(for: sessionID, at: after(0.5)) == .needsConfirmation)
    #expect(throws: SharedResultError.notInsertable(.needsConfirmation)) {
      try result.beginInsertion(for: sessionID, at: after(100))
    }

    try result.beginInsertionAfterConfirmation(for: sessionID, at: after(100))
    #expect(result.status == .inserting(startedAt: after(100)))
  }

  @Test("iOS-IPC-03: 消費の記録は冪等で、2回目は最初の時刻を保ち、挿入不可のまま")
  func consumingIsIdempotent() throws {
    var result = try inserting()
    try result.markConsumed(at: after(2))
    try result.markConsumed(at: after(5))

    #expect(result.status == .consumed(at: after(2)))
    #expect(result.consumedAt == after(2))
    #expect(throws: SharedResultError.notInsertable(.consumed)) {
      try result.beginInsertion(for: sessionID, at: after(6))
    }
    #expect(throws: SharedResultError.notInsertable(.consumed)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(6))
    }
  }

  @Test("iOS-IPC-03: 挿入を始めていない結果は消費を記録できない")
  func cannotConsumeWithoutInsertion() {
    var result = result()

    #expect(throws: SharedResultError.invalidTransition) {
      try result.markConsumed(at: after(1))
    }
    #expect(result.status == .ready)
  }

  @Test(
    "iOS-IPC-03: 挿入結果が不明な状態から、自動では再挿入可能にならない",
    arguments: [1.0, 300, 10_000]
  )
  func insertionUnknownNeverBecomesInsertableByItself(_ seconds: TimeInterval) throws {
    var result = try unknown()

    #expect(result.status == .insertionUnknown)
    #expect(result.insertability(for: sessionID, at: after(seconds)) == .needsConfirmation)
    #expect(throws: SharedResultError.notInsertable(.needsConfirmation)) {
      try result.beginInsertion(for: sessionID, at: after(seconds))
    }
  }

  @Test("iOS-IPC-03: 挿入結果が不明でも、利用者が確認すれば期限内に限り挿入し直せる")
  func reinsertsAfterConfirmation() throws {
    var result = try unknown()

    try result.beginInsertionAfterConfirmation(for: sessionID, at: after(10))

    #expect(result.status == .inserting(startedAt: after(10)))
    try result.markConsumed(at: after(11))
    #expect(result.consumedAt == after(11))
  }

  @Test("iOS-IPC-03: 確認後の再挿入も、期限切れ・時刻の逆行なら挿入しない")
  func confirmationDoesNotBypassExpiry() throws {
    var result = try unknown()

    #expect(throws: SharedResultError.notInsertable(.expired)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(600))
    }
    #expect(throws: SharedResultError.notInsertable(.invalidTimestamp)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(-1))
    }
    #expect(result.status == .insertionUnknown)
  }

  @Test("iOS-IPC-03: 挿入待ちの結果に、確認後の再挿入は使えない")
  func confirmationRequiresUnknownState() {
    var ready = result()

    #expect(throws: SharedResultError.invalidTransition) {
      try ready.beginInsertionAfterConfirmation(for: sessionID, at: after(1))
    }
  }

  @Test("iOS-IPC-03: 挿入結果が不明な結果を、利用者が挿入済みと確認したら消費済みにする")
  func resolvesUnknownAsConsumed() throws {
    var result = try unknown()

    try result.markConsumed(at: after(20))

    #expect(result.status == .consumed(at: after(20)))
  }

  @Test("iOS-IPC-03: 挿入を始めていない・消費済みの結果は、結果不明にできない")
  func cannotMarkUnknownOutsideInsertion() throws {
    var ready = result()
    #expect(throws: SharedResultError.invalidTransition) {
      try ready.markInsertionUnknown()
    }

    var consumed = try inserting()
    try consumed.markConsumed(at: after(2))
    #expect(throws: SharedResultError.invalidTransition) {
      try consumed.markInsertionUnknown()
    }
  }

  @Test("iOS-IPC-01: 文字列表現とリフレクションに本文を含めない")
  func redactsText() {
    let result = result(text: "秘密の発話内容")
    let outputs = [
      String(describing: result),
      String(reflecting: result),
      String(describing: Mirror(reflecting: result).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の発話内容"))
    }
    #expect(String(describing: result).contains("length: 7"))
  }
}
