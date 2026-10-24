import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// 入力履歴のウインドウ（7章, AC-12）。状態と操作は `InputHistoryScreenModel` が持ち、ここは表示だけを行う。
///
/// 開くたびに設定と履歴を読み込み、閉じたら一覧の本文を手放す。
struct InputHistoryWindow: View {
  static let id = "inputHistory"

  let database: AppDatabaseProvider
  let settingsStore: AppSettingsStore
  @State private var model: InputHistoryScreenModel?
  @State private var openFailed = false

  var body: some View {
    Group {
      if let model {
        InputHistoryContent(model: model)
      } else if openFailed {
        ContentUnavailableView(
          "履歴を開けませんでした", systemImage: "exclamationmark.triangle",
          description: Text("ウインドウを閉じて、もう一度開いてください。"))
      } else {
        ProgressView()
      }
    }
    .frame(minWidth: 420, minHeight: 360)
    .task {
      do {
        let historyStore = InputHistoryStore(database: try await database.database())
        // 開いている間にウインドウを閉じたら、閉じた画面に本文を読み込まない
        guard !Task.isCancelled else { return }
        let model = InputHistoryScreenModel(
          settingsStore: settingsStore, historyStore: historyStore)
        self.model = model
        await model.load()
      } catch {
        openFailed = true
      }
    }
    .onDisappear {
      model?.close()
      model = nil
      openFailed = false
    }
  }
}

/// 有効・無効に応じた画面
private struct InputHistoryContent: View {
  let model: InputHistoryScreenModel
  @State private var confirmsDisable = false
  @State private var confirmsRemoveAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch model.phase {
      case .closed:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .disabled:
        optIn
      case .enabled:
        header
        list
      }
      if let failure = model.failure {
        Label(failure.message(phase: model.phase), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
    .padding()
    .disabled(model.isBusy)
    .confirmationDialog(
      "履歴を無効にしますか？", isPresented: $confirmsDisable, titleVisibility: .visible
    ) {
      Button("無効にして履歴を削除", role: .destructive) {
        Task { await model.disable() }
      }
    } message: {
      Text("保存済みの履歴はすべて削除され、元に戻せません。")
    }
    .confirmationDialog(
      "履歴をすべて削除しますか？", isPresented: $confirmsRemoveAll, titleVisibility: .visible
    ) {
      Button("すべて削除", role: .destructive) {
        Task { await model.removeAll() }
      }
    } message: {
      Text("削除した履歴は元に戻せません。履歴の記録は有効のままです。")
    }
  }

  /// 無効のときの説明と、明示的に有効にする操作
  private var optIn: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("入力履歴は無効です").font(.title2)
      Text(
        """
        有効にすると、挿入した文章と日時をこの Mac の中だけに保存し、ここで見返し・コピー・削除できます。\
        履歴は外部へ送信しません。
        パスワード欄・機密アプリ・除外したアプリへの入力と、入力先を判定できないときは保存しません。
        無効に戻すと、保存済みの履歴はすべて削除します。
        """
      )
      .fixedSize(horizontal: false, vertical: true)
      Button("履歴を有効にする") {
        Task { await model.enable() }
      }
      Spacer()
    }
  }

  private var header: some View {
    HStack {
      Text("入力履歴は有効です").font(.headline)
      Spacer()
      Button("再読み込み") {
        Task { await model.load() }
      }
      Button("すべて削除…", role: .destructive) { confirmsRemoveAll = true }
        .disabled(model.entries.isEmpty)
      Button("履歴を無効にする…") { confirmsDisable = true }
    }
  }

  @ViewBuilder private var list: some View {
    if model.entries.isEmpty {
      ContentUnavailableView("履歴はありません", systemImage: "clock")
    } else {
      List(model.entries, id: \.sessionID) { entry in
        InputHistoryRow(entry: entry) {
          Task { await model.remove(session: entry.sessionID) }
        }
      }
    }
  }
}

/// 履歴の1件
private struct InputHistoryRow: View {
  let entry: InputHistoryEntry
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(entry.text)
          .lineLimit(4)
          .textSelection(.enabled)
      }
      Spacer()
      Button("コピー") { HistoryPasteboard.copy(entry.text) }
      Button("削除", role: .destructive, action: remove)
    }
    .padding(.vertical, 2)
  }
}

/// 履歴の本文をクリップボードへコピーする
private enum HistoryPasteboard {
  /// クリップボード管理アプリに機密として扱わせる印（nspasteboard.org の慣例）。
  /// 履歴の本文は利用者の入力そのものなので、管理アプリの履歴に残りにくくする
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  @MainActor static func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setData(Data(), forType: concealedType)
  }
}

extension InputHistoryScreenFailure {
  /// 画面に出す文言。内部のエラーの詳細は出さない
  fileprivate func message(phase: InputHistoryScreenModel.Phase) -> String {
    switch self {
    case .settingsNotSaved:
      "設定を保存できませんでした。もう一度お試しください。"
    case .historyNotLoaded:
      "履歴を読み込めませんでした。もう一度お試しください。"
    case .historyNotRemoved where phase == .disabled:
      // 無効のまま開くと、残った履歴を削除し直す（InputHistoryScreenModel.load）
      "履歴を削除できませんでした。ウインドウを開き直すと、もう一度削除します。"
    case .historyNotRemoved:
      "履歴を削除できませんでした。もう一度お試しください。"
    }
  }
}
