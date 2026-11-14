import SwiftUI
import UtterAI
import UtterCore
import UtterPersistence
import UtteriOSKit

/// 録音の開始・停止・状態と、結果の確認・コピー・消去（iOS-04, iOS-07）。進行の判断は `RecordingSessionModel` が持つ。
///
/// ホームでは文体の切り替えと整形先・認識先・最大録音時間、録音中は経過時間・音量の波形・チップ・途中の文字、
/// 結果では文体・整形先・残り時間と元のアプリへの戻り方を出す（#201）。文言と判定は UtteriOSKit が持つ。
struct RecordingView: View {
  let model: RecordingSessionModel
  let home: HomeSettingsModel
  let refinementSettings: RefinementSettingsModel
  let consentSettings: ConsentSettingsModel
  let claudeAPIKeySettings: APIKeySettingsModel
  let speechEngine: SpeechEngineSelection
  /// 取得できるモデルがあるエンジンのときだけ
  let speechModel: SpeechModelSettingsModel?
  /// キーボード拡張に本体アプリの状態を伝える。App Group を設定したときだけ（#56）
  let hostAppStatus: HostAppStatusPublisher?
  /// キーボードの待機セッション。App Group を設定したときだけ（iOS-04）
  let standby: StandbyDriver?
  /// セットアップ画面の状態（#200）
  let setup: SetupChecklistModel
  /// 個人署名の期限。読めなければ `nil`（警告を出さない）
  let signingExpiry: SigningExpiry?
  @Environment(\.scenePhase) private var scenePhase
  @State private var isShowingSettings = false
  @State private var isShowingSetup = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          if let signingWarning {
            Text(signingWarning.message)
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(Color.utterWarningText)
              .utterCard()
              .background(
                Color.utterWarningFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          if let standby {
            StandbySection(driver: standby, isRecording: !model.canStartRecording)
          }
          recordingSection
          if model.canStartRecording {
            homeSummary
          }
          resultsSection
          if hasCopyableResult {
            returnGuideSection
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 34)
      }
      .background(Color.utterBackground)
      .navigationTitle("utter")
      .refreshable { await model.refreshResults() }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            isShowingSetup = true
          } label: {
            Label("セットアップ", systemImage: "checklist")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isShowingSettings = true
          } label: {
            Label("設定", systemImage: "gearshape")
          }
        }
      }
      .sheet(
        isPresented: $isShowingSetup,
        onDismiss: {
          // 一度閉じたら、次の起動からは自動では出さない
          setup.dismiss()
          reloadHome()
          // マイクの許可・モデルの取得の後の状態をキーボード拡張に伝える（iAC-07）
          Task { await hostAppStatus?.publish() }
        }
      ) {
        SetupView(
          setup: setup, home: home, refinementSettings: refinementSettings,
          speechEngine: speechEngine, speechModel: speechModel, signingExpiry: signingExpiry)
      }
    }
    .tint(Color.utterAccent)
    .sheet(
      isPresented: $isShowingSettings,
      onDismiss: {
        // 整形と予算・同意の画面で変わった整形先をホームに出す
        reloadHome()
        // 処理系の選択はキーボード拡張の案内に出すため、設定を閉じたら書き直す（iAC-07）
        Task { await hostAppStatus?.publish() }
      }
    ) {
      SettingsView(
        refinementSettings: refinementSettings, consentSettings: consentSettings,
        claudeAPIKeySettings: claudeAPIKeySettings,
        speechEngine: speechEngine, speechModel: speechModel)
    }
    .task {
      // 初めて使うときは、セットアップ画面を出す（#200）
      if setup.presentsOnLaunch {
        isShowingSetup = true
      }
      await model.prepareResults()
      // 起動時に本体アプリの状態を書く（iAC-07）
      await hostAppStatus?.publish()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        reloadHome()
        Task { await model.prepareResults() }
        // 設定アプリで権限を変えて戻ったときを含め、前面に来るたびに書き直す（iAC-07）
        Task { await hostAppStatus?.publish() }
      }
    }
    .onChange(of: speechModel?.availability) {
      // モデルの取得状態が変わったら書き直す
      Task { await hostAppStatus?.publish() }
    }
    .onChange(of: model.isRecording) { _, isRecording in
      // 話している間に自動ロックで録音が止まらないようにする。録音していないときは元に戻す
      UIApplication.shared.isIdleTimerDisabled = isRecording
    }
  }

  private var recordingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      UtterSectionLabel("このアプリで録音")
      Button {
        Task {
          await model.toggleRecording()
          // 録音の開始で権限を求めた後の状態を書き直す
          await hostAppStatus?.publish()
        }
      } label: {
        Label(
          model.isRecording ? "録音を止める" : "録音を始める",
          systemImage: model.isRecording ? "stop.circle.fill" : "mic.circle.fill")
      }
      .buttonStyle(UtterFilledButtonStyle(tone: .strong, height: 56))
      // 待機中は入力がミュートされた待機のセッションを保つため、本体アプリでの録音は待機を終えてから行う
      .disabled(!canToggle || standby?.isStandingBy == true)

      if model.canStartRecording {
        Text(RecordingDurationText.maximum(model.maxRecordingDuration))
          .font(.system(size: 13))
          .foregroundStyle(Color.utterSecondary)
      } else {
        sessionProgress
      }

      Text(model.phase.statusLabel)
        .font(.system(size: 15))
        .foregroundStyle(Color.utterSecondary)

      if canCancel {
        Button("キャンセル", role: .cancel) { model.cancel() }
          .buttonStyle(UtterOutlineButtonStyle())
      }
      if let stopNotice = model.stopNotice {
        Text(stopNotice.message)
          .font(.system(size: 15))
          .foregroundStyle(Color.utterText)
      }
      if let refinementNotice = model.refinementNotice {
        Text(refinementNotice.message)
          .font(.system(size: 13))
          .foregroundStyle(Color.utterSecondary)
      }
      if let failure = model.failure {
        Text(failure.message)
          .font(.system(size: 15))
          .foregroundStyle(.red)
        Button("閉じる") { model.dismissError() }
          .buttonStyle(UtterOutlineButtonStyle())
      }
      if let unsavedText = model.unsavedText {
        Text(unsavedText)
          .font(.system(size: 15))
          .foregroundStyle(Color.utterText)
          .textSelection(.enabled)
        Button("コピー") { Task { await model.copyUnsavedText() } }
          .buttonStyle(UtterOutlineButtonStyle())
      }
    }
    .utterCard()
  }

  /// ホーム: 文体の切り替え、整形先・認識先（設計の「いつもの設定」）
  private var homeSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      UtterSectionLabel("いつもの設定")
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Picker("文体", selection: styleSelection) {
            ForEach(RefinementMode.allCases, id: \.self) { mode in
              Text(mode.styleName).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          Text(home.style.styleDescription)
            .font(.system(size: 13))
            .foregroundStyle(Color.utterSecondary)
          if home.saveFailed {
            Text("文体を保存できませんでした。")
              .font(.system(size: 13))
              .foregroundStyle(.red)
          }
        }
        .padding(16)
        Divider().overlay(Color.utterLine)
        DestinationRow(title: "整形", destination: home.refinementDestination)
        Divider().overlay(Color.utterLine)
        DestinationRow(title: "認識", destination: home.speechDestination)
      }
      .background(Color.utterCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  /// 録音中・処理中: 経過時間、音量の波形、文体・認識・整形先のチップ、途中の文字
  @ViewBuilder
  private var sessionProgress: some View {
    if model.isRecording {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        if let progress = model.recordingProgress() {
          VStack(alignment: .leading, spacing: 4) {
            Text(progress.text)
              .font(.title3.monospacedDigit())
              .foregroundStyle(Color.utterText)
            ProgressView(value: progress.fraction)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("経過 / 最大録音時間 \(progress.text)")
        }
      }
      LevelWaveform(levels: model.levels.levels)
    }
    sessionChips
    if let interim = InterimTranscript(model.transcript) {
      InterimTranscriptView(interim: interim)
    }
  }

  private var sessionChips: some View {
    let mode = model.sessionRefinementMode ?? model.refinementMode
    let refinement = home.refinementDestination(for: mode)
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        Chip(text: "文体: \(mode.styleName)", sendsText: false)
        Chip(
          text: "認識: \(home.speechDestination.name)",
          sendsText: home.speechDestination.sendsText)
        Chip(text: "整形: \(refinement.name)", sendsText: refinement.sendsText)
      }
    }
  }

  private var resultsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      UtterSectionLabel("結果")
      VStack(alignment: .leading, spacing: 6) {
        Text(model.sharing.message)
          .font(.system(size: 13))
          .foregroundStyle(Color.utterSecondary)
        if let copyNotice = model.copyNotice {
          Text(copyNotice.message)
        }
        if let discardNotice = model.discardNotice {
          Text(discardNotice.message)
        }
        if model.isRescueListUnavailable {
          Text("保存した結果を読み込めませんでした。端末のロック中なら、解除してから引き下げて読み直してください。")
        }
        if model.rescueList.unavailableCount > 0 {
          Text("端末のロック中のため読めない結果が \(model.rescueList.unavailableCount) 件あります。")
        }
        if model.rescueList.items.isEmpty {
          Text("保存した結果はありません。")
            .foregroundStyle(Color.utterSecondary)
        }
      }
      .font(.system(size: 15))
      .foregroundStyle(Color.utterText)
      .utterCard()
      ForEach(model.rescueList.items, id: \.sessionID) { item in
        ResultRow(
          item: item, context: model.resultContexts[item.sessionID],
          canRecordAgain: model.canStartRecording,
          copy: { Task { await model.copyResult(item.sessionID) } },
          discard: { Task { await model.discardResult(item.sessionID) } },
          recordAgain: {
            Task {
              await model.recordAgain(item.sessionID)
              // 録音の開始で権限を求めた後の状態を書き直す
              await hostAppStatus?.publish()
            }
          })
      }
    }
  }

  /// 元のアプリに戻ってキーボードから入れる手順と、キーボードが出ない欄でのコピーの案内（iOS-03, iOS-07）
  private var returnGuideSection: some View {
    let guide = ResultReturnGuide(sharing: model.sharing)
    return VStack(alignment: .leading, spacing: 8) {
      UtterSectionLabel("元のアプリで入れる")
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
          Text("\(index + 1). \(step)")
            .font(.system(size: 15))
            .foregroundStyle(Color.utterText)
        }
        Text(guide.copyHint)
          .font(.system(size: 13))
          .foregroundStyle(Color.utterSecondary)
      }
      .utterCard()
    }
  }

  /// コピー・挿入できる結果があるか
  private var hasCopyableResult: Bool {
    model.rescueList.items.contains { $0.state.text != nil }
  }

  /// 文体の選択。保存できたときだけ次の録音に使う
  private var styleSelection: Binding<RefinementMode> {
    Binding(
      get: { home.style },
      set: { style in
        home.select(style)
        model.refinementMode = home.style
      })
  }

  /// ホームで警告する個人署名の残り。期限が近い・過ぎたときだけ（12.6節）
  private var signingWarning: SigningExpiryStatus? {
    guard let status = signingExpiry?.status(at: Date()), status.isWarning else { return nil }
    return status
  }

  /// 保存済みの設定を読み直し、文体を次の録音に使う
  private func reloadHome() {
    home.reload()
    model.refinementMode = home.style
  }

  /// 待機中・失敗の表示中は開始、録音中は停止を受け付ける。処理中は押せない
  private var canToggle: Bool {
    switch model.phase {
    case .idle, .recording, .error: true
    case .recognizing, .refining, .inserting: false
    }
  }

  private var canCancel: Bool {
    switch model.phase {
    case .recording, .recognizing, .refining: true
    case .idle, .inserting, .error: false
    }
  }
}

/// 救済画面の1件。本文はコピーしてよい状態のときだけ出す（iOS-07, iOS-IPC-05）。
///
/// 本文を出す結果には、文体・整形先（このアプリを起動してから保存した結果だけ）と残り時間、
/// 「コピー」「この文章を消す」「録音し直す」を出す。
private struct ResultRow: View {
  let item: SharedResultRescueItem
  let context: SavedResultContext?
  let canRecordAgain: Bool
  let copy: () -> Void
  let discard: () -> Void
  let recordAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(item.createdAt, style: .time)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Color.utterSecondary)
        Spacer()
        Text(item.state.label)
          .font(.system(size: 13))
          .foregroundStyle(Color.utterWarningText)
      }
      if let text = item.state.text {
        if let context {
          HStack(spacing: 8) {
            Chip(text: "文体: \(context.mode.styleName)", sendsText: false)
            Chip(
              text: "整形: \(context.refinement.name)", sendsText: context.refinement.sendsText)
          }
        }
        Text(text)
          .font(.system(size: 15))
          .lineSpacing(5)
          .foregroundStyle(Color.utterText)
          .textSelection(.enabled)
        // 表示している間も残り時間を進める（キーボードと同じく 15 秒ごと）
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
          Text(ResultRemainingTime.message(until: item.expiresAt, at: timeline.date))
            .font(.system(size: 13))
            .foregroundStyle(Color.utterWarningText)
        }
        HStack(spacing: 8) {
          Button("コピー", action: copy)
            .buttonStyle(UtterOutlineButtonStyle())
          Button("消す", role: .destructive, action: discard)
            .buttonStyle(UtterOutlineButtonStyle(role: .destructive))
            .accessibilityLabel("この文章を消す")
          Button("録音し直す", action: recordAgain)
            .buttonStyle(UtterOutlineButtonStyle())
            .disabled(!canRecordAgain)
        }
      }
    }
    .utterCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
  }
}

/// 整形先・認識先の行。文字を送る先には「文字を送信」と示す（AC-06）
private struct DestinationRow: View {
  let title: String
  let destination: ProcessingDestination

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(Color.utterText)
      Spacer()
      HStack(spacing: 8) {
        Text(destination.name)
          .foregroundStyle(Color.utterSecondary)
        if destination.sendsText {
          UtterWarningPill(text: ProcessingDestination.sendsTextLabel)
        }
      }
    }
    .font(.system(size: 15))
    .frame(minHeight: 44)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
  }
}

/// 録音中・結果に出すチップ。文字を送る先には「文字を送信」と添える
private struct Chip: View {
  let text: String
  let sendsText: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(text)
        .foregroundStyle(Color.utterText)
      if sendsText {
        Text("・\(ProcessingDestination.sendsTextLabel)")
          .foregroundStyle(Color.utterWarningText)
      }
    }
    .font(.system(size: 12))
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(Color.utterBackground, in: Capsule())
  }
}

/// 音量の波形。音量の値だけを描き、音声は扱わない
private struct LevelWaveform: View {
  let levels: [Float]
  /// 波形の高さ
  private let height: CGFloat = 32

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule()
          .fill(Color.utterAccent)
          .frame(width: 3, height: max(2, CGFloat(level) * height))
      }
    }
    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    .accessibilityHidden(true)
  }
}

/// 録音中の途中の文字。確定した部分と聞き取り中の部分を分けて出す（本文は表示だけ）
private struct InterimTranscriptView: View {
  let interim: InterimTranscript

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let confirmed = interim.confirmed {
        Text("確定")
          .font(.caption)
          .foregroundStyle(Color.utterSecondary)
        Text(confirmed)
          .foregroundStyle(Color.utterText)
      }
      if let listening = interim.listening {
        Text("聞き取り中")
          .font(.caption)
          .foregroundStyle(Color.utterSecondary)
        Text(listening)
          .foregroundStyle(Color.utterSecondary)
          .italic()
      }
    }
  }
}

extension SessionPhase {
  fileprivate var statusLabel: String {
    switch self {
    case .idle: "待機中"
    case .recording: "録音中"
    case .recognizing: "認識中"
    case .refining: "整形中"
    case .inserting: "保存中"
    case .error: "完了できませんでした"
    }
  }
}

extension SharedResultRescueState {
  fileprivate var label: String {
    switch self {
    case .notInserted: "未挿入"
    case .insertionUnknown: "挿入されたか不明（入力欄を確認してください）"
    case .inserting: "キーボードが挿入中"
    case .inserted: "挿入済み・コピー済み"
    case .expired: "期限切れ"
    case .invalidTimestamp: "端末の時刻を確認してください"
    }
  }

  fileprivate var text: String? {
    switch self {
    case .notInserted(let text), .insertionUnknown(let text): text
    case .inserting, .inserted, .expired, .invalidTimestamp: nil
    }
  }
}
