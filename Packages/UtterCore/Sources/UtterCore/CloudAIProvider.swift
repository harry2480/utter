/// 文章を送信するクラウド AI プロバイダー（AI-01）。
///
/// 同意は送信先ごとに取得するため、プロバイダーを区別する（AI-04, 7章）。
public enum CloudAIProvider: Hashable, Sendable, CaseIterable {
  /// Claude API
  case claude
  /// Sign in with ChatGPT
  case chatGPT
}
