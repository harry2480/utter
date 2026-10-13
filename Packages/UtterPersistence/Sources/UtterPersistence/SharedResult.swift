import Foundation
import UtterCore

/// iOS 本体アプリからキーボード拡張へ渡す挿入用の結果（iOS-IPC-01〜03）。
///
/// 端末の再起動をまたいで判定するため、時刻は実時刻（`Date`）で持ち、判定時の時刻は引数で受け取る。
/// API キー・OAuth トークン・音声は持たない。保存（App Group への書き込み）は別 Issue で扱う。
public struct SharedResult: Hashable, Sendable {
  public let sessionID: SessionID
  public let createdAt: Date
  public let expiresAt: Date
  public private(set) var status: SharedResultStatus
  /// 挿入する本文
  public let text: String
  /// 挿入を確定した時刻
  public private(set) var consumedAt: Date?

  /// 保存済みの値から復元する。
  public init(
    sessionID: SessionID,
    createdAt: Date,
    expiresAt: Date,
    status: SharedResultStatus,
    text: String,
    consumedAt: Date?
  ) {
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.status = status
    self.text = text
    self.consumedAt = consumedAt
  }

  /// 新しい共有結果を作る。有効期限は `createdAt` から設定の時間後。
  public init(
    sessionID: SessionID,
    text: String,
    createdAt: Date,
    configuration: SharedResultConfiguration = SharedResultConfiguration()
  ) {
    self.init(
      sessionID: sessionID,
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(Self.timeInterval(configuration.timeToLive)),
      status: .ready,
      text: text,
      consumedAt: nil
    )
  }

  /// 指定したセッションの結果として、`now` の時点で挿入してよいかを判定する（iOS-IPC-02, iOS-IPC-03）。
  public func insertability(for sessionID: SessionID, at now: Date) -> SharedResultInsertability {
    guard sessionID == self.sessionID else {
      return .sessionMismatch
    }
    switch status {
    case .consumed:
      return .consumed
    case .inserting, .insertionUnknown:
      return .needsConfirmation
    case .ready:
      break
    }
    // 端末の時刻が作成時より戻っている場合は、期限を判定できないため挿入しない。
    guard now >= createdAt else {
      return .invalidTimestamp
    }
    guard now < expiresAt else {
      return .expired
    }
    return .insertable
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
    status = .inserting(startedAt: now)
  }

  /// 挿入結果が確認できない状態から、利用者の確認を受けて挿入し直す（iOS-IPC-03）。
  ///
  /// 自動では呼ばない。利用者が再挿入を明示的に選んだときだけ呼ぶ。期限切れ・セッション不一致なら挿入しない。
  public mutating func beginInsertionAfterConfirmation(
    for sessionID: SessionID,
    at now: Date
  ) throws(SharedResultError) {
    guard insertability(for: sessionID, at: now) == .needsConfirmation else {
      throw .invalidTransition
    }
    let ready = SharedResult(
      sessionID: self.sessionID, createdAt: createdAt, expiresAt: expiresAt, status: .ready,
      text: text, consumedAt: nil)
    let insertability = ready.insertability(for: sessionID, at: now)
    guard insertability == .insertable else {
      throw .notInsertable(insertability)
    }
    status = .inserting(startedAt: now)
  }

  /// 挿入の成功を記録する。記録は冪等で、2回目以降は最初の時刻を保つ（iOS-IPC-03）。
  ///
  /// 挿入結果が不明だった結果を、利用者が「挿入済み」と確認した場合にも使う。
  public mutating func markConsumed(at now: Date) throws(SharedResultError) {
    switch status {
    case .consumed:
      return
    case .inserting, .insertionUnknown:
      status = .consumed
      consumedAt = now
    case .ready:
      throw .invalidTransition
    }
  }

  /// 挿入を試みたが成功を確認できなかったことを記録する。この状態からは自動で再挿入できない（iOS-IPC-03）。
  public mutating func markInsertionUnknown() throws(SharedResultError) {
    switch status {
    case .insertionUnknown:
      return
    case .inserting:
      status = .insertionUnknown
    case .ready, .consumed:
      throw .invalidTransition
    }
  }

  private static func timeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには状態と文字数だけを出す。
extension SharedResult: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "SharedResult(status: \(status), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "sessionID": sessionID, "createdAt": createdAt, "expiresAt": expiresAt, "status": status,
        "length": text.count, "consumedAt": consumedAt as Any,
      ])
  }
}

/// 共有結果の状態（iOS-IPC-01, iOS-IPC-03）。
public enum SharedResultStatus: Hashable, Sendable {
  /// 挿入を待っている
  case ready
  /// キーボード拡張が挿入を始めた。完了を記録する前に拡張が終了した場合もこの状態のまま残る
  case inserting(startedAt: Date)
  /// 挿入を試みたが成功を確認できなかった
  case insertionUnknown
  /// 挿入済み
  case consumed
}

/// 共有結果を挿入してよいかの判定（iOS-IPC-02, iOS-IPC-03）。
public enum SharedResultInsertability: Hashable, Sendable {
  case insertable
  case expired
  case consumed
  /// キーボードが待っているセッションの結果ではない
  case sessionMismatch
  /// 挿入中または挿入結果が不明。自動では再挿入せず、利用者に確認する
  case needsConfirmation
  /// 端末の時刻が作成時より前で、期限を判定できない
  case invalidTimestamp
}

public enum SharedResultError: Error, Hashable, Sendable {
  case notInsertable(SharedResultInsertability)
  case invalidTransition
}
