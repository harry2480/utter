import Network
import UIKit
import UtterCore
import UtterPersistence

/// utter のカスタムキーボード（iOS-02〜09）。
///
/// OS の状態を UtterCore の `KeyboardEnvironment` に変換し、提示する操作と案内は `KeyboardAvailability` に、
/// 共有結果の選択・プレビュー・二重挿入の防止は UtterPersistence の `SharedResultInsertionCoordinator` に任せる。
/// ここは画面と OS の値の受け渡しだけを持つ。
///
/// - マイク録音・STT モデル・クラウド認証トークン・ネットワーク送信を持たない（iAC-08）。録音は本体アプリで行う
/// - 挿入は `UITextDocumentProxy` だけで行い、利用者の明示的な挿入操作まで挿入しない（iOS-05, iAC-04）
/// - セキュア入力欄・電話番号欄・判定できない欄では共有結果を読まず、文字入力と地球儀キーだけを残す（iOS-09, iAC-06）
/// - 本体アプリを開くのは公開 API（`NSExtensionContext.open(_:)`）で、自アプリの URL スキームを設定したときだけ。
///   開けなければ手動で切り替える案内を出す（iOS-03, iAC-05）
/// - 入力した文字・本文をログに出さず、保持もしない
final class KeyboardViewController: UIInputViewController {
  /// 共有結果を読む準備の結果
  private enum SharedServices {
    /// App Group を設定していないビルド
    case notConfigured
    /// App Group のコンテナを取得できない
    case unavailable
    case ready(coordinator: SharedResultInsertionCoordinator, hostAppStatus: HostAppStatusStore)
  }

  /// 共有結果の表示の状態
  private enum PreviewState: Equatable {
    case loading
    case loaded(SharedResultPreview)
    /// 結果を読めなかった（端末のロック中など）
    case failed
    /// 挿入した直後。次にキーボードを表示するまで別の結果を出さない
    case cleared
  }

  /// 共有コンテナから読んだ内容
  private struct SharedSnapshot {
    var container: SharedContainerState
    var sessionID: SessionID?
    var preview: PreviewState
  }

  private let configuration = KeyboardConfiguration()
  private lazy var services = makeServices()

  private let keysView = KeyboardKeysView()
  private let noticesLabel = KeyboardViewController.makeLabel()
  private let previewMessageLabel = KeyboardViewController.makeLabel()
  private let previewTextLabel = KeyboardViewController.makeLabel()
  private let statusLabel = KeyboardViewController.makeLabel()
  private let hostAppLabel = KeyboardViewController.makeLabel()
  private let insertButton = KeyboardViewController.makeActionButton(title: "挿入")
  private let reloadButton = KeyboardViewController.makeActionButton(title: "更新")
  private let openHostAppButton = KeyboardViewController.makeActionButton(title: "本体アプリを開く")
  private let sharedResultSection = UIStackView()
  private let hostAppSection = UIStackView()

  private var snapshot = SharedSnapshot(container: .notConfigured, preview: .loading)
  /// 最後に読み込んだときの入力欄の制限。変わったら読み込み直す
  private var loadedRestrictions: Set<KeyboardFieldRestriction>?
  /// 古い読み込みの結果で上書きしないための番号
  private var loadGeneration = 0
  private var isInserting = false
  private var statusMessage: String?
  private var hostAppOpenFailed = false

  private var network = NetworkReachability.unknown
  private var networkMonitor: NWPathMonitor?
  private var networkTask: Task<Void, Never>?

  override func viewDidLoad() {
    super.viewDidLoad()
    buildLayout()
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    statusMessage = nil
    hostAppOpenFailed = false
    startNetworkMonitor()
    reload()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopNetworkMonitor()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    keysView.setGlobeKeyVisible(needsInputModeSwitchKey)
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    // 入力欄を移ったときに制限が変われば、共有結果を読むかどうかから判定し直す
    if currentInputField().restrictions != loadedRestrictions {
      reload()
    }
  }

  // MARK: 状態

  private func makeServices() -> SharedServices {
    guard let appGroupID = configuration.appGroupID else {
      return .notConfigured
    }
    guard let store = SharedResultStore(groupIdentifier: appGroupID),
      let hostAppStatus = HostAppStatusStore(groupIdentifier: appGroupID)
    else {
      return .unavailable
    }
    let coordinator = SharedResultInsertionCoordinator(
      store: store, inserter: TextDocumentProxyInserter(controller: self))
    return .ready(coordinator: coordinator, hostAppStatus: hostAppStatus)
  }

  /// 入力欄の属性を OS 非依存の値にする。取れない属性は `unknown`（安全側, iOS-09）
  private func currentInputField() -> KeyboardInputField {
    let proxy = textDocumentProxy
    let secure: SensitiveSignal = proxy.isSecureTextEntry.map { $0 ? .on : .off } ?? .unknown
    let phone: SensitiveSignal =
      proxy.keyboardType.map { $0 == .phonePad || $0 == .namePhonePad ? .on : .off } ?? .unknown
    return KeyboardInputField(secureTextEntry: secure, phoneNumber: phone)
  }

  private func currentAvailability() -> KeyboardAvailability {
    // フルアクセスがないとキーボードはネットワークを使えず、オフラインと区別できないため観測しない
    let environment = KeyboardEnvironment(
      hasFullAccess: hasFullAccess, sharedContainer: snapshot.container,
      inputField: currentInputField(), network: hasFullAccess ? network : .unknown)
    return KeyboardAvailability(environment, at: Date())
  }

  /// 共有結果を読み直す。制限のある入力欄では読まない（`KeyboardAvailability` の契約）
  private func reload() {
    loadGeneration += 1
    let generation = loadGeneration
    let restrictions = currentInputField().restrictions
    loadedRestrictions = restrictions
    guard restrictions.isEmpty else {
      // 制限のある入力欄では `KeyboardAvailability` が共有コンテナの状態を使わない
      snapshot = SharedSnapshot(container: .unavailable, preview: .cleared)
      render()
      return
    }
    switch services {
    case .notConfigured:
      snapshot = SharedSnapshot(container: .notConfigured, preview: .cleared)
      render()
    case .unavailable:
      snapshot = SharedSnapshot(container: .unavailable, preview: .cleared)
      render()
    case .ready(let coordinator, let hostAppStatus):
      if case .available = snapshot.container {
        snapshot.preview = .loading
      } else {
        snapshot = SharedSnapshot(container: .available(hostApp: nil), preview: .loading)
      }
      render()
      Task {
        let loaded = await Self.load(coordinator: coordinator, hostAppStatus: hostAppStatus)
        guard generation == loadGeneration else { return }
        snapshot = loaded
        render()
      }
    }
  }

  private static func load(
    coordinator: SharedResultInsertionCoordinator, hostAppStatus: HostAppStatusStore
  ) async -> SharedSnapshot {
    let sessionID: SessionID?
    do {
      sessionID = try await coordinator.latestSessionID()
    } catch {
      // 共有コンテナの一覧を読めない（フルアクセスなし・署名の不備）
      return SharedSnapshot(container: .unavailable, preview: .cleared)
    }
    // 本体アプリの状態は読めなければ使わない（案内を出さないだけで、共有結果の表示は続ける）
    let host = try? await hostAppStatus.load()
    let preview: PreviewState
    if let sessionID {
      preview =
        (try? await coordinator.preview(sessionID: sessionID)).map(PreviewState.loaded) ?? .failed
    } else {
      preview = .loaded(.notFound)
    }
    return SharedSnapshot(
      container: .available(hostApp: host), sessionID: sessionID, preview: preview)
  }

  // MARK: 操作

  private func insertSharedResult() {
    guard !isInserting, case .ready(let coordinator, _) = services,
      let sessionID = snapshot.sessionID
    else {
      return
    }
    let confirmedReinsertion: Bool
    switch snapshot.preview {
    case .loaded(.insertable): confirmedReinsertion = false
    case .loaded(.needsConfirmation): confirmedReinsertion = true
    default: return
    }
    // 挿入の直前に、その時点の入力欄で判定し直す（`KeyboardAvailability` の契約）
    guard currentAvailability().actions.contains(.sharedResult) else {
      statusMessage = KeyboardMessages.restrictedAtInsertion
      reload()
      return
    }
    isInserting = true
    render()
    Task {
      let outcome = try? await coordinator.insert(
        sessionID: sessionID, confirmedReinsertion: confirmedReinsertion)
      isInserting = false
      statusMessage = KeyboardMessages.outcome(outcome)
      if outcome == .inserted {
        // 挿入した結果は削除済み。続けて別の結果を出さず、次にキーボードを表示したときに読み直す
        loadGeneration += 1
        snapshot.sessionID = nil
        snapshot.preview = .cleared
        render()
      } else {
        reload()
      }
    }
  }

  private func openHostApp() {
    guard let url = configuration.hostAppURL, let context = extensionContext else {
      hostAppOpenFailed = true
      render()
      return
    }
    context.open(url) { [weak self] success in
      Task { @MainActor in
        self?.hostAppOpenFailed = !success
        self?.render()
      }
    }
  }

  // MARK: ネットワーク（案内のための観測だけ。送信はしない）

  private func startNetworkMonitor() {
    guard networkMonitor == nil else { return }
    let monitor = NWPathMonitor()
    let (stream, continuation) = AsyncStream.makeStream(
      of: NetworkReachability.self, bufferingPolicy: .bufferingNewest(1))
    monitor.pathUpdateHandler = { path in
      switch path.status {
      case .satisfied: continuation.yield(.online)
      case .unsatisfied: continuation.yield(.offline)
      default: continuation.yield(.unknown)
      }
    }
    monitor.start(queue: DispatchQueue(label: "utter.keyboard.network"))
    networkMonitor = monitor
    networkTask = Task { [weak self] in
      for await value in stream {
        guard let self else { return }
        if network != value {
          network = value
          render()
        }
      }
    }
  }

  private func stopNetworkMonitor() {
    networkMonitor?.cancel()
    networkMonitor = nil
    networkTask?.cancel()
    networkTask = nil
    network = .unknown
  }

  // MARK: 画面

  private func render() {
    guard isViewLoaded else { return }
    let availability = currentAvailability()

    let notices = availability.notices.map(KeyboardMessages.notice)
    noticesLabel.text = notices.joined(separator: "\n")
    noticesLabel.isHidden = notices.isEmpty

    let showsSharedResult = availability.actions.contains(.sharedResult)
    sharedResultSection.isHidden = !showsSharedResult
    var previewText: String?
    var previewMessage: String?
    switch snapshot.preview {
    case .loading:
      previewMessage = KeyboardMessages.previewLoading
    case .loaded(let preview):
      previewMessage = KeyboardMessages.preview(preview)
      switch preview {
      case .insertable(let text):
        previewText = text
        insertButton.configuration?.title = "挿入"
      case .needsConfirmation(let text):
        previewText = text
        insertButton.configuration?.title = "再挿入"
      case .notFound, .notInsertable:
        break
      }
    case .failed:
      previewMessage = KeyboardMessages.previewLoadFailed
    case .cleared:
      break
    }
    let canInsert = showsSharedResult && previewText != nil
    previewMessageLabel.text = previewMessage
    previewMessageLabel.isHidden = previewMessage == nil
    // 本文は画面に表示するだけ。ログ・保存には出さない
    previewTextLabel.text = showsSharedResult ? previewText : nil
    previewTextLabel.isHidden = !canInsert
    insertButton.isHidden = !canInsert
    insertButton.isEnabled = canInsert && !isInserting

    statusLabel.text = statusMessage
    statusLabel.isHidden = statusMessage == nil

    hostAppSection.isHidden = !availability.actions.contains(.openHostApp)
    hostAppLabel.text =
      hostAppOpenFailed
      ? KeyboardMessages.hostAppGuide + "\n" + KeyboardMessages.hostAppOpenFailed
      : KeyboardMessages.hostAppGuide
    openHostAppButton.isHidden = configuration.hostAppURL == nil
  }

  private func buildLayout() {
    let root: UIView = inputView ?? view
    let height = root.heightAnchor.constraint(equalToConstant: 330)
    height.priority = .defaultHigh
    height.isActive = true

    keysView.onText = { [weak self] text in self?.textDocumentProxy.insertText(text) }
    keysView.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
    keysView.globeButton.addTarget(
      self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

    insertButton.addAction(
      UIAction { [weak self] _ in self?.insertSharedResult() }, for: .touchUpInside)
    reloadButton.addAction(
      UIAction { [weak self] _ in
        self?.statusMessage = nil
        self?.reload()
      }, for: .touchUpInside)
    openHostAppButton.addAction(
      UIAction { [weak self] _ in self?.openHostApp() }, for: .touchUpInside)

    previewTextLabel.font = .preferredFont(forTextStyle: .body)
    previewTextLabel.textColor = .label
    previewTextLabel.numberOfLines = 4

    let sharedButtons = UIStackView(arrangedSubviews: [insertButton, reloadButton])
    sharedButtons.axis = .horizontal
    sharedButtons.spacing = 6
    sharedButtons.distribution = .fillEqually
    for (section, views) in [
      (sharedResultSection, [previewMessageLabel, previewTextLabel, sharedButtons]),
      (hostAppSection, [hostAppLabel, openHostAppButton]),
    ] {
      for view in views {
        section.addArrangedSubview(view)
      }
      section.axis = .vertical
      section.spacing = 4
    }

    let panel = UIStackView(arrangedSubviews: [
      noticesLabel, statusLabel, sharedResultSection, hostAppSection,
    ])
    panel.axis = .vertical
    panel.spacing = 8
    panel.translatesAutoresizingMaskIntoConstraints = false
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(panel)

    keysView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(scrollView)
    root.addSubview(keysView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
      scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      scrollView.heightAnchor.constraint(equalToConstant: 130),
      panel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      panel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      panel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      panel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      keysView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
      keysView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
      keysView.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
      keysView.bottomAnchor.constraint(
        equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -4),
    ])
  }

  private static func makeLabel() -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    return label
  }

  private static func makeActionButton(title: String) -> UIButton {
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    return UIButton(configuration: configuration)
  }
}
