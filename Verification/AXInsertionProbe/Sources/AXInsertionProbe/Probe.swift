import AppKit
import ApplicationServices
import UtterCore

@MainActor
enum Probe {
  static func check(prompt: Bool) -> Int32 {
    let trusted = Permissions.isAccessibilityTrusted(prompt: prompt)
    let canPost = Permissions.canPostEvents(request: prompt)
    print("Accessibility（AXIsProcessTrusted）: \(trusted ? "許可済み" : "未許可")")
    print("イベント送信（CGPreflightPostEventAccess）: \(canPost ? "許可済み" : "未許可")")
    print(
      "セキュア入力（IsSecureEventInputEnabled）: \(Permissions.isSecureEventInputEnabled ? "有効" : "無効")")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    if !trusted || !canPost {
      print("")
      print(Permissions.guidance)
      return 1
    }
    return 0
  }

  static func inspect(delay: Double) -> Int32 {
    guard requireTrust() else { return 1 }
    countdown(delay, message: "秒後にフォーカス中の要素を調べます。対象の入力欄をクリックしてください。")
    guard let target = FocusedTarget.current() else {
      print("フォーカス中の要素を取得できませんでした（AXFocusedUIElement なし）。")
      return 1
    }
    let snapshot = ReadBack.snapshot(target.element)
    print("bundle ID: \(target.bundleID)")
    print("アプリ版: \(target.appVersion)")
    print("role / subrole: \(target.role) / \(target.subrole.isEmpty ? "-" : target.subrole)")
    print("セキュア入力欄: \(target.isSecureField ? "はい（挿入しない）" : "いいえ")")
    print("ターミナル系: \(target.isTerminal ? "はい" : "いいえ")")
    for attribute in [AXAttribute.value, AXAttribute.selectedText, AXAttribute.selectedTextRange] {
      print("\(attribute) 書き込み可: \(AX.isSettable(target.element, attribute) ? "可" : "不可")")
    }
    print("AXValue 読み取り: \(snapshot.value.map { "可（\($0.utf16.count) 文字。中身は表示しない）" } ?? "不可")")
    if let range = snapshot.selectedRange {
      print("選択範囲: location \(range.location), length \(range.length)")
    } else {
      print("選択範囲: 取得不可")
    }
    return 0
  }

  static func run(_ options: RunOptions) -> Int32 {
    guard requireTrust() else { return 1 }
    if options.route == .pasteboard || options.route == .cgevent,
      !Permissions.canPostEvents(request: false)
    {
      print("イベント送信の権限がありません。`ax-insertion-probe check --prompt` を実行してください。")
      return 1
    }
    print("経路: \(options.route.rawValue)、文字列: \(options.text.rawValue)、試行: \(options.trials) 回")
    print("記録先: \(options.outputDirectory)/trials.csv, trials.jsonl")
    for trial in 1...options.trials {
      if trial == 1 || options.interactive {
        countdown(options.delay, message: "秒後に挿入します。対象アプリの入力欄をクリックしてカーソルを置いてください。")
      } else {
        Thread.sleep(forTimeInterval: options.interval)
      }
      var record = runTrial(trial, options: options)
      if options.interactive {
        askHuman(&record, options: options)
      }
      record.outcome = outcome(of: record)
      do {
        try RecordWriter.append(record, to: options.outputDirectory)
      } catch {
        print("記録の書き込みに失敗しました: \(error.localizedDescription)")
        return 1
      }
      print(
        "[\(trial)/\(options.trials)] \(record.bundleID) \(record.route): \(record.outcome)"
          + "（応答 \(record.response.isEmpty ? "-" : record.response)、読み戻し \(record.readBack.isEmpty ? "-" : record.readBack)"
          + (record.skipReason.isEmpty ? "" : "、理由 \(record.skipReason)")
          + (record.restore.isEmpty || record.restore == RestoreOutcome.notApplicable.rawValue
            ? "" : "、復元 \(record.restore)")
          + "、\(record.confirmMs)ms）")
    }
    return 0
  }

  // MARK: - 1回の試行

  private static func runTrial(_ trial: Int, options: RunOptions) -> TrialRecord {
    var record = TrialRecord()
    record.timestamp = ISO8601DateFormatter().string(from: Date())
    record.label = options.label
    record.trial = trial
    record.route = options.route.rawValue
    record.insertionRoute = "\(options.route.insertionRoute)"
    record.macOS = ProcessInfo.processInfo.operatingSystemVersionString
    record.textPreset = options.text.rawValue
    record.axFlag = options.axFlag ?? ""
    record.markers = options.route == .pasteboard ? options.markers.rawValue : ""
    record.restore = RestoreOutcome.notApplicable.rawValue

    func skip(_ reason: String) -> TrialRecord {
      record.result = "skipped"
      record.skipReason = reason
      return record
    }

    guard var target = FocusedTarget.current() else { return skip("no-focus") }
    fill(&record, with: target)

    var restoreFlag: (() -> Void)?
    if let flag = options.axFlag {
      restoreFlag = enableAppFlag(flag, pid: target.pid)
      // 属性を有効にするとアプリが AX ツリーを作り直すため、少し待って取り直す
      Thread.sleep(forTimeInterval: 1.0)
      guard let refreshed = FocusedTarget.current(), refreshed.pid == target.pid else {
        restoreFlag?()
        return skip("target-changed")
      }
      target = refreshed
      fill(&record, with: target)
    }
    defer { restoreFlag?() }

    if Permissions.isSecureEventInputEnabled { return skip("secure-input") }
    if target.isSecureField { return skip("secure-field") }
    if target.isTerminal, options.text.containsNewline, !options.allowMultilineInTerminal {
      return skip("multiline-in-terminal")
    }
    if options.hold > 0 {
      Thread.sleep(forTimeInterval: options.hold)
      guard let again = FocusedTarget.current(), again.isSameElement(as: target) else {
        return skip("target-changed")
      }
    }

    let text = options.text.text
    let before = ReadBack.snapshot(target.element)
    let clock = ContinuousClock()
    let start = clock.now
    var pending: PendingRestore?
    let response: InsertionResponse
    switch options.route {
    case .axSelected:
      response = Inserter.axSelected(target.element, text: text)
    case .axValue:
      response = Inserter.axValue(target.element, before: before, text: text)
    case .cgevent:
      response = Inserter.cgEvent(text: text)
    case .pasteboard:
      (response, pending) = Inserter.pasteboard(text: text, markers: options.markers)
    }
    record.insertMs = milliseconds(clock.now - start)

    let (readBack, method) = ReadBack.poll(
      element: target.element, before: before, text: text, timeout: options.readBackTimeout)
    record.confirmMs = milliseconds(clock.now - start)

    if let pending {
      record.clipboardItems = pending.snapshot.items.count
      record.clipboardTypes = pending.snapshot.typeCount
      record.clipboardUnreadableTypes = pending.snapshot.unreadableTypeCount
      Thread.sleep(forTimeInterval: options.restoreDelay)
      record.restore =
        PasteboardRestorer.restore(
          pending.snapshot, on: NSPasteboard.general, policy: pending.policy
        ).rawValue
    }

    record.response = "\(response)"
    record.readBack = "\(readBack)"
    record.readBackMethod = method.rawValue
    switch InsertionResult.classify(
      route: options.route.insertionRoute, response: response, readBack: readBack)
    {
    case .verified: record.result = "verified"
    case .unconfirmed: record.result = "unconfirmed"
    case .failed: record.result = "failed"
    case .preview: record.result = "preview"
    }
    return record
  }

  private static func fill(_ record: inout TrialRecord, with target: FocusedTarget) {
    record.bundleID = target.bundleID
    record.appVersion = target.appVersion
    record.role = target.role
    record.subrole = target.subrole
  }

  /// アプリ要素に属性を true で設定し、元に戻す処理を返す
  private static func enableAppFlag(_ flag: String, pid: pid_t) -> () -> Void {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
    let previous = (AX.copy(app, flag) as? Bool) ?? false
    _ = AX.set(app, flag, kCFBooleanTrue)
    return { _ = AX.set(app, flag, previous ? kCFBooleanTrue : kCFBooleanFalse) }
  }

  // MARK: - 人の記録

  private static func askHuman(_ record: inout TrialRecord, options: RunOptions) {
    guard record.result != "skipped" else { return }
    if record.result != "verified" {
      record.visualMatch = ask(
        "対象の入力欄に、ダミー文字列がちょうど1回、欠けずに入っていますか（目視）",
        choices: [("y", "yes"), ("n", "no")])
    }
    print("対象アプリへ戻り、⌘Z を1回だけ押してから、ここへ戻って答えてください。")
    record.undo = ask(
      "⌘Z 1回で挿入全体が取り消されましたか（o: 1回で全体 / m: 複数回必要 / p: 一部だけ / x: 取り消せない）",
      choices: [("o", "once"), ("m", "multiple"), ("p", "partial"), ("x", "none")])
    if options.route == .pasteboard {
      record.clipboardHistory = ask(
        "クリップボード管理アプリの履歴にダミー文字列が残っていますか",
        choices: [("y", "yes"), ("n", "no")])
    }
    print("メモ（なければ Enter）:")
    record.note = readLine(strippingNewline: true) ?? ""
  }

  /// 選択肢を質問する。s または空入力は「未記録」として空欄を返す
  private static func ask(_ question: String, choices: [(key: String, value: String)]) -> String {
    let keys = (choices.map(\.key) + ["s"]).joined(separator: "/")
    while true {
      print("\(question) [\(keys)]（s: 記録しない）")
      let answer = (readLine(strippingNewline: true) ?? "s").trimmingCharacters(in: .whitespaces)
        .lowercased()
      if answer.isEmpty || answer == "s" { return "" }
      if let match = choices.first(where: { $0.key == answer }) { return match.value }
    }
  }

  // MARK: - 補助

  private static func outcome(of record: TrialRecord) -> String {
    switch (record.result, record.visualMatch) {
    case ("skipped", _): "skipped"
    case ("verified", _): "success"
    case (_, "yes"): "success-visual"
    case (_, "no"): "failure"
    case ("failed", _): "failure"
    default: "unknown"
    }
  }

  private static func requireTrust() -> Bool {
    guard Permissions.isAccessibilityTrusted(prompt: false) else {
      print(Permissions.guidance)
      return false
    }
    return true
  }

  private static func countdown(_ seconds: Double, message: String) {
    print("\(Int(seconds.rounded(.up))) \(message)")
    var remaining = seconds
    while remaining > 0 {
      let step = min(1, remaining)
      Thread.sleep(forTimeInterval: step)
      remaining -= step
      if remaining > 0 { print("  \(Int(remaining.rounded(.up)))…") }
    }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
