import Foundation
import UtterSpeech

/// 初回セットアップの認識モデルの手順に出す、取得するモデルの説明（PERM-03）。
///
/// エンジンごとの中身はここで作り、手順の画面と進み方（`FirstRunSetupModel`）はエンジンによらない。
/// 別のエンジン（#48 / #49 の判定の結果）に替えるときは、ここと `STTEngineSetting.makeModelAssets` を書き換える。
struct SpeechModelDescription: Hashable, Sendable {
  /// モデル名
  let name: String
  /// 取得元
  let source: String
  /// サイズ
  let size: String
  /// 取得後の完全性の確かめ方
  let integrity: String

  /// 使うエンジンのモデルの説明。モデルを取得しないエンジン・未選択なら `nil`
  static func of(
    _ engine: STTEngineKind?, locale: Locale = SpeechAnalyzerRecognizer.defaultLocale
  ) -> SpeechModelDescription? {
    switch engine {
    case .speechAnalyzer:
      // モデルは OS が管理するアセットで、取得・保存・完全性の確認を macOS が行う（ModelIntegrityVerifier の対象外）。
      // サイズは取得の前に問い合わせる API がないため、推測の値を出さない
      SpeechModelDescription(
        name: "Apple の音声認識（SpeechTranscriber）の言語モデル（\(locale.identifier(.bcp47))）",
        source: "Apple のサーバー（macOS が取得し、この Mac に保存します）",
        size: "macOS が管理するため、取得の前には表示できません",
        integrity: "取得・保存とその確認は macOS が行います（utter は独自の照合をしません）")
    // WhisperKit は配布しない（#49 の判定待ち）。stub はモデルを使わない
    case .whisperKit, .stub, nil:
      nil
    }
  }
}
