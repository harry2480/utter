import AppKit
import Observation
import SwiftUI
import UtterCore

/// 設定画面の「ショートカット」の行（REC-01, REC-02, AC-14）。現在の割当と、「記録」「解除」のボタンを出す。
///
/// 録音ショートカットと Edit Mode のショートカットで共有する。どの項目を編集するかは `shortcut` で選ぶ。
/// 記録した組み合わせは `SettingsForm` の `shortcut` の項目に入れるだけで、ほかの項目と同じ「保存」で保存する。
/// 記録中だけ設定ウインドウのキー入力を受け取り、画面が消えたとき（ウインドウを閉じた・タブを移った）、
/// 設定ウインドウがキーウインドウでなくなったとき（辞書などほかのウインドウに移った）、
/// アプリが前面でなくなったときに記録をやめる。
struct RecordingShortcutRow: View {
  @Bindable var model: SettingsModel
  /// 行の見出し
  var title = "ショートカット"
  /// 編集する項目
  var shortcut: WritableKeyPath<SettingsForm, KeyCombination?> = \.recordingShortcut
  /// この行の下に出す保存時の問題
  var issueKinds: Set<SettingsIssue> = [.recordingShortcut]
  /// 行の下に出す説明
  var caption =
    "Command・Option・Control のいずれかを含む組み合わせか、F1〜F20 を割り当てられます。変更は「保存」で反映します。"
  @State private var recording = ShortcutRecordingMonitor()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title) {
        HStack {
          Text(shortcutText)
            .foregroundStyle(recording.isRecording ? Color.secondary : Color.primary)
          if recording.isRecording {
            Button("取り消す") { recording.stop() }
          } else {
            Button("記録") {
              // ボタンを押した直後のキーウインドウが設定ウインドウ
              recording.start(
                systemShortcuts: SystemShortcuts.loadEnabledBindings(), in: NSApp.keyWindow
              ) {
                model.form[keyPath: shortcut] = $0
              }
            }
            Button("解除") { model.form[keyPath: shortcut] = nil }
              .disabled(model.form[keyPath: shortcut] == nil)
          }
        }
      }
      if let issue = recording.issue {
        Text(issue.message).font(.caption).foregroundStyle(.red)
      }
      ForEach(model.issues(in: issueKinds), id: \.self) { issue in
        Text(issue.message).font(.caption).foregroundStyle(.red)
      }
      Text(caption)
        .font(.caption).foregroundStyle(.secondary)
    }
    // ウインドウを閉じた・タブを移ったときに、記録中のモニターを外す
    .onDisappear { recording.stop() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
    ) { _ in recording.stop() }
  }

  private var shortcutText: String {
    if recording.isRecording {
      return ShortcutRecorder.promptText
    }
    return ShortcutRecorder.displayText(for: model.form[keyPath: shortcut])
  }
}

/// 録音ショートカットの記録中だけ、`NSEvent` のローカルモニターでキー入力を受け取る（REC-01）。
///
/// 解釈は `ShortcutRecorder`（純粋な値型）が行い、ここはモニターの付け外しと結果の受け渡しだけを持つ。
/// 記録中の設定ウインドウでの通常のキーの押下は utter のほかの操作（⌘W・Return での保存など）に渡さない。
/// ほかのウインドウ（辞書の編集など）へのキー入力は奪わず、記録をやめてそのまま渡す。
/// ローカルモニターは utter が前面のときのキー入力だけを受け取り、ほかのアプリの入力は受け取らない。
/// 入力されたキーはログに出さない。
@MainActor
@Observable
final class ShortcutRecordingMonitor {
  private(set) var isRecording = false
  /// 直前のキー入力を割り当てられなかった理由。記録の開始・終了で消える
  private(set) var issue: ShortcutRecordingIssue?
  @ObservationIgnored private var recorder: ShortcutRecorder?
  @ObservationIgnored private var monitor: Any?
  @ObservationIgnored private var onRecord: ((KeyCombination) -> Void)?
  /// 記録を始めたウインドウの番号。`nil` ならウインドウで絞らない
  @ObservationIgnored private var windowNumber: Int?
  /// 記録を始めたウインドウがキーウインドウでなくなった通知の登録
  @ObservationIgnored private var resignKeyObserver: (any NSObjectProtocol)?

  /// 記録を始める。割り当てられる組み合わせを受け取ったら `onRecord` を呼んで記録を終える。
  /// - Parameter window: 記録を受け付けるウインドウ（設定ウインドウ）。ほかのウインドウへの入力は奪わない
  func start(
    systemShortcuts: [ShortcutBinding], in window: NSWindow?,
    onRecord: @escaping (KeyCombination) -> Void
  ) {
    stop()
    recorder = ShortcutRecorder(systemShortcuts: systemShortcuts)
    self.onRecord = onRecord
    windowNumber = window?.windowNumber
    isRecording = true
    if let window {
      resignKeyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.stop() }
      }
    }
    let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
    monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      let eventWindowNumber = event.windowNumber
      let isOtherWindow = MainActor.assumeIsolated {
        self?.isOtherWindow(eventWindowNumber) ?? false
      }
      if isOtherWindow {
        // ほかのウインドウへの入力は奪わない。記録はやめる
        MainActor.assumeIsolated { self?.stop() }
        return event
      }
      let isKeyDown = event.type == .keyDown
      let modifiers = ShortcutRecorder.modifiers(from: event.modifierFlags)
      // キーリピートは最初の押下の続きのため渡さない（押下と同じく、ほかの操作にも渡さない）
      let recorderEvent: ShortcutRecorder.Event?
      if !isKeyDown {
        recorderEvent = .flagsChanged(modifiers: modifiers)
      } else if event.isARepeat {
        recorderEvent = nil
      } else {
        recorderEvent = .keyDown(keyCode: event.keyCode, modifiers: modifiers)
      }
      if let recorderEvent {
        // ローカルモニターはメインスレッドで呼ばれる
        MainActor.assumeIsolated { self?.handle(recorderEvent) }
      }
      // 修飾キーの変化はそのまま渡す（押したままの表示などを崩さない）
      return isKeyDown ? nil : event
    }
  }

  /// 記録をやめ、モニターを外す。記録していなければ何もしない
  func stop() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    if let resignKeyObserver {
      NotificationCenter.default.removeObserver(resignKeyObserver)
    }
    resignKeyObserver = nil
    windowNumber = nil
    recorder = nil
    onRecord = nil
    isRecording = false
    issue = nil
  }

  isolated deinit {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    if let resignKeyObserver {
      NotificationCenter.default.removeObserver(resignKeyObserver)
    }
  }

  /// 記録を始めたウインドウとは別のウインドウへの入力か
  private func isOtherWindow(_ number: Int) -> Bool {
    guard let windowNumber else { return false }
    return number != windowNumber
  }

  private func handle(_ event: ShortcutRecorder.Event) {
    guard var recorder else { return }
    let outcome = recorder.handle(event)
    self.recorder = recorder
    guard let outcome else { return }
    switch outcome {
    case .recorded(let combination):
      let onRecord = self.onRecord
      stop()
      onRecord?(combination)
    case .cancelled:
      stop()
    case .rejected(let reason):
      issue = reason
    }
  }
}
