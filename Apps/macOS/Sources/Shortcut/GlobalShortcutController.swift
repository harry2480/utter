import UtterCore

/// 録音のグローバルショートカットの登録と、押下・解放・Esc のセッション操作への変換（REC-01, REC-02）。
///
/// - 通常のキー組み合わせ（修飾キー＋キー）は RegisterEventHotKey で登録する（権限不要）
/// - 修飾キー単独（Fn・右 Option 等）は入力監視のイベントタップで検出する（#51 の判定待ち。
///   `ShortcutCapabilities.supportsModifierOnly` が有効なときだけ）
/// - セッション中だけの Esc 捕捉はアクセシビリティのイベントタップで行う（#51 の判定待ち。
///   `ShortcutCapabilities.supportsEscapeCapture` が有効で、ショートカットを登録でき、設定で Esc でのキャンセルを
///   オフにしていない（`GlobalShortcutSetting.cancelsWithEscape`）ときだけ）
///
/// capability が無効ならイベントタップを作らず、権限の確認もしない（PERM-01）。権限がない・取り消された場合は
/// その機能だけを無効にし、理由を `status` / `escapeStatus` に残す（PERM-02）。
///
/// 割当の検証は UtterCore の `ShortcutValidator`、押下・解放・Esc の解釈は `ShortcutInterpreter` が行い、
/// ここは OS の登録と、両者・アプリの結線だけを持つ。
@MainActor
final class GlobalShortcutController {
  /// 競合検出で使う utter の録音ショートカットの ID（設定画面の記録の判定 `ShortcutRecorder` でも使う）
  nonisolated static let recordBindingID = "utter.record"

  let capabilities: ShortcutCapabilities
  private let registrar: any HotKeyRegistering
  private let tapFactory: any KeyEventTapFactory
  private let permissions: any EventTapPermissionChecking
  private let systemShortcuts: () -> [ShortcutBinding]
  private let currentPhase: () -> SessionPhase
  private let perform: (ShortcutCommand) -> Void
  private let validator: ShortcutValidator
  private var interpreter = ShortcutInterpreter(mode: .toggle)
  private var translator = HotKeyEventTranslator()
  private var setting: GlobalShortcutSetting?
  /// セッション中に変わり、待機に戻ってから適用する割当（`update(_:)`）
  private var pending: PendingSetting?
  private var registration: HotKeyRegistrationID?
  private var modifierTap: (any KeyEventTap)?
  private var detector: ModifierOnlyDetector?
  private var escapeTap: (any KeyEventTap)?
  private var escapeFilter: EscapeCaptureFilter?

  private(set) var status: GlobalShortcutStatus = .unassigned {
    didSet { if status != oldValue { onStatusChange?() } }
  }
  private(set) var escapeStatus: EscapeCaptureStatus = .off {
    didSet { if escapeStatus != oldValue { onStatusChange?() } }
  }
  /// `status` か `escapeStatus` が変わったときに呼ぶ（権限の取り消しなど、操作によらない変化を含む）
  var onStatusChange: (() -> Void)?

  /// - Parameters:
  ///   - capabilities: 修飾キー単独・Esc 捕捉を使うか。Phase 0（#51）の判定までは `.keyCombinationsOnly`
  ///   - systemShortcuts: 競合を検出する相手（有効なシステムのショートカット）。割当のたびに取得する
  ///   - currentPhase: セッションの現在の状態
  ///   - perform: 実行するセッション操作
  init(
    registrar: any HotKeyRegistering,
    tapFactory: any KeyEventTapFactory,
    permissions: any EventTapPermissionChecking,
    capabilities: ShortcutCapabilities,
    systemShortcuts: @escaping () -> [ShortcutBinding],
    currentPhase: @escaping () -> SessionPhase,
    perform: @escaping (ShortcutCommand) -> Void
  ) {
    self.registrar = registrar
    self.tapFactory = tapFactory
    self.permissions = permissions
    self.capabilities = capabilities
    self.systemShortcuts = systemShortcuts
    self.currentPhase = currentPhase
    self.perform = perform
    validator = ShortcutValidator(capabilities: capabilities)
  }

  isolated deinit {
    if let registration {
      registrar.unregister(registration)
    }
    modifierTap?.invalidate()
    escapeTap?.invalidate()
  }

  /// RegisterEventHotKey でいま登録している組み合わせ。登録していない（割当なし・登録の失敗・修飾キー単独）なら `nil`。
  ///
  /// セッション中に割当が変わると、待機に戻るまで前の組み合わせのまま（`update(_:)`）。Edit Mode のショートカットが
  /// 同じ組み合わせを二重に登録しないよう、`ShortcutAssignments` が使う
  var registeredCombination: KeyCombination? {
    registration == nil ? nil : setting?.combination
  }

  /// イベントタップを使う機能が有効か。有効なときだけ、アプリは権限の変化を `refreshPermissions` で反映する
  var usesEventTaps: Bool {
    capabilities.supportsModifierOnly || capabilities.supportsEscapeCapture
  }

  /// 割当を置き換える。`nil` なら登録しない（既定のショートカットは要件で決まっていない）。
  ///
  /// 前の割当は先に解除する。新しい割当を使えないときは何も登録せず、理由を `status` に残す。
  @discardableResult
  func apply(_ setting: GlobalShortcutSetting?) -> GlobalShortcutStatus {
    removeEscapeCapture()
    unregister()
    self.setting = setting
    status = register(setting)
    escapeStatus = installEscapeCapture()
    return status
  }

  /// 設定画面で変わった割当を、待機中ならすぐに、セッション中なら待機に戻ってから適用する。
  ///
  /// セッションの途中で登録し直すと、押下中の状態（Push-to-talk の解放での停止）と Esc の捕捉を失うため、
  /// 進行中のセッションでは変えない。今の割当と同じなら登録し直さない（競合・登録失敗の表示をそのまま残す）
  func update(_ setting: GlobalShortcutSetting?) {
    guard setting != self.setting else {
      pending = nil
      return
    }
    guard currentPhase() == .idle else {
      pending = PendingSetting(setting: setting)
      return
    }
    pending = nil
    apply(setting)
  }

  /// スリープ等で解放を取りこぼしうるときに、押下中の状態を破棄する。
  func reset() {
    translator.reset()
    interpreter.reset()
    detector?.reset()
    escapeFilter?.reset()
    updateEscapeTap()
  }

  /// セッションの状態が、ショートカット以外の要因（認識の完了・自動停止など）で変わったときに呼ぶ。
  /// Esc の捕捉をセッション中だけ有効にする。待機に戻ったら、セッション中に変わった割当を適用する。
  func sessionPhaseDidChange() {
    if let pending, currentPhase() == .idle {
      self.pending = nil
      apply(pending.setting)
      return
    }
    updateEscapeTap()
  }

  /// 権限の変化を反映する（PERM-02）。
  ///
  /// 使用中の権限が取り消されていればその機能だけを無効にし、権限がなくて使えなかった機能は許可されていれば有効にする。
  func refreshPermissions() {
    if modifierTap != nil, !permissions.isGranted(.inputMonitoring) {
      unregister()
      if let setting {
        status = .unavailable(setting, .eventTapUnavailable(.permissionMissing(.inputMonitoring)))
      }
      removeEscapeCapture()
      escapeStatus = .off
    } else if case .unavailable(_, .eventTapUnavailable(.permissionMissing(let permission))) =
      status, permissions.isGranted(permission)
    {
      apply(setting)
      return
    }
    if escapeTap != nil, !permissions.isGranted(.accessibility) {
      removeEscapeCapture()
      escapeStatus = .unavailable(.permissionMissing(.accessibility))
    } else if case .unavailable(.permissionMissing(let permission)) = escapeStatus,
      permissions.isGranted(permission)
    {
      escapeStatus = installEscapeCapture()
    }
  }

  /// 権限を求める。利用者がメニューから選んだときに呼ぶ（PERM-01）。
  func requestPermission(_ permission: EventTapPermission) {
    permissions.request(permission)
  }

  /// 登録したホットキー、または修飾キー単独の判定結果を受け取る。
  func receive(_ phase: HotKeyPhase) {
    guard let input = translator.translate(phase) else { return }
    if case .consumed(let command?) = interpreter.handle(input, phase: currentPhase()) {
      perform(command)
    }
    updateEscapeTap()
  }

  // MARK: - 登録

  private func register(_ setting: GlobalShortcutSetting?) -> GlobalShortcutStatus {
    guard let setting else { return .unassigned }
    let issues = Self.applicableIssues(
      validator.issues(
        for: setting.combination, bindingID: Self.recordBindingID, registered: systemShortcuts()),
      for: setting)
    guard issues.isEmpty else {
      return .unavailable(setting, .invalid(issues))
    }
    interpreter.mode = setting.mode
    interpreter.pressWhileProcessing = setting.pressWhileProcessing
    if let key = setting.modifierKey {
      return registerModifierOnly(key, setting: setting)
    }
    let spec: CarbonHotKeySpec
    switch CarbonHotKeySpec.make(for: setting.combination) {
    case .success(let made): spec = made
    case .failure(let issue): return .unavailable(setting, .unsupported(issue))
    }
    let result = registrar.register(spec) { [weak self] phase in
      self?.receive(phase)
    }
    switch result {
    case .success(let id):
      registration = id
      return .active(setting)
    case .failure(let failure):
      return .unavailable(setting, .registrationFailed(failure))
    }
  }

  /// 検証の問題のうち、この割当で実際に起きるもの。
  ///
  /// 修飾キー単独の Toggle は、他のキーを挟まずに離したときだけ反応する（`ModifierOnlyDetector`）ため、
  /// その修飾キーを含む別のショートカット（⌥⌘D 等）を押しても誤って反応しない。この場合だけ修飾キーの重複を除く。
  /// Push-to-talk は押下で開始するため、重複は実際に起きる競合として残す。
  static func applicableIssues(
    _ issues: [ShortcutValidationIssue], for setting: GlobalShortcutSetting
  ) -> [ShortcutValidationIssue] {
    guard setting.modifierKey != nil,
      ModifierOnlyDetector.Firing(mode: setting.mode) == .onCleanRelease
    else { return issues }
    return issues.filter { issue in
      if case .conflict(_, .modifierOverlap) = issue { return false }
      return true
    }
  }

  private func registerModifierOnly(_ key: ModifierOnlyKey, setting: GlobalShortcutSetting)
    -> GlobalShortcutStatus
  {
    let permission = KeyEventTapMode.listen.requiredPermission
    guard permissions.isGranted(permission) else {
      return .unavailable(setting, .eventTapUnavailable(.permissionMissing(permission)))
    }
    let detector = ModifierOnlyDetector(
      key: key, firing: ModifierOnlyDetector.Firing(mode: setting.mode))
    guard
      let tap = tapFactory.makeTap(
        mode: .listen,
        events: detector.observedEvents,
        enabled: true,
        handler: { [weak self] event in
          self?.receiveModifierEvent(event)
          // 修飾キーの監視ではイベントを止めない
          return true
        },
        onDisabled: { [weak self] in self?.modifierTapDisabled() }
      )
    else {
      return .unavailable(setting, .eventTapUnavailable(.tapCreationFailed))
    }
    modifierTap = tap
    self.detector = detector
    return .active(setting)
  }

  private func unregister() {
    if let registration {
      registrar.unregister(registration)
    }
    registration = nil
    modifierTap?.invalidate()
    modifierTap = nil
    detector = nil
    reset()
  }

  private func receiveModifierEvent(_ event: KeyTapEvent) {
    guard var detector else { return }
    let phases = detector.handle(event)
    self.detector = detector
    for phase in phases {
      receive(phase)
    }
  }

  private func modifierTapDisabled() {
    // 無効化中に解放を取りこぼした可能性があるため、押下中の状態を破棄してから再有効化する
    detector?.reset()
    translator.reset()
    interpreter.reset()
    // 権限が取り消されていれば、ここでタップごと外れる
    refreshPermissions()
    modifierTap?.setEnabled(true)
  }

  // MARK: - Esc の捕捉

  private func installEscapeCapture() -> EscapeCaptureStatus {
    // 設定でオフにしていても、capability が無効なら（#51 の判定まで）どちらにしても使わない
    guard capabilities.supportsEscapeCapture, case .active(let setting) = status,
      setting.cancelsWithEscape
    else {
      return .off
    }
    let permission = KeyEventTapMode.filter.requiredPermission
    guard permissions.isGranted(permission) else {
      return .unavailable(.permissionMissing(permission))
    }
    let filter = EscapeCaptureFilter(
      mode: setting.mode, triggerModifiers: setting.combination.modifiers)
    guard
      let tap = tapFactory.makeTap(
        mode: .filter,
        events: [.keyDown, .keyUp],
        // 待機中はタップを無効にし、他アプリの Esc 操作を見ない（REC-01）
        enabled: filter.needsTap(capturing: capturesEscapeNow),
        handler: { [weak self] event in self?.receiveEscapeEvent(event) ?? true },
        onDisabled: { [weak self] in self?.escapeTapDisabled() }
      )
    else { return .unavailable(.tapCreationFailed) }
    escapeTap = tap
    escapeFilter = filter
    return .ready
  }

  private func removeEscapeCapture() {
    escapeTap?.invalidate()
    escapeTap = nil
    escapeFilter = nil
  }

  private var capturesEscapeNow: Bool {
    ShortcutInterpreter.capturesEscape(in: currentPhase())
  }

  private func updateEscapeTap() {
    guard let escapeTap, let escapeFilter else { return }
    let enable = escapeFilter.needsTap(capturing: capturesEscapeNow)
    if escapeTap.isEnabled != enable {
      escapeTap.setEnabled(enable)
    }
  }

  /// 戻り値は他アプリへ渡すか。
  private func receiveEscapeEvent(_ event: KeyTapEvent) -> Bool {
    guard var filter = escapeFilter else { return true }
    let verdict = filter.handle(event, capturing: capturesEscapeNow)
    escapeFilter = filter
    // 解放の取りこぼしからの回復（.pass）でもフィルタの状態が変わるため、判定によらずタップの有効・無効を更新する
    defer { updateEscapeTap() }
    switch verdict {
    case .pass:
      return true
    case .swallow:
      return false
    case .cancel:
      if case .consumed(let command?) = interpreter.handle(.escapePressed, phase: currentPhase()) {
        perform(command)
      }
      return false
    }
  }

  private func escapeTapDisabled() {
    // 無効化中に Esc の解放を取りこぼした可能性があるため、止める状態を解除する
    escapeFilter?.reset()
    refreshPermissions()
    // 権限が残っていれば、セッション中なら再有効化する（OS が無効化したタップは isEnabled が false になる）
    updateEscapeTap()
  }
}

/// 待機に戻ってから適用する割当。割当なし（`nil`）への変更も待つため、`Optional` を包む
private struct PendingSetting {
  let setting: GlobalShortcutSetting?
}

/// 録音ショートカットの割当。
struct GlobalShortcutSetting: Hashable, Sendable {
  let combination: KeyCombination
  let mode: ShortcutTriggerMode
  /// 修飾キー単独のときの物理キー（左右の区別）。UtterCore の `KeyCombination` は左右を区別しないため、ここで持つ。
  /// 修飾キー単独でも物理キーを決められない組み合わせ（左右を指定しない Option 等）は `nil` で、登録できない
  let modifierKey: ModifierOnlyKey?
  /// 認識中・整形中にもう一度押したときの動作（REC-06）。既定は何もしない
  var pressWhileProcessing: ShortcutPressWhileProcessing = .ignore
  /// セッション中の Esc でキャンセルするか（REC-01）。既定はする。Esc の捕捉そのものは capability
  /// （`ShortcutCapabilities.supportsEscapeCapture`, #51 の判定待ち）が有効なときだけ使い、ここでオンにしても有効にならない
  var cancelsWithEscape = true

  /// 通常のキー組み合わせ。修飾キー単独の Fn は `modifierKey` を `.function` にする
  init(combination: KeyCombination, mode: ShortcutTriggerMode) {
    self.combination = combination
    self.mode = mode
    modifierKey = ModifierOnlyKey(combination: combination)
  }

  /// 修飾キー単独
  init(modifierKey: ModifierOnlyKey, mode: ShortcutTriggerMode) {
    combination = modifierKey.combination
    self.mode = mode
    self.modifierKey = modifierKey
  }
}

/// 録音ショートカットの状態。メニューに表示する。
enum GlobalShortcutStatus: Hashable, Sendable {
  /// 割当なし
  case unassigned
  /// 登録済み
  case active(GlobalShortcutSetting)
  /// 割当はあるが使えない
  case unavailable(GlobalShortcutSetting, GlobalShortcutUnavailableReason)
}

enum GlobalShortcutUnavailableReason: Hashable, Sendable {
  /// 割当の検証で問題がある（Esc の予約、システムのショートカットとの競合、修飾キー単独）
  case invalid([ShortcutValidationIssue])
  /// RegisterEventHotKey で扱えない組み合わせ
  case unsupported(HotKeySpecIssue)
  /// 登録に失敗した（他アプリとの競合など）
  case registrationFailed(HotKeyRegistrationFailure)
  /// 修飾キー単独の検出に使うイベントタップを使えない
  case eventTapUnavailable(EventTapUnavailableReason)
}

/// セッション中の Esc 捕捉の状態（REC-01）。
enum EscapeCaptureStatus: Hashable, Sendable {
  /// 使わない（capability が無効、ショートカットが登録されていない、または設定で Esc でのキャンセルをオフにした）
  case off
  /// 録音〜整形中に Esc を捕捉する
  case ready
  /// 使えない
  case unavailable(EventTapUnavailableReason)
}

enum EventTapUnavailableReason: Hashable, Sendable {
  /// 権限がない、または取り消された（PERM-02）
  case permissionMissing(EventTapPermission)
  /// 権限の確認は通ったが、タップを作成できなかった
  case tapCreationFailed
}
