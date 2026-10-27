import Foundation
import Network
import Synchronization
import UtterAI

/// Network.framework による `ChatGPTLoopbackServer`（S3, #50）。
///
/// - `127.0.0.1` の空いているポートだけで待ち受ける（`localhost` や外部のインターフェースでは受けない）
/// - `/auth/callback` への最初の GET の URL だけをサインインへ渡し、ほかの要求には 404 を返す
/// - ブラウザに返すページには、受け取った値（認可コード・state）を載せない
/// - 受け取った URL・要求の中身はログに出さない
struct NetworkLoopbackServer: ChatGPTLoopbackServer {
  func start() async throws(ChatGPTSignInError) -> any ChatGPTLoopbackListener {
    let listener = try LoopbackCallbackListener.make()
    try await listener.start()
    return listener
  }
}

/// 1回のサインインのための待ち受け。`stop()` で終える
final class LoopbackCallbackListener: ChatGPTLoopbackListener, Sendable {
  /// 1つの要求で読む上限（要求行とヘッダー）
  private static let maxRequestBytes = 16 * 1024

  private typealias StartResult = Result<UInt16, ChatGPTSignInError>
  private typealias CallbackResult = Result<URL, ChatGPTSignInError>

  private struct State {
    var port: UInt16 = 0
    var startWaiter: CheckedContinuation<StartResult, Never>?
    var callbackWaiter: CheckedContinuation<CallbackResult, Never>?
    var outcome: CallbackResult?
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "utter.chatgpt-sign-in.loopback")
  private let state = Mutex(State())

  private init(listener: NWListener) {
    self.listener = listener
  }

  /// `127.0.0.1` の任意のポートで待ち受ける `NWListener` を作る（まだ始めない）
  static func make() throws(ChatGPTSignInError) -> LoopbackCallbackListener {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    parameters.acceptLocalOnly = true
    guard let listener = try? NWListener(using: parameters) else {
      throw .listenerUnavailable
    }
    return LoopbackCallbackListener(listener: listener)
  }

  var port: UInt16 {
    state.withLock { $0.port }
  }

  /// 待ち受けを始め、ポートが決まるまで待つ。ブラウザを開く前に呼ぶ（S3）
  func start() async throws(ChatGPTSignInError) {
    listener.stateUpdateHandler = { [weak self] update in
      self?.handle(update)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    let result: StartResult = await withCheckedContinuation { continuation in
      state.withLock { $0.startWaiter = continuation }
      listener.start(queue: queue)
    }
    _ = try result.get()
  }

  func callback() async throws(ChatGPTSignInError) -> URL {
    let result: CallbackResult = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { state -> CallbackResult? in
          guard let outcome = state.outcome else {
            state.callbackWaiter = continuation
            return nil
          }
          return outcome
        }
        if let ready {
          continuation.resume(returning: ready)
        }
      }
    } onCancel: {
      finish(.failure(.cancelled))
    }
    return try result.get()
  }

  func stop() {
    listener.cancel()
    finish(.failure(.cancelled))
    resolveStart(.failure(.listenerUnavailable))
  }

  // MARK: - 待ち受けの状態

  private func handle(_ update: NWListener.State) {
    switch update {
    case .ready:
      guard let port = listener.port?.rawValue else {
        resolveStart(.failure(.listenerUnavailable))
        return
      }
      state.withLock { $0.port = port }
      resolveStart(.success(port))
    case .failed, .cancelled, .waiting:
      resolveStart(.failure(.listenerUnavailable))
      finish(.failure(.listenerUnavailable))
    case .setup:
      break
    @unknown default:
      break
    }
  }

  private func resolveStart(_ result: StartResult) {
    let waiter = state.withLock { state in
      defer { state.startWaiter = nil }
      return state.startWaiter
    }
    waiter?.resume(returning: result)
  }

  /// 最初の結果だけを残し、待っている `callback()` に返す
  private func finish(_ result: CallbackResult) {
    let waiter = state.withLock { state -> CheckedContinuation<CallbackResult, Never>? in
      guard state.outcome == nil else { return nil }
      state.outcome = result
      defer { state.callbackWaiter = nil }
      return state.callbackWaiter
    }
    waiter?.resume(returning: result)
  }

  // MARK: - 要求

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  /// 要求行とヘッダーの終わりまで読む。上限を超えたら閉じる
  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
      [weak self] content, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var received = buffer
      if let content {
        received.append(content)
      }
      if let end = received.range(of: Data("\r\n\r\n".utf8)) {
        self.respond(on: connection, to: received[..<end.lowerBound])
      } else if error != nil || isComplete || received.count >= Self.maxRequestBytes {
        connection.cancel()
      } else {
        self.receive(on: connection, buffer: received)
      }
    }
  }

  /// `GET /auth/callback?…` だけを受け付け、最初の1回の URL をサインインへ渡す
  private func respond(on connection: NWConnection, to head: Data) {
    // 要求行（`GET /auth/callback?… HTTP/1.1`）だけを読む。CRLF は1つの Character
    let lineBreak: Character = "\r\n"
    let text = String(decoding: head, as: UTF8.self)
    let requestLine = text.split(separator: lineBreak, maxSplits: 1).first ?? ""
    let parts = requestLine.split(separator: " " as Character)
    var url: URL?
    if parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") {
      url = URL(string: "http://\(ChatGPTSignIn.callbackHost):\(port)\(parts[1])")
    }
    guard let url, url.path == ChatGPTSignIn.callbackPath else {
      send(status: "404 Not Found", body: "Not Found", on: connection)
      return
    }
    finish(.success(url))
    send(status: "200 OK", body: Self.completionPage, on: connection)
  }

  private func send(status: String, body: String, on connection: NWConnection) {
    let bodyData = Data(body.utf8)
    let header = [
      "HTTP/1.1 \(status)",
      "Content-Type: text/html; charset=utf-8",
      "Content-Length: \(bodyData.count)",
      "Cache-Control: no-store",
      "Referrer-Policy: no-referrer",
      "Connection: close",
      "",
      "",
    ].joined(separator: "\r\n")
    connection.send(
      content: Data(header.utf8) + bodyData,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  /// サインインの結果を受け取ったあとにブラウザへ返すページ。受け取った値は載せない
  private static let completionPage = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8"><title>utter</title></head>
    <body><p>ChatGPT のサインインの結果を utter に渡しました。このタブを閉じて utter に戻ってください。</p></body></html>
    """
}
