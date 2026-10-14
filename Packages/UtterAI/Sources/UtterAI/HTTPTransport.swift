import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// HTTP の送信部。本番は `URLSessionTransport`、テストは Stub を注入して実ネットワークに出ない。
///
/// `request` のヘッダーには API キーが、本文には発話が入る。実装は `request` をログに出さない。
public protocol HTTPTransport: Sendable {
  /// リクエストを送り、本文と HTTP 応答を返す。
  ///
  /// 呼び出し元の Task がキャンセルされたら通信を止め、`CancellationError` か
  /// `URLError(.cancelled)` を投げる。
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` による送信部。既定では Cookie・キャッシュをディスクに残さない ephemeral の構成を使う。
public struct URLSessionTransport: HTTPTransport {
  public let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, response)
  }
}
