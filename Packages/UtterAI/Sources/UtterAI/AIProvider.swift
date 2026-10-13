/// AI 整形プロバイダーの共通インターフェース（AI-01, AI-06）。
///
/// Claude / ChatGPT / Local Basic の各実装と `StubAIProvider` がこれに準拠し、呼び出し側から差し替えられる。
/// 実装は `request.text` を整形対象のデータとして扱い、指示として実行しない（TXT-04）。
public protocol AIProvider: Sendable {
  /// STT テキストを整形して返す。応答の検証（空応答・保護対象など）は呼び出し側が行う。
  ///
  /// 呼び出し元の Task がキャンセルされた場合は `AIProviderError.cancelled` を投げる。
  func refine(_ request: RefinementRequest) async throws(AIProviderError) -> RefinementResponse
}
