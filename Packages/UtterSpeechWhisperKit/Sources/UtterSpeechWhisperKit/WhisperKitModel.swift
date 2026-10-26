import Foundation
import UtterSpeech

/// 読み込む WhisperKit のモデル（PERM-03）。
///
/// モデルの種類（tiny / base など）は WhisperKit がモデルの次元から判定するため、モデル名は持たない。
/// 仮置きのモデル名は `WhisperKitRecognizerConfiguration.provisionalModelName`（Apps が取得するモデルを選ぶのに使う）。
///
/// モデルは同梱しない。Apps が取得して `directory` に置き、`manifest` と照合できたものだけを読み込む。
/// トークナイザー（`tokenizer.json` など）も `directory` の直下に置き、同じマニフェストに含める
/// （`WhisperKitModelCheck`、ライセンス・依存関係.md 3.4 の案 a）。
public struct WhisperKitModel: Hashable, Sendable {
  /// モデルのディレクトリ。アプリだけが書き込める場所に置く
  public let directory: URL
  /// 照合に使うマニフェスト。モデルとは別の信頼できる経路で持つ（`ModelManifest`）
  public let manifest: ModelManifest

  public init(directory: URL, manifest: ModelManifest) {
    self.directory = directory
    self.manifest = manifest
  }
}
