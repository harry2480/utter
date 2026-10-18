import AppKit
import Carbon.HIToolbox
import Foundation
import UtterCore

/// Phase 0 検証 #51: 修飾キー単独ショートカットと Esc 捕捉の権限を実機で確かめる CLI。
/// 使い方は README.md と `hotkey-probe help` を参照。
@main
@MainActor
enum HotkeyProbe {
  static let usage = """
    使い方: HotkeyProbe <コマンド> [オプション]

    コマンド:
      permissions [--request-listen] [--request-accessibility]
          権限の状態を表示する。--request-* で許可ダイアログを要求する（操作は人が行う）
      system-shortcuts [<組み合わせ>]
          システムのショートカット一覧を表示する。組み合わせを渡すと UtterCore の検証結果も出す
      hotkey <組み合わせ> [--exclusive] [--register-twice] [--mode toggle|ptt]
          RegisterEventHotKey で通常の組み合わせを登録し、押下・解放を記録する（例: ctrl+option+k）
      modifier <修飾キー> [--backend tap|nsevent] [--tap listen|default] [--flags-only]
                         [--mode toggle|ptt] [--fire-on down|clean-up]
          修飾キー単独の押下・解放を記録する（例: fn, right-option, right-command）
      session [--trigger <組み合わせ|修飾キー>] [--esc-strategy toggle-tap|filter]
              [--esc-tap default|listen] [--processing-seconds 4] [--mode toggle|ptt]
              [--fire-on down|clean-up]
          ショートカットでセッションを模擬し、セッション中だけ Esc を捕捉する

    共通オプション:
      --log <パス>        ログをファイルにも追記する（例: logs/session.log。logs/ は gitignore 済み）
      --duration <秒>     指定秒数で終了する（省略時は Ctrl-C まで）

    修飾キー: \(ModifierTarget.all.map(\.name).joined(separator: ", "))
    """

  static func main() {
    var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
    do throws(ProbeError) {
      try run(&arguments)
    } catch {
      switch error {
      case .usage(let message):
        FileHandle.standardError.write(Data("エラー: \(message)\n\n\(usage)\n".utf8))
        exit(64)
      case .failed(let message):
        FileHandle.standardError.write(Data("失敗: \(message)\n".utf8))
        exit(1)
      }
    }
  }

  private static func run(_ arguments: inout Arguments) throws(ProbeError) {
    guard let command = arguments.next() else { throw .usage("コマンドを指定してください") }
    if command == "help" || command == "--help" {
      print(usage)
      return
    }
    let log: ProbeLog
    do {
      log = try ProbeLog(filePath: arguments.option("--log"))
    } catch {
      throw .failed("ログファイルを開けません: \(error.localizedDescription)")
    }
    let duration = try arguments.option("--duration").map { text throws(ProbeError) in
      guard let seconds = Double(text), seconds > 0 else { throw .usage("--duration は正の秒数") }
      return seconds
    }
    log.write("start", "command=\(command) pid=\(getpid()) 実行ファイル=\(CommandLine.arguments[0])")

    switch command {
    case "permissions":
      try runPermissions(&arguments, log: log)
      log.close()
      return
    case "system-shortcuts":
      try runSystemShortcuts(&arguments, log: log)
      log.close()
      return
    case "hotkey":
      try startHotkey(&arguments, log: log)
    case "modifier":
      try startModifier(&arguments, log: log)
    case "session":
      try startSession(&arguments, log: log)
    default:
      throw .usage("不明なコマンド: \(command)")
    }
    try arguments.finish()
    runEventLoop(log: log, duration: duration)
  }

  // MARK: - permissions

  private static func runPermissions(_ arguments: inout Arguments, log: ProbeLog) throws(ProbeError)
  {
    let requestListen = arguments.flag("--request-listen")
    let requestAccessibility = arguments.flag("--request-accessibility")
    try arguments.finish()
    log.write("perm", "権限は実行したターミナルアプリ（責任のあるプロセス）に対して判定される")
    Permissions.log(Permissions.snapshot(), to: log)
    if requestListen {
      log.write("perm", "CGRequestListenEventAccess()=\(Permissions.requestListenEvent())")
    }
    if requestAccessibility {
      log.write(
        "perm", "AXIsProcessTrustedWithOptions(prompt)=\(Permissions.requestAccessibility())")
    }
    if requestListen || requestAccessibility {
      log.write("perm", "許可を変えたらターミナルアプリを再起動してから permissions を再実行する")
    }
  }

  // MARK: - system-shortcuts

  private static func runSystemShortcuts(_ arguments: inout Arguments, log: ProbeLog)
    throws(ProbeError)
  {
    let candidate = try arguments.next().map { text throws(ProbeError) in
      try parseCandidate(text)
    }
    try arguments.finish()
    let entries = SystemShortcuts.load()
    log.write("system", "システムのショートカット \(entries.count) 件（CopySymbolicHotKeys）")
    for entry in entries {
      log.write(
        "system",
        "\(entry.binding.id) 有効=\(entry.enabled) key=\(entry.binding.combination.key?.rawValue ?? "-") modifiers=\(describe(entry.binding.combination.modifiers)) raw=0x\(String(entry.rawModifiers, radix: 16))"
      )
    }
    if let candidate {
      logValidation(candidate, log: log)
    }
  }

  // MARK: - hotkey

  private static func startHotkey(_ arguments: inout Arguments, log: ProbeLog) throws(ProbeError) {
    guard let text = arguments.next() else { throw .usage("組み合わせを指定してください") }
    let exclusive = arguments.flag("--exclusive")
    let registerTwice = arguments.flag("--register-twice")
    let mode = try parseMode(arguments.option("--mode"))
    let parsed = try ParsedCombination.parse(text)
    guard let keyCode = parsed.keyCode else {
      throw .usage("RegisterEventHotKey には通常のキーが必要です。修飾キー単独は modifier コマンドを使う")
    }
    Permissions.log(Permissions.snapshot(), to: log)
    logValidation(parsed.combination, log: log)

    let simulator = SessionSimulator(mode: mode, processingSeconds: 4, log: log)
    let hotKeys = CarbonHotKeys { id, phase in
      log.write("hotkey", "id=\(id) \(phase == .pressed ? "pressed" : "released")")
      _ = simulator.handle(
        phase == .pressed ? .shortcutPressed(isRepeat: false) : .shortcutReleased)
    }
    log.write("hotkey", "InstallEventHandler=\(hotKeys.installHandler())")
    let times = registerTwice ? 2 : 1
    for attempt in 1...times {
      let (status, id) = hotKeys.register(
        keyCode: keyCode, carbonModifiers: parsed.carbonModifiers, exclusive: exclusive)
      log.write(
        "hotkey",
        "登録\(attempt) \(text) exclusive=\(exclusive) carbonModifiers=0x\(String(parsed.carbonModifiers, radix: 16)) → \(CarbonHotKeys.describe(status)) id=\(id.map(String.init) ?? "-")"
      )
    }
    log.write("hotkey", "登録が成功しても、システム側が先に処理する組み合わせは届かない。押して pressed が出るかを確かめる")
    retained.append(hotKeys)
    retained.append(simulator)
  }

  // MARK: - modifier

  private static func startModifier(_ arguments: inout Arguments, log: ProbeLog) throws(ProbeError)
  {
    guard let name = arguments.next(), let target = ModifierTarget.named(name) else {
      throw .usage("修飾キーを指定してください")
    }
    let backend = try parseEnum(arguments.option("--backend"), default: ModifierWatcher.Backend.tap)
    let tapMode = try parseEnum(arguments.option("--tap"), default: EventTap.Mode.listen)
    let flagsOnly = arguments.flag("--flags-only")
    let mode = try parseMode(arguments.option("--mode"))
    let fireOn = try parseFireOn(arguments.option("--fire-on"), mode: mode)

    Permissions.log(Permissions.snapshot(), to: log)
    guard let combination = KeyCombination(modifierOnly: target.modifier) else {
      throw .failed("修飾キーの変換に失敗")
    }
    logValidation(combination, log: log)
    let simulator = SessionSimulator(mode: mode, processingSeconds: 4, log: log)
    let watcher = try startWatcher(
      target: target, backend: backend, tapMode: tapMode, includeKeyEvents: !flagsOnly,
      fireOn: fireOn, simulator: simulator, log: log)
    retained.append(watcher)
    retained.append(simulator)
    startSecureInputMonitor(log: log)
  }

  // MARK: - session

  private static func startSession(_ arguments: inout Arguments, log: ProbeLog) throws(ProbeError) {
    let trigger = arguments.option("--trigger") ?? "ctrl+option+k"
    let strategy = try parseEnum(
      arguments.option("--esc-strategy"), default: EscapeCapture.Strategy.toggleTap)
    let escTapMode = try parseEnum(arguments.option("--esc-tap"), default: EventTap.Mode.default)
    let mode = try parseMode(arguments.option("--mode"))
    let fireOn = try parseFireOn(arguments.option("--fire-on"), mode: mode)
    let processingText = arguments.option("--processing-seconds") ?? "4"
    guard let processingSeconds = Double(processingText), processingSeconds >= 0 else {
      throw .usage("--processing-seconds は0以上の秒数")
    }

    Permissions.log(Permissions.snapshot(), to: log)
    let simulator = SessionSimulator(mode: mode, processingSeconds: processingSeconds, log: log)
    let escape = EscapeCapture(strategy: strategy, simulator: simulator, log: log)
    simulator.onPhaseChange = { _ in escape.update() }
    guard escape.install(mode: escTapMode) else {
      throw .failed(
        "Esc のイベントタップを作成できません（\(escTapMode.rawValue)）。default はアクセシビリティ、listen は入力監視の許可が必要")
    }
    retained.append(escape)
    retained.append(simulator)

    if let target = ModifierTarget.named(trigger) {
      let watcher = try startWatcher(
        target: target, backend: .tap, tapMode: .listen, includeKeyEvents: true,
        fireOn: fireOn, simulator: simulator, log: log)
      retained.append(watcher)
    } else {
      let parsed = try ParsedCombination.parse(trigger)
      guard let keyCode = parsed.keyCode else { throw .usage("未対応のトリガー: \(trigger)") }
      let hotKeys = CarbonHotKeys { _, phase in
        log.write("hotkey", "trigger \(phase == .pressed ? "pressed" : "released")")
        _ = simulator.handle(
          phase == .pressed ? .shortcutPressed(isRepeat: false) : .shortcutReleased)
      }
      _ = hotKeys.installHandler()
      let (status, _) = hotKeys.register(
        keyCode: keyCode, carbonModifiers: parsed.carbonModifiers, exclusive: false)
      log.write("hotkey", "トリガー \(trigger) 登録 → \(CarbonHotKeys.describe(status))")
      guard status == noErr else { throw .failed("トリガーを登録できません") }
      retained.append(hotKeys)
    }
    log.write("session", "待機中。トリガーで録音開始（模擬）。録音〜整形中だけ Esc を捕捉する")
    startSecureInputMonitor(log: log)
  }

  // MARK: - 共通

  /// イベントループが動いている間、生かしておくオブジェクト
  private static var retained: [AnyObject] = []

  enum FireOn: String {
    /// 押下で押下、解放で解放として渡す
    case down
    /// 他のキーを挟まずに離したときだけ、押下＋解放として渡す（Toggle 向け）
    case cleanUp = "clean-up"
  }

  private static func startWatcher(
    target: ModifierTarget, backend: ModifierWatcher.Backend, tapMode: EventTap.Mode,
    includeKeyEvents: Bool, fireOn: FireOn, simulator: SessionSimulator, log: ProbeLog
  ) throws(ProbeError) -> ModifierWatcher {
    var forwardedDown = false
    let watcher = ModifierWatcher(target: target, log: log) { change in
      switch (change, fireOn) {
      case (.down(let othersDown), .down):
        guard !othersDown else {
          log.write("modifier", "他の修飾キーと同時のため、ショートカットとして扱わない")
          return
        }
        forwardedDown = true
        simulator.handle(.shortcutPressed(isRepeat: false))
      case (.up, .down):
        guard forwardedDown else { return }
        forwardedDown = false
        simulator.handle(.shortcutReleased)
      case (.down(let othersDown), .cleanUp):
        forwardedDown = !othersDown
      case (.up(_, let otherKey), .cleanUp):
        guard forwardedDown, !otherKey else {
          log.write("modifier", "他のキーと併用されたため、ショートカットとして扱わない")
          forwardedDown = false
          return
        }
        forwardedDown = false
        simulator.handle(.shortcutPressed(isRepeat: false))
        simulator.handle(.shortcutReleased)
      }
    }
    watcher.onReset = {
      forwardedDown = false
      simulator.resetInterpreter()
    }
    let started = watcher.start(
      backend: backend, tapMode: tapMode, includeKeyEvents: includeKeyEvents)
    log.write(
      "modifier",
      "監視開始 target=\(target.name) backend=\(backend.rawValue) tap=\(tapMode.rawValue) keyDownも監視=\(includeKeyEvents) fireOn=\(fireOn.rawValue) → \(started ? "成功" : "失敗")"
    )
    guard started else {
      throw .failed(
        "イベントタップを作成できません。listen は入力監視、default はアクセシビリティの許可が必要（permissions で確認）")
    }
    return watcher
  }

  private static func startSecureInputMonitor(log: ProbeLog) {
    Task { @MainActor in
      var last = IsSecureEventInputEnabled()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        let now = IsSecureEventInputEnabled()
        if now != last {
          log.write("secure", "SecureEventInput 有効=\(now)（有効中はキーボードのイベントタップに届かない）")
          last = now
        }
      }
    }
  }

  private static func runEventLoop(log: ProbeLog, duration: Double?) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { finish(log: log, reason: "Ctrl-C") }
    }
    source.resume()
    retained.append(source as AnyObject)
    if let duration {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(duration))
        finish(log: log, reason: "--duration \(duration)s")
      }
    }
    log.write("loop", "イベントループ開始。終了は Ctrl-C")
    app.run()
  }

  private static func finish(log: ProbeLog, reason: String) {
    for object in retained {
      (object as? EscapeCapture)?.uninstall()
      (object as? ModifierWatcher)?.stop()
      (object as? CarbonHotKeys)?.unregisterAll()
    }
    log.write("end", "終了（\(reason)）")
    log.close()
    exit(0)
  }

  private static func logValidation(_ combination: KeyCombination, log: ProbeLog) {
    let registered = SystemShortcuts.load().filter(\.enabled).map(\.binding)
    let validator = ShortcutValidator(
      capabilities: ShortcutCapabilities(supportsModifierOnly: true))
    let issues = validator.issues(
      for: combination, bindingID: "utter.record", registered: registered)
    log.write(
      "validate",
      "UtterCore ShortcutValidator（修飾キー単独を許可として判定）: key=\(combination.key?.rawValue ?? "-") modifiers=\(describe(combination.modifiers)) 有効なシステムのショートカット \(registered.count) 件と比較 → 問題 \(issues.count) 件"
    )
    for issue in issues.prefix(10) {
      log.write("validate", "  \(issue)")
    }
    if issues.count > 10 {
      log.write("validate", "  ほか \(issues.count - 10) 件（system-shortcuts で一覧を確認）")
    }
  }

  private static func describe(_ modifiers: ShortcutModifiers) -> String {
    let names: [(ShortcutModifiers, String)] = [
      (.control, "ctrl"), (.option, "option"), (.shift, "shift"), (.command, "cmd"),
      (.function, "fn"),
    ]
    let parts = names.filter { modifiers.contains($0.0) }.map(\.1)
    return parts.isEmpty ? "-" : parts.joined(separator: "+")
  }

  private static func parseCandidate(_ text: String) throws(ProbeError) -> KeyCombination {
    if let target = ModifierTarget.named(text),
      let combination = KeyCombination(
        modifierOnly: target.modifier)
    {
      return combination
    }
    return try ParsedCombination.parse(text).combination
  }

  private static func parseMode(_ text: String?) throws(ProbeError) -> ShortcutTriggerMode {
    switch text {
    case nil, "toggle": .toggle
    case "ptt": .pushToTalk
    case let other?: throw .usage("--mode は toggle か ptt: \(other)")
    }
  }

  private static func parseFireOn(_ text: String?, mode: ShortcutTriggerMode) throws(ProbeError)
    -> FireOn
  {
    let fireOn = try parseEnum(text, default: FireOn.down)
    if fireOn == .cleanUp && mode == .pushToTalk {
      throw .usage("--fire-on clean-up は --mode toggle でのみ使える")
    }
    return fireOn
  }

  private static func parseEnum<T: RawRepresentable>(_ text: String?, default value: T)
    throws(ProbeError) -> T where T.RawValue == String
  {
    guard let text else { return value }
    guard let parsed = T(rawValue: text) else { throw .usage("不明な値: \(text)") }
    return parsed
  }
}

/// 引数の簡易パーサー。
struct Arguments {
  private var items: [String]

  init(_ items: [String]) {
    self.items = items
  }

  /// 先頭の位置引数（オプションとその値以外）を取り出す
  mutating func next() -> String? {
    var index = 0
    while index < items.count {
      let item = items[index]
      if Self.valueOptions.contains(item) {
        index += 2
      } else if item.hasPrefix("--") {
        index += 1
      } else {
        return items.remove(at: index)
      }
    }
    return nil
  }

  mutating func flag(_ name: String) -> Bool {
    guard let index = items.firstIndex(of: name) else { return false }
    items.remove(at: index)
    return true
  }

  mutating func option(_ name: String) -> String? {
    guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
    let value = items[index + 1]
    items.removeSubrange(index...(index + 1))
    return value
  }

  func finish() throws(ProbeError) {
    guard items.isEmpty else { throw .usage("不明な引数: \(items.joined(separator: " "))") }
  }

  private static let valueOptions: Set<String> = [
    "--log", "--duration", "--mode", "--backend", "--tap", "--fire-on", "--trigger",
    "--esc-strategy", "--esc-tap", "--processing-seconds",
  ]
}
