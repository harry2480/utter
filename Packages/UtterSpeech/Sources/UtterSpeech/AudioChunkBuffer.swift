import Synchronization

/// 録音から音声認識へ音声を渡すバッファ（REC-05）。
///
/// 認識側がまだ読んでいない音声の長さに上限を設ける。上限に達したら、そのチャンクまでを受け入れてから
/// 録音を自動停止扱いにし、受け入れた音声はすべて認識側へ渡す（無言で音声を破棄しない）。
/// 録音側は `append(_:)` の結果で上限到達を区別し、`SessionStateMachine.stopRecordingAtBufferLimit()`
/// と HUD 通知につなげる。認識側は `stream` を `SpeechRecognizer.recognize(_:session:)` に渡す。
/// 読み手は1つだけを想定する。
public final class AudioChunkBuffer: Sendable {
  /// まだ読まれていない音声の長さの上限の既定値（暫定）。最大録音時間（5分）に余裕を持たせた値
  public static let defaultLimit: Duration = .seconds(330)

  public let limit: Duration
  private let state = Mutex(State())

  private struct State {
    var queue: [AudioChunk] = []
    var head = 0
    var pending: Duration = .zero
    var closeReason: AudioChunkBufferCloseReason?
    var waiter: CheckedContinuation<AudioChunk?, Never>?
  }

  public init(limit: Duration = AudioChunkBuffer.defaultLimit) throws(AudioChunkBufferError) {
    guard limit > .zero else { throw .nonPositiveLimit }
    self.limit = limit
  }

  /// まだ読まれていない音声の長さ
  public var pendingDuration: Duration {
    state.withLock { $0.pending }
  }

  /// 読み手が次の音声を待っているか
  var hasWaitingConsumer: Bool {
    state.withLock { $0.waiter != nil }
  }

  /// 閉じた理由。受け付け中は `nil`
  public var closeReason: AudioChunkBufferCloseReason? {
    state.withLock { $0.closeReason }
  }

  /// 録音した音声を追加する。
  ///
  /// 上限に達した場合もこのチャンクは受け入れ、以後の追加を拒否して `.limitReached` を返す。
  @discardableResult
  public func append(_ chunk: AudioChunk) -> AudioChunkAppendResult {
    let (result, resume) = state.withLock {
      state -> (AudioChunkAppendResult, (CheckedContinuation<AudioChunk?, Never>, AudioChunk)?) in
      if let reason = state.closeReason {
        return (.rejected(reason), nil)
      }
      var resume: (CheckedContinuation<AudioChunk?, Never>, AudioChunk)?
      if let waiter = state.waiter {
        // 待っている読み手へ直接渡すため、読まれていない音声は増えない
        state.waiter = nil
        resume = (waiter, chunk)
      } else {
        state.queue.append(chunk)
        state.pending += chunk.duration
      }
      guard state.pending < limit else {
        state.closeReason = .limitReached
        return (.limitReached, resume)
      }
      return (.accepted, resume)
    }
    if let (waiter, chunk) = resume {
      waiter.resume(returning: chunk)
    }
    return result
  }

  /// 録音を終える。読み手は残りの音声を読み終えた後に終わりを受け取る。
  public func finish() {
    close(.finished)
  }

  /// 読み手へ渡すストリーム。読み手がキャンセルすると、以後の追加は `.rejected(.consumerCancelled)` になる。
  public var stream: AsyncStream<AudioChunk> {
    AsyncStream(unfolding: { [self] in await next() }, onCancel: { [self] in cancelConsumer() })
  }

  func next() async -> AudioChunk? {
    if Task.isCancelled {
      cancelConsumer()
      return nil
    }
    return await withCheckedContinuation { continuation in
      let immediate = state.withLock { state -> AudioChunk?? in
        if state.head < state.queue.count {
          let chunk = state.queue[state.head]
          state.head += 1
          state.pending -= chunk.duration
          if state.head == state.queue.count {
            state.queue.removeAll(keepingCapacity: true)
            state.head = 0
          }
          return .some(chunk)
        }
        if state.closeReason != nil {
          return .some(nil)
        }
        state.waiter = continuation
        return .none
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }
  }

  private func cancelConsumer() {
    close(.consumerCancelled)
  }

  private func close(_ reason: AudioChunkBufferCloseReason) {
    let waiter = state.withLock { state -> CheckedContinuation<AudioChunk?, Never>? in
      if state.closeReason == nil {
        state.closeReason = reason
      }
      if reason == .consumerCancelled {
        state.queue.removeAll()
        state.head = 0
        state.pending = .zero
      }
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: nil)
  }
}

/// `append(_:)` の結果。
public enum AudioChunkAppendResult: Hashable, Sendable {
  /// 受け入れた
  case accepted
  /// 受け入れたが上限に達した。録音を自動停止扱いにし、HUD で通知する（REC-05）
  case limitReached
  /// 閉じた後のため受け入れなかった
  case rejected(AudioChunkBufferCloseReason)
}

/// バッファを閉じた理由。
public enum AudioChunkBufferCloseReason: Hashable, Sendable {
  /// 録音側が終えた
  case finished
  /// 読まれていない音声が上限に達した（REC-05）
  case limitReached
  /// 読み手がキャンセルした
  case consumerCancelled
}

public enum AudioChunkBufferError: Error, Hashable, Sendable {
  case nonPositiveLimit
}
