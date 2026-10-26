import Foundation
import UtterSpeech

/// macOS で使う STT エンジンの選び方（4章, 11章, #57）。
///
/// 既定のエンジンは Phase 0 の判定（#48 SpeechAnalyzer / #49 WhisperKit）待ちのため持たない（`nil`）。
/// Config/Local.xcconfig の `UTTER_MAC_STT_ENGINE`（Info.plist の `UtterSTTEngine`）、または Debug ビルドの
/// 起動引数 `-UtterDebugSTTEngine` で明示したときだけ使う。知らない値・空の値は未選択に倒す。
enum STTEngineSetting {
  /// ビルド設定 `UTTER_MAC_STT_ENGINE` を埋め込む Info.plist のキー（Apps/macOS/Info.plist）
  static let infoPlistKey = "UtterSTTEngine"

  /// ビルド設定と起動引数から使うエンジンを選ぶ。どちらも使えない値なら `nil`（音声認識が未設定）。
  ///
  /// 受け付けるのは STT Worker に登録したエンジンだけ（`STTWorkerEngines`）。WhisperKit は未登録のため受け付けない。
  /// - Parameters:
  ///   - buildSetting: Info.plist の `UtterSTTEngine`（Config/Local.xcconfig の
  ///     `UTTER_MAC_STT_ENGINE`）
  ///   - launchArgument: Debug ビルドの起動引数 `-UtterDebugSTTEngine` の値。Release では渡さない。
  ///     ビルド設定より優先し、使えない値ならビルド設定に従う
  ///   - allowsStub: 開発用の `stub`（Worker の往復の確認用）を受け付けるか。Debug ビルドだけ `true` にする
  static func resolve(
    buildSetting: String?, launchArgument: String?, allowsStub: Bool
  ) -> STTEngineKind? {
    if let engine = acceptedEngine(from: launchArgument, allowsStub: allowsStub) {
      return engine
    }
    return acceptedEngine(from: buildSetting, allowsStub: allowsStub)
  }

  /// 設定値から読む。前後の空白は無視し、知らない値・受け付けないエンジンは `nil`
  private static func acceptedEngine(from value: String?, allowsStub: Bool) -> STTEngineKind? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      let engine = STTEngineKind(rawValue: trimmed)
    else { return nil }
    switch engine {
    case .speechAnalyzer: return engine
    case .stub: return allowsStub ? engine : nil
    // アダプターは先行実装のみで、STT Worker に登録していない（#49）
    case .whisperKit: return nil
    }
  }

  /// 利用者の操作で取得するモデル。OS が管理するモデルを使わないエンジン・未選択なら `nil`（PERM-03）
  static func makeModelAssets(for engine: STTEngineKind?) -> (any SpeechModelAssets)? {
    switch engine {
    case .speechAnalyzer: SpeechAnalyzerAssets()
    case .whisperKit, .stub, nil: nil
    }
  }
}
