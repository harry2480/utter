import SwiftUI
import UtterCore
import UtterPersistence
import UtteriOSKit

/// 録音の開始・停止・状態と、結果の確認・コピー（iOS-04, iOS-07）。進行の判断は `RecordingSessionModel` が持つ。
struct RecordingView: View {
  let model: RecordingSessionModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        recordingSection
        resultsSection
      }
      .navigationTitle("utter")
      .refreshable { await model.refreshResults() }
    }
    .task { await model.prepareResults() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await model.prepareResults() }
      }
    }
    .onChange(of: model.isRecording) { _, isRecording in
      // 話している間に自動ロックで録音が止まらないようにする。録音していないときは元に戻す
      UIApplication.shared.isIdleTimerDisabled = isRecording
    }
  }

  private var recordingSection: some View {
    Section {
      Button {
        Task { await model.toggleRecording() }
      } label: {
        Label(
          model.isRecording ? "録音を止める" : "録音を始める",
          systemImage: model.isRecording ? "stop.circle.fill" : "mic.circle.fill"
        )
        .font(.title2)
      }
      .disabled(!canToggle)

      Text(model.phase.statusLabel)
        .foregroundStyle(.secondary)

      if canCancel {
        Button("キャンセル", role: .cancel) { model.cancel() }
      }
      if let stopNotice = model.stopNotice {
        Text(stopNotice.message)
      }
      if let failure = model.failure {
        Text(failure.message)
          .foregroundStyle(.red)
        Button("閉じる") { model.dismissError() }
      }
      if let unsavedText = model.unsavedText {
        Text(unsavedText)
          .textSelection(.enabled)
        Button("コピー") { Task { await model.copyUnsavedText() } }
      }
    }
  }

  private var resultsSection: some View {
    Section {
      Text(model.sharing.message)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if let copyNotice = model.copyNotice {
        Text(copyNotice.message)
      }
      if model.isRescueListUnavailable {
        Text("保存した結果を読み込めませんでした。端末のロック中なら、解除してから引き下げて読み直してください。")
      }
      if model.rescueList.unavailableCount > 0 {
        Text("端末のロック中のため読めない結果が \(model.rescueList.unavailableCount) 件あります。")
      }
      if model.rescueList.items.isEmpty {
        Text("保存した結果はありません。")
          .foregroundStyle(.secondary)
      }
      ForEach(model.rescueList.items, id: \.sessionID) { item in
        ResultRow(item: item) { Task { await model.copyResult(item.sessionID) } }
      }
    } header: {
      Text("結果")
    }
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

/// 救済画面の1件。本文はコピーしてよい状態のときだけ出す（iOS-07, iOS-IPC-05）
private struct ResultRow: View {
  let item: SharedResultRescueItem
  let copy: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(item.createdAt, style: .time)
        Spacer()
        Text(item.state.label)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if let text = item.state.text {
        Text(text)
          .textSelection(.enabled)
        Button("コピー", action: copy)
          .buttonStyle(.borderless)
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
