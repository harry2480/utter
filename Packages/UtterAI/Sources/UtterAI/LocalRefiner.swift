/// ネットワークを使わないローカル整形（Raw / Local Basic, AI-03）。
///
/// クラウド整形に失敗したときの退避先として使うため、失敗しない（4.1節）。
public protocol LocalRefiner: Sendable {
  func refine(_ request: RefinementRequest) -> String
}

/// STT テキストをそのまま返すローカル整形（Raw）。
public struct RawRefiner: LocalRefiner {
  public init() {}

  public func refine(_ request: RefinementRequest) -> String {
    request.text
  }
}
