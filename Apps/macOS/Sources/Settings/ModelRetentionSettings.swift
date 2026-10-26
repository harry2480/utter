import UtterPersistence
import UtterSpeech

extension ModelRetentionMode {
  /// 設定（版2設定）の保持モードから（6章）
  init(_ setting: ModelRetentionModeSetting) {
    switch setting {
    case .powerSaving: self = .powerSaving
    case .balanced: self = .balanced
    case .performance: self = .performance
    }
  }
}

extension ModelRetentionPolicy {
  /// 保存された設定の保持モードと高速モードの許可から作る（6章）。
  ///
  /// バランスモードの保持時間は設定に持たないため、暫定の既定値（`defaultBalancedRetention`）を使う。
  /// 既定値は正の値で検証を通るため、`nil` にはならない
  static func fromSettings(_ settings: AppSettings) -> ModelRetentionPolicy? {
    try? ModelRetentionPolicy(
      mode: ModelRetentionMode(settings.modelRetentionMode),
      performanceRetentionAllowed: settings.performanceRetentionAllowed)
  }
}
