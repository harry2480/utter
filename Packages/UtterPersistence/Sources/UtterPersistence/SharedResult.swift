import Foundation
import UtterCore

/// iOS 本体アプリからキーボード拡張へ渡す挿入用の結果（iOS-IPC-01〜03）。
///
/// 端末の再起動をまたいで判定するため、時刻は実時刻（`Date`）で持ち、判定時の時刻は引数で受け取る。
/// API キー・OAuth トークン・音声は持たない。保存（App Group への書き込み）は別 Issue で扱う。
///
/// 本体アプリとキーボード拡張は別プロセスのため、値型の状態遷移だけでは二重挿入を防げない。
/// 保存層は、読み込んだときの `revision` と保存済みの `revision` が一致するときだけ書き込む
/// （比較交換）ことで、挿入の確保をアトミックにする。
public struct SharedResult: Hashable, Sendable, Codable {
  public let sessionID: SessionID
  public let createdAt: Date
  public let expiresAt: Date
  public private(set) var status: SharedResultStatus
  /// 挿入する本文
  public let text: String
  /// 状態が変わるたびに増える。保存層の比較交換に使う
  public private(set) var revision: UInt64
  public let configuration: SharedResultConfiguration

  /// 挿入を確定した時刻（iOS-IPC-01）。本体アプリでコピーした時刻も含む（iOS-07）
  public var consumedAt: Date? {
    guard case .consumed(let at) = status else {
      return nil
    }
    return at
  }

  /// 保存済みの値から復元する。有効期限が作成時刻以前なら矛盾した値として拒否する。
  public init(
    sessionID: SessionID,
    createdAt: Date,
    expiresAt: Date,
    status: SharedResultStatus,
    text: String,
    revision: UInt64,
    configuration: SharedResultConfiguration = SharedResultConfiguration()
  ) throws(SharedResultError) {
    guard expiresAt > createdAt else {
      throw .inconsistentStoredValue
    }
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.status = status
    self.text = text
    self.revision = revision
    self.configuration = configuration
  }

  /// 新しい共有結果を作る。有効期限は `createdAt` から設定の時間後。
  public init(
    sessionID: SessionID,
    text: String,
    createdAt: Date,
    configuration: SharedResultConfiguration = SharedResultConfiguration()
  ) {
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.expiresAt = createdAt.addingTimeInterval(Self.timeInterval(configuration.timeToLive))
    self.status = .ready
    self.text = text
    self.revision = 0
    self.configuration = configuration
  }

  /// 指定したセッションの結果として、`now` の時点で挿入してよいかを判定する（iOS-IPC-02, iOS-IPC-03）。
  ///
  /// セッション → 状態 → 時刻の順に判定する。別セッションの結果に再挿入の確認を出さないため、セッションを最初に見る。
  public func insertability(for sessionID: SessionID, at now: Date) -> SharedResultInsertability {
    guard sessionID == self.sessionID else {
      return .sessionMismatch
    }
    switch status {
    case .consumed:
      return .consumed
    case .inserting(let startedAt):
      let deadline = startedAt.addingTimeInterval(
        Self.timeInterval(configuration.insertionGracePeriod))
      // 時刻が開始時より戻った場合も、挿入中かどうかを判定できないため確認に回す。
      return (startedAt...deadline).contains(now) ? .inProgress : .needsConfirmation
    case .insertionUnknown:
      return .needsConfirmation
    case .ready:
      return timeValidity(at: now) ?? .insertable
    }
  }

  /// 挿入を始める。挿入可能な場合だけ `inserting` にし、連打や再生成による2回目の挿入を防ぐ（iOS-IPC-03）。
  public mutating func beginInsertion(
    for sessionID: SessionID,
    at now: Date
  ) throws(SharedResultError) {
    let insertability = insertability(for: sessionID, at: now)
    guard insertability == .insertable else {
      throw .notInsertable(insertability)
    }
    transition(to: .inserting(startedAt: now))
  }

  /// 挿入結果が確認できない状態から、利用者の確認を受けて挿入し直す（iOS-IPC-03）。
  ///
  /// 自動では呼ばない。利用者が再挿入を明示的に選んだときだけ呼ぶ。
  /// 挿入中（猶予時間内）・期限切れ・セッション不一致なら挿入しない。
  public mutating func beginInsertionAfterConfirmation(
    for sessionID: SessionID,
    at now: Date
  ) throws(SharedResultError) {
    let insertability = insertability(for: sessionID, at: now)
    guard insertability == .needsConfirmation else {
      throw insertability == .insertable ? .invalidTransition : .notInsertable(insertability)
    }
    if let invalid = timeValidity(at: now) {
      throw .notInsertable(invalid)
    }
    transition(to: .inserting(startedAt: now))
  }

  /// 挿入の成功を記録する。記録は冪等で、2回目以降は最初の時刻を保つ（iOS-IPC-03）。
  ///
  /// 挿入結果が不明だった結果を、利用者が「挿入済み」と確認した場合にも使う。
  public mutating func markConsumed(at now: Date) throws(SharedResultError) {
    switch status {
    case .consumed:
      return
    case .inserting, .insertionUnknown:
      transition(to: .consumed(at: now))
    case .ready:
      throw .invalidTransition
    }
  }

  /// 本体アプリの救済導線で本文をコピーしたことを記録する（iOS-07）。
  ///
  /// コピーした結果は利用者の手で貼り付けられるため、挿入済みと同じく `consumed` にし、
  /// キーボードからの挿入と二重にならないようにする。未挿入・挿入結果不明（猶予時間を過ぎた挿入中を含む）で、
  /// 期限内の結果だけコピーできる。挿入中（猶予時間内）・挿入済み・期限切れはコピーしない。
  public mutating func markCopied(at now: Date) throws(SharedResultError) {
    let insertability = insertability(for: sessionID, at: now)
    guard insertability == .insertable || insertability == .needsConfirmation else {
      throw .notInsertable(insertability)
    }
    // 挿入結果不明は時刻を見ずに判定されるため、ここで期限を確かめる
    if let invalid = timeValidity(at: now) {
      throw .notInsertable(invalid)
    }
    transition(to: .consumed(at: now))
  }

  /// 挿入を試みたが成功を確認できなかったことを記録する。この状態からは自動で再挿入できない（iOS-IPC-03）。
  public mutating func markInsertionUnknown() throws(SharedResultError) {
    switch status {
    case .insertionUnknown:
      return
    case .inserting:
      transition(to: .insertionUnknown)
    case .ready, .consumed:
      throw .invalidTransition
    }
  }

  private mutating func transition(to status: SharedResultStatus) {
    self.status = status
    revision += 1
  }

  /// 時刻が作成時より戻っていれば `invalidTimestamp`、期限切れなら `expired`、問題なければ `nil`。
  private func timeValidity(at now: Date) -> SharedResultInsertability? {
    guard now >= createdAt else {
      return .invalidTimestamp
    }
    guard now < expiresAt else {
      return .expired
    }
    return nil
  }

  private static func timeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには状態と文字数だけを出す。
extension SharedResult: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "SharedResult(status: \(status), revision: \(revision), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "sessionID": sessionID, "createdAt": createdAt, "expiresAt": expiresAt, "status": status,
        "revision": revision, "length": text.count,
      ])
  }
}

/// 共有結果の状態（iOS-IPC-01, iOS-IPC-03）。
public enum SharedResultStatus: Hashable, Sendable, Codable {
  /// 挿入を待っている
  case ready
  /// キーボード拡張が挿入を始めた。完了を記録する前に拡張が終了した場合もこの状態のまま残る
  case inserting(startedAt: Date)
  /// 挿入を試みたが成功を確認できなかった
  case insertionUnknown
  /// 挿入済み（本体アプリでコピーした場合も含む）
  case consumed(at: Date)
}

/// 共有結果を挿入してよいかの判定（iOS-IPC-02, iOS-IPC-03）。
public enum SharedResultInsertability: Hashable, Sendable {
  case insertable
  case expired
  case consumed
  /// キーボードが待っているセッションの結果ではない
  case sessionMismatch
  /// 挿入中（猶予時間内）。連打・再生成による2回目の挿入として拒否する
  case inProgress
  /// 挿入結果が不明、または猶予時間を過ぎても挿入中のまま。自動では再挿入せず、利用者に確認する
  case needsConfirmation
  /// 端末の時刻が作成時より前で、期限を判定できない
  case invalidTimestamp
}

public enum SharedResultError: Error, Hashable, Sendable {
  case notInsertable(SharedResultInsertability)
  case invalidTransition
  /// 保存済みの値が矛盾している（有効期限が作成時刻以前など）
  case inconsistentStoredValue
}
