import Foundation
import UtterCore
import UtterPersistence

/// 待機セッションの時間の設定（iOS-04, iOS-06）。
public struct StandbySessionConfiguration: Hashable, Sendable {
  /// 無操作で待機を終えるまでの時間の既定値（iOS-04: 既定5分）
  public static let defaultIdleTimeout: Duration = .seconds(300)
  /// 停止の合図が届かない録音を捨てるまでの時間の既定値（iOS-06: 既定120秒）
  public static let defaultMaxCaptureDuration: Duration = .seconds(120)
  /// キーボードの生存の印が途絶えたとみなす時間の既定値（暫定。キーボードは1秒ごとに書く想定）
  public static let defaultKeyboardHeartbeatTimeout: Duration = .seconds(5)
  /// 開始の合図を受け付ける、書かれてからの時間の既定値（暫定。遅れて届いた開始で録音を始めない）
  public static let defaultStartCommandMaxAge: Duration = .seconds(5)

  /// 無操作で待機を終えるまでの時間。`nil` なら無操作では終えない
  public var idleTimeout: Duration?
  public var maxCaptureDuration: Duration
  public var keyboardHeartbeatTimeout: Duration
  public var startCommandMaxAge: Duration

  public init(
    idleTimeout: Duration? = defaultIdleTimeout,
    maxCaptureDuration: Duration = defaultMaxCaptureDuration,
    keyboardHeartbeatTimeout: Duration = defaultKeyboardHeartbeatTimeout,
    startCommandMaxAge: Duration = defaultStartCommandMaxAge
  ) {
    self.idleTimeout = idleTimeout
    self.maxCaptureDuration = maxCaptureDuration
    self.keyboardHeartbeatTimeout = keyboardHeartbeatTimeout
    self.startCommandMaxAge = startCommandMaxAge
  }
}

/// 待機セッションで、本体アプリのアダプターに頼む処理。
public enum StandbySessionEffect: Hashable, Sendable {
  /// マイクの入力のミュートを外して録音を始める
  case beginCapture(SessionID)
  /// 録音を止めて、認識・整形・共有結果への保存を始める。終わったら `finishProcessing` を呼ぶ
  case finishCapture(SessionID)
  /// 録音を止めて捨てる。認識の結果も保存しない
  case abandonCapture(SessionID, StandbyFailure)
  /// 待機を終える（オーディオセッションを手放す）
  case endStandby(StandbyEndReason)
}

/// 待機を終えた理由。
public enum StandbyEndReason: Hashable, Sendable {
  /// 利用者が終えた
  case userRequested
  /// 無操作が続いた（iOS-04）
  case idleTimeout
}

/// 待機セッションの進行（iOS-04, iOS-06）。OS の API を使わず、合図・時刻・生存の印から次の処理を決める。
///
/// アダプター（Apps/iOS）は、合図のファイルを読み直すたび・定期的に、この値に渡して返った処理を行い、
/// `hostState(at:)` を App Group に書く。合図の欠落・重複・遅延は次のように扱う。
/// - 重複・古い合図：処理済みの番号以下なら捨てる
/// - 遅延：書かれてから `startCommandMaxAge` を過ぎた開始の合図は捨てる（停止・取り消しは遅れても扱う）
/// - 欠落：取り消しを取りこぼしても、生存の印の途絶・録音の上限・別のセッションの開始で録音を捨てる
public struct StandbySessionMachine: Sendable {
  public enum Phase: Hashable, Sendable {
    case off
    case standby
    case recording(SessionID, startedAt: Date)
    case processing(SessionID)
    case done(SessionID)
    case failed(SessionID?, StandbyFailure)
  }

  public private(set) var phase: Phase = .off
  public var configuration: StandbySessionConfiguration
  /// 処理済みの合図の番号
  public private(set) var lastSequence: Int64 = 0
  private var lastActivity: Date?

  public init(configuration: StandbySessionConfiguration = StandbySessionConfiguration()) {
    self.configuration = configuration
  }

  /// 待機を始める。始める前に書かれていた合図（`pendingCommand`）は処理済みとして扱い、実行しない
  public mutating func startStandby(pendingCommand: StandbyCommand?, at now: Date) {
    guard phase == .off else { return }
    lastSequence = max(lastSequence, pendingCommand?.sequence ?? 0)
    lastActivity = now
    phase = .standby
  }

  /// 利用者が待機を終える
  public mutating func endStandby(at now: Date) -> [StandbySessionEffect] {
    end(.userRequested)
  }

  /// キーボードの合図を受け取る
  public mutating func receive(_ command: StandbyCommand, at now: Date) -> [StandbySessionEffect] {
    guard phase != .off, command.sequence > lastSequence else { return [] }
    lastSequence = command.sequence
    lastActivity = now

    switch command.action {
    case .start:
      guard now.timeIntervalSince(command.issuedAt) <= configuration.startCommandMaxAge.secondsValue
      else { return [] }
      var effects: [StandbySessionEffect] = []
      switch phase {
      case .recording(let active, _) where active == command.sessionID:
        return []
      case .recording(let active, _):
        effects.append(.abandonCapture(active, .supersededBySession))
      case .processing:
        return []
      case .off, .standby, .done, .failed:
        break
      }
      phase = .recording(command.sessionID, startedAt: now)
      effects.append(.beginCapture(command.sessionID))
      return effects

    case .stop:
      guard case .recording(let active, _) = phase, active == command.sessionID else { return [] }
      phase = .processing(active)
      return [.finishCapture(active)]

    case .cancel:
      guard case .recording(let active, _) = phase, active == command.sessionID else { return [] }
      return abandon(active, .keyboardDismissed)
    }
  }

  /// 定期的に呼ぶ。録音の上限・生存の印の途絶・無操作を確かめる
  /// - Parameter heartbeat: App Group にあるキーボードの生存の印（読めなければ `nil`）
  public mutating func tick(heartbeat: KeyboardHeartbeat?, at now: Date) -> [StandbySessionEffect] {
    switch phase {
    case .recording(let active, let startedAt):
      if now.timeIntervalSince(startedAt) > configuration.maxCaptureDuration.secondsValue {
        return abandon(active, .captureLimitExceeded)
      }
      // 印がまだ届いていなければ、録音を始めた時刻から数える
      let lastSign = heartbeat.flatMap { $0.sessionID == active ? $0.at : nil }
      let since = max(lastSign ?? startedAt, startedAt)
      if now.timeIntervalSince(since) > configuration.keyboardHeartbeatTimeout.secondsValue {
        return abandon(active, .keyboardHeartbeatLost)
      }
      return []
    case .standby, .done, .failed:
      if let idleTimeout = configuration.idleTimeout, let lastActivity,
        now.timeIntervalSince(lastActivity) > idleTimeout.secondsValue
      {
        return end(.idleTimeout)
      }
      return []
    case .off, .processing:
      return []
    }
  }

  /// 録音中に着信などのオーディオの割り込みが始まった（iOS-PERF-03）
  public mutating func interruptionBegan(at now: Date) -> [StandbySessionEffect] {
    guard case .recording(let active, _) = phase else { return [] }
    return abandon(active, .interrupted)
  }

  /// 認識・整形・保存が終わった
  /// - Parameter failure: 失敗したときの理由。保存できたなら `nil`
  public mutating func finishProcessing(
    _ sessionID: SessionID, failure: StandbyFailure?, at now: Date
  ) {
    guard case .processing(let active) = phase, active == sessionID else { return }
    lastActivity = now
    phase = failure.map { .failed(sessionID, $0) } ?? .done(sessionID)
  }

  /// キーボードに知らせる状態
  public func hostState(at now: Date) -> StandbyHostState {
    switch phase {
    case .off: StandbyHostState(phase: .off, sessionID: nil, updatedAt: now)
    case .standby: StandbyHostState(phase: .standby, sessionID: nil, updatedAt: now)
    case .recording(let id, _): StandbyHostState(phase: .recording, sessionID: id, updatedAt: now)
    case .processing(let id): StandbyHostState(phase: .processing, sessionID: id, updatedAt: now)
    case .done(let id): StandbyHostState(phase: .done, sessionID: id, updatedAt: now)
    case .failed(let id, let failure):
      StandbyHostState(phase: .failed, sessionID: id, updatedAt: now, failure: failure)
    }
  }

  private mutating func abandon(
    _ sessionID: SessionID, _ failure: StandbyFailure
  ) -> [StandbySessionEffect] {
    phase = .failed(sessionID, failure)
    return [.abandonCapture(sessionID, failure)]
  }

  private mutating func end(_ reason: StandbyEndReason) -> [StandbySessionEffect] {
    guard phase != .off else { return [] }
    var effects: [StandbySessionEffect] = []
    if case .recording(let active, _) = phase {
      effects.append(.abandonCapture(active, .standbyEnded))
    }
    phase = .off
    lastActivity = nil
    effects.append(.endStandby(reason))
    return effects
  }
}

extension Duration {
  fileprivate var secondsValue: TimeInterval {
    let components = components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
