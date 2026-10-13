/// 文章の送信先となるクラウド AI プロバイダーの種類（AI-01）。
///
/// `AIProvider` の実装ではなく、同意や設定で送信先を指す識別子。
///
/// 同意は送信先ごとに取得するため、プロバイダーを区別する（AI-04, 7章）。
public enum CloudAIProviderKind: Hashable, Sendable, CaseIterable {
  /// Claude API
  case claude
  /// Sign in with ChatGPT
  case chatGPT
}
