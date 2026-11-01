// Phase i0 検証用（#56, #53）のキーボード拡張。本番コードではない。
// 拡張はマイク・STT モデル・クラウド認証情報を持たない（iAC-08）。外部への送信もしない。
// 本体アプリを開く操作は公開 API だけを試す。responder chain をたどって UIApplication の openURL を呼ぶ等の
// 抜け道は使わない（iOS-03）。開けなければ「開けない」と表示し、手動切替を案内する。
// ホストアプリの入力欄の本文（documentContextBeforeInput 等）は、音声入力の挿入の確認（VoiceTextInserter）にだけ使う。
// 本文は保存・記録せず、計測の記録に残すのは文字数だけ。

import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
  private let statusLabel = UILabel()
  private let scrollView = UIScrollView()
  private var globeButton: UIButton?
  private var lastReadPayload: ProbePayload?
  private var readLines: [String] = ["読み込み: 未実行"]
  private var writeLine = "拡張からの書き込み: 未実行"
  private var insertLine = "挿入: 未実行"
  private var openLine = "本体アプリを開く: 未実行"
  private var insertCount = 0
  private lazy var voicePanel = VoiceKeyboardPanel(controller: self)
  /// このプロセスで何代目のキーボードか（計測の記録用）
  private static var instanceCount = 0
  let instanceNumber: Int = {
    MainActor.assumeIsolated {
      KeyboardViewController.instanceCount += 1
      return KeyboardViewController.instanceCount
    }
  }()
  private weak var debugToggle: UIView?
  private weak var openContextButton: UIView?
  private weak var openSwiftUIView: UIView?
  private let debugStack = UIStackView()

  override func viewDidLoad() {
    super.viewDidLoad()
    VoiceStore.appendEvent(
      source: "keyboard", name: "viewDidLoad", detail: "インスタンス\(instanceNumber)")
    buildLayout()
    refreshStatus()
    voicePanel.onRender = { [weak self] in self?.writePresence(visible: true) }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    VoiceStore.appendEvent(
      source: "keyboard", name: "viewDidAppear", detail: "インスタンス\(instanceNumber)")
    writePresence(visible: true)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    writePresence(visible: true)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    VoiceStore.appendEvent(
      source: "keyboard", name: "viewWillDisappear", detail: "インスタンス\(instanceNumber)")
    voicePanel.keyboardWillDisappear()
    writePresence(visible: false)
  }

  /// UI テスト用に、ボタンの位置と案内を App Group に書く（XCUITest からキーボードの中は見えないため）
  private func writePresence(visible: Bool) {
    guard let root = inputView else { return }
    var targets = voicePanel.testTargets
    targets["debug.toggle"] = debugToggle
    targets["debug.openContext"] = openContextButton
    targets["debug.openSwiftUI"] = openSwiftUIView
    var frames: [String: VoiceKeyboardPresence.Frame] = [:]
    for (identifier, view) in targets {
      guard view.window != nil, !Self.isHidden(view, below: root) else { continue }
      frames[identifier] = Self.frame(view.convert(view.bounds, to: root))
    }
    let screenRect = root.window.map { window in
      window.convert(root.convert(root.bounds, to: window), to: window.screen.coordinateSpace)
    }
    let presence = VoiceKeyboardPresence(
      at: Date(), visible: visible, rootSize: Self.frame(root.bounds),
      rootInScreen: screenRect.map(Self.frame), frames: frames, hint: voicePanel.hintText,
      autoInsert: voicePanel.autoInsert, openLine: openLine)
    try? VoiceStore.write(presence, to: VoiceKeyboardPresence.fileName)
  }

  private static func isHidden(_ view: UIView, below root: UIView) -> Bool {
    var current: UIView? = view
    while let candidate = current, candidate !== root {
      if candidate.isHidden || candidate.alpha == 0 { return true }
      current = candidate.superview
    }
    return false
  }

  private static func frame(_ rect: CGRect) -> VoiceKeyboardPresence.Frame {
    VoiceKeyboardPresence.Frame(
      x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshStatus()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    globeButton?.isHidden = !needsInputModeSwitchKey
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    refreshStatus()
  }

  // MARK: 画面

  private func buildLayout() {
    guard let root = inputView else { return }
    // 幅は OS に任せる（false にすると幅が決まらず、中身の最小の幅に縮む）。高さだけを指定する
    let height = root.heightAnchor.constraint(equalToConstant: 300)
    height.priority = .defaultHigh
    height.isActive = true

    statusLabel.numberOfLines = 0
    statusLabel.accessibilityIdentifier = "debug.status"
    statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(statusLabel)

    let globe = makeButton(title: "🌐", action: nil)
    globe.addTarget(
      self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    globeButton = globe

    let firstRow = makeRow([
      makeButton(title: "読む", action: #selector(readTapped)),
      makeButton(title: "書く", action: #selector(writeTapped)),
      makeButton(title: "挿入", action: #selector(insertTapped)),
      makeButton(title: "更新", action: #selector(refreshTapped)),
    ])

    let openButtonHost = UIHostingController(
      rootView: OpenURLProbeButton { [weak self] accepted in
        self?.openLine =
          "本体アプリを開く（SwiftUI openURL）: \(accepted ? "受理された" : "拒否された")"
          + " \(ProbeTime.format(Date()))"
        self?.refreshStatus()
      })
    addChild(openButtonHost)
    openButtonHost.view.backgroundColor = .clear
    openButtonHost.didMove(toParent: self)

    let openContext = makeButton(
      title: "開く(ctx)", action: #selector(openViaExtensionContextTapped),
      identifier: "debug.openContext")
    openContextButton = openContext
    openSwiftUIView = openButtonHost.view
    let secondRow = makeRow([openContext, openButtonHost.view])

    // 検証用の表示と操作（#56・#53）。「検証」を押したときだけ出す
    debugStack.addArrangedSubview(scrollView)
    debugStack.addArrangedSubview(firstRow)
    debugStack.addArrangedSubview(secondRow)
    debugStack.axis = .vertical
    debugStack.spacing = 6
    // 検証の表示の開閉は覚えておく（アプリを切り替えるとキーボードが作り直されるため）
    debugStack.isHidden = !UserDefaults.standard.bool(forKey: "debugShown")
    voicePanel.view.isHidden = !debugStack.isHidden

    // 下の段: 地球儀（必要なときだけ）・空白・削除・改行・検証
    let space = makeButton(title: "空白", action: #selector(spaceTapped))
    let debugButton = makeButton(
      title: "検証", action: #selector(debugTapped), identifier: "debug.toggle")
    debugToggle = debugButton
    let bottomRow = UIStackView(arrangedSubviews: [
      globe, space, makeButton(title: "⌫", action: #selector(deleteTapped)),
      makeButton(title: "改行", action: #selector(returnTapped)),
      debugButton,
    ])
    bottomRow.axis = .horizontal
    bottomRow.spacing = 6
    bottomRow.distribution = .fill
    space.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for button in bottomRow.arrangedSubviews where button !== space {
      button.setContentHuggingPriority(.required, for: .horizontal)
    }

    let stack = UIStackView(arrangedSubviews: [voicePanel.view, debugStack, bottomRow])
    stack.axis = .vertical
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -6),
      firstRow.heightAnchor.constraint(equalToConstant: 40),
      secondRow.heightAnchor.constraint(equalToConstant: 40),
      bottomRow.heightAnchor.constraint(equalToConstant: 44),
      statusLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      statusLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      statusLabel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])
  }

  private func makeButton(title: String, action: Selector?, identifier: String? = nil) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.title = title
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 4, bottom: 4, trailing: 4)
    let button = UIButton(configuration: configuration)
    if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    button.accessibilityIdentifier = identifier
    return button
  }

  private func makeRow(_ views: [UIView]) -> UIStackView {
    let row = UIStackView(arrangedSubviews: views)
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.spacing = 4
    return row
  }

  // MARK: 状態表示

  private func refreshStatus() {
    let proxy = textDocumentProxy
    var lines: [String] = []
    lines.append("hasFullAccess: \(hasFullAccess)")
    lines.append("needsInputModeSwitchKey: \(needsInputModeSwitchKey)")
    lines.append("App Group: \(ProbeStore.containerStatus)")
    lines.append(
      "入力欄 keyboardType: \(proxy.keyboardType.map(Self.describe(keyboardType:)) ?? "nil")")
    lines.append(
      "入力欄 isSecureTextEntry: \(proxy.isSecureTextEntry.map { String($0) } ?? "nil")")
    lines.append("入力欄 textContentType: \(proxy.textContentType?.rawValue ?? "nil")")
    lines.append("--")
    lines.append(contentsOf: readLines)
    lines.append(writeLine)
    lines.append(insertLine)
    lines.append(openLine)
    lines.append("--")
    lines.append("本体アプリを開けない場合: ホームインジケータを左右にスワイプするか、")
    lines.append("App スイッチャーで「utter Probe」を選んで手動で切り替える")
    statusLabel.text = lines.joined(separator: "\n")
    writePresence(visible: true)
  }

  private static func describe(keyboardType: UIKeyboardType) -> String {
    let name: String
    switch keyboardType {
    case .default: name = "default"
    case .asciiCapable: name = "asciiCapable"
    case .numbersAndPunctuation: name = "numbersAndPunctuation"
    case .URL: name = "URL"
    case .numberPad: name = "numberPad"
    case .phonePad: name = "phonePad"
    case .namePhonePad: name = "namePhonePad"
    case .emailAddress: name = "emailAddress"
    case .decimalPad: name = "decimalPad"
    case .twitter: name = "twitter"
    case .webSearch: name = "webSearch"
    case .asciiCapableNumberPad: name = "asciiCapableNumberPad"
    @unknown default: name = "unknown"
    }
    return "\(name)(\(keyboardType.rawValue))"
  }

  // MARK: 操作

  @objc private func readTapped() {
    var lines: [String] = []
    var latest: ProbePayload?
    for protection in ProbeProtection.allCases {
      let (outcome, payload) = ProbeStore.read(fileName: protection.resultFileName)
      lines.append(
        "読む \(protection.shortLabel): \(outcome.succeeded ? "OK" : "NG") \(outcome.summary)")
      if let detail = outcome.detail { lines.append("  \(detail)") }
      if let payload, payload.writtenAt > (latest?.writtenAt ?? .distantPast) { latest = payload }
    }
    lines.insert("読み込み \(ProbeTime.format(Date()))（hasFullAccess=\(hasFullAccess)）", at: 0)
    readLines = lines
    lastReadPayload = latest
    refreshStatus()
  }

  @objc private func writeTapped() {
    let outcome = ProbeStore.write(
      fileName: ProbeConfig.keyboardWriteFileName, text: ProbeConfig.dummyText,
      protection: .completeUntilFirstUserAuthentication, writer: "keyboard")
    writeLine =
      "拡張からの書き込み（hasFullAccess=\(hasFullAccess)）: \(outcome.succeeded ? "OK" : "NG") "
      + "\(outcome.summary)\(outcome.detail.map { " [\($0)]" } ?? "")"
    refreshStatus()
  }

  @objc private func insertTapped() {
    // セキュア入力欄・電話番号欄には挿入しない（iAC-06）。OS が標準キーボードへ切り替えなかった場合の保険。
    let proxy = textDocumentProxy
    let isPhoneField = proxy.keyboardType == .phonePad || proxy.keyboardType == .namePhonePad
    if proxy.isSecureTextEntry == true || isPhoneField {
      insertLine = "挿入 \(ProbeTime.format(Date())): セキュア入力欄・電話番号欄のため挿入しない"
      refreshStatus()
      return
    }
    let source: String
    let text: String
    if let payload = lastReadPayload {
      text = payload.text
      source = "共有結果（\(ProbeTime.format(payload.writtenAt)) 書き込み分）"
    } else {
      text = ProbeConfig.dummyText
      source = "固定のダミー（共有結果を読めていない）"
    }
    textDocumentProxy.insertText(text)
    insertCount += 1
    insertLine = "挿入 \(insertCount) 回目 \(ProbeTime.format(Date())): \(source)"
    refreshStatus()
  }

  @objc private func refreshTapped() {
    refreshStatus()
  }

  @objc private func deleteTapped() {
    textDocumentProxy.deleteBackward()
  }

  @objc private func spaceTapped() {
    textDocumentProxy.insertText(" ")
  }

  @objc private func debugTapped() {
    debugStack.isHidden.toggle()
    voicePanel.view.isHidden = !debugStack.isHidden
    UserDefaults.standard.set(!debugStack.isHidden, forKey: "debugShown")
    refreshStatus()
    view.layoutIfNeeded()
    writePresence(visible: true)
  }

  @objc private func returnTapped() {
    textDocumentProxy.insertText("\n")
  }

  /// 公開 API の候補 1: NSExtensionContext.open。Today 拡張向けで、キーボードでは false が返る想定。
  @objc private func openViaExtensionContextTapped() {
    guard let url = ProbeConfig.openAppURL(via: "extensionContext") else { return }
    guard let context = extensionContext else {
      openLine = "本体アプリを開く（extensionContext.open）: extensionContext が nil"
      refreshStatus()
      return
    }
    context.open(url) { [weak self] success in
      Task { @MainActor in
        self?.openLine =
          "本体アプリを開く（extensionContext.open）: \(success ? "成功が返った" : "失敗が返った")"
          + " \(ProbeTime.format(Date()))"
        self?.refreshStatus()
      }
    }
  }
}

/// 公開 API の候補 2: SwiftUI の OpenURLAction。拡張内で受理されるかを確かめる。
private struct OpenURLProbeButton: View {
  @Environment(\.openURL) private var openURL
  let onResult: @MainActor (Bool) -> Void

  var body: some View {
    Button("開く(UI)") {
      guard let url = ProbeConfig.openAppURL(via: "swiftUIOpenURL") else { return }
      openURL(url) { accepted in
        Task { @MainActor in onResult(accepted) }
      }
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("debug.openSwiftUI")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
