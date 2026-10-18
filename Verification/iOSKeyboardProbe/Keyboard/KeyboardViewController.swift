// Phase i0 検証用（#56, #53）のキーボード拡張。本番コードではない。
// 拡張はマイク・STT モデル・クラウド認証情報を持たない（iAC-08）。外部への送信もしない。
// 本体アプリを開く操作は公開 API だけを試す。responder chain をたどって UIApplication の openURL を呼ぶ等の
// 抜け道は使わない（iOS-03）。開けなければ「開けない」と表示し、手動切替を案内する。
// ホストアプリの入力欄の本文（documentContextBeforeInput 等）は読まない。

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

  override func viewDidLoad() {
    super.viewDidLoad()
    buildLayout()
    refreshStatus()
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
    root.translatesAutoresizingMaskIntoConstraints = false
    let height = root.heightAnchor.constraint(equalToConstant: 320)
    height.priority = .defaultHigh
    height.isActive = true

    statusLabel.numberOfLines = 0
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

    let secondRow = makeRow([
      globe,
      makeButton(title: "開く(ctx)", action: #selector(openViaExtensionContextTapped)),
      openButtonHost.view,
      makeButton(title: "⌫", action: #selector(deleteTapped)),
      makeButton(title: "改行", action: #selector(returnTapped)),
    ])

    let stack = UIStackView(arrangedSubviews: [scrollView, firstRow, secondRow])
    stack.axis = .vertical
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -6),
      firstRow.heightAnchor.constraint(equalToConstant: 40),
      secondRow.heightAnchor.constraint(equalToConstant: 40),
      statusLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      statusLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      statusLabel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])
  }

  private func makeButton(title: String, action: Selector?) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.title = title
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 4, bottom: 4, trailing: 4)
    let button = UIButton(configuration: configuration)
    if let action { button.addTarget(self, action: action, for: .touchUpInside) }
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
