import Foundation
import UtterCore

// 待機セッション方式（iOS-03〜06, #247）で、キーボード拡張と本体アプリが App Group のファイルでやりとりする値。
// どれも発話の本文・音声・秘密情報を持たない（iOS-IPC-04）。正はファイルで、プロセス間の通知は
// 「読み直して」のきっかけにだけ使う（欠落・重複・遅延を前提にする, iOS-04）。

/// キーボードから本体アプリへの合図。
public struct StandbyCommand: Hashable, Sendable, Codable {
  public enum Action: String, Hashable, Sendable, Codable {
    /// 録音を始める
    case start
    /// 録音を止めて、認識・整形する
    case stop
    /// 録音を止めて捨てる（録音中にキーボードが閉じられたとき, iOS-06）
    case cancel
  }

  /// 単調に増える番号。本体アプリは処理済みより大きいものだけを扱う（重複の排除）
  public let sequence: Int64
  public let action: Action
  /// キーボードが録音ごとに作る識別子
  public let sessionID: SessionID
  /// キーボードが合図を書いた時刻（遅れて届いた開始の合図を捨てるのに使う）
  public let issuedAt: Date

  public init(sequence: Int64, action: Action, sessionID: SessionID, issuedAt: Date) {
    self.sequence = sequence
    self.action = action
    self.sessionID = sessionID
    self.issuedAt = issuedAt
  }

  /// 前の合図の次の番号で合図を作る。番号は時刻（ミリ秒）を元にし、前の番号より必ず大きくする
  public static func next(
    after previous: StandbyCommand?, action: Action, sessionID: SessionID, at now: Date
  ) -> StandbyCommand {
    let milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    let sequence = max(milliseconds, (previous?.sequence ?? 0) + 1)
    return StandbyCommand(sequence: sequence, action: action, sessionID: sessionID, issuedAt: now)
  }
}

/// 本体アプリの待機セッションの状態。キーボードは、待機中か・結果ができたかをこれで判断する。
public struct StandbyHostState: Hashable, Sendable, Codable {
  public enum Phase: String, Hashable, Sendable, Codable {
    /// 待機していない
    case off
    /// 待機中（合図を待っている）
    case standby
    /// 録音中
    case recording
    /// 認識・整形中
    case processing
    /// 結果を共有結果に保存した
    case done
    /// 録音を捨てた、または認識・整形に失敗した（理由は `failure`）
    case failed
  }

  public let phase: Phase
  /// 録音中・処理中・結果のセッション。待機中・待機していないときは `nil`
  public let sessionID: SessionID?
  /// 本体アプリが最後に書いた時刻。待機中は定期的に書き直す（古ければ本体アプリが止まっている）
  public let updatedAt: Date
  public let failure: StandbyFailure?

  /// 待機中とみなす、更新の新しさの上限
  public static let heartbeatTimeout: Duration = .seconds(8)

  public init(phase: Phase, sessionID: SessionID?, updatedAt: Date, failure: StandbyFailure? = nil)
  {
    self.phase = phase
    self.sessionID = sessionID
    self.updatedAt = updatedAt
    self.failure = failure
  }

  /// 本体アプリが待機セッションを続けているか。待機していない・更新が途絶えていれば `false`
  public func isAlive(at now: Date) -> Bool {
    phase != .off && now.timeIntervalSince(updatedAt) <= Self.heartbeatTimeout.timeInterval
  }
}

/// 録音を捨てた・失敗した理由。発話の本文やエラーの詳細を持たない。
public enum StandbyFailure: String, Hashable, Sendable, Codable {
  /// 録音中にキーボードが閉じられた（取り消しの合図）
  case keyboardDismissed
  /// 録音中にキーボードの生存の印が途絶えた（キーボード拡張が取り消しを送れずに終わった）
  case keyboardHeartbeatLost
  /// 停止の合図が届かないまま、録音の上限を超えた
  case captureLimitExceeded
  /// 着信などのオーディオの割り込みで録音が止まった
  case interrupted
  /// 別のセッションの開始の合図が届いた（前のセッションの取り消しを取りこぼした）
  case supersededBySession
  /// 録音中に、利用者が本体アプリで待機を終えた
  case standbyEnded
  /// 認識できる発話がなかった
  case noSpeech
  /// 認識・整形・保存に失敗した
  case processingFailed
}

/// 録音中にキーボードが書く生存の印（iOS-06）。本体アプリは途絶えたら録音を捨てる。
public struct KeyboardHeartbeat: Hashable, Sendable, Codable {
  public let sessionID: SessionID
  public let at: Date

  public init(sessionID: SessionID, at: Date) {
    self.sessionID = sessionID
    self.at = at
  }
}

extension Duration {
  /// 秒数（`TimeInterval`）
  var timeInterval: TimeInterval {
    let components = components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
