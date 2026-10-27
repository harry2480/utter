import AppKit
import SwiftUI
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 設定画面（AC-05, AC-12, AI-05, AI-07, CTX-01, CTX-02, PERM-03, REC-01, REC-02, REC-05,
/// 2.2節, 4章, 6章, 7章）。
///
/// 検証・保存・表示値は `SettingsModel` / `SettingsForm` / `CloudCostBridge` が持ち、ここは並べるだけにする。
/// 入力はまとめて「保存」で検証・保存する（数値・通貨・サイトなどの入力途中の値を保存しない）。
struct SettingsView: View {
  @Bindable var model: SettingsModel
  /// 「API キー」タブの状態。キーは Keychain に即時に保存し、下の「保存」とは別に扱う（AC-12）
  let apiKeyModel: APIKeySettingsModel
  /// 「API キー」タブの OpenAI API キー（クラウド STT, #188）の状態
  let openAIAPIKeyModel: APIKeySettingsModel
  /// 「音声認識」タブに出すローカルのエンジン。ビルド設定で選び、この画面では変えない（未選択なら `nil`）。
  /// ローカルのエンジンとクラウド STT のどちらを使うかは、このタブで選んで「保存」する（#188）
  let sttEngine: STTEngineKind?
  /// 「音声認識」タブのモデルの取得状態。モデルの取得はタブのボタンからだけ行う（PERM-03）
  let speechModel: SpeechModelSettingsModel?
  @State private var selection: SettingsTab = .recording

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $selection) {
        RecordingSettingsTab(model: model)
          .tabItem { Label("録音", systemImage: "mic") }
          .tag(SettingsTab.recording)
        RefinementSettingsTab(model: model)
          .tabItem { Label("整形", systemImage: "text.badge.checkmark") }
          .tag(SettingsTab.refinement)
        CostSettingsTab(model: model)
          .tabItem { Label("費用", systemImage: "yensign.circle") }
          .tag(SettingsTab.cost)
        StyleSettingsTab(model: model)
          .tabItem { Label("スタイル", systemImage: "paintbrush") }
          .tag(SettingsTab.style)
        ExcludedAppsSettingsTab(model: model)
          .tabItem { Label("除外アプリ", systemImage: "hand.raised") }
          .tag(SettingsTab.excludedApps)
        SpeechRecognitionSettingsTab(settings: model, engine: sttEngine, model: speechModel)
          .tabItem { Label("音声認識", systemImage: "waveform") }
          .tag(SettingsTab.speechRecognition)
        APIKeySettingsView(claude: apiKeyModel, openAI: openAIAPIKeyModel)
          .tabItem { Label("API キー", systemImage: "key") }
          .tag(SettingsTab.apiKey)
      }
      // API キーのタブは独自の保存・削除を持つため、設定の「保存」「元に戻す」を出さない
      if selection.showsSaveActions {
        Divider()
        SettingsFooter(model: model)
          .padding()
      }
    }
    .frame(minWidth: 560, minHeight: 480)
    .onAppear {
      model.reload()
      Task { await model.refreshCost() }
    }
  }
}

private enum SettingsTab: Hashable {
  case recording
  case refinement
  case cost
  case style
  case excludedApps
  case speechRecognition
  case apiKey

  /// 設定の「保存」「元に戻す」を出すタブか
  var showsSaveActions: Bool {
    switch self {
    case .recording, .refinement, .cost, .style, .excludedApps, .speechRecognition: true
    case .apiKey: false
    }
  }
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

// MARK: - 録音

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

  var body: some View {
    Form {
      Section("録音") {
        RecordingShortcutRow(model: model)
        Picker("録音の操作", selection: $model.form.recordingTrigger) {
          ForEach(ShortcutTriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        LabeledContent("最大録音時間") {
          HStack {
            TextField("秒", text: $model.form.maxRecordingSeconds)
              .frame(width: 80)
              .multilineTextAlignment(.trailing)
            Text("秒")
          }
        }
        IssueText(issues: model.issues(in: [.maxRecordingDuration]))
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
      Section("音声認識モデルの保持") {
        Picker("保持モード", selection: $model.form.modelRetentionMode) {
          ForEach(ModelRetentionModeSetting.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("高速モードでのモデル保持を許可する", isOn: $model.form.performanceRetentionAllowed)
        if model.form.notices.contains(.performanceRetentionNotAllowed) {
          NoticeText(notice: .performanceRetentionNotAllowed)
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - 整形

private struct RefinementSettingsTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      Section {
        Picker("処理系", selection: $model.form.provider) {
          ForEach(RefinementProviderChoice.allCases) { choice in
            Text(choice.label).tag(choice).disabled(!choice.isSelectable)
          }
        }
        .pickerStyle(.radioGroup)
        IssueText(issues: model.issues(in: [.providerUnavailable]))
        Text("ChatGPT は利用条件の確認（Phase 0）が終わるまで選べません。")
          .font(.caption).foregroundStyle(.secondary)
        if model.form.provider == .claude {
          Text("クラウド AI へは、送信の同意がない間は送信しません。API キーと同意は別の画面で設定します。")
            .font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("処理系")
      }
      Section("整形") {
        Picker("整形モード", selection: $model.form.refinementMode) {
          ForEach(RefinementModeSetting.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        TextField("整形用モデル名", text: $model.form.refinementModel)
        IssueText(issues: model.issues(in: [.refinementModelEmpty]))
        Text("既定は \(AppSettings.defaultRefinementModel)。モデルの廃止・改名に合わせて変更できます。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - 費用

private struct CostSettingsTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
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
        ForEach(model.form.notices.filter { $0 != .performanceRetentionNotAllowed }, id: \.self) {
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
    .formStyle(.grouped)
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

// MARK: - スタイル

private struct StyleSettingsTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
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
    .formStyle(.grouped)
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

private struct ExcludedAppsSettingsTab: View {
  @Bindable var model: SettingsModel
  /// 「起動中のアプリから追加」の候補。タブを開いたとき・一覧を変えたとき・アプリの起動と終了で読み直す
  @State private var candidates: [ExcludedAppCandidate] = []

  var body: some View {
    Form {
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
        Text("ここに追加したアプリへの入力では、クラウドへの送信と入力履歴への保存をしません。追加・削除は「保存」で反映します。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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
