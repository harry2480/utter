// #233 の待機セッション方式の試作（キーボード側）。本番コードではない。
// キーボードはマイク・STT を持たない（iAC-08）。合図を App Group に書き、本体アプリが保存した共有結果を挿入するだけ。
// 挿入は utter 本体と同じ SharedResultInsertionCoordinator（ready → inserting → consumed）で行い、二重挿入を防ぐ。

import UIKit
import UtterCore
import UtterPersistence

@MainActor
final class VoiceKeyboardPanel {
  private enum State {
    case idle
    case recording(SessionID)
    case waiting(SessionID, since: Date)
    case preview(SessionID, text: String)
  }

  let view = UIStackView()
  private let micButton = UIButton(configuration: .filled())
  private let insertButton = UIButton(configuration: .gray())
  private let autoInsertSwitch = UISwitch()
  private let label = UILabel()
  private weak var controller: UIInputViewController?
  private var state: State = .idle
  private var waitTask: Task<Void, Never>?
  private var observers: [any NSObjectProtocol] = []

  private static let autoInsertKey = "voiceAutoInsert"
  /// 停止から結果を待つ上限
  private static let resultTimeout: TimeInterval = 20

  init(controller: UIInputViewController) {
    self.controller = controller
    VoiceSignal.startForwarding()
    autoInsertSwitch.isOn =
      UserDefaults.standard.object(forKey: Self.autoInsertKey) as? Bool ?? true
    autoInsertSwitch.addTarget(self, action: #selector(autoInsertChanged), for: .valueChanged)
    micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
    insertButton.configuration?.title = "挿入"
    insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)
    label.numberOfLines = 2
    label.font = .systemFont(ofSize: 12)

    let autoLabel = UILabel()
    autoLabel.text = "自動挿入"
    autoLabel.font = .systemFont(ofSize: 11)
    let autoStack = UIStackView(arrangedSubviews: [autoLabel, autoInsertSwitch])
    autoStack.axis = .vertical
    autoStack.alignment = .center
    view.addArrangedSubview(micButton)
    view.addArrangedSubview(label)
    view.addArrangedSubview(insertButton)
    view.addArrangedSubview(autoStack)
    view.axis = .horizontal
    view.spacing = 6
    view.alignment = .center
    micButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)

    observers.append(
      NotificationCenter.default.addObserver(
        forName: VoiceSignal.hostState.localName, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.hostStateChanged() }
      })
    render()
  }

  // MARK: 操作

  @objc private func micTapped() {
    switch state {
    case .idle, .preview:
      start()
    case .recording(let sessionID):
      stop(sessionID)
    case .waiting:
      break
    }
  }

  @objc private func insertTapped() {
    guard case .preview(let sessionID, _) = state else { return }
    Task { await insert(sessionID) }
  }

  @objc private func autoInsertChanged() {
    UserDefaults.standard.set(autoInsertSwitch.isOn, forKey: Self.autoInsertKey)
  }

  private func start() {
    let sessionID = SessionID()
    VoiceStore.appendEvent(source: "keyboard", name: "tapStart", sessionID: sessionID)
    guard let host = VoiceStore.read(VoiceHostState.self, from: VoiceStore.hostStateFileName),
      host.isAlive(at: Date())
    else {
      show("待機していません。本体アプリ「utter Probe」で「待機を始める」を押してください")
      return
    }
    guard send(.start, sessionID: sessionID) else { return }
    state = .recording(sessionID)
    render()
  }

  private func stop(_ sessionID: SessionID) {
    VoiceStore.appendEvent(source: "keyboard", name: "tapStop", sessionID: sessionID)
    guard send(.stop, sessionID: sessionID) else {
      state = .idle
      render()
      return
    }
    state = .waiting(sessionID, since: Date())
    render()
    // Darwin 通知を取りこぼしても進むよう、上限まで状態を読み直す
    waitTask?.cancel()
    waitTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        self?.hostStateChanged()
      }
    }
  }

  /// 合図を書いて知らせる。書けなければ（フルアクセスなしなど）理由を出して false
  private func send(_ action: VoiceCommand.Action, sessionID: SessionID) -> Bool {
    let command = VoiceCommand(
      sequence: Int64(Date().timeIntervalSince1970 * 1000), action: action, sessionID: sessionID,
      issuedAt: Date())
    do {
      try VoiceStore.write(command, to: VoiceStore.commandFileName)
    } catch {
      let hasFullAccess = controller?.hasFullAccess ?? false
      show("合図を書けません（フルアクセス: \(hasFullAccess ? "あり" : "なし")）")
      return false
    }
    VoiceSignal.command.post()
    return true
  }

  // MARK: 本体アプリの状態

  private func hostStateChanged() {
    guard let host = VoiceStore.read(VoiceHostState.self, from: VoiceStore.hostStateFileName) else {
      return
    }
    switch state {
    case .recording(let sessionID):
      if host.sessionID == sessionID, host.phase == .failed { fail(host) }
      if host.sessionID == sessionID, host.phase == .recording { render(hostRecording: true) }
    case .waiting(let sessionID, let since):
      if host.sessionID == sessionID, host.phase == .done {
        waitTask?.cancel()
        Task { await resultReady(sessionID) }
      } else if host.sessionID == sessionID, host.phase == .failed {
        fail(host)
      } else if Date().timeIntervalSince(since) > Self.resultTimeout {
        waitTask?.cancel()
        VoiceStore.appendEvent(source: "keyboard", name: "resultTimeout", sessionID: sessionID)
        state = .idle
        show("結果が届きません。本体アプリで確認してください")
      }
    case .idle, .preview:
      break
    }
  }

  private func fail(_ host: VoiceHostState) {
    waitTask?.cancel()
    state = .idle
    show("失敗: \(host.detail ?? host.phase.rawValue)")
  }

  private func resultReady(_ sessionID: SessionID) async {
    guard case .waiting = state else { return }
    VoiceStore.appendEvent(source: "keyboard", name: "resultSeen", sessionID: sessionID)
    if autoInsertSwitch.isOn {
      await insert(sessionID)
      return
    }
    guard let store = VoiceStore.resultStore(), let controller else { return }
    let coordinator = SharedResultInsertionCoordinator(
      store: store, inserter: VoiceTextInserter(controller: controller))
    if case .insertable(let text, _) = try? await coordinator.preview(sessionID: sessionID) {
      state = .preview(sessionID, text: text)
      render()
    } else {
      state = .idle
      show("結果を読めません")
    }
  }

  private func insert(_ sessionID: SessionID) async {
    guard let store = VoiceStore.resultStore(), let controller else { return }
    let coordinator = SharedResultInsertionCoordinator(
      store: store, inserter: VoiceTextInserter(controller: controller))
    let outcome = try? await coordinator.insert(sessionID: sessionID)
    VoiceStore.appendEvent(
      source: "keyboard", name: "inserted", sessionID: sessionID,
      detail: outcome.map { String(describing: $0) } ?? "error")
    state = .idle
    switch outcome {
    case .inserted: show("挿入しました")
    case .insertionUnknown: show("挿入できたか確認できません")
    default: show("挿入できません（\(outcome.map { String(describing: $0) } ?? "エラー")）")
    }
  }

  // MARK: 表示

  private func show(_ message: String) {
    label.text = message
    render()
  }

  private func render(hostRecording: Bool = false) {
    var configuration = micButton.configuration ?? .filled()
    switch state {
    case .idle:
      configuration.title = "🎤"
      configuration.baseBackgroundColor = .systemBlue
      insertButton.isHidden = true
    case .recording:
      configuration.title = "■"
      configuration.baseBackgroundColor = .systemRed
      label.text = hostRecording ? "録音中…もう一度タップで終了" : "録音を始めています…"
      insertButton.isHidden = true
    case .waiting:
      configuration.title = "…"
      configuration.baseBackgroundColor = .systemGray
      label.text = "Thinking…"
      insertButton.isHidden = true
    case .preview(_, let text):
      configuration.title = "🎤"
      configuration.baseBackgroundColor = .systemBlue
      label.text = text
      insertButton.isHidden = false
    }
    micButton.configuration = configuration
  }
}

/// `UITextDocumentProxy` へ挿入する（utter 本体の TextDocumentProxyInserter を簡略にしたもの）
@MainActor
final class VoiceTextInserter: SharedResultTextInserter {
  private weak var controller: UIInputViewController?

  init(controller: UIInputViewController) {
    self.controller = controller
  }

  func insert(_ text: String) async -> SharedResultInsertionConfirmation {
    guard let proxy = controller?.textDocumentProxy else { return .unknown }
    let before = proxy.documentContextBeforeInput
    proxy.insertText(text)
    return SharedResultInsertionConfirmation(
      insertedText: text, contextBefore: before, contextAfter: proxy.documentContextBeforeInput)
  }
}
