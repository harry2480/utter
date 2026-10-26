import UtterCore

/// テスト用の `AIProvider`（AI-06）。ネットワークに出ない。
///
/// 固定応答・空応答・各エラーと、応答までの遅延を注入できる。
/// 呼び出しごとに受け取った入力を記録する。
public actor StubAIProvider: AIProvider {
  /// 呼び出しに対する振る舞い。
  public enum Behavior: Hashable, Sendable {
    /// 指定したテキストを返す。空文字列で空応答になる
    case respond(String, usage: TokenUsage? = nil)
    /// 指定したエラーを投げる
    case fail(AIProviderError)
    /// 入力テキストをそのまま返す
    case echo
  }

  public nonisolated let destination: CloudAIProviderKind
  /// Claude の送信先として振る舞うときだけ、トークン課金の送信先として申告する
  public nonisolated var isTokenBilled: Bool { destination == .claude }
  public private(set) var behavior: Behavior
  /// 振る舞いを返すまでの遅延
  public private(set) var delay: Duration
  /// 受け取った入力（呼び出し順）
  public private(set) var receivedRequests: [RefinementRequest] = []

  public var callCount: Int { receivedRequests.count }

  public init(
    behavior: Behavior = .respond(""), delay: Duration = .zero,
    destination: CloudAIProviderKind = .claude
  ) {
    self.destination = destination
    self.behavior = behavior
    self.delay = delay
  }

  /// 振る舞いを変える。`delay` を省略すると、現在の遅延を保つ。
  public func setBehavior(_ behavior: Behavior, delay: Duration? = nil) {
    self.behavior = behavior
    if let delay {
      self.delay = delay
    }
  }

  public func refine(_ request: RefinementRequest) async throws(AIProviderError)
    -> RefinementResponse
  {
    receivedRequests.append(request)
    // 遅延中に振る舞いが変わっても、呼び出した時点の設定で応答する。
    let behavior = self.behavior
    let delay = self.delay
    if delay > .zero {
      do {
        try await Task.sleep(for: delay)
      } catch {
        throw .cancelled
      }
    }
    if Task.isCancelled {
      throw .cancelled
    }
    switch behavior {
    case .respond(let text, let usage):
      return RefinementResponse(text: text, usage: usage)
    case .fail(let error):
      throw error
    case .echo:
      return RefinementResponse(text: request.text)
    }
  }
}

// テストの失敗表示やログに応答の本文を出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension StubAIProvider.Behavior: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .respond(let text, let usage):
      "respond(length: \(text.count), usage: \(usage.map { "\($0)" } ?? "nil"))"
    case .fail(let error): "fail(\(error))"
    case .echo: "echo"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
