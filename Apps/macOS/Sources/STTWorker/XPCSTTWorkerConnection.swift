import Foundation
import UtterSpeech
import XPC

/// アプリに組み込んだ XPC STT Worker（Workers/macOSSTT）への接続を作る（4章, 13章）。
struct XPCSTTWorkerConnector: STTWorkerConnecting {
  /// Worker の Bundle ID。アプリの Bundle ID に `.stt-worker` を付けたもの（Apps/macOS/Specs/UtterSTTWorker.yml）
  let serviceName: String

  init(serviceName: String) {
    self.serviceName = serviceName
  }

  /// アプリに組み込まれた Worker。Bundle ID が取れなければ `nil`
  init?(bundle: Bundle = .main) {
    guard let identifier = bundle.bundleIdentifier else { return nil }
    self.init(serviceName: identifier + ".stt-worker")
  }

  func connect() throws(STTWorkerConnectionError) -> any STTWorkerConnection {
    do {
      return try XPCSTTWorkerConnection(serviceName: serviceName)
    } catch {
      // 失敗の詳細は持たない（接続先の名前以外に情報がなく、利用者への案内は種類で足りる）
      throw .unavailable
    }
  }
}

/// `XPCSession` を `STTWorkerConnection` として見せる。
///
/// Worker の終了は `XPCSession` の取り消しとして届く。`canRetry`（作り直せば再接続できる）なら異常終了（interrupted）、
/// そうでなければ接続の無効化（invalidated）とする。
final class XPCSTTWorkerConnection: STTWorkerConnection {
  let events: AsyncStream<STTWorkerConnectionEvent>
  private let continuation: AsyncStream<STTWorkerConnectionEvent>.Continuation
  private let session: XPCSession

  init(serviceName: String) throws {
    let (events, continuation) = AsyncStream.makeStream(of: STTWorkerConnectionEvent.self)
    self.events = events
    self.continuation = continuation
    session = try XPCSession(
      xpcService: serviceName,
      incomingMessageHandler: { (response: STTWorkerResponse) -> (any Encodable)? in
        continuation.yield(.message(response))
        return nil
      },
      cancellationHandler: { error in
        continuation.yield(error.canRetry ? .interrupted : .invalidated)
        continuation.finish()
      })
  }

  func send(_ request: STTWorkerRequest) {
    do {
      try session.send(request)
    } catch {
      continuation.yield(.interrupted)
      continuation.finish()
    }
  }

  func invalidate() {
    continuation.finish()
    session.cancel(reason: "STT Worker への接続を閉じた")
  }
}
