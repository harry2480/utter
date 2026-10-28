import SwiftUI
import UtterPersistence
import UtterSpeech

/// 設定画面の「認識モデルと省電力」タブ。ローカルのエンジンとクラウド STT の選択、使っているローカルのエンジン、
/// モデルの取得状態・取得と削除の操作、モデルの保持モード（6章）、OpenAI API キーを出す（4章, PERM-03, #188, #199）。
///
/// ローカルのエンジンはビルド設定（Config/Local.xcconfig の `UTTER_MAC_STT_ENGINE`）で選び、この画面では変えない。
/// クラウド STT（MVP 外）は既定で無効で、ここで選んで「保存」すると次のセッションから使う。選んでも、同意の画面での
/// 音声の送信への同意・OpenAI API キー・月次予算と単価表がそろわなければ送らない（AC-06, AI-04）。
/// モデルは「モデルを取得」ボタンを押したときだけ取得する。タブを開いただけでは状態を確かめるだけで、ネットワークを使わない。
/// 削除は公開 API ではアプリからすぐにはできないため、予約を解除して macOS の削除に任せ、そのことを画面に書く。
struct SpeechRecognitionSettingsTab: View {
  /// 設定画面の入力。クラウド STT を使うかを持つ
  @Bindable var settings: SettingsModel
  /// 使っているエンジン。未選択なら `nil`（`AppComposition.selectedEngine()`）
  let engine: STTEngineKind?
  /// モデルの取得状態。OS が管理するモデルを使うエンジンを選んでいるときだけ（`STTEngineSetting.makeModelAssets`）
  let model: SpeechModelSettingsModel?
  /// OpenAI API キー（クラウド STT）。この欄で Keychain にすぐ保存し、下の「保存」とは別に扱う（AC-12）
  let openAIAPIKey: APIKeySettingsModel

  var body: some View {
    Form {
      Section {
        Picker("使う音声認識", selection: $settings.form.cloudSpeechRecognitionEnabled) {
          Text("ローカルのエンジン（Mac の中で認識）").tag(false)
          Text("クラウド音声認識（OpenAI）").tag(true)
        }
      } header: {
        Text("認識の場所")
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text("クラウド音声認識は、録音した音声を OpenAI へ送って認識します（MVP 外）。")
          Text("送るには、同意の画面の「クラウド音声認識」への同意（整形とは別）と、このタブの下の OpenAI API キーが要ります。")
          Text("「整形の実行先と費用」タブの月次予算と、単価表のモデル \(CloudSpeechRecognitionPipeline.model) の単価も要ります。")
          Text("そろわなければ送らず、HUD に理由を出します。変更は次の録音から使います。")
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("ローカルの音声認識") {
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
      Section("省電力（音声認識モデルの保持）") {
        Picker("保持モード", selection: $settings.form.modelRetentionMode) {
          ForEach(ModelRetentionModeSetting.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("高速モードでのモデル保持を許可する", isOn: $settings.form.performanceRetentionAllowed)
        if settings.form.notices.contains(.performanceRetentionNotAllowed) {
          Label(SettingsNotice.performanceRetentionNotAllowed.message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      APIKeySection(model: openAIAPIKey, labels: .openAI)
        .onAppear { openAIAPIKey.refresh() }
        .onDisappear { openAIAPIKey.clearInput() }
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

/// 音声認識モデルの取得状態と「モデルを取得」「モデルを削除」ボタン（PERM-03, #199）
private struct SpeechModelSection: View {
  let model: SpeechModelSettingsModel
  @State private var isConfirmingRelease = false

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
      if model.canRelease {
        Button("モデルを削除…", role: .destructive) { isConfirmingRelease = true }
      }
      if model.isReleasing {
        ProgressView().controlSize(.small)
      }
      switch model.releaseResult {
      case .released:
        Text("utter の予約を解除しました。ほかのアプリが使っていなければ、macOS が後で削除します。削除されるまでは音声認識に使えます。")
          .font(.caption).foregroundStyle(.secondary)
      case .notReserved:
        Text("utter はこのモデルを予約していないため、utter からは削除できません。モデルは macOS が管理しています。")
          .font(.caption).foregroundStyle(.secondary)
      case nil:
        EmptyView()
      }
    } header: {
      Text("音声認識モデル")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("モデルは Apple のサーバーから macOS が取得し、この Mac に保存します。取得にはネットワークを使います。")
        Text("サイズと保存・削除は macOS が管理するため、取得の前には表示できません。")
        Text("macOS の公開 API では、アプリからモデルをすぐに削除できません。「モデルを削除」は utter の予約を解除し、削除を macOS に任せます。")
        Text("認識は Mac の中で行い、音声は Mac の外に送りません。")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .confirmationDialog("音声認識モデルを削除しますか？", isPresented: $isConfirmingRelease) {
      Button("削除", role: .destructive) { Task { await model.releaseReservation() } }
    } message: {
      Text("utter の予約を解除します。ほかのアプリが使っていなければ macOS が後で削除し、削除後に音声入力するにはモデルを取得し直す必要があります。")
    }
    // OS が取得中の間は、終わった・失敗したことが分かるよう数秒おきに確かめ直す（ネットワークは使わない）。
    // 取得のボタンを押して取得中になったときにも始め直す。タブを離れる・設定画面を閉じると止まる
    .task(id: model.needsStatusPolling) {
      await model.refresh()
      while model.needsStatusPolling {
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { return }
        await model.refresh()
      }
    }
  }
}

extension SpeechModelSettingsModel {
  /// 取得の終わりを待って状態を確かめ直すか（取得の要求中か、OS が取得中）
  fileprivate var needsStatusPolling: Bool {
    availability == .downloading || isInstalling
  }

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
