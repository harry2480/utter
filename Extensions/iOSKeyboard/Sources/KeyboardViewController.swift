import Network
import SwiftUI
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
/// - 本体アプリを開くのは公開 API（SwiftUI の `OpenURLAction`。`HostAppOpener` に任せる）で、自アプリの
///   URL スキームを設定したときだけ。開けなければ手動で切り替える案内を出す（iOS-03, iAC-05）
/// - 入力した文字・本文をログに出さず、保持もしない
final class KeyboardViewController: UIInputViewController {
  /// 共有結果を読む準備の結果
  private enum SharedServices {
    /// App Group を設定していないビルド
    case notConfigured
    /// App Group のコンテナを取得できない
    case unavailable
    case ready(
      coordinator: SharedResultInsertionCoordinator, hostAppStatus: HostAppStatusStore,
      standby: KeyboardStandbyDictation?)
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
  private let insertButton = KeyboardViewController.makeActionButton(
    title: "カーソルの位置に入れる", style: .accent)
  private let confirmInsertedButton = KeyboardViewController.makeActionButton(
    title: "入っていた", style: .accent)
  private let reinsertButton = KeyboardViewController.makeActionButton(
    title: "もう一度入れる", style: .outline)
  private let discardButton = KeyboardViewController.makeActionButton(title: "消す", style: .outline)
  private let reloadButton = KeyboardViewController.makeActionButton(title: "更新", style: .outline)
  private let fullAccessStepsButton = KeyboardViewController.makeActionButton(
    title: KeyboardMessages.showFullAccessSteps, style: .outline)
  private let openHostAppButton = KeyboardViewController.makeActionButton(
    title: "本体アプリを開く", style: .outline)
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

  /// 本体アプリを開く要求。開くのは `HostAppOpenerView`（SwiftUI の `OpenURLAction`）
  private let hostAppOpenRequest = HostAppOpenRequest()

  private var network = NetworkReachability.unknown
  private var networkMonitor: NWPathMonitor?
  private var networkTask: Task<Void, Never>?
  /// 表示している間、残り時間を更新する
  private var clockTask: Task<Void, Never>?
  /// 表示している間、待機セッションの状態を読み直す（iOS-04）。通知は読み直しのきっかけにだけ使う
  private var standbyTask: Task<Void, Never>?
  private var standbyObservation: StandbyDarwinObservation?
  private let micButton = KeyboardViewController.makeActionButton(title: "話す", style: .strong)
  private let micTitleLabel = KeyboardViewController.makeLabel()
  private let micSubtitleLabel = KeyboardViewController.makeLabel()
  private let micDotView = UIView()
  private let micCheckView = UIImageView(image: UIImage(systemName: "checkmark.circle"))
  private let micRow = UIStackView()
  private let micTextStack = UIStackView()
  private let bandCard = UIView()
  private let scrollView = UIScrollView()

  // 録音中・認識中の暗い帯（設計: キーボード 2・3）
  private let darkBand = UIView()
  private let bandTitleLabel = KeyboardViewController.makeBandLabel(size: 16, bold: true)
  private let bandElapsedLabel = KeyboardViewController.makeBandLabel(
    size: 15, color: UtterPalette.bandBodyText, monospaced: true)
  private let bandDotView = UIView()
  private let bandCaptionLabel = KeyboardViewController.makeBandLabel(
    size: 12, color: UtterPalette.bandSecondaryText)
  private let bandProgressStack = UIStackView()
  private let bandCancelButton = KeyboardViewController.makeBandButton(
    title: "やめる", filled: false)
  private let bandStopButton = KeyboardViewController.makeBandButton(
    title: "止めて入れる", filled: true)
  private let bandGlobeButton = KeyboardViewController.makeBandGlobeButton()
  private let bandButtons = UIStackView()
  /// 録音中の経過時間の起点。録音が始まったときにキーボード側で控える（本体アプリの時間とは別）
  private var recordingStartedAt: Date?

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
    startStandbyLoop()
    reload()
    reportSetup()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopNetworkMonitor()
    stopClock()
    stopStandbyLoop()
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
    // 待機セッションの置き場所を開けなければ、従来の経路（本体アプリで録音）だけにする
    let standby = StandbySessionStore(groupIdentifier: appGroupID).map { standbyStore in
      let dictation = KeyboardStandbyDictation(
        signals: NotifyingKeyboardStandbySignals(store: standbyStore, groupIdentifier: appGroupID),
        inserter: coordinator, canInsert: { [weak self] in self?.viewIfLoaded?.window != nil })
      dictation.onChange = { [weak self] in self?.standbyStateChanged() }
      return dictation
    }
    return .ready(coordinator: coordinator, hostAppStatus: hostAppStatus, standby: standby)
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
    case .ready(let coordinator, let hostAppStatus, _):
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
    guard !isBusy, case .ready(let coordinator, _, _) = services,
      let sessionID = snapshot.sessionID
    else {
      return
    }
    // 表示し直す前に期限を過ぎるなどして操作を出さなくなっていれば、何もせず表示を最新にする
    guard currentPanel()?.actions.contains(action) == true else {
      render()
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
    let generation = loadGeneration
    Task {
      let (message, finished) = await Self.run(
        action, sessionID: sessionID, coordinator: coordinator)
      isBusy = false
      // 操作の間に読み直した（「更新」・キーボードの再表示・入力欄の移動）なら、古い操作の結果で表示を上書きしない
      guard generation == loadGeneration, snapshot.sessionID == sessionID else {
        reload()
        return
      }
      statusMessage = message
      if finished {
        standby?.resultHandled()
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

  /// 本体アプリを開く。URL スキームを設定していない・開けなかったときは、手動で切り替える案内を出す（iOS-03, iAC-05）
  private func openHostApp() {
    guard let url = configuration.hostAppURL else {
      hostAppOpenFailed = true
      render()
      return
    }
    hostAppOpenRequest.open(url) { [weak self] accepted in
      guard let self else { return }
      hostAppOpenFailed = !accepted
      render()
    }
  }

  // MARK: 待機セッションの録音（iOS-03〜06）

  private var standby: KeyboardStandbyDictation? {
    guard case .ready(_, _, let standby) = services else { return nil }
    return standby
  }

  /// 待機セッションの状態を読み直し続ける。録音中は生存の印も書く。本体アプリからの通知でもすぐ読み直す
  private func startStandbyLoop() {
    guard standbyTask == nil, let standby else { return }
    if let appGroupID = configuration.appGroupID {
      standbyObservation = StandbyDarwinSignal.hostState.observe(groupIdentifier: appGroupID) {
        [weak self] in
        Task { @MainActor in
          guard let self, self.currentInputField().restrictions.isEmpty else { return }
          await self.standby?.tick()
        }
      }
    }
    standbyTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        // 制限のある入力欄では録音しない（iOS-09）
        if currentInputField().restrictions.isEmpty {
          await standby.tick()
        } else {
          await standby.keyboardClosed()
        }
        updateBandElapsed()
        // 録音の途中は細かく、そうでなければ間を空けて読み直す
        try? await Task.sleep(for: standby.isBusy ? .milliseconds(300) : .seconds(2))
      }
    }
  }

  /// キーボードが閉じられた。録音中なら取り消しを送る（iOS-06）
  private func stopStandbyLoop() {
    standbyTask?.cancel()
    standbyTask = nil
    standbyObservation = nil
    guard let standby else { return }
    Task { await standby.keyboardClosed() }
  }

  private func standbyStateChanged() {
    switch standby?.state {
    case .inserted:
      // 挿入した結果は削除済み。次にキーボードを表示するまで別の結果を出さない
      statusMessage = nil
      loadGeneration += 1
      snapshot.sessionID = nil
      snapshot.preview = .cleared
    case .resultReady, .insertionUnknown, .failed(.insertFailed):
      // 結果のプレビューと明示的な操作の画面に出す
      statusMessage = nil
      reload()
    default:
      break
    }
    render()
  }

  /// マイクのボタン。待機していれば録音を始め・止め、待機していなければ本体アプリを開く
  private func tapMic() {
    // 制限のある入力欄では録音しない（iOS-09）。押した時点でも確かめる
    guard currentInputField().restrictions.isEmpty else {
      render()
      return
    }
    guard let standby, standby.state != .unavailable else {
      openHostApp()
      return
    }
    statusMessage = nil
    Task { await standby.toggle() }
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

    // マイクの行は、制限のない入力欄で、共有結果を読める（待機の状態を使える）ときだけ出す
    let standbyState = standby?.state ?? .unavailable
    let offersMic = showsSharedResult && standby != nil
    renderMicRow(standbyState, visible: offersMic)
    renderDarkBand(standbyState, visible: offersMic)
    micButton.isEnabled = !isBusy
    let standbyMessage = KeyboardMessages.standbyStatus(standbyState)
    let message = [statusMessage, standbyMessage].compactMap { $0 }.joined(separator: "\n")
    statusLabel.text = message
    statusLabel.isHidden = message.isEmpty

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
    addHostAppOpener(to: root)
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
    micButton.addAction(
      UIAction { [weak self] _ in self?.tapMic() }, for: .touchUpInside)

    previewTextLabel.font = .systemFont(ofSize: 15)
    previewTextLabel.textColor = UtterPalette.text
    previewTextLabel.numberOfLines = 4
    remainingLabel.textColor = UtterPalette.warningText
    remainingLabel.font = .systemFont(ofSize: 12)
    remainingLabel.textAlignment = .right
    noticesLabel.textColor = UtterPalette.warningText

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

    // マイクの行: 状態の文字（点・題・補足）とマイクのボタン
    micDotView.translatesAutoresizingMaskIntoConstraints = false
    micDotView.layer.cornerRadius = 4.5
    micCheckView.translatesAutoresizingMaskIntoConstraints = false
    micCheckView.tintColor = UtterPalette.accent
    micCheckView.isHidden = true
    NSLayoutConstraint.activate([
      micDotView.widthAnchor.constraint(equalToConstant: 9),
      micDotView.heightAnchor.constraint(equalToConstant: 9),
      micCheckView.widthAnchor.constraint(equalToConstant: 24),
      micCheckView.heightAnchor.constraint(equalToConstant: 24),
    ])
    micTitleLabel.font = .systemFont(ofSize: 14, weight: .bold)
    micTitleLabel.textColor = UtterPalette.text
    micSubtitleLabel.font = .systemFont(ofSize: 12)
    let titleRow = UIStackView(arrangedSubviews: [micDotView, micCheckView, micTitleLabel])
    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 6
    micTextStack.axis = .vertical
    micTextStack.spacing = 2
    micTextStack.addArrangedSubview(titleRow)
    micTextStack.addArrangedSubview(micSubtitleLabel)
    micRow.axis = .horizontal
    micRow.alignment = .center
    micRow.spacing = 10
    micRow.addArrangedSubview(micTextStack)
    micRow.addArrangedSubview(micButton)
    micButton.setContentHuggingPriority(.required, for: .horizontal)
    micButton.setContentCompressionResistancePriority(.required, for: .horizontal)

    let panel = UIStackView(arrangedSubviews: [
      noticesLabel, fullAccessSection, micRow, statusLabel, sharedResultSection, hostAppSection,
    ])
    panel.axis = .vertical
    panel.spacing = 10
    panel.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(panel)

    bandCard.backgroundColor = UtterPalette.card
    bandCard.layer.cornerRadius = 14
    bandCard.translatesAutoresizingMaskIntoConstraints = false
    bandCard.addSubview(scrollView)
    root.backgroundColor = UtterPalette.keyboardBackground

    keysView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bandCard)
    root.addSubview(keysView)
    buildDarkBand(in: root)

    // 内容の高さに合わせ、高くなりすぎたらスクロールにする
    let fitContent = scrollView.heightAnchor.constraint(
      equalTo: scrollView.contentLayoutGuide.heightAnchor)
    fitContent.priority = .defaultHigh
    NSLayoutConstraint.activate([
      bandCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      bandCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      bandCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: bandCard.leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: bandCard.trailingAnchor, constant: -12),
      scrollView.topAnchor.constraint(equalTo: bandCard.topAnchor, constant: 10),
      scrollView.bottomAnchor.constraint(equalTo: bandCard.bottomAnchor, constant: -10),
      fitContent,
      scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 130),
      panel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      panel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      panel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      panel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      keysView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
      keysView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
      keysView.topAnchor.constraint(equalTo: bandCard.bottomAnchor, constant: 10),
      keysView.bottomAnchor.constraint(
        equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -4),
    ])
  }

  /// 録音中・認識中の暗い帯。キーの代わりに全面へ重ねる
  private func buildDarkBand(in root: UIView) {
    darkBand.backgroundColor = UtterPalette.band
    darkBand.isHidden = true
    darkBand.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(darkBand)

    bandDotView.translatesAutoresizingMaskIntoConstraints = false
    bandDotView.layer.cornerRadius = 5.5
    bandDotView.backgroundColor = UtterPalette.bandAccent
    NSLayoutConstraint.activate([
      bandDotView.widthAnchor.constraint(equalToConstant: 11),
      bandDotView.heightAnchor.constraint(equalToConstant: 11),
    ])
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = UIStackView(arrangedSubviews: [
      bandDotView, bandTitleLabel, spacer, bandElapsedLabel,
    ])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 8

    bandProgressStack.axis = .horizontal
    bandProgressStack.distribution = .fillEqually
    bandProgressStack.spacing = 8

    bandButtons.axis = .horizontal
    bandButtons.spacing = 12
    bandButtons.addArrangedSubview(bandCancelButton)
    bandButtons.addArrangedSubview(bandStopButton)
    bandCancelButton.setContentHuggingPriority(.required, for: .horizontal)
    bandStopButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

    bandCaptionLabel.numberOfLines = 0
    let footer = UIStackView(arrangedSubviews: [bandCaptionLabel, bandGlobeButton])
    footer.axis = .horizontal
    footer.alignment = .center
    footer.spacing = 12

    let content = UIStackView(arrangedSubviews: [header, bandProgressStack, bandButtons, footer])
    content.axis = .vertical
    content.distribution = .equalSpacing
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    darkBand.addSubview(content)
    NSLayoutConstraint.activate([
      darkBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      darkBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      darkBand.topAnchor.constraint(equalTo: root.topAnchor),
      darkBand.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: darkBand.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: darkBand.trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: darkBand.topAnchor, constant: 16),
      content.bottomAnchor.constraint(
        equalTo: darkBand.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      bandStopButton.heightAnchor.constraint(equalToConstant: 56),
      bandCancelButton.heightAnchor.constraint(equalToConstant: 56),
    ])
    bandCancelButton.addAction(
      UIAction { [weak self] _ in
        guard let self, let standby else { return }
        Task { await standby.cancel() }
      }, for: .touchUpInside)
    bandStopButton.addAction(
      UIAction { [weak self] _ in self?.tapMic() }, for: .touchUpInside)
    bandGlobeButton.addTarget(
      self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
  }

  // MARK: マイクの行と暗い帯

  /// マイクの行（話せる状態・待機していない・入れた直後）。録音中・認識中は暗い帯が代わる
  private func renderMicRow(_ state: KeyboardStandbyState, visible: Bool) {
    var isDarkState = false
    switch state {
    case .starting, .recording, .processing: isDarkState = true
    default: break
    }
    micRow.isHidden = !visible || isDarkState
    guard visible else { return }
    micCheckView.isHidden = true
    micDotView.isHidden = false
    micSubtitleLabel.isHidden = true
    switch state {
    case .unavailable:
      // 待機していない: 本体アプリを開いて待機を始めてもらう
      micDotView.backgroundColor = UtterPalette.idleDot
      micTitleLabel.text = "まだ話せません"
      Self.applyStyle(micButton, title: "utter を開いて待機を始める", style: .accent, symbol: nil)
      micRow.axis = .vertical
      micRow.alignment = .fill
    case .inserted:
      micCheckView.isHidden = false
      micDotView.isHidden = true
      micTitleLabel.text = "入れました"
      micSubtitleLabel.text = "続けて話せます"
      micSubtitleLabel.isHidden = false
      Self.applyStyle(micButton, title: "続けて話す", style: .strong, symbol: "mic")
      micRow.axis = .horizontal
      micRow.alignment = .center
    default:
      micDotView.backgroundColor = UtterPalette.accent
      micTitleLabel.text = "話せます"
      Self.applyStyle(micButton, title: "話す", style: .strong, symbol: "mic")
      micRow.axis = .horizontal
      micRow.alignment = .center
    }
  }

  /// 暗い帯（録音中・認識中）。表示している間はキーと明るい帯を隠す
  private func renderDarkBand(_ state: KeyboardStandbyState, visible: Bool) {
    var showsBand = false
    switch state {
    case .starting:
      showsBand = visible
      bandTitleLabel.text = "開始しています…"
      bandElapsedLabel.isHidden = true
      bandProgressStack.isHidden = true
      bandButtons.isHidden = false
      bandStopButton.isEnabled = false
      bandStopButton.alpha = 0.4
      bandCaptionLabel.text = "キーボードを閉じると、この録音は捨てます。"
      recordingStartedAt = nil
    case .recording:
      showsBand = visible
      if recordingStartedAt == nil { recordingStartedAt = Date() }
      bandTitleLabel.text = "録音中"
      bandElapsedLabel.isHidden = false
      bandProgressStack.isHidden = true
      bandButtons.isHidden = false
      bandStopButton.isEnabled = !isBusy
      bandStopButton.alpha = 1
      bandCaptionLabel.text = "キーボードを閉じると、この録音は捨てます。"
      updateBandElapsed()
    case .processing:
      showsBand = visible
      recordingStartedAt = nil
      bandTitleLabel.text = "文字にしています"
      bandElapsedLabel.isHidden = true
      bandButtons.isHidden = true
      bandProgressStack.isHidden = false
      renderProgressSteps()
      bandCaptionLabel.text = "終わるまでお待ちください。結果は、キーボードを閉じても残ります。"
    default:
      recordingStartedAt = nil
    }
    darkBand.isHidden = !showsBand
    bandCard.isHidden = showsBand
    keysView.isHidden = showsBand
    bandDotView.isHidden = state != .unavailable && !isRecordingState(state)
  }

  private func isRecordingState(_ state: KeyboardStandbyState) -> Bool {
    if case .recording = state { return true }
    return false
  }

  /// 認識・整形の進み具合。キーボードが知っているのは「処理中」だけなので、3段（録音済み・認識と整形・挿入）で示す
  private func renderProgressSteps() {
    guard bandProgressStack.arrangedSubviews.isEmpty else { return }
    let steps: [(String, UIColor, Bool)] = [
      ("録音", UtterPalette.bandAccent, false),
      ("認識・整形", UtterPalette.bandText, true),
      ("挿入", UtterPalette.bandTrack, false),
    ]
    for (title, color, isCurrent) in steps {
      let bar = UIView()
      bar.backgroundColor = color
      bar.layer.cornerRadius = 2
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
      let label = Self.makeBandLabel(
        size: 13, bold: isCurrent,
        color: isCurrent ? UtterPalette.bandText : UtterPalette.bandSecondaryText)
      label.text = title
      let column = UIStackView(arrangedSubviews: [bar, label])
      column.axis = .vertical
      column.spacing = 6
      bandProgressStack.addArrangedSubview(column)
    }
  }

  /// 録音中の経過時間（0:07 の形）。キーボードが録音を始めたと知った時刻から数える
  private func updateBandElapsed() {
    guard let startedAt = recordingStartedAt else { return }
    let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
    bandElapsedLabel.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  /// 本体アプリを開くための画面を重ねる。大きさを持たないため、キーボードの見た目は変わらない
  private func addHostAppOpener(to root: UIView) {
    let opener = UIHostingController(rootView: HostAppOpenerView(request: hostAppOpenRequest))
    opener.view.translatesAutoresizingMaskIntoConstraints = false
    opener.view.backgroundColor = .clear
    opener.view.isUserInteractionEnabled = false
    addChild(opener)
    root.addSubview(opener.view)
    opener.didMove(toParent: self)
    NSLayoutConstraint.activate([
      opener.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      opener.view.topAnchor.constraint(equalTo: root.topAnchor),
      opener.view.widthAnchor.constraint(equalToConstant: 0),
      opener.view.heightAnchor.constraint(equalToConstant: 0),
    ])
  }

  private static func makeLabel() -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 13)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = UtterPalette.secondaryText
    return label
  }

  /// 暗い帯の上の文字
  private static func makeBandLabel(
    size: CGFloat, bold: Bool = false, color: UIColor = UtterPalette.bandText,
    monospaced: Bool = false
  ) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.font =
      monospaced
      ? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
      : .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    label.textColor = color
    return label
  }

  private enum ButtonStyle { case accent, strong, outline }

  private static func makeActionButton(title: String, style: ButtonStyle) -> UIButton {
    let button = UIButton(configuration: .plain())
    applyStyle(button, title: title, style: style, symbol: nil)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    return button
  }

  /// ボタンの見た目（青・濃い色・枠だけ）。タップ領域は 44pt 以上
  private static func applyStyle(
    _ button: UIButton, title: String, style: ButtonStyle, symbol: String?
  ) {
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.image = symbol.flatMap { UIImage(systemName: $0) }
    configuration.imagePadding = 8
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = style == .strong ? 12 : 10
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 10, leading: 16, bottom: 10, trailing: 16)
    let font = UIFont.systemFont(
      ofSize: style == .strong ? 17 : 15, weight: style == .outline ? .regular : .bold)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = font
      return attributes
    }
    switch style {
    case .accent:
      configuration.baseBackgroundColor = UtterPalette.accent
      configuration.baseForegroundColor = UtterPalette.onAccent
    case .strong:
      configuration.baseBackgroundColor = UtterPalette.strongFill
      configuration.baseForegroundColor = UtterPalette.onStrongFill
    case .outline:
      configuration.baseBackgroundColor = UtterPalette.card
      configuration.baseForegroundColor = UtterPalette.text
      configuration.background.strokeColor = UtterPalette.line
      configuration.background.strokeWidth = 1
    }
    button.configuration = configuration
  }

  /// 暗い帯のボタン。`filled` は明るい塗り（止めて入れる）、そうでなければ枠だけ（やめる）
  private static func makeBandButton(title: String, filled: Bool) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = 14
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    if filled {
      configuration.baseBackgroundColor = UtterPalette.bandText
      configuration.baseForegroundColor = UtterPalette.band
      configuration.image = UIImage(systemName: "stop.fill")
      configuration.imagePadding = 10
    } else {
      configuration.baseBackgroundColor = .clear
      configuration.baseForegroundColor = UtterPalette.bandText
      configuration.background.strokeColor = UtterPalette.bandLine
      configuration.background.strokeWidth = 1
    }
    let size: CGFloat = filled ? 18 : 15
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = UIFont.systemFont(ofSize: size, weight: filled ? .bold : .regular)
      return attributes
    }
    return UIButton(configuration: configuration)
  }

  private static func makeBandGlobeButton() -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.image = UIImage(systemName: "globe")
    configuration.baseBackgroundColor = UtterPalette.bandRaised
    configuration.baseForegroundColor = UtterPalette.bandText
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = 8
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = "キーボードを切り替える"
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 44),
      button.heightAnchor.constraint(equalToConstant: 44),
    ])
    return button
  }
}
