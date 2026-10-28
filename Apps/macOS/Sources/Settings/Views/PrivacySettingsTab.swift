import SwiftUI
import UtterPersistence

/// 設定画面の「プライバシー」タブ（7章, AC-06, AC-10, CTX-03, #199）。
///
/// 送らないもの（利用状況・ウインドウ名・入力欄にすでにある文・URL）と、声を処理する場所を示し、
/// 異常終了で残った音声の保存期限を選ぶ。ウインドウ名・入力欄の文・URL を送る選択肢は設けない（CTX-03）。
/// 送信の同意は別の画面（メニューの「クラウド送信の同意…」）で変える。
struct PrivacySettingsTab: View {
  @Bindable var model: SettingsModel
  @Environment(\.openWindow) private var openWindow

  /// 保存期限の選択肢（時間）。保存値が選択肢にないときは、その値も並べる
  private static let standardRetentionChoices = [1, 6, 12, 24, 48, 72, 168]

  var body: some View {
    Form {
      Section("送信") {
        LabeledContent("利用状況の送信", value: "行いません")
        Text("利用状況・解析のための情報（テレメトリ）は送りません。")
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent("声の処理", value: voiceProcessingLabel)
        Text(voiceProcessingCaption)
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Text(Self.contextCaption)
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent("クラウドへの送信の同意") {
          Button("同意の画面を開く…") { openWindow(id: ConsentSettingsScene.windowID) }
        }
      } header: {
        Text("クラウドで整形するときに送るもの")
      }
      Section {
        Picker("保存期限", selection: $model.form.temporaryAudioRetentionHours) {
          ForEach(retentionChoices, id: \.self) { Text(Self.label(hours: $0)).tag($0) }
        }
      } header: {
        Text("異常終了で残った音声")
      } footer: {
        Text(Self.retentionCaption)
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  /// CTX-03: 送るもの・送らないもの
  static let contextCaption = [
    "送るのは、整形する文と、文体の区分・辞書の語だけです（送信に同意したときだけ）。",
    "ウインドウ名・入力欄にすでにある文・URL（サイトのホスト名を含む）は送りません。",
  ].joined()

  /// 7章, AC-10: 一時音声の保存期限
  static let retentionCaption = [
    "処理を終える前に utter が止まったときに残った音声は、この Mac にだけ保存し、次の起動時に復旧するか尋ねます。",
    "保存期限を過ぎた音声は起動時に削除します。変更は次の起動から使います。",
  ].joined()

  /// 声を処理する場所。クラウド音声認識（MVP 外、既定は無効）を選んでいるときは、そう示す
  private var voiceProcessingLabel: String {
    model.form.cloudSpeechRecognitionEnabled ? "クラウド音声認識（OpenAI）を選んでいます" : "この Mac の中だけ"
  }

  private var voiceProcessingCaption: String {
    if model.form.cloudSpeechRecognitionEnabled {
      return "同意・OpenAI API キー・予算がそろったときだけ、録音した音声を OpenAI へ送ります（「認識モデルと省電力」タブで変えられます）。"
    }
    return "録音した音声はこの Mac の中で認識し、Mac の外に送りません。"
  }

  private var retentionChoices: [Int] {
    let current = model.form.temporaryAudioRetentionHours
    let choices = Self.standardRetentionChoices
    return choices.contains(current) ? choices : (choices + [current]).sorted()
  }

  private static func label(hours: Int) -> String {
    hours.isMultiple(of: 24) ? "\(hours / 24)日（\(hours)時間）" : "\(hours)時間"
  }
}
