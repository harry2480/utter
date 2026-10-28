import AppKit
import SwiftUI
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 設定画面（AC-05, AC-12, AI-04, AI-05, AI-07, CTX-01, CTX-02, CTX-03, PERM-03, REC-01, REC-02, REC-05,
/// REC-06, 2.2節, 4章, 6章, 7章）。
///
/// 録音とショートカット・文体と辞書・整形の実行先と費用・アプリ別の設定・プライバシー・認識モデルと省電力の6つのタブに分ける。
/// 検証・保存・表示値は `SettingsModel` / `SettingsForm` / `CloudCostBridge` が持ち、ここは並べるだけにする。
/// 入力はまとめて「保存」で検証・保存する（数値・通貨・サイトなどの入力途中の値を保存しない）。
/// API キー（AC-12）とサインイン（#50）は、それぞれの欄で Keychain にすぐ保存し、下の「保存」とは別に扱う。
struct SettingsView: View {
  @Bindable var model: SettingsModel
  /// 「整形の実行先と費用」タブの Claude API キーの状態。キーは Keychain に即時に保存し、下の「保存」とは別に扱う（AC-12）
  let apiKeyModel: APIKeySettingsModel
  /// OpenAI API キーの状態。「認識モデルと省電力」タブ（クラウド STT, #188）と、「整形の実行先と費用」タブで
  /// OpenAI API キー方式（#58）を選んだときに出す。同じキーを使う
  let openAIAPIKeyModel: APIKeySettingsModel
  /// 「整形の実行先と費用」タブの Sign in with ChatGPT（#50）の状態。サインインは Keychain に即時に保存し、下の「保存」とは別に扱う
  let chatGPTAccount: ChatGPTAccountSettingsModel
  /// 「認識モデルと省電力」タブに出すローカルのエンジン。ビルド設定で選び、この画面では変えない（未選択なら `nil`）。
  /// ローカルのエンジンとクラウド STT のどちらを使うかは、このタブで選んで「保存」する（#188）
  let sttEngine: STTEngineKind?
  /// 「認識モデルと省電力」タブのモデルの取得状態。モデルの取得・削除はタブのボタンからだけ行う（PERM-03）
  let speechModel: SpeechModelSettingsModel?
  @State private var selection: SettingsTab = .recording

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $selection) {
        RecordingSettingsTab(model: model)
          .tabItem { Label("録音とショートカット", systemImage: "mic") }
          .tag(SettingsTab.recording)
        StyleAndDictionarySettingsTab(model: model)
          .tabItem { Label("文体と辞書", systemImage: "character.book.closed") }
          .tag(SettingsTab.styleAndDictionary)
        RefinementSettingsTab(
          model: model, chatGPTAccount: chatGPTAccount, apiKey: apiKeyModel,
          openAIAPIKey: openAIAPIKeyModel
        )
        .tabItem { Label("整形の実行先と費用", systemImage: "text.badge.checkmark") }
        .tag(SettingsTab.refinement)
        AppSpecificSettingsTab(model: model)
          .tabItem { Label("アプリ別の設定", systemImage: "app.badge") }
          .tag(SettingsTab.apps)
        PrivacySettingsTab(model: model)
          .tabItem { Label("プライバシー", systemImage: "hand.raised") }
          .tag(SettingsTab.privacy)
        speechRecognitionTab
          .tabItem { Label("認識モデルと省電力", systemImage: "waveform") }
          .tag(SettingsTab.speechRecognition)
      }
      Divider()
      SettingsFooter(model: model)
        .padding()
    }
    .frame(minWidth: 640, minHeight: 520)
    .onAppear {
      model.reload()
      // メニューで変えた入力モード・文体・整形の実行先を、開いたままの画面にも反映する（#197）
      model.followStoreChanges()
      Task { await model.refreshCost() }
    }
  }

  private var speechRecognitionTab: some View {
    SpeechRecognitionSettingsTab(
      settings: model, engine: sttEngine, model: speechModel, openAIAPIKey: openAIAPIKeyModel)
  }
}

/// 設定画面のタブ（設計の6タブ）
private enum SettingsTab: Hashable {
  case recording
  case styleAndDictionary
  case refinement
  case apps
  case privacy
  case speechRecognition
}

private struct SettingsFooter: View {
  let model: SettingsModel

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        if model.saveFailed {
          Text("設定を保存できませんでした。").foregroundStyle(.red)
        } else if !model.issues.isEmpty {
          Text("入力に問題があるため保存していません（\(model.issues.count) 件）。各タブの赤字を確認してください。")
            .foregroundStyle(.red)
        }
      }
      .font(.callout)
      Spacer()
      Button("元に戻す") { model.revert() }
      Button("保存") {
        if model.save() {
          Task { await model.refreshCost() }
        }
      }
      .keyboardShortcut(.defaultAction)
    }
  }
}

/// 入力欄の下に出す問題の文言
private struct IssueText: View {
  let issues: [SettingsIssue]

  var body: some View {
    ForEach(issues, id: \.self) { issue in
      Text(issue.message).font(.caption).foregroundStyle(.red)
    }
  }
}

private struct NoticeText: View {
  let notice: SettingsNotice

  var body: some View {
    Label(notice.message, systemImage: "info.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

// MARK: - 録音とショートカット

private struct RecordingSettingsTab: View {
  @Bindable var model: SettingsModel

  /// Edit Mode のショートカットの説明（AC-14, AC-06）
  static let editModeCaption = [
    "録音とは別のキーを割り当てます。未割り当ての間は Edit Mode を使いません。",
    "押すと選択テキストを読み、指示を録音します。もう一度押すと録音を止め、選択テキストと指示を Claude へ送って編集案を表示します。",
    "送るには、クラウド送信の同意の画面で「選択テキストの編集」への同意と、Claude API キー・月次予算・単価表が要ります。",
  ].joined()

  /// Realtime Direct の説明（2.2節, AC-15）。対応アプリは許可リスト（`RealtimeDirectAllowlist`）から出す
  static var realtimeDirectCaption: String {
    let apps = RealtimeDirectAllowlist.launchConfigured().apps.sorted()
    var supported = "対応を確かめたアプリはまだないため、今はどのアプリでも使えません。"
    if !apps.isEmpty {
      supported = "対応アプリ: \(apps.joined(separator: ", "))。"
    }
    return [
      "実験機能です。確定した認識結果を、整形せずに入力欄へ順に入力します。",
      supported,
      "対応していないアプリ・パスワード欄など・クラウド音声認識では自動で使わず、停止後にまとめて入力します。",
      "途中で入力欄が変わったら入力をやめ、全体をコピーできるようにします。",
    ].joined()
  }

  /// Esc でのキャンセルの説明（REC-01）。Esc の捕捉は #51 の判定まで既定で使わない（`ShortcutCoordinator.capabilities()`）
  static var escapeCaption: String {
    var lines = [
      "録音中・処理中に Esc を押すと、入力をキャンセルします。",
      "Esc はセッションの間だけ受け取り、ほかのアプリの Esc は妨げません。",
    ]
    if !ShortcutCoordinator.capabilities().supportsEscapeCapture {
      lines.append("Esc でのキャンセルは検証中のため、今はオンにしても使えません（メニューの「キャンセル」は使えます）。")
    }
    return lines.joined()
  }

  var body: some View {
    Form {
      Section("録音") {
        RecordingShortcutRow(model: model)
        Picker("録音の操作", selection: $model.form.recordingTrigger) {
          ForEach(ShortcutTriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        LabeledContent("最大録音時間") {
          HStack {
            TextField("分", text: $model.form.maxRecordingMinutes)
              .frame(width: 80)
              .multilineTextAlignment(.trailing)
            Text("分")
          }
        }
        IssueText(issues: model.issues(in: [.maxRecordingDuration]))
        Text("1〜60 分。上限に達したら録音を止め、それまでの音声を入力します。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("録音中・処理中の操作") {
        Picker("認識・整形の途中でもう一度押したとき", selection: $model.form.pressWhileProcessing) {
          ForEach(ShortcutPressWhileProcessing.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Text("録音中に押したときは、操作の方式に従って録音を止めます。入力欄への入力が始まった後は取り消しません。")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Esc でキャンセルする", isOn: $model.form.escapeCancelEnabled)
        Text(Self.escapeCaption)
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Edit Mode（選択テキストを音声の指示で編集）") {
        RecordingShortcutRow(
          model: model, title: "Edit Mode のショートカット", shortcut: \.editModeShortcut,
          issueKinds: [.editModeShortcut, .editModeShortcutSameAsRecording],
          caption: Self.editModeCaption)
      }
      Section("入力") {
        Picker("入力モード", selection: $model.form.inputMode) {
          ForEach(InputMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if model.form.inputMode == .realtimeDirect {
          Text(Self.realtimeDirectCaption)
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - 整形の実行先と費用

private struct RefinementSettingsTab: View {
  @Bindable var model: SettingsModel
  let chatGPTAccount: ChatGPTAccountSettingsModel
  /// Claude API キー。この欄で Keychain にすぐ保存し、下の「保存」とは別に扱う（AC-12）
  let apiKey: APIKeySettingsModel
  /// OpenAI API キー（クラウド STT と共用）。OpenAI API キー方式を選んだときだけ出す。この欄で Keychain にすぐ保存する
  let openAIAPIKey: APIKeySettingsModel

  /// 失敗時の切り替えの説明（AI-04, AC-06）
  static let fallbackCaption = [
    "Claude か ChatGPT（Sign in with ChatGPT）の整形が失敗したら、もう一方で1回だけ整形し直します。既定はオフです。",
    "切り替え先へは、その送信先への送信に同意していて、API キーと予算（Claude）またはサインインとモデル（ChatGPT）が",
    "そろっているときだけ送ります。そろわなければ送らず、この Mac で整形します。",
    "OpenAI API キー方式へは切り替えず、OpenAI API キー方式を選んでいるときは切り替えません。",
  ].joined()

  /// OpenAI API キー方式の説明（AI-01, AI-04, AI-05, AC-06, CTX-03）
  static let openAIAPIKeyCaption = [
    "OpenAI API キー方式は、あなたの OpenAI API キーで ChatGPT（OpenAI）へ送って整形します。API の利用料がかかります。",
    "送るのは整形する本文・スタイル区分・辞書語だけです。",
    "送信の同意（Sign in with ChatGPT と同じ「ChatGPT」への同意）・下の OpenAI API キー・整形用モデル名・",
    "月次予算と、単価表のそのモデルの単価がそろうまで送らず、この Mac で整形します。",
    "失敗したときは Local Basic で整形し、Sign in with ChatGPT や Claude へは切り替えません。",
  ].joined()

  var body: some View {
    Form {
      Section {
        Picker("処理系", selection: $model.form.provider) {
          ForEach(RefinementProviderChoice.allCases) { choice in
            Text(choice.label).tag(choice)
          }
        }
        .pickerStyle(.radioGroup)
        Text(
          "ChatGPT は、ChatGPT プランを使う Sign in with ChatGPT と、OpenAI API キーを使う OpenAI API キー方式を別々に選びます。"
        )
        .font(.caption).foregroundStyle(.secondary)
        switch model.form.provider {
        case .claude:
          Text("Claude へは、送信の同意がない間は送信しません。API キーはこのタブの下で、同意は別の画面で設定します。")
            .font(.caption).foregroundStyle(.secondary)
        case .chatGPTSignIn:
          Text("ChatGPT へは、送信の同意とサインインがそろうまで送信しません。同意は別の画面で設定します。")
            .font(.caption).foregroundStyle(.secondary)
        case .openAIAPIKey:
          Text("ChatGPT（OpenAI）へは、送信の同意・API キー・モデル名・予算がそろうまで送信しません。同意は別の画面で設定します。")
            .font(.caption).foregroundStyle(.secondary)
        case .localBasic:
          EmptyView()
        }
      } header: {
        Text("処理系")
      }
      if model.form.provider == .chatGPTSignIn {
        ChatGPTAccountSection(
          account: chatGPTAccount, modelName: $model.form.chatGPTRefinementModel)
        if model.form.notices.contains(.chatGPTModelNotSelected) {
          Section {
            NoticeText(notice: .chatGPTModelNotSelected)
          }
        }
      }
      if model.form.provider == .openAIAPIKey {
        Section("ChatGPT（OpenAI API キー方式）") {
          TextField("OpenAI の整形用モデル名", text: $model.form.openAIRefinementModel)
          if model.form.notices.contains(.openAIModelNotEntered) {
            NoticeText(notice: .openAIModelNotEntered)
          }
          Text(Self.openAIAPIKeyCaption)
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Claude") {
        TextField("Claude の整形用モデル名", text: $model.form.refinementModel)
        IssueText(issues: model.issues(in: [.refinementModelEmpty]))
        Text("既定は \(AppSettings.defaultRefinementModel)。モデルの廃止・改名に合わせて変更できます。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("失敗したとき") {
        Toggle("別のクラウドへ自動で切り替える", isOn: $model.form.cloudRefinementFallbackEnabled)
          // OpenAI API キー方式を選んでいる間は切り替えないため、操作できなくする（保存値は変えない）
          .disabled(model.form.provider == .openAIAPIKey)
        Text(Self.fallbackCaption)
          .font(.caption).foregroundStyle(.secondary)
      }
      CostSections(model: model)
      APIKeySection(model: apiKey, labels: .claude)
        .onAppear { apiKey.refresh() }
        .onDisappear { apiKey.clearInput() }
      if model.form.provider == .openAIAPIKey {
        APIKeySection(model: openAIAPIKey, labels: .openAI)
          .onAppear { openAIAPIKey.refresh() }
          .onDisappear { openAIAPIKey.clearInput() }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - 費用

/// 今月の推定費用・月次予算・単価表（AI-04, AI-05）。「整形の実行先と費用」タブに並べる
private struct CostSections: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Section("今月の推定費用") {
      EstimatedCostView(state: model.cost)
    }
    Section("月次予算") {
      Toggle("月次予算を設定する", isOn: $model.form.budgetEnabled)
      if model.form.budgetEnabled {
        TextField("上限", text: $model.form.budgetLimit)
        IssueText(issues: model.issues(in: [.budgetLimit]))
      }
      TextField("通貨（例: USD）", text: $model.form.currencyCode)
      IssueText(issues: model.issues(in: [.currencyCode]))
      ForEach(model.form.notices.filter(\.isCostNotice), id: \.self) {
        NoticeText(notice: $0)
      }
    }
    Section {
      PriceUpdatedOnRow(model: model)
      IssueText(issues: model.issues(in: [.priceUpdatedOnMissing]))
      ForEach($model.form.priceRows) { $row in
        VStack(alignment: .leading) {
          HStack {
            TextField("モデル名", text: $row.model)
            TextField("入力", text: $row.inputPerMillionTokens).frame(width: 90)
            TextField("出力", text: $row.outputPerMillionTokens).frame(width: 90)
            Button {
              model.form.removePriceRow(id: row.id)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("この行を削除")
          }
          IssueText(issues: model.issues(forRow: row.id))
        }
      }
      Button("単価を追加") { model.form.addPriceRow() }
    } header: {
      Text("単価表（100万トークンあたり）")
    } footer: {
      Text("単価はプロバイダーの公開価格を見て入力し、更新日を合わせて直してください。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct PriceUpdatedOnRow: View {
  @Bindable var model: SettingsModel
  private let calendar = Calendar.current

  var body: some View {
    if let day = model.form.priceUpdatedOn, let date = SettingsForm.date(of: day, in: calendar) {
      HStack {
        DatePicker(
          "更新日",
          selection: Binding(
            get: { date },
            set: { model.form.priceUpdatedOn = SettingsForm.calendarDay(of: $0, in: calendar) }),
          displayedComponents: .date)
        Button("消す") { model.form.priceUpdatedOn = nil }
      }
    } else {
      LabeledContent("更新日") {
        Button("今日の日付を入れる") {
          model.form.priceUpdatedOn = SettingsForm.calendarDay(of: Date(), in: calendar)
        }
      }
    }
  }
}

private struct EstimatedCostView: View {
  let state: SettingsModel.CostState

  var body: some View {
    switch state {
    case .loading:
      ProgressView().controlSize(.small)
    case .summary(let summary):
      let code = summary.currency.code
      LabeledContent("推定費用（\(summary.month.year)年\(summary.month.month)月）") {
        Text(summary.estimatedSpent, format: .currency(code: code))
      }
      if summary.reserved > 0 {
        LabeledContent("送信中の見込み") {
          Text(summary.reserved, format: .currency(code: code))
        }
      }
      LabeledContent("月次予算") {
        Text(summary.limitAmount, format: .currency(code: code))
      }
      LabeledContent("予算の推定の残り") {
        Text(summary.estimatedRemaining, format: .currency(code: code))
      }
      LabeledContent("計算に使った単価表の更新日") {
        Text(
          "\(String(summary.priceTableUpdatedOn.year))/\(summary.priceTableUpdatedOn.month)/\(summary.priceTableUpdatedOn.day)"
        )
      }
      Text("トークン使用量と単価表から計算した推定値です。プロバイダーの請求額や API クレジットの残高ではありません。")
        .font(.caption).foregroundStyle(.secondary)
    case .unavailable(let reason):
      Text(Self.message(for: reason)).foregroundStyle(.secondary)
    case .unreadable:
      Text("推定費用の記録を読み込めませんでした。").foregroundStyle(.red)
    }
  }

  private static func message(for reason: CloudCostBridge.Unavailable) -> String {
    switch reason {
    case .budgetNotSet:
      "月次予算を設定すると、今月の推定費用と予算の残りを表示します。"
    case .priceTableIncomplete:
      "単価表の通貨と更新日を設定すると、推定費用を表示します。"
    case .currencyMismatch:
      "予算と単価表の通貨が異なるため、推定費用を表示できません。"
    case .invalidMonth:
      "今月の年月を集計に使えないため、推定費用を表示できません。"
    case .usageInOtherCurrency:
      "今月、別の通貨で推定費用が記録されています。換算はしないため、今月は推定費用を表示できず、予算の判定もできません。"
    }
  }
}

// MARK: - 文体と辞書

/// 文体（整形モード, TXT-01）と、辞書の編集画面への案内（TXT-03）
private struct StyleAndDictionarySettingsTab: View {
  @Bindable var model: SettingsModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      Section {
        Picker("文体", selection: $model.form.refinementMode) {
          ForEach(RefinementModeSetting.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.radioGroup)
      } header: {
        Text("文体")
      } footer: {
        Text("アプリやサイトごとの書き分け（丁寧・簡潔など）は「アプリ別の設定」タブで選びます。メニューからも切り替えられます。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("ユーザー辞書") {
          Button("辞書を編集…") { openWindow(id: DictionaryEditorScene.windowID) }
        }
      } header: {
        Text("辞書")
      } footer: {
        Text("辞書の置換は整形の前にこの Mac で行います。クラウドで整形するときは、辞書の語を整形の手がかりとして送ります。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - アプリ別の設定

/// アプリ別・サイト別の文体（CTX-01, CTX-02）と除外アプリ（7章, AC-12）
private struct AppSpecificSettingsTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      StyleSections(model: model)
      ExcludedAppsSection(model: model)
    }
    .formStyle(.grouped)
  }
}

// MARK: - スタイル

/// アプリ別・サイト別のスタイルの上書きと既定の対応表（CTX-01, CTX-02）
private struct StyleSections: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Section {
      ForEach($model.form.appStyleRows) { $row in
        StyleOverrideRowView(
          placeholder: "bundle ID（例: com.apple.mail）", row: $row,
          issues: model.issues(forRow: row.id)
        ) {
          model.form.removeAppStyleRow(id: row.id)
        }
      }
      Button("アプリを追加") { model.form.addAppStyleRow() }
    } header: {
      Text("アプリ別の上書き")
    } footer: {
      Text("上書きがないアプリは、下の既定の対応表から自動で選び、どれにも当たらなければ標準にします。")
        .font(.caption).foregroundStyle(.secondary)
    }
    Section {
      Toggle("Web サイト単位でスタイルを選ぶことを許可する", isOn: $model.form.siteIdentificationAllowed)
      Text("許可すると、前面のブラウザで表示中のサイトのホスト名を読みます。ホスト名・URL はクラウドへ送りません。許可を外しても一覧は残ります。")
        .font(.caption).foregroundStyle(.secondary)
      ForEach($model.form.siteStyleRows) { $row in
        StyleOverrideRowView(
          placeholder: "サイト（例: mail.example.com）", row: $row,
          issues: model.issues(forRow: row.id)
        ) {
          model.form.removeSiteStyleRow(id: row.id)
        }
      }
      Button("サイトを追加") { model.form.addSiteStyleRow() }
    } header: {
      Text("サイト別の上書き")
    }
    Section("既定の対応表") {
      DisclosureGroup("アプリごとの既定のスタイル（\(AppStyleResolver.builtInStyles.count) 件）") {
        ForEach(AppStyleResolver.builtInStyles.sorted(by: { $0.key < $1.key }), id: \.key) {
          LabeledContent($0.key, value: $0.value.label)
        }
      }
    }
  }
}

private struct StyleOverrideRowView: View {
  let placeholder: String
  @Binding var row: SettingsForm.StyleOverrideRow
  let issues: [SettingsIssue]
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        TextField(placeholder, text: $row.key)
        Picker("スタイル", selection: $row.style) {
          ForEach(RefinementStyle.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .frame(width: 200)
        Button(action: onRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("この行を削除")
      }
      IssueText(issues: issues)
    }
  }
}

// MARK: - 除外アプリ

/// 除外アプリの一覧（7章, AC-12）
private struct ExcludedAppsSection: View {
  @Bindable var model: SettingsModel
  /// 「起動中のアプリから追加」の候補。タブを開いたとき・一覧を変えたとき・アプリの起動と終了で読み直す
  @State private var candidates: [ExcludedAppCandidate] = []

  var body: some View {
    Section {
      ForEach($model.form.excludedAppRows) { $row in
        ExcludedAppRowView(row: $row, issues: model.issues(forRow: row.id)) {
          model.form.removeExcludedAppRow(id: row.id)
        }
      }
      if model.form.excludedAppRows.isEmpty {
        Text("除外アプリはありません。").foregroundStyle(.secondary)
      }
      HStack {
        Button("bundle ID で追加") { model.form.addExcludedAppRow() }
        Menu("起動中のアプリから追加") {
          if candidates.isEmpty {
            Text("追加できるアプリがありません")
          }
          ForEach(candidates) { candidate in
            Button("\(candidate.name)（\(candidate.bundleID)）") {
              model.form.addExcludedApp(bundleID: candidate.bundleID)
            }
          }
        }
        .fixedSize()
      }
    } header: {
      Text("除外アプリ")
    } footer: {
      Text("ここに追加したアプリへの入力では、録音・クラウドへの送信・入力履歴への保存をしません。追加・削除は「保存」で反映します。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear(perform: reloadCandidates)
    // 入力の1文字ごとではなく、一覧に入っているアプリが変わったときだけ読み直す
    .onChange(of: listedApps) { reloadCandidates() }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification)
    ) { _ in reloadCandidates() }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification)
    ) { _ in reloadCandidates() }
  }

  private func reloadCandidates() {
    let running = NSWorkspace.shared.runningApplications.map {
      ExcludedAppCandidate.RunningApp(
        bundleID: $0.bundleIdentifier, name: $0.localizedName,
        isRegular: $0.activationPolicy == .regular)
    }
    candidates = ExcludedAppCandidate.candidates(
      from: running, ownBundleID: Bundle.main.bundleIdentifier, form: model.form)
  }

  /// 一覧に入っているアプリ（大文字・小文字と前後の空白を除いた bundle ID）
  private var listedApps: Set<String> {
    Set(
      model.form.excludedAppRows.map {
        $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      })
  }
}

private struct ExcludedAppRowView: View {
  @Binding var row: SettingsForm.ExcludedAppRow
  let issues: [SettingsIssue]
  let onRemove: () -> Void
  /// インストールされているアプリの名前。bundle ID が変わったときだけ引き直す
  @State private var appName: String?

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        TextField("bundle ID（例: com.example.app）", text: $row.bundleID)
        if let appName {
          Text(appName).foregroundStyle(.secondary).lineLimit(1)
        }
        Button(action: onRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("この行を削除")
      }
      IssueText(issues: issues)
    }
    .task(id: row.bundleID) {
      appName = Self.appName(for: row.bundleID)
    }
  }

  /// インストールされているアプリの名前。見つからなければ `nil`
  private static func appName(for bundleID: String) -> String? {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SettingsForm.isPlausibleBundleID(trimmed),
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
    else { return nil }
    return FileManager.default.displayName(atPath: url.path)
  }
}
