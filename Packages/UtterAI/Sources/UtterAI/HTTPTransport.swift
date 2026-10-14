import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// HTTP の送信部。本番は `URLSession`、テストは Stub を注入して実ネットワークに出ない。
public protocol HTTPTransport: Sendable {
  /// リクエストを送り、本文と HTTP 応答を返す。
  ///
  /// 呼び出し元の Task がキャンセルされたら通信を止め、`CancellationError` か
  /// `URLError(.cancelled)` を投げる。
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, response)
  }
}
