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

  @Test("iOS-IPC-01: 共有結果は sessionID・createdAt・expiresAt・status・text・consumedAt を持つ")
  func holdsRequiredFields() {
    let result = result()

    #expect(result.sessionID == sessionID)
    #expect(result.createdAt == createdAt)
    #expect(result.expiresAt == after(600))
    #expect(result.status == .ready)
    #expect(result.text == "明日の会議は10時からです。")
    #expect(result.consumedAt == nil)
  }

  @Test("iOS-IPC-01: 保存済みの値から同じ内容に復元できる")
  func restoresFromStoredValues() throws {
    var original = result()
    try original.beginInsertion(for: sessionID, at: after(1))
    try original.markConsumed(at: after(2))

    let restored = SharedResult(
      sessionID: original.sessionID, createdAt: original.createdAt,
      expiresAt: original.expiresAt, status: original.status, text: original.text,
      consumedAt: original.consumedAt)

    #expect(restored == original)
  }

  @Test("iOS-IPC-02: 有効期限の既定は10分で、設定で変えられる")
  func expiryIsConfigurable() throws {
    #expect(SharedResultConfiguration().timeToLive == .seconds(600))

    let configuration = try SharedResultConfiguration(timeToLive: .milliseconds(1500))
    let result = SharedResult(
      sessionID: sessionID, text: "本文", createdAt: createdAt, configuration: configuration)

    #expect(result.expiresAt == after(1.5))
  }

  @Test("iOS-IPC-02: 有効期限が0以下の設定は拒否する", arguments: [Duration.zero, .seconds(-1)])
  func rejectsNonPositiveTimeToLive(_ timeToLive: Duration) {
    #expect(throws: SharedResultConfigurationError.nonPositiveTimeToLive) {
      try SharedResultConfiguration(timeToLive: timeToLive)
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

  @Test("iOS-IPC-02: セッションID が一致しない結果は挿入可能と判定しない")
  func sessionMismatchIsNotInsertable() {
    #expect(result().insertability(for: SessionID(), at: after(1)) == .sessionMismatch)
  }

  @Test("iOS-IPC-02: 端末の時刻が作成時より前なら挿入可能と判定しない")
  func clockBeforeCreationIsNotInsertable() {
    #expect(result().insertability(for: sessionID, at: after(-1)) == .invalidTimestamp)
  }

  @Test("iOS-IPC-02: 消費済みの結果は挿入可能と判定しない")
  func consumedIsNotInsertable() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))
    try result.markConsumed(at: after(2))

    #expect(result.insertability(for: sessionID, at: after(3)) == .consumed)
  }

  @Test("iOS-IPC-03: 挿入を始めると、連打やキーボード再生成による2回目の挿入を拒否する")
  func rejectsSecondInsertionWhileInserting() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))

    #expect(result.status == .inserting(startedAt: after(1)))
    #expect(throws: SharedResultError.notInsertable(.needsConfirmation)) {
      try result.beginInsertion(for: sessionID, at: after(1))
    }
  }

  @Test("iOS-IPC-03: 消費の記録は冪等で、2回目は最初の時刻を保ち、挿入不可のまま")
  func consumingIsIdempotent() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))
    try result.markConsumed(at: after(2))
    try result.markConsumed(at: after(5))

    #expect(result.status == .consumed)
    #expect(result.consumedAt == after(2))
    #expect(throws: SharedResultError.notInsertable(.consumed)) {
      try result.beginInsertion(for: sessionID, at: after(6))
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
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(0.5))
    try result.markInsertionUnknown()

    #expect(result.status == .insertionUnknown)
    #expect(result.insertability(for: sessionID, at: after(seconds)) == .needsConfirmation)
    #expect(throws: SharedResultError.notInsertable(.needsConfirmation)) {
      try result.beginInsertion(for: sessionID, at: after(seconds))
    }
  }

  @Test("iOS-IPC-03: 挿入中のまま拡張が終了した結果も、自動では再挿入可能にならない")
  func abandonedInsertionNeedsConfirmation() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))

    #expect(result.insertability(for: sessionID, at: after(100)) == .needsConfirmation)
  }

  @Test(
    "iOS-IPC-03: 挿入結果が不明でも、利用者が確認すれば期限内に限り挿入し直せる",
    arguments: [true, false]
  )
  func reinsertsAfterConfirmation(_ markedUnknown: Bool) throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))
    if markedUnknown {
      try result.markInsertionUnknown()
    }

    try result.beginInsertionAfterConfirmation(for: sessionID, at: after(10))

    #expect(result.status == .inserting(startedAt: after(10)))
    try result.markConsumed(at: after(11))
    #expect(result.consumedAt == after(11))
  }

  @Test("iOS-IPC-03: 確認後の再挿入も、期限切れ・時刻の逆行なら挿入しない")
  func confirmationDoesNotBypassExpiry() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))
    try result.markInsertionUnknown()

    #expect(throws: SharedResultError.notInsertable(.expired)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(600))
    }
    #expect(throws: SharedResultError.notInsertable(.invalidTimestamp)) {
      try result.beginInsertionAfterConfirmation(for: sessionID, at: after(-1))
    }
    #expect(result.status == .insertionUnknown)
  }

  @Test("iOS-IPC-03: 確認後の再挿入は、挿入結果が不明な結果だけに使える")
  func confirmationRequiresUnknownState() throws {
    var ready = result()
    #expect(throws: SharedResultError.invalidTransition) {
      try ready.beginInsertionAfterConfirmation(for: sessionID, at: after(1))
    }

    var consumed = result()
    try consumed.beginInsertion(for: sessionID, at: after(1))
    try consumed.markConsumed(at: after(2))
    #expect(throws: SharedResultError.invalidTransition) {
      try consumed.beginInsertionAfterConfirmation(for: sessionID, at: after(3))
    }

    var unknown = result()
    try unknown.beginInsertion(for: sessionID, at: after(1))
    try unknown.markInsertionUnknown()
    #expect(throws: SharedResultError.invalidTransition) {
      try unknown.beginInsertionAfterConfirmation(for: SessionID(), at: after(2))
    }
  }

  @Test("iOS-IPC-03: 挿入結果が不明な結果を、利用者が挿入済みと確認したら消費済みにする")
  func resolvesUnknownAsConsumed() throws {
    var result = result()
    try result.beginInsertion(for: sessionID, at: after(1))
    try result.markInsertionUnknown()
    try result.markInsertionUnknown()

    try result.markConsumed(at: after(20))

    #expect(result.status == .consumed)
    #expect(result.consumedAt == after(20))
  }

  @Test("iOS-IPC-03: 挿入を始めていない・消費済みの結果は、結果不明にできない")
  func cannotMarkUnknownOutsideInsertion() throws {
    var ready = result()
    #expect(throws: SharedResultError.invalidTransition) {
      try ready.markInsertionUnknown()
    }

    var consumed = result()
    try consumed.beginInsertion(for: sessionID, at: after(1))
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
