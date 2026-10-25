import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// 応答本文を受信しながら読む HTTP の送信部。本番は `URLSessionStreamingTransport`、テストは Stub を注入して
/// 実ネットワークに出ない。
///
/// 受信量の上限を受け取る側で守れるよう、本文はまとめて返さずバイト列の並びとして返す。
/// `request` のヘッダーには API キーが、本文には発話が入る。実装は `request` をログに出さない。
public protocol HTTPStreamingTransport: Sendable {
  associatedtype Bytes: AsyncSequence<UInt8, any Error>

  /// リクエストを送り、HTTP 応答と本文のバイト列を返す。
  ///
  /// 呼び出し元の Task がキャンセルされたら通信を止め、`CancellationError` か
  /// `URLError(.cancelled)` を投げる。返したバイト列を読み終える前に捨てられたら、通信を止める。
  func bytes(for request: URLRequest) async throws -> (Bytes, HTTPURLResponse)
}

/// `URLSession` による受信しながら読む送信部。既定では Cookie・キャッシュをディスクに残さない ephemeral の構成を使う。
public struct URLSessionStreamingTransport: HTTPStreamingTransport {
  public let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func bytes(for request: URLRequest) async throws -> (
    URLSessionByteStream, HTTPURLResponse
  ) {
    let box = DataTaskBox()
    let (bytes, response) = try await session.bytes(
      for: request, delegate: TaskCapturingDelegate(box: box))
    guard let response = response as? HTTPURLResponse else {
      box.cancel()
      throw URLError(.badServerResponse)
    }
    return (URLSessionByteStream(base: bytes, canceller: DataTaskCanceller(box: box)), response)
  }
}

/// `URLSessionStreamingTransport` が返す本文のバイト列。読み終える前に捨てられたら通信を止める
/// （受信量の上限で読むのをやめたあと、残りを受信し続けないため）。
public struct URLSessionByteStream: AsyncSequence {
  public typealias Element = UInt8

  let base: URLSession.AsyncBytes
  let canceller: DataTaskCanceller

  public struct AsyncIterator: AsyncIteratorProtocol {
    var base: URLSession.AsyncBytes.AsyncIterator
    let canceller: DataTaskCanceller

    public mutating func next() async throws -> UInt8? {
      try await base.next()
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(base: base.makeAsyncIterator(), canceller: canceller)
  }
}

/// 通信の Task を持つ入れ物。delegate と `DataTaskCanceller` で共有する
final class DataTaskBox: Sendable {
  private struct State {
    var task: URLSessionTask?
    var isCancelled = false
  }

  private let state = Mutex(State())

  func set(_ task: URLSessionTask) {
    let isCancelled = state.withLock { state in
      state.task = task
      return state.isCancelled
    }
    if isCancelled {
      task.cancel()
    }
  }

  func cancel() {
    let task = state.withLock { state in
      state.isCancelled = true
      return state.task
    }
    task?.cancel()
  }
}

/// 最後の参照が消えたら通信を止める。読み終えたあとの取り消しは何もしない
final class DataTaskCanceller: Sendable {
  private let box: DataTaskBox

  init(box: DataTaskBox) {
    self.box = box
  }

  deinit {
    box.cancel()
  }
}

/// 作られた通信の Task を受け取る delegate。`DataTaskCanceller` を持たず、循環参照にしない
final class TaskCapturingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  private let box: DataTaskBox

  init(box: DataTaskBox) {
    self.box = box
  }

  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    box.set(task)
  }

  /// リダイレクトには従わない。送信先の確認は最初のホストにしかしないため、API キーと発話を別のホストへ送らない
  /// （AC-06, AI-02）。3xx の応答はそのまま返り、呼び出し元で失敗として扱う
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
