import SwiftUI
import UtterSpeech

/// 設定画面の「音声認識」タブ。使っているエンジンと、モデルの取得状態・取得の操作を出す（4章, PERM-03）。
///
/// エンジンはビルド設定（Config/Local.xcconfig の `UTTER_MAC_STT_ENGINE`）で選び、この画面では変えない。
/// モデルは「モデルを取得」ボタンを押したときだけ取得する。タブを開いただけでは状態を確かめるだけで、ネットワークを使わない。
struct SpeechRecognitionSettingsTab: View {
  /// 使っているエンジン。未選択なら `nil`（`AppComposition.selectedEngine()`）
  let engine: STTEngineKind?
  /// モデルの取得状態。OS が管理するモデルを使うエンジンを選んでいるときだけ（`STTEngineSetting.makeModelAssets`）
  let model: SpeechModelSettingsModel?

  var body: some View {
    Form {
      Section("音声認識") {
        LabeledContent("エンジン", value: Self.label(of: engine))
        if engine == nil {
          VStack(alignment: .leading, spacing: 4) {
            Text("未設定です。既定のエンジンは検証中のため決めていません（音声入力は使えません）。")
            Text("Config/Local.xcconfig の UTTER_MAC_STT_ENGINE で選び、ビルドし直してください。")
            Text("例: UTTER_MAC_STT_ENGINE = speechAnalyzer")
          }
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let model {
        SpeechModelSection(model: model)
      }
    }
    .formStyle(.grouped)
  }

  private static func label(of engine: STTEngineKind?) -> String {
    switch engine {
    case nil: "未設定"
    case .speechAnalyzer: "SpeechAnalyzer（Mac の中で認識）"
    case .whisperKit: "WhisperKit"
    case .stub: "固定の結果（開発用）"
    }
  }
}

/// 音声認識モデルの取得状態と「モデルを取得」ボタン（PERM-03）
private struct SpeechModelSection: View {
  let model: SpeechModelSettingsModel

  var body: some View {
    Section {
      LabeledContent("状態", value: model.statusLabel)
      if model.canInstall {
        Button("モデルを取得") { Task { await model.install() } }
      }
      if model.isInstalling {
        ProgressView().controlSize(.small)
      }
      if model.installFailed {
        Text("モデルを取得できませんでした。通信状態と空き容量を確かめて、もう一度お試しください。")
          .foregroundStyle(.red)
      }
    } header: {
      Text("音声認識モデル")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("モデルは Apple のサーバーから macOS が取得し、この Mac に保存します。取得にはネットワークを使います。")
        Text("サイズと保存・削除は macOS が管理するため、取得の前には表示できません。")
        Text("認識は Mac の中で行い、音声は Mac の外に送りません。")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .task {
      // OS が取得中の間は、終わった・失敗したことが分かるよう数秒おきに確かめ直す（ネットワークは使わない）。
      // タブを離れる・設定画面を閉じると止まる
      await model.refresh()
      while model.availability == .downloading || model.isInstalling {
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { return }
        await model.refresh()
      }
    }
  }
}

extension SpeechModelSettingsModel {
  fileprivate var statusLabel: String {
    if isInstalling { return "取得中" }
    switch availability {
    case nil: return "確認中"
    case .unsupported: return "この Mac・言語では使えません"
    case .notInstalled: return "未取得"
    case .downloading: return "取得中"
    case .installed: return "取得済み"
    }
  }
}
