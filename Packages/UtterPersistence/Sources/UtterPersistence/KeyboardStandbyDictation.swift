import Foundation
import UtterCore

/// キーボードが待機セッションへ合図を書き、状態を読む口（iOS-04）。本番は `StandbySessionStore`。
public protocol KeyboardStandbySignals: Sendable {
  func issueCommand(
    _ action: StandbyCommand.Action, sessionID: SessionID, at now: Date
  ) async throws -> StandbyCommand
  func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) async throws
  func loadHostState() async throws -> StandbyHostState?
}

extension StandbySessionStore: KeyboardStandbySignals {}

/// 録音の結果を入力欄へ挿入する口。本番は `SharedResultInsertionCoordinator`。
public protocol KeyboardStandbyInserting: Sendable {
  /// 結果を1回だけ挿入する（挿入の確保は共有結果の比較交換で行うため、重ねて呼んでも二重に入らない, iAC-04）
  func insertResult(sessionID: SessionID) async throws -> SharedResultInsertionOutcome
}

extension SharedResultInsertionCoordinator: KeyboardStandbyInserting {
  public func insertResult(sessionID: SessionID) async throws -> SharedResultInsertionOutcome {
    try await insert(sessionID: sessionID)
  }
}

/// 待機セッションの録音を、キーボードから見た状態（iOS-03〜06, iAC-11）。
public enum KeyboardStandbyState: Hashable, Sendable {
  /// 本体アプリが待機していない（または状態が途絶えている）。従来の経路（本体アプリを開く）を案内する
  case unavailable
  /// 待機中。マイクの操作で録音を始められる
  case ready
  /// 開始の合図を書いた。本体アプリが録音を始めるのを待っている
  case starting(SessionID)
  case recording(SessionID)
  /// 停止の合図を書いた。認識・整形・保存を待っている
  case processing(SessionID)
  /// 結果ができた。挿入前のプレビューの設定のとき、利用者の明示的な挿入操作を待つ（iOS-05）
  case resultReady(SessionID)
  /// 自動で挿入した（確認できた）
  case inserted
  /// 挿入を試みたが入ったか確認できない。自動ではやり直さず、プレビューで利用者に確認してもらう（iOS-IPC-03）
  case insertionUnknown(SessionID)
  case failed(KeyboardStandbyFailure)
}

/// 録音から挿入までに失敗した理由。発話の本文やエラーの詳細を持たない。
public enum KeyboardStandbyFailure: Hashable, Sendable {
  /// 本体アプリが捨てた・失敗した
  case host(StandbyFailure)
  /// 本体アプリの状態が途絶えた、または合図を書けなかった
  case hostLost
  /// 開始の合図に本体アプリが応えなかった
  case startTimedOut
  /// 結果を挿入できなかった（結果は挿入候補として残る）
  case insertFailed
}

/// キーボードの待機セッションの操作（マイクの1回目の操作で録音を始め、2回目で止める, iOS-03〜06）。
///
/// 時間は `tick()` を短い間隔（0.3秒ほど）で呼んで進める。呼ぶたびに、録音中は生存の印を間隔を空けて書き、
/// 本体アプリの状態を読み直す。プロセス間の通知は読み直しのきっかけにしかならないため、通知を受けたときも
/// `tick()` を呼ぶだけでよい。
///
/// - 録音を始めたキーボードが閉じられたら、取り消しの合図を書く（`keyboardClosed()`）。書けなくても、
///   生存の印が途絶えることで本体アプリが録音を捨てる
/// - 停止後、挿入までにキーボードが閉じられたら自動挿入しない。結果は保存されたままで、次に表示したときの
///   挿入候補になる
/// - 結果は1つのセッションにつき1回だけ挿入を試みる（連打・読み直しの重なりでも二重に入れない, iAC-04）
@MainActor
public final class KeyboardStandbyDictation {
  public private(set) var state: KeyboardStandbyState = .unavailable
  /// 状態が変わるたびに呼ぶ
  public var onChange: (() -> Void)?

  private let signals: any KeyboardStandbySignals
  private let inserter: any KeyboardStandbyInserting
  private let now: @Sendable () -> Date
  /// 挿入先のキーボードが表示されているか。表示されていなければ、結果を確保せずに候補として残す（iOS-06）
  private let canInsert: @MainActor () -> Bool
  private let heartbeatInterval: TimeInterval
  private let startTimeout: TimeInterval
  private let processingTimeout: TimeInterval

  /// 開始の合図を書いた時刻
  private var startedAt: Date?
  private var lastHeartbeat: Date?
  /// キーボードを閉じるたびに増やす。閉じる前に始めた読み込みの結果で動かないため
  private var epoch = 0
  /// 挿入を試みた（または試みている）セッション
  private var insertionAttempted: Set<SessionID> = []
  /// 停止の合図を書いた時刻（本体アプリが結果を返さないときに待ち続けないため）
  private var processingSince: Date?
  /// 開始・停止の合図を書いている間（重ねて押されても合図を重ねない）
  private var isIssuing = false
  /// 開始の合図を書いている間（この間の取り消しは、開始が済んでから送る）
  private var isStartIssuing = false
  /// 開始の合図を書いている間に取り消しが押された
  private var cancelPending = false
  /// `tick()` が重ならないようにする
  private var isTicking = false

  /// - Parameters:
  ///   - heartbeatInterval: 生存の印を書く間隔。本体アプリの途絶の判定（既定5秒）より十分短くする
  ///   - startTimeout: 開始の合図に本体アプリが応えるのを待つ時間
  ///   - processingTimeout: 停止の合図のあと、結果を待つ時間
  public init(
    signals: any KeyboardStandbySignals,
    inserter: any KeyboardStandbyInserting,
    heartbeatInterval: TimeInterval = 1,
    startTimeout: TimeInterval = 8,
    processingTimeout: TimeInterval = 90,
    canInsert: @escaping @MainActor () -> Bool = { true },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.signals = signals
    self.inserter = inserter
    self.heartbeatInterval = heartbeatInterval
    self.startTimeout = startTimeout
    self.processingTimeout = processingTimeout
    self.canInsert = canInsert
    self.now = now
  }

  /// 録音の途中（開始の待ち・録音中・処理中）か。`tick()` を続ける必要がある
  public var isBusy: Bool {
    switch state {
    case .starting, .recording, .processing: true
    default: false
    }
  }

  /// マイクの操作。待機中なら録音を始め、録音中なら止める。それ以外では何もしない
  public func toggle() async {
    guard !isIssuing else { return }
    isIssuing = true
    defer { isIssuing = false }
    switch state {
    case .ready, .inserted, .failed, .resultReady, .insertionUnknown:
      isStartIssuing = true
      cancelPending = false
      defer { isStartIssuing = false }
      await start()
    case .starting(let id), .recording(let id):
      await stop(id)
    case .unavailable, .processing:
      break
    }
  }

  /// 録音をやめる（入れない）。開始の待ち・録音中なら取り消しの合図を書いて待機に戻る。それ以外では何もしない
  public func cancel() async {
    guard !isIssuing else {
      if isStartIssuing { cancelPending = true }
      return
    }
    isIssuing = true
    defer { isIssuing = false }
    switch state {
    case .starting(let id), .recording(let id):
      let startEpoch = epoch
      do {
        _ = try await signals.issueCommand(.cancel, sessionID: id, at: now())
      } catch {
        if startEpoch == epoch { set(.failed(.hostLost)) }
        return
      }
      guard startEpoch == epoch else { return }
      startedAt = nil
      lastHeartbeat = nil
      set(.ready)
    case .unavailable, .ready, .processing, .resultReady, .inserted, .insertionUnknown, .failed:
      break
    }
  }

  /// 本体アプリの状態を読み直す。録音の途中なら生存の印も書く
  public func tick() async {
    guard !isTicking else { return }
    isTicking = true
    defer { isTicking = false }
    let startEpoch = epoch
    let current = now()
    switch state {
    case .starting(let id), .recording(let id):
      await writeHeartbeat(id, at: current)
      await follow(id, startEpoch: startEpoch, at: current)
    case .processing(let id):
      await follow(id, startEpoch: startEpoch, at: current)
    case .unavailable, .ready, .inserted, .failed, .resultReady, .insertionUnknown:
      await refreshAvailability(startEpoch: startEpoch, at: current)
    }
  }

  /// キーボードが閉じられた（表示が終わった・入力欄が制限された）。録音中なら取り消しを送る（iOS-06）
  public func keyboardClosed() async {
    epoch += 1
    let id: SessionID?
    switch state {
    case .starting(let sessionID), .recording(let sessionID): id = sessionID
    default: id = nil
    }
    // 次の表示でやり直せるよう、待機の判定からやり直す。結果が保存済みなら挿入候補として残る
    set(.unavailable)
    startedAt = nil
    lastHeartbeat = nil
    if let id {
      _ = try? await signals.issueCommand(.cancel, sessionID: id, at: now())
    }
  }

  /// 利用者の明示的な挿入操作など、キーボードの外で結果を扱い終えた
  public func resultHandled() {
    if case .resultReady = state { set(.ready) }
    if case .insertionUnknown = state { set(.ready) }
  }

  // MARK: 合図

  private func start() async {
    let id = SessionID()
    let current = now()
    let startEpoch = epoch
    do {
      _ = try await signals.issueCommand(.start, sessionID: id, at: current)
    } catch {
      if startEpoch == epoch { set(.failed(.hostLost)) }
      return
    }
    // 合図を書いている間に閉じられたら、追跡せず、書いた開始を取り消す（iOS-06）
    guard startEpoch == epoch else {
      _ = try? await signals.issueCommand(.cancel, sessionID: id, at: now())
      return
    }
    startedAt = current
    lastHeartbeat = nil
    set(.starting(id))
    // 録音の開始と同時に印を書き、本体アプリが印を待たずに録音を捨てないようにする
    await writeHeartbeat(id, at: current)
    // 開始を書いている間に取り消された。開始が済んだので、取り消しを書いて待機に戻る
    if cancelPending {
      cancelPending = false
      // 待っている間に `tick()` が同じセッションを録音中へ進めていても、取り消す
      switch state {
      case .starting(let current), .recording(let current):
        guard current == id, startEpoch == epoch else { return }
      default:
        return
      }
      do {
        _ = try await signals.issueCommand(.cancel, sessionID: id, at: now())
      } catch {
        if startEpoch == epoch { set(.failed(.hostLost)) }
        return
      }
      guard startEpoch == epoch else { return }
      startedAt = nil
      lastHeartbeat = nil
      set(.ready)
    }
  }

  private func stop(_ id: SessionID) async {
    let startEpoch = epoch
    // 本体アプリが開始を読む前に停止を書くと、合図は1つのファイルのため開始が上書きされ、停止だけが残って
    // 無視される。開始の待ちの間は、停止ではなく取り消しを書いて、録音を始めずに戻る
    var isStarting = false
    if case .starting = state { isStarting = true }
    do {
      _ = try await signals.issueCommand(isStarting ? .cancel : .stop, sessionID: id, at: now())
    } catch {
      if startEpoch == epoch { set(.failed(.hostLost)) }
      return
    }
    guard startEpoch == epoch else { return }
    if isStarting {
      startedAt = nil
      lastHeartbeat = nil
      set(.ready)
    } else {
      processingSince = now()
      set(.processing(id))
    }
  }

  private func writeHeartbeat(_ id: SessionID, at current: Date) async {
    if let lastHeartbeat, current.timeIntervalSince(lastHeartbeat) < heartbeatInterval { return }
    lastHeartbeat = current
    try? await signals.saveHeartbeat(KeyboardHeartbeat(sessionID: id, at: current))
  }

  // MARK: 状態の読み直し

  private func refreshAvailability(startEpoch: Int, at current: Date) async {
    let host = try? await signals.loadHostState()
    guard startEpoch == epoch else { return }
    let standing = host.map { Self.isStandingBy($0, at: current) } ?? false
    switch state {
    case .unavailable where standing: set(.ready)
    // 完了・失敗の後でも、本体アプリが待機を終えたら本体アプリを開く案内に戻す
    case .ready, .inserted, .failed, .resultReady, .insertionUnknown:
      if !standing { set(.unavailable) }
    default: break
    }
  }

  /// 録音を始められる待機か。更新が途絶えていれば待機していないものとして扱う
  private static func isStandingBy(_ host: StandbyHostState, at current: Date) -> Bool {
    guard host.isAlive(at: current) else { return false }
    switch host.phase {
    case .standby, .done, .failed: return true
    case .off, .recording, .processing: return false
    }
  }

  private func follow(_ id: SessionID, startEpoch: Int, at current: Date) async {
    let host: StandbyHostState?
    do {
      host = try await signals.loadHostState()
    } catch {
      host = nil
    }
    // 読んでいる間に閉じられた・別の操作で状態が変わったなら、古い読み込みの結果では動かない
    guard startEpoch == epoch, isFollowing(id) else { return }
    guard let host, host.isAlive(at: current) else {
      // 状態が読めない・更新が途絶えた
      if case .starting = state, let startedAt, current.timeIntervalSince(startedAt) <= startTimeout
      {
        return
      }
      set(.failed(.hostLost))
      return
    }
    guard host.sessionID == id else {
      if case .processing = state, let processingSince,
        current.timeIntervalSince(processingSince) > processingTimeout
      {
        set(.failed(.hostLost))
        return
      }
      if case .starting = state, let startedAt, current.timeIntervalSince(startedAt) > startTimeout
      {
        // 開始の合図に応えない。遅れて録音が始まる場合に備えて取り消しを書く
        _ = try? await signals.issueCommand(.cancel, sessionID: id, at: now())
        set(.failed(.startTimedOut))
      }
      return
    }
    switch host.phase {
    case .recording:
      if case .starting = state { set(.recording(id)) }
    case .processing:
      if case .starting = state { set(.processing(id)) }
      if case .recording = state { set(.processing(id)) }
    case .done:
      await finish(id, mode: host.insertionMode, startEpoch: startEpoch)
    case .failed:
      set(.failed(.host(host.failure ?? .processingFailed)))
    case .standby, .off:
      break
    }
  }

  private func isFollowing(_ id: SessionID) -> Bool {
    switch state {
    case .starting(let current), .recording(let current), .processing(let current): current == id
    default: false
    }
  }

  private func finish(_ id: SessionID, mode: StandbyInsertionMode, startEpoch: Int) async {
    switch mode {
    case .preview:
      set(.resultReady(id))
    case .automatic:
      // 表示されていないキーボードには挿入せず、結果を確保しないまま次の表示の挿入候補にする（iOS-06）
      guard canInsert() else {
        set(.unavailable)
        return
      }
      // 1つのセッションにつき1回だけ試みる。結果不明でも自動では重ねて試みない
      guard insertionAttempted.insert(id).inserted else { return }
      let outcome = try? await inserter.insertResult(sessionID: id)
      // 挿入の前の判定（`follow` の epoch の確認）から、ここまでは待たずに進む。閉じられた後に済んだ挿入の結果は、
      // 閉じた後の画面に出さない
      guard startEpoch == epoch else { return }
      switch outcome {
      case .inserted: set(.inserted)
      case .insertionUnknown: set(.insertionUnknown(id))
      case .notInserted, .notFound, nil: set(.failed(.insertFailed))
      }
    }
  }

  private func set(_ new: KeyboardStandbyState) {
    guard state != new else { return }
    state = new
    onChange?()
  }
}
