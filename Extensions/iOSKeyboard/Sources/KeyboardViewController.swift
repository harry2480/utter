import Network
import UIKit
import UtterCore
import UtterPersistence

/// utter のカスタムキーボード（iOS-02〜09）。
///
/// OS の状態を UtterCore の `KeyboardEnvironment` に変換し、提示する操作と案内は `KeyboardAvailability` に、
/// 共有結果の選択・プレビュー・二重挿入の防止・消す操作は UtterPersistence の `SharedResultInsertionCoordinator` に、
/// 結果ごとに出す操作（挿入・入っていた・もう一度入れる・消す）と残り時間は `SharedResultKeyboardPanel` に任せる。
/// ここは画面と OS の値の受け渡しだけを持つ。
///
/// - 挿入を確認できなくても自動ではやり直さず、「入っていた」か「もう一度入れる」を利用者に選んでもらう（iOS-IPC-03）
/// - フルアクセスをオンにする手順は表示するだけで、設定アプリを開かない（iOS-03, iAC-07）
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
  /// 本体アプリのセットアップ画面への報告の書き込み先。App Group を設定したビルドだけ（#200）
  private lazy var setupReportStore = configuration.appGroupID.flatMap {
    KeyboardSetupReportStore(groupIdentifier: $0)
  }

  private let keysView = KeyboardKeysView()
  private let noticesLabel = KeyboardViewController.makeLabel()
  private let previewMessageLabel = KeyboardViewController.makeLabel()
  private let previewTextLabel = KeyboardViewController.makeLabel()
  private let statusLabel = KeyboardViewController.makeLabel()
  private let hostAppLabel = KeyboardViewController.makeLabel()
  private let remainingLabel = KeyboardViewController.makeLabel()
  private let fullAccessStepsLabel = KeyboardViewController.makeLabel()
  private let insertButton = KeyboardViewController.makeActionButton(title: "挿入")
  private let confirmInsertedButton = KeyboardViewController.makeActionButton(title: "入っていた")
  private let reinsertButton = KeyboardViewController.makeActionButton(title: "もう一度入れる")
  private let discardButton = KeyboardViewController.makeActionButton(title: "消す")
  private let reloadButton = KeyboardViewController.makeActionButton(title: "更新")
  private let fullAccessStepsButton = KeyboardViewController.makeActionButton(
    title: KeyboardMessages.showFullAccessSteps)
  private let openHostAppButton = KeyboardViewController.makeActionButton(title: "本体アプリを開く")
  private let primaryButtons = UIStackView()
  private let sharedResultSection = UIStackView()
  private let fullAccessSection = UIStackView()
  private let hostAppSection = UIStackView()

  private var snapshot = SharedSnapshot(container: .notConfigured, preview: .loading)
  /// 最後に読み込んだときの入力欄の制限。変わったら読み込み直す
  private var loadedRestrictions: Set<KeyboardFieldRestriction>?
  /// 古い読み込みの結果で上書きしないための番号
  private var loadGeneration = 0
  /// 挿入・消す・挿入済みにする操作の途中。終わるまで次の操作を受けない
  private var isBusy = false
  private var statusMessage: String?
  private var hostAppOpenFailed = false
  private var showsFullAccessSteps = false

  private var network = NetworkReachability.unknown
  private var networkMonitor: NWPathMonitor?
  private var networkTask: Task<Void, Never>?
  /// 表示している間、残り時間を更新する
  private var clockTask: Task<Void, Never>?

  /// 共有結果への操作と、そのボタン。並べる順は `SharedResultKeyboardPanel.actions` が決める
  private var actionButtons: [(SharedResultKeyboardAction, UIButton)] {
    [
      (.insert, insertButton), (.confirmInserted, confirmInsertedButton),
      (.reinsert, reinsertButton), (.discard, discardButton),
    ]
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildLayout()
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    statusMessage = nil
    hostAppOpenFailed = false
    showsFullAccessSteps = false
    startNetworkMonitor()
    startClock()
    reload()
    reportSetup()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopNetworkMonitor()
    stopClock()
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

  private func currentInputField() -> KeyboardInputField {
    KeyboardInputField(textDocumentProxy)
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
      let hasFullAccess = hasFullAccess
      Task {
        let loaded = await Self.load(
          coordinator: coordinator, hostAppStatus: hostAppStatus, hasFullAccess: hasFullAccess)
        guard generation == loadGeneration else { return }
        snapshot = loaded
        render()
      }
    }
  }

  private static func load(
    coordinator: SharedResultInsertionCoordinator, hostAppStatus: HostAppStatusStore,
    hasFullAccess: Bool
  ) async -> SharedSnapshot {
    let sessionID: SessionID?
    do {
      sessionID = try await coordinator.latestSessionID()
    } catch {
      // 共有コンテナの一覧を読めない（フルアクセスなし・署名の不備）
      return SharedSnapshot(container: .unavailable, preview: .cleared)
    }
    // フルアクセスがないと、共有コンテナが権限エラーではなく空に見える場合がある（Phase i0 #56 で確認）。
    // 「結果なし」と区別できないため、結果が見つからなければ読めないものとして扱い、フルアクセスを案内する
    if sessionID == nil, !hasFullAccess {
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

  /// キーボードが表示されたこととフルアクセスの有無を、本体アプリのセットアップ画面に伝える（#200）。
  /// 書くのは観測時刻とフルアクセスの有無だけで、入力した文字・本文は書かない。
  /// フルアクセスがないと書けない場合があり、そのときは本体アプリで手動で済んだことにしてもらう
  private func reportSetup() {
    guard let store = setupReportStore else { return }
    let report = KeyboardSetupReport(observedAt: Date(), hasFullAccess: hasFullAccess)
    Task {
      try? await store.save(report)
    }
  }

  // MARK: 操作

  /// 表示している共有結果に対して出す操作と残り時間。表示する時刻で決める
  private func currentPanel() -> SharedResultKeyboardPanel? {
    guard case .loaded(let preview) = snapshot.preview else {
      return nil
    }
    return SharedResultKeyboardPanel(preview, at: Date())
  }

  /// 利用者が選んだ共有結果への操作を行う。挿入結果が不明でも、自動ではやり直さない（iOS-IPC-03）
  private func perform(_ action: SharedResultKeyboardAction) {
    guard !isBusy, case .ready(let coordinator, _) = services,
      let sessionID = snapshot.sessionID, currentPanel()?.actions.contains(action) == true
    else {
      return
    }
    // 操作の直前に、その時点の入力欄で判定し直す（`KeyboardAvailability` の契約）
    guard currentAvailability().actions.contains(.sharedResult) else {
      statusMessage = KeyboardMessages.restrictedAtInsertion
      reload()
      return
    }
    isBusy = true
    render()
    Task {
      let (message, finished) = await Self.run(
        action, sessionID: sessionID, coordinator: coordinator)
      isBusy = false
      statusMessage = message
      if finished {
        // 挿入した・消した結果は削除済み。続けて別の結果を出さず、次にキーボードを表示したときに読み直す
        loadGeneration += 1
        snapshot.sessionID = nil
        snapshot.preview = .cleared
        render()
      } else {
        reload()
      }
    }
  }

  /// 共有結果への操作を行い、表示する文言と、結果を使い終えたか（挿入済み・消した）を返す
  private static func run(
    _ action: SharedResultKeyboardAction, sessionID: SessionID,
    coordinator: SharedResultInsertionCoordinator
  ) async -> (message: String, finished: Bool) {
    switch action {
    case .insert, .reinsert:
      let outcome = try? await coordinator.insert(
        sessionID: sessionID, confirmedReinsertion: action == .reinsert)
      return (KeyboardMessages.outcome(outcome), outcome == .inserted)
    case .confirmInserted:
      let outcome = try? await coordinator.confirmInserted(sessionID: sessionID)
      return (KeyboardMessages.dismissal(outcome, action: action), outcome == .dismissed)
    case .discard:
      let outcome = try? await coordinator.discard(sessionID: sessionID)
      return (KeyboardMessages.dismissal(outcome, action: action), outcome == .dismissed)
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

  // MARK: 残り時間

  /// 表示している間、残り時間と期限切れを画面に反映するため、定期的に表示し直す（読み込み直しはしない）
  private func startClock() {
    guard clockTask == nil else { return }
    clockTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { return }
        render()
      }
    }
  }

  private func stopClock() {
    clockTask?.cancel()
    clockTask = nil
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
    // 読み込んだときと入力欄の制限が変わっていれば（textDidChange が来ない場合も）、読み直してから表示する
    guard currentInputField().restrictions == loadedRestrictions else {
      reload()
      return
    }
    let availability = currentAvailability()

    let notices = availability.notices.map(KeyboardMessages.notice)
    noticesLabel.text = notices.joined(separator: "\n")
    noticesLabel.isHidden = notices.isEmpty

    // フルアクセスの手順は、利用者が「オンにする手順を見る」を押したときだけ出す（iAC-07）
    let offersFullAccessSteps = availability.actions.contains(.fullAccessSteps)
    fullAccessSection.isHidden = !offersFullAccessSteps
    fullAccessStepsButton.configuration?.title =
      showsFullAccessSteps
      ? KeyboardMessages.hideFullAccessSteps : KeyboardMessages.showFullAccessSteps
    fullAccessStepsLabel.text = KeyboardMessages.fullAccessSteps
    fullAccessStepsLabel.isHidden = !(offersFullAccessSteps && showsFullAccessSteps)

    let showsSharedResult = availability.actions.contains(.sharedResult)
    sharedResultSection.isHidden = !showsSharedResult
    let panel = showsSharedResult ? currentPanel() : nil
    var previewText: String?
    var previewMessage: String?
    switch snapshot.preview {
    case .loading:
      previewMessage = KeyboardMessages.previewLoading
    case .loaded(let preview):
      previewMessage =
        panel?.isExpired == true
        ? KeyboardMessages.previewExpiredWhileShown : KeyboardMessages.preview(preview)
      switch preview {
      case .insertable(let text, _), .needsConfirmation(let text, _):
        previewText = text
      case .notFound, .notInsertable:
        break
      }
    case .failed:
      previewMessage = KeyboardMessages.previewLoadFailed
    case .cleared:
      break
    }
    previewMessageLabel.text = previewMessage
    previewMessageLabel.isHidden = previewMessage == nil
    let remaining = panel?.remainingMinutes.map(KeyboardMessages.remaining(minutes:))
    remainingLabel.text = remaining
    remainingLabel.isHidden = remaining == nil
    // 本文は画面に表示するだけ。ログ・保存には出さない
    previewTextLabel.text = showsSharedResult ? previewText : nil
    previewTextLabel.isHidden = !showsSharedResult || previewText == nil
    let actions = panel?.actions ?? []
    for (action, button) in actionButtons {
      button.isHidden = !actions.contains(action)
      button.isEnabled = !isBusy
    }
    primaryButtons.isHidden = !actions.contains { $0 != .discard }

    statusLabel.text = statusMessage
    statusLabel.isHidden = statusMessage == nil

    hostAppSection.isHidden = !availability.actions.contains(.openHostApp)
    let guide =
      showsSharedResult
      ? KeyboardMessages.hostAppGuide : KeyboardMessages.hostAppGuideWithoutSharing
    hostAppLabel.text =
      hostAppOpenFailed ? guide + "\n" + KeyboardMessages.hostAppOpenFailed : guide
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

    for (action, button) in actionButtons {
      button.addAction(
        UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
    }
    reloadButton.addAction(
      UIAction { [weak self] _ in
        self?.statusMessage = nil
        self?.reload()
      }, for: .touchUpInside)
    fullAccessStepsButton.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        showsFullAccessSteps.toggle()
        render()
      }, for: .touchUpInside)
    openHostAppButton.addAction(
      UIAction { [weak self] _ in self?.openHostApp() }, for: .touchUpInside)

    previewTextLabel.font = .preferredFont(forTextStyle: .body)
    previewTextLabel.textColor = .label
    previewTextLabel.numberOfLines = 4
    remainingLabel.textColor = .label
    discardButton.configuration?.baseForegroundColor = .systemRed

    // 挿入・入っていた・もう一度入れるの行と、消す・更新の行に分ける
    for button in [insertButton, confirmInsertedButton, reinsertButton] {
      primaryButtons.addArrangedSubview(button)
    }
    let secondaryButtons = UIStackView(arrangedSubviews: [discardButton, reloadButton])
    for row in [primaryButtons, secondaryButtons] {
      row.axis = .horizontal
      row.spacing = 6
      row.distribution = .fillEqually
    }
    let sharedResultViews: [UIView] = [
      previewMessageLabel, remainingLabel, previewTextLabel, primaryButtons, secondaryButtons,
    ]
    let sections: [(UIStackView, [UIView])] = [
      (sharedResultSection, sharedResultViews),
      (fullAccessSection, [fullAccessStepsButton, fullAccessStepsLabel]),
      (hostAppSection, [hostAppLabel, openHostAppButton]),
    ]
    for (section, views) in sections {
      for view in views {
        section.addArrangedSubview(view)
      }
      section.axis = .vertical
      section.spacing = 4
    }

    let panel = UIStackView(arrangedSubviews: [
      noticesLabel, fullAccessSection, statusLabel, sharedResultSection, hostAppSection,
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
