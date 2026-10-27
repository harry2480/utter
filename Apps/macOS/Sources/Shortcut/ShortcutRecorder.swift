import AppKit
import Carbon.HIToolbox
import UtterCore

/// 設定画面で録音ショートカットを記録するときの、キー入力の解釈（REC-01, REC-02）。
///
/// 「記録」を押した後の次のキー入力を `KeyCombination` にする。受け付けるのは、RegisterEventHotKey で登録できる
/// 通常のキーの組み合わせだけ（`CarbonHotKeySpec`）。修飾キー単独と Fn を含む組み合わせは #51 の判定まで扱わない。
/// 修飾キーなしの Esc は記録の取り消しに使う。
///
/// OS のイベントは受け取らない純粋な値型で、画面（`NSEvent` のローカルモニター）が `Event` にして渡す。
/// 入力されたキーは結果の組み合わせ以外に保持せず、ログにも出さない。
struct ShortcutRecorder: Sendable {
  /// 画面から渡すキー入力
  enum Event: Hashable, Sendable {
    /// 修飾キー以外のキーの押下（`NSEvent.keyCode` と、そのとき押されている修飾キー）。キーリピートは渡さない
    case keyDown(keyCode: UInt16, modifiers: ShortcutModifiers)
    /// 修飾キーの押下・解放（変化した後に押されている修飾キー）
    case flagsChanged(modifiers: ShortcutModifiers)
  }

  /// キー入力の結果
  enum Outcome: Hashable, Sendable {
    /// 割り当てられる組み合わせ。記録を終える
    case recorded(KeyCombination)
    /// 修飾キーなしの Esc。割当を変えずに記録を終える
    case cancelled
    /// 割り当てられない。理由を示し、記録を続ける
    case rejected(ShortcutRecordingIssue)
  }

  /// 競合を検出する相手（有効なシステムのショートカット）。記録を始めるときに取得する
  let systemShortcuts: [ShortcutBinding]
  /// 最後に通常のキーを押してから、同時に押された修飾キー。修飾キーだけを押して離したことの判定に使う
  private var pressedModifiers: ShortcutModifiers = []

  init(systemShortcuts: [ShortcutBinding]) {
    self.systemShortcuts = systemShortcuts
  }

  /// キー入力を1つ受け取る。結果がまだ決まらない（修飾キーを押している途中）なら `nil`。
  mutating func handle(_ event: Event) -> Outcome? {
    switch event {
    case .keyDown(let keyCode, let modifiers):
      pressedModifiers = []
      if Int(keyCode) == kVK_Escape, modifiers.isEmpty {
        return .cancelled
      }
      let result = Self.combination(keyCode: keyCode, modifiers: modifiers)
      switch result {
      case .failure(let issue):
        return .rejected(issue)
      case .success(let combination):
        if let issue = Self.issue(for: combination, systemShortcuts: systemShortcuts) {
          return .rejected(issue)
        }
        return .recorded(combination)
      }
    case .flagsChanged(let modifiers):
      guard modifiers.isEmpty else {
        pressedModifiers.formUnion(modifiers)
        return nil
      }
      // 通常のキーを挟まずにすべての修飾キーを離した
      let released = pressedModifiers
      pressedModifiers = []
      guard !released.isEmpty else { return nil }
      return .rejected(released.contains(.function) ? .functionModifier : .modifierOnly)
    }
  }

  // MARK: - 変換と判定

  /// 押されたキーを組み合わせにする。対応表（`MacKeyCodes`）にないキーは `unsupportedKey`。
  ///
  /// `NSEvent` は F キー・矢印キーの押下に Fn のビット（`.function`）を付けるため、これらのキーでは外す
  /// （`SystemShortcuts` の照合と同じ）。そのため Fn を押しながらの F キー・矢印キーは Fn なしと同じに扱う。
  static func combination(keyCode: UInt16, modifiers: ShortcutModifiers)
    -> Result<KeyCombination, ShortcutRecordingIssue>
  {
    guard let name = MacKeyCodes.namesByCode[UInt32(keyCode)], let key = ShortcutKey(rawValue: name)
    else { return .failure(.unsupportedKey) }
    var modifiers = modifiers
    if MacKeyCodes.isFunctionKey(key) || MacKeyCodes.isArrowKey(key) {
      modifiers.remove(.function)
    }
    return .success(KeyCombination(key: key, modifiers: modifiers))
  }

  /// 録音ショートカットとして割り当てられない理由。割り当てられるなら `nil`。
  ///
  /// 登録時（`GlobalShortcutController`）と同じく、RegisterEventHotKey で扱えるか（`CarbonHotKeySpec`）と、
  /// Esc の予約・システムのショートカットとの競合（`ShortcutValidator`）を確かめる。
  /// 他アプリが独自に処理するショートカットは検出できない。
  static func issue(for combination: KeyCombination, systemShortcuts: [ShortcutBinding])
    -> ShortcutRecordingIssue?
  {
    if case .failure(let issue) = CarbonHotKeySpec.make(for: combination) {
      return ShortcutRecordingIssue(issue)
    }
    let issues = ShortcutValidator(capabilities: .keyCombinationsOnly).issues(
      for: combination, bindingID: GlobalShortcutController.recordBindingID,
      registered: systemShortcuts)
    return issues.first.map { ShortcutRecordingIssue($0) }
  }

  /// `NSEvent` の修飾キーを UtterCore の型にする。Caps Lock・テンキー・Help のビットは使わない（左右は区別しない）。
  static func modifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    var result: ShortcutModifiers = []
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.shift) { result.insert(.shift) }
    if flags.contains(.function) { result.insert(.function) }
    return result
  }

  // MARK: - 表示

  /// 設定画面に出す現在の割当（例: `⌥⌘R`）。未設定なら「未設定」。
  static func displayText(for combination: KeyCombination?) -> String {
    combination.map { ShortcutNotation.display($0) } ?? "未設定"
  }

  /// 記録中に出す案内
  static let promptText = "割り当てるキーを押してください（Esc で取り消し）"
}

/// 記録したキー入力を録音ショートカットにできない理由（REC-01, REC-02）。利用者の入力したキーは含めない。
enum ShortcutRecordingIssue: Error, Hashable, Sendable {
  /// 修飾キーだけを押して離した（#51 の判定待ち）
  case modifierOnly
  /// Fn / 地球儀キーを含む
  case functionModifier
  /// 対応表にないキー
  case unsupportedKey
  /// F1〜F20 以外のキーで、Command・Option・Control のいずれも含まない
  case missingModifier
  /// 修飾キーなしの Esc（セッション中のキャンセルに予約）
  case reservedForCancel
  /// 有効なシステムのショートカットと重なる
  case conflictsWithSystemShortcut

  init(_ issue: HotKeySpecIssue) {
    switch issue {
    case .modifierOnly: self = .modifierOnly
    case .functionModifier: self = .functionModifier
    case .unsupportedKey: self = .unsupportedKey
    case .missingModifier: self = .missingModifier
    }
  }

  init(_ issue: ShortcutValidationIssue) {
    switch issue {
    case .modifierOnlyUnsupported: self = .modifierOnly
    case .reservedForCancel: self = .reservedForCancel
    case .conflict: self = .conflictsWithSystemShortcut
    }
  }

  /// 画面に出す文言。押されたキーは埋め込まない
  var message: String {
    switch self {
    case .modifierOnly:
      "修飾キーだけでは割り当てられません。修飾キーを押しながらほかのキーを押してください。"
    case .functionModifier:
      "Fn（地球儀キー）を含む組み合わせには対応していません。"
    case .unsupportedKey:
      "このキーには対応していません。英数字・Space・Return・Tab・Delete・矢印・F1〜F20 などを使ってください。"
    case .missingModifier:
      "Command・Option・Control のいずれかと組み合わせてください（F1〜F20 は単独でも使えます）。"
    case .reservedForCancel:
      "Esc は録音のキャンセルに使います。"
    case .conflictsWithSystemShortcut:
      "システムのショートカットと重なっています。システム設定で外すか、別の組み合わせにしてください。"
    }
  }
}
