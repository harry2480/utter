import SwiftUI
import UtterSpeech
import UtteriOSKit

/// 音声認識の設定画面。使っているエンジンと、モデルの取得状態・取得の操作を出す（PERM-03）。
///
/// モデルは「取得」ボタンを押したときだけ取得する。画面を開いただけでは状態を確かめるだけで、ネットワークを使わない。
struct SpeechSettingsView: View {
  let engine: SpeechEngineSelection
  let model: SpeechModelSettingsModel?

  var body: some View {
    List {
      Section {
        LabeledContent("エンジン", value: engine.label)
        if engine == .unconfigured {
          Text("iOS の音声認識は検証中のため、既定では使いません。録音はできますが、文字にはしません。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("音声認識")
      }
      if let model {
        SpeechModelSection(model: model)
      }
    }
    .navigationTitle("音声認識の設定")
  }
}

/// 音声認識モデルの取得状態と「取得」ボタン（PERM-03）
private struct SpeechModelSection: View {
  let model: SpeechModelSettingsModel

  var body: some View {
    Section {
      LabeledContent("状態", value: model.statusLabel)
      if model.canInstall {
        Button("モデルを取得") { Task { await model.install() } }
      }
      if model.isInstalling {
        ProgressView()
      }
      if model.installFailed {
        Text("モデルを取得できませんでした。通信状態と空き容量を確かめて、もう一度お試しください。")
          .foregroundStyle(.red)
      }
    } header: {
      Text("音声認識モデル")
    } footer: {
      Text(
        "モデルは Apple のサーバーから iOS が取得し、端末内に保存します。サイズと保存・削除は iOS が管理するため、取得の前には表示できません。音声は端末の外に送りません。"
      )
    }
    .task {
      // OS が取得中の間は、終わった・失敗したことが分かるよう数秒おきに確かめ直す（ネットワークは使わない）。
      // 画面を閉じると止まる
      await model.refresh()
      while model.availability == .downloading || model.isInstalling {
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { return }
        await model.refresh()
      }
    }
  }
}

extension SpeechEngineSelection {
  fileprivate var label: String {
    switch self {
    case .unconfigured: "未設定"
    case .speechAnalyzer: "SpeechAnalyzer（端末内）"
    }
  }
}

extension SpeechModelSettingsModel {
  fileprivate var statusLabel: String {
    if isInstalling { return "取得中" }
    switch availability {
    case nil: return "確認中"
    case .unsupported: return "この端末・言語では使えません"
    case .notInstalled: return "未取得"
    case .downloading: return "取得中"
    case .installed: return "取得済み"
    }
  }
}
