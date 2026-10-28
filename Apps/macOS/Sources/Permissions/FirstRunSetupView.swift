import AppKit
import SwiftUI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 初回セットアップの画面（PERM-01〜03, REC-01, REC-02, AI-03, #198）。
///
/// 上に手順の一覧（今の手順と、済んだ手順）を、下に今の手順の内容と「戻る」「次へ」を出す。
/// 開いたとき・アプリが前面に来たときに、権限・モデル・設定の状態を取り直す（ネットワークは使わない）。
/// 通信するのは、認識モデルの手順で「取得を開始」を押したときだけ。
struct FirstRunSetupView: View {
  let model: FirstRunSetupModel
  let shortcuts: ShortcutCoordinator
  /// 整形の実行先の手順で選んでいる選択肢。まだ選んでいなければ保存済みの値を使う
  @State private var refinementSelection: RefinementProviderChoice?

  var body: some View {
    Form {
      Section {
        ForEach(Array(FirstRunSetupStep.allCases.enumerated()), id: \.element) { index, step in
          FirstRunSetupStepListRow(
            number: index + 1, step: step, state: model.state(of: step),
            isCurrent: step == model.progress.current)
        }
      } header: {
        Text("手順")
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text("最後まで進めるまでは、途中で閉じても次の起動で続きの手順から始めます。")
          Text("「あとで」にした手順は、メニューの「初回セットアップ…」から続きを済ませられます。")
        }
      }

      if let step = model.progress.current {
        stepContent(step)
        navigation(step)
      } else {
        summary
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 560)
    .onAppear { bringToFront() }
    .task { await model.refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await model.refresh() }
    }
  }

  /// 最後の手順の先のまとめ。飛ばした・まだ済んでいない手順があれば、続きから済ませられる
  private var summary: some View {
    Section {
      if model.nextIncompleteStep == nil {
        Text("初回セットアップを終えました。設定はメニューの「設定…」でいつでも変えられます。")
      } else {
        Text("「あとで」にした手順や、まだ済んでいない手順があります。続きから済ませられます。")
      }
      HStack {
        Button("最初から見直す") { model.restart() }
        Spacer()
        if model.nextIncompleteStep != nil {
          Button("続きから済ませる") { model.resumeIncompleteStep() }
            .buttonStyle(.borderedProminent)
        }
      }
    }
  }

  @ViewBuilder private func stepContent(_ step: FirstRunSetupStep) -> some View {
    switch step {
    case .microphone:
      PermissionStepSection(
        model: model, step: .microphone,
        footer: "録音して文字にするため、録音中だけマイクを使います。使う音声認識が求めるときは、音声認識の許可もここで求めます。")
    case .accessibility:
      PermissionStepSection(
        model: model, step: .accessibility,
        footer: "認識した文字を入力中の欄へ直接入れるために使います。許可がなくても、コピーできるプレビューで結果を受け取れます。")
      let undecided = model.permissions.onboarding.undecidedFeatures
      if !undecided.isEmpty {
        Section {
          Text(AppFeature.displayNames(undecided))
        } header: {
          Text("確認中")
        } footer: {
          Text("必要な権限を確認中のため、これらの機能はまだ使わず、権限も求めません。")
        }
      }
    case .speechModel:
      SpeechModelStepSection(model: model)
    case .shortcut:
      ShortcutStepSection(model: model, shortcuts: shortcuts)
    case .refinement:
      RefinementStepSection(selection: refinementSelectionBinding)
    }
  }

  /// 「戻る」「あとで」「次へ」。「あとで」は利用者の操作が要る手順にだけ出し、権限の状態・設定は変えない
  private func navigation(_ step: FirstRunSetupStep) -> some View {
    Section {
      HStack {
        Button("戻る") { model.goBack() }
          .disabled(step.previous == nil)
        Spacer()
        if model.canDefer {
          Button("あとで") { model.deferCurrentStep() }
        }
        if step == .refinement {
          if model.canAdvance {
            Button("次へ") { model.advance() }
          }
          Button("この実行先にする") { model.chooseRefinement(refinementChoice) }
            .buttonStyle(.borderedProminent)
        } else {
          Button("次へ") { model.advance() }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAdvance)
        }
      }
      if model.saveFailed {
        Text("設定を保存できませんでした。もう一度お試しください。")
          .font(.caption).foregroundStyle(.red)
      }
    } footer: {
      if !model.canAdvance {
        Text("この手順を済ませるか「あとで」を選ぶと、次へ進めます。「あとで」では権限も設定も変えません。")
      }
    }
  }

  private var refinementChoice: RefinementProviderChoice {
    refinementSelection ?? model.refinementChoice
  }

  private var refinementSelectionBinding: Binding<RefinementProviderChoice> {
    Binding(
      get: { refinementChoice },
      set: { refinementSelection = $0 })
  }
}

// MARK: - 手順の一覧

/// 手順の一覧の1行。今の手順と、手順の状態（済み・不要・あとでなど）を示す
private struct FirstRunSetupStepListRow: View {
  let number: Int
  let step: FirstRunSetupStep
  let state: FirstRunSetupStepState
  let isCurrent: Bool

  var body: some View {
    HStack {
      Text("\(number). \(step.title)")
        .font(isCurrent ? .headline : .body)
      if isCurrent {
        Text("今の手順")
          .font(.caption)
          .foregroundStyle(.tint)
      }
      Spacer()
      Label(state.label, systemImage: state.systemImage)
        .foregroundStyle(state.color)
    }
  }
}

extension FirstRunSetupStep {
  fileprivate var title: String {
    switch self {
    case .microphone: "マイク"
    case .accessibility: "アクセシビリティ"
    case .speechModel: "認識モデル"
    case .shortcut: "ショートカット"
    case .refinement: "整形の実行先"
    }
  }
}

extension FirstRunSetupStepState {
  fileprivate var label: String {
    switch self {
    case .completed: "完了"
    case .notNeeded: "不要"
    case .inProgress: "取得中"
    case .needsAction: "未完了"
    case .unavailable: "ここでは設定できません"
    case .deferred: "あとで"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .completed: "checkmark.circle.fill"
    case .notNeeded: "minus.circle"
    case .inProgress: "arrow.down.circle"
    case .needsAction: "circle"
    case .unavailable: "exclamationmark.triangle"
    case .deferred: "clock"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .completed: .green
    case .inProgress: .blue
    case .unavailable: .orange
    case .notNeeded, .needsAction, .deferred: .secondary
    }
  }
}

// MARK: - 権限の手順

/// マイク・アクセシビリティの手順。手順で扱う権限を、要求の順に並べる
private struct PermissionStepSection: View {
  let model: FirstRunSetupModel
  let step: FirstRunSetupStep
  let footer: String

  var body: some View {
    Section {
      let steps = model.permissionSteps(for: step)
      if steps.isEmpty {
        Text("この構成では、この権限は要りません。")
      }
      ForEach(steps, id: \.permission) { permissionStep in
        PermissionStepRow(step: permissionStep) {
          Task { await model.permissions.perform(permissionStep) }
        }
        .disabled(model.permissions.isPerforming)
      }
    } header: {
      Text(step.title)
    } footer: {
      Text(footer)
    }
  }
}

/// 権限1つの行。許可されていなければ、要求・システム設定を開くボタンを出す
private struct PermissionStepRow: View {
  let step: PermissionOnboardingStep
  let action: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(step.permission.displayName)
          .font(.headline)
        Text("用途: \(AppFeature.displayNames(step.features))")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let note {
          Text(note)
            .font(.callout)
            .foregroundStyle(isRevoked ? .orange : .secondary)
        }
      }
      Spacer()
      if step.state == .granted {
        Label("許可済み", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else if let buttonTitle {
        Button(buttonTitle, action: action)
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private var isRevoked: Bool {
    if case .needed(_, wasRevoked: true) = step.state { true } else { false }
  }

  private var note: String? {
    guard case .needed(let action, let wasRevoked) = step.state else { return nil }
    let revoked = wasRevoked ? "許可が取り消されました。" : ""
    return switch action {
    case .requestFromSystem: wasRevoked ? revoked : nil
    case .openSystemSettings: revoked + "システム設定で許可してください。"
    case .notChangeableByUser: "管理者により制限されているため変更できません。"
    }
  }

  private var buttonTitle: String? {
    guard case .needed(let action, _) = step.state else { return nil }
    return switch action {
    case .requestFromSystem: "許可する…"
    case .openSystemSettings: "システム設定を開く"
    case .notChangeableByUser: nil
    }
  }
}

// MARK: - 認識モデルの手順

/// 認識モデルの手順（PERM-03）。モデル名・取得元・サイズ・取得後の確認を示し、「取得を開始」を押したときだけ取得する
private struct SpeechModelStepSection: View {
  let model: FirstRunSetupModel

  var body: some View {
    Section {
      if let speechModel = model.speechModel, let description = model.speechModelDescription {
        LabeledContent("モデル", value: description.name)
        LabeledContent("取得元", value: description.source)
        LabeledContent("サイズ", value: description.size)
        LabeledContent("取得後の確認", value: description.integrity)
        LabeledContent("状態", value: speechModel.setupStatusLabel)
        if speechModel.canInstall {
          Button("取得を開始") { Task { await model.installSpeechModel() } }
            .buttonStyle(.borderedProminent)
        }
        if speechModel.isInstalling {
          ProgressView().controlSize(.small)
        }
        if speechModel.installFailed {
          Text("モデルを取得できませんでした。通信状態と空き容量を確かめて、もう一度お試しください。")
            .foregroundStyle(.red)
        }
      } else if model.sttEngine == nil {
        VStack(alignment: .leading, spacing: 4) {
          Text("音声認識のエンジンが未設定のため、取得するモデルはありません（音声入力は使えません）。")
          Text("既定のエンジンは検証中のため決めていません。")
            .font(.caption).foregroundStyle(.secondary)
          Text("Config/Local.xcconfig の UTTER_MAC_STT_ENGINE で選び、ビルドし直してください。")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text("使っている音声認識のエンジンには、取得するモデルはありません。")
      }
    } header: {
      Text("認識モデル")
    } footer: {
      Text("モデルは「取得を開始」を押したときだけ取得し、そのときだけネットワークを使います。認識は Mac の中で行い、音声は Mac の外に送りません。")
    }
    // OS が取得中の間は、終わった・失敗したことが分かるよう数秒おきに確かめ直す（ネットワークは使わない）。
    // 取得を始めたときにも始め直す。手順を移る・画面を閉じると止まる
    .task(id: needsStatusPolling) {
      guard needsStatusPolling, let speechModel = model.speechModel else { return }
      while speechModel.availability == .downloading || speechModel.isInstalling {
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { return }
        await speechModel.refresh()
      }
    }
  }

  private var needsStatusPolling: Bool {
    guard let speechModel = model.speechModel else { return false }
    return speechModel.availability == .downloading || speechModel.isInstalling
  }
}

extension SpeechModelSettingsModel {
  fileprivate var setupStatusLabel: String {
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

// MARK: - ショートカットの手順

/// ショートカットの手順（REC-01, REC-02）。今の割当と重なりの確認の結果を示し、記録して変えられる。
///
/// 記録は設定画面と同じ `ShortcutRecordingMonitor` で、この画面のウインドウのキー入力だけを受け取る。
/// 記録した組み合わせは、重なりがなければすぐに保存する（録音ショートカットの項目だけを書き換える）。
private struct ShortcutStepSection: View {
  let model: FirstRunSetupModel
  let shortcuts: ShortcutCoordinator
  @State private var recording = ShortcutRecordingMonitor()

  var body: some View {
    Section {
      LabeledContent("録音ショートカット") {
        HStack {
          Text(shortcutText)
            .foregroundStyle(recording.isRecording ? Color.secondary : Color.primary)
          if recording.isRecording {
            Button("取り消す") { recording.stop() }
          } else {
            Button(model.recordingShortcut == nil ? "記録" : "変更") {
              model.beginRecordingShortcut()
              // ボタンを押した直後のキーウインドウがこの画面のウインドウ
              recording.start(
                systemShortcuts: SystemShortcuts.loadEnabledBindings(), in: NSApp.keyWindow
              ) {
                model.assignShortcut($0)
              }
            }
          }
        }
      }
      if let issue = recording.issue {
        Text(issue.message).font(.caption).foregroundStyle(.red)
      }
      LabeledContent("重なりの確認") {
        Text(checkText)
          .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
      }
      ForEach(model.permissionSteps(for: .shortcut), id: \.permission) { permissionStep in
        PermissionStepRow(step: permissionStep) {
          Task { await model.permissions.perform(permissionStep) }
        }
        .disabled(model.permissions.isPerforming)
      }
      // 修飾キー単独のショートカット・Esc の捕捉に要る権限（使うときだけ。メニューと同じ求め方）
      ForEach(shortcuts.missingPermissions, id: \.self) { permission in
        Button(GlobalShortcutStatusText.requestTitle(for: permission)) {
          shortcuts.requestPermission(permission)
        }
      }
    } header: {
      Text("ショートカット")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Command・Option・Control のいずれかを含む組み合わせか、F1〜F20 を割り当てられます。")
        Text("有効なシステムのショートカットとの重なりと、登録の結果を確かめます。")
        Text("他のアプリが独自に使うショートカットは確かめられません。")
      }
    }
    // ウインドウを閉じた・手順を移ったときに、記録中のモニターを外す
    .onDisappear { recording.stop() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
    ) { _ in recording.stop() }
  }

  private var shortcutText: String {
    if recording.isRecording {
      return ShortcutRecorder.promptText
    }
    return ShortcutRecorder.displayText(for: model.recordingShortcut)
  }

  /// 直前に記録した組み合わせを割り当てられなかったら、その結果を優先して出す
  private var check: FirstRunShortcutCheck {
    model.rejectedShortcut ?? model.shortcutCheck
  }

  private var isAvailable: Bool {
    if case .available = check { true } else { false }
  }

  private var checkText: String {
    switch check {
    case .unassigned:
      "まだ割り当てていません。「記録」を押して、割り当てるキーを押してください。"
    case .rejected(let combination, let issue):
      "\(ShortcutNotation.display(combination)) は割り当てられません。\(issue.message)"
    case .sameAsEditMode(let combination):
      "\(ShortcutNotation.display(combination)) は Edit Mode のショートカットと同じです。別の組み合わせにしてください。"
    case .unavailable(_, let reason):
      GlobalShortcutStatusText.reasonText(reason)
    case .available:
      "システムのショートカットとの重なりは見つかりません。"
    }
  }
}

// MARK: - 整形の実行先の手順

/// 整形の実行先の手順（AI-03, AC-06）。選択肢は設定画面と同じ（`RefinementProviderChoice`）。
/// 「あとで」で飛ばせる。既定は Local Basic で、送信しない
private struct RefinementStepSection: View {
  @Binding var selection: RefinementProviderChoice

  var body: some View {
    Section {
      Picker("整形の実行先", selection: $selection) {
        ForEach(RefinementProviderChoice.allCases) { choice in
          Text(choice.label).tag(choice)
        }
      }
      .pickerStyle(.radioGroup)
      switch selection {
      case .claude:
        Text("Claude へは、同意の画面での送信の同意と、設定画面の API キーがそろうまで送信しません。")
          .font(.caption).foregroundStyle(.secondary)
      case .chatGPTSignIn:
        Text("ChatGPT へは、同意の画面での送信の同意と、設定画面でのサインインがそろうまで送信しません。")
          .font(.caption).foregroundStyle(.secondary)
      case .openAIAPIKey:
        Text(
          "ChatGPT（OpenAI API キー方式）へは、同意の画面での送信の同意と、設定画面の OpenAI API キー・整形用モデル名・月次予算と単価表がそろうまで送信しません。"
        )
        .font(.caption).foregroundStyle(.secondary)
      case .localBasic:
        EmptyView()
      }
    } header: {
      Text("整形の実行先")
    } footer: {
      Text("既定は Local Basic で、Mac の中で整形し、どこへも送りません。「あとで」を選ぶと既定のままにします。設定画面の「整形の実行先と費用」タブで変えられます。")
    }
  }
}
