import Synchronization

/// 録音から音声認識へ音声を渡すバッファ（REC-05）。
///
/// 認識側がまだ読んでいない音声の長さに上限を設ける。上限に達したら、そのチャンクまでを受け入れてから
/// 録音を自動停止扱いにし、受け入れた音声はすべて認識側へ渡す（無言で音声を破棄しない）。
/// そのため読まれていない音声は「上限＋最大1チャンク」まで増えうる。
///
/// 録音側は `append(_:)` の結果で上限到達を区別し、`SessionStateMachine.stopRecordingAtBufferLimit()`
/// と HUD 通知につなげる。認識側は `stream` を `SpeechRecognizer.recognize(_:session:)` に渡す。
/// 録音のタップから同期的に追加できるよう、actor ではなく `Mutex` で状態を守る。
public final class AudioChunkBuffer: Sendable {
  /// まだ読まれていない音声の長さの上限の既定値（暫定）。最大録音時間（5分）に余裕を持たせた値
  public static let defaultLimit: Duration = .seconds(330)

  public let limit: Duration
  /// 読み手へ渡すストリーム。読み手は1つだけで、同時に2つ目の読み手が待つとそちらはすぐに終わる。
  /// 読み手がキャンセルすると、未読の音声を捨てて以後の追加を `.rejected(.consumerCancelled)` にする
  public let stream: AsyncStream<AudioChunk>
  private let storage: Storage

  public init(limit: Duration = AudioChunkBuffer.defaultLimit) throws(AudioChunkBufferError) {
    guard limit > .zero else { throw .nonPositiveLimit }
    let storage = Storage(limit: limit)
    self.limit = limit
    self.storage = storage
    stream = AsyncStream(
      unfolding: { await storage.next() }, onCancel: { storage.close(.consumerCancelled) })
  }

  /// まだ読まれていない音声の長さ
  public var pendingDuration: Duration {
    storage.state.withLock { $0.pending }
  }

  /// 閉じた理由。受け付け中は `nil`
  public var closeReason: AudioChunkBufferCloseReason? {
    storage.state.withLock { $0.closeReason }
  }

  /// 読み手が次の音声を待っているか
  var hasWaitingConsumer: Bool {
    storage.state.withLock { $0.waiter != nil }
  }

  /// 読み済みのチャンクを保持している数（メモリの確認用）
  var retainedChunkCount: Int {
    storage.state.withLock { $0.queue.count }
  }

  /// 録音した音声を追加する。
  ///
  /// 上限に達した場合もこのチャンクは受け入れ、以後の追加を拒否して `.limitReached` を返す。
  @discardableResult
  public func append(_ chunk: AudioChunk) -> AudioChunkAppendResult {
    storage.append(chunk)
  }

  /// 録音を終える。読み手は残りの音声を読み終えた後に終わりを受け取る。
  ///
  /// 録音側は必ず呼ぶ。呼ばずにバッファを捨てると、読み手は終わらない。
  public func finish() {
    storage.close(.finished)
  }
}

extension AudioChunkBuffer {
  fileprivate struct State {
    var queue: [AudioChunk] = []
    var head = 0
    var pending: Duration = .zero
    var closeReason: AudioChunkBufferCloseReason?
    var waiter: CheckedContinuation<AudioChunk?, Never>?

    /// 読み済みのチャンクを手放す
    mutating func compact() {
      if head == queue.count {
        queue.removeAll(keepingCapacity: true)
        head = 0
      } else if head >= 16, head * 2 >= queue.count {
        queue.removeFirst(head)
        head = 0
      }
    }
  }

  fileprivate final class Storage: Sendable {
    let limit: Duration
    let state = Mutex(State())

    init(limit: Duration) {
      self.limit = limit
    }

    func append(_ chunk: AudioChunk) -> AudioChunkAppendResult {
      let (result, waiter) = state.withLock {
        state -> (AudioChunkAppendResult, CheckedContinuation<AudioChunk?, Never>?) in
        if let reason = state.closeReason {
          return (.rejected(reason), nil)
        }
        // 待っている読み手へ直接渡すなら、読まれていない音声は増えない
        let waiter = state.waiter.take()
        if waiter == nil {
          state.queue.append(chunk)
          state.pending += chunk.duration
        }
        guard state.pending < limit else {
          state.closeReason = .limitReached
          return (.limitReached, waiter)
        }
        return (.accepted, waiter)
      }
      waiter?.resume(returning: chunk)
      return result
    }

    func next() async -> AudioChunk? {
      await withCheckedContinuation { continuation in
        let immediate = state.withLock { state -> AudioChunk?? in
          if state.head < state.queue.count {
            let chunk = state.queue[state.head]
            state.head += 1
            state.pending -= chunk.duration
            state.compact()
            return .some(chunk)
          }
          // 閉じた後と、すでに別の読み手が待っている場合はすぐに終える
          if state.closeReason != nil || state.waiter != nil {
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

    func close(_ reason: AudioChunkBufferCloseReason) {
      let waiter = state.withLock { state -> CheckedContinuation<AudioChunk?, Never>? in
        if state.closeReason == nil {
          state.closeReason = reason
        }
        if reason == .consumerCancelled {
          // セッションのキャンセル（REC-01）なので、未読の音声は捨てる
          state.queue.removeAll()
          state.head = 0
          state.pending = .zero
        }
        return state.waiter.take()
      }
      waiter?.resume(returning: nil)
    }
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

/// バッファを閉じた理由。先に閉じた理由を保持する。
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
