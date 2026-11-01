// #233 の待機セッション方式を、つないだ iPhone の上で自動で試す UI テスト。本番コードではない。
//
// 前提:
// - iPhone を Mac につなぎ、ロックを解除しておく。キーボード「utter Probe」を追加し、フルアクセスをオンにしておく
// - 入力先にはメモアプリの新しいメモを使う（最後に削除する）
// - 声は Mac のスピーカーから合成音声を流し続けて、iPhone のマイクに拾わせる（run-ui-tests.sh）
// - キーボードの中と App Group は UI テストから見えない。本体アプリを -ProbeUITest YES で起動すると、キーボードが
//   App Group に書いたボタンの位置・本体アプリの状態・計測の記録を読み取り用に出すので、それを読む
//   （UITestReadout）。キーボードのボタンはその位置を座標でタップする
// - 結果は「UTTER-RESULT」で始まる行に出す
//
// 発話の本文はテストの記録に出さない（文字数だけを出す）。

import XCTest

@MainActor
final class VoiceSessionUITests: XCTestCase {
  private let probe = XCUIApplication()
  private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
  /// キーボードのボタンの位置（メモを開いたときに読んだもの）
  private var layout: Probe.Presence?
  private var testStarted = Date()

  override func setUp() async throws {
    continueAfterFailure = false
    probe.launchArguments = ["-ProbeIdleTimeoutMinutes", "0", "-ProbeUITest", "YES"]
    testStarted = Date()
  }

  // MARK: 1回だけ試す（準備ができているかの確認）

  func testSingleCycle() throws {
    try startStandby()
    try openNewNote()
    let added = try runCycle(speakSeconds: 4)
    report("single", "増えた文字数 \(added)")
    let sessions = analyze(readProbe().events)
    for line in sessions { report("single", line.line) }
    XCTAssertEqual(sessions.first?.outcome, "inserted")
    clearNote()
  }

  // MARK: 2. 20回続けて使う

  func testTwentyCycles() throws {
    try startStandby()
    try openNewNote()
    var added: [Int] = []
    for _ in 1...20 {
      added.append(try runCycle(speakSeconds: 3))
    }
    let sessions = analyze(readProbe().events)
    for (index, session) in sessions.enumerated() {
      report("cycle\(index + 1)", "\(session.line)、増えた文字数 \(added[safe: index] ?? -1)")
    }
    let inserted = sessions.filter { $0.outcome == "inserted" && $0.insertEvents == 1 }
    let doubled = sessions.filter { $0.insertEvents > 1 }
    report(
      "twenty",
      "セッション \(sessions.count)、挿入できた \(inserted.count)、二重の挿入 \(doubled.count)、"
        + "文字が増えなかった回 \(added.filter { $0 <= 0 }.count)、"
        + "🎤→録音開始 \(summary(inserted.map(\.startMs)))、停止→挿入 \(summary(inserted.map(\.stopToEndMs)))"
    )
    clearNote()
  }

  /// 20回を2セット続けて流す（まれな失敗を捕まえるため）。startStandby が本体アプリを起動し直すので、2セット目も待機から始まる
  func testFortyCycles() throws {
    try testTwentyCycles()
    testStarted = Date()
    try testTwentyCycles()
  }

  /// ミュートで待つ方式（待機中にマイクの表示が出ない）で20回
  func testTwentyCyclesMuted() throws {
    useMutedStandby()
    try testTwentyCycles()
  }

  /// ミュートで待つ方式で、5分後・30分後
  func testStandbyEnduranceMuted() throws {
    useMutedStandby()
    try testStandbyEndurance()
  }

  private func useMutedStandby() {
    probe.launchArguments += ["-ProbeStandbyMode", "mutedMicrophone"]
  }

  // MARK: 1. 待機がどのくらい続くか（5分後・30分後）

  func testStandbyEndurance() throws {
    try startStandby()
    try openNewNote()
    let started = Date()
    var added: [Int] = []
    for minutes in [5, 30] {
      waitKeepingScreenOn(until: started.addingTimeInterval(Double(minutes * 60)))
      added.append(try runCycle(speakSeconds: 4))
    }
    let snapshot = readProbe()
    for (index, session) in analyze(snapshot.events).enumerated() {
      report(
        "endurance\(index == 0 ? 5 : 30)min", "\(session.line)、増えた文字数 \(added[safe: index] ?? -1)")
    }
    report("endurance", "本体アプリの状態 \(snapshot.hostPhase)")
    clearNote()
  }

  // MARK: 3. 割り込み: 録音中に本体アプリを強制終了する

  func testHostTerminatedWhileRecording() throws {
    try startStandby()
    try openNewNote()
    let before = noteText().count
    try tap("voice.mic")
    sleep(3)
    probe.terminate()
    sleep(1)
    try tap("voice.mic")
    // キーボードは結果を20秒まで待つ
    sleep(25)
    let added = noteText().count - before
    // 本体アプリが止まった後に🎤を押す
    try tap("voice.mic")
    sleep(2)
    let snapshot = readProbe(launch: true)
    for session in analyze(snapshot.events) { report("terminate", session.line) }
    report(
      "terminate",
      "増えた文字数 \(added)、最後の案内「\(snapshot.presence?.hint ?? "-")」、本体アプリの状態 \(snapshot.hostPhase)")
    clearNote()
  }

  /// 録音中にホーム画面へ出る（ロックと同じく、キーボードが閉じられる）。録音が裏で続かず、戻ってすぐ入力できるか
  func testLeaveKeyboardWhileRecording() throws {
    try startStandby()
    try openNewNote()
    try tap("voice.mic")
    sleep(2)
    XCUIDevice.shared.press(.home)
    sleep(3)
    let left = readProbe()
    report("leave", "ホーム画面に出た後の本体アプリの状態 \(left.hostPhase)")
    backToNote()
    let added = try runCycle(speakSeconds: 4)
    let sessions = analyze(readProbe().events)
    for session in sessions { report("leave", session.line) }
    report("leave", "戻った後の1回で増えた文字数 \(added)")
    clearNote()
  }

  /// ロックの後にキーボードが反応しなくなる件の切り分け。ロックと解除は人が行う（XCUITest にロックの操作がなく、解除に Face ID が要る）。
  /// 合図: 🎤が赤くなったら1回目、キーボードが Typeless に変わったら2回目のロック→5秒後に解除
  func testRecoverAfterLock() throws {
    try startStandby()
    try openNewNote()
    try tap("voice.mic")
    screenshot("lock1-recording")
    report("lock", "1回目のロックを待つ（30秒）")
    sleep(30)
    screenshot("lock1-afterUnlock")
    // そのまま🎤を押す
    try tap("voice.mic")
    sleep(2)
    screenshot("lock1-tapMic")
    try tap("voice.mic")
    sleep(2)
    // キーボードを閉じて出し直してから🎤
    let done = notes.buttons["完了"]
    if done.exists { done.tap() }
    sleep(1)
    notes.textViews.firstMatch.tap()
    sleep(2)
    screenshot("lock1-reopened")
    let before = noteText().count
    try tap("voice.mic")
    sleep(5)
    try tap("voice.mic")
    sleep(4)
    report("lock", "出し直した後の1回で増えた文字数 \(noteText().count - before)")
    // Typeless に切り替えて2回目のロック
    let next = notes.buttons["次のキーボード"]
    next.press(forDuration: 1.0)
    let typeless = notes.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Typeless")
    ).firstMatch
    if typeless.waitForExistence(timeout: 3) {
      typeless.tap()
      sleep(2)
      screenshot("lock2-typeless")
      report("lock", "2回目のロックを待つ（30秒）")
      sleep(30)
      screenshot("lock2-afterUnlock")
      // Typeless の中央のボタン（スクリーンショットで測った位置）を押して、反応を見る
      notes.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 201, dy: 670)).tap()
      sleep(2)
      screenshot("lock2-tapTypeless")
      notes.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 201, dy: 670)).tap()
      sleep(2)
    } else {
      report("lock", "キーボードの一覧に Typeless がない")
    }
    let snapshot = readProbe()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    for event in snapshot.events where event.at >= testStarted {
      report(
        "lock",
        "\(formatter.string(from: event.at)) \(event.source) \(event.name) \(event.detail ?? "")")
    }
    clearNote()
  }

  /// 停止の合図が来ないまま録音の上限（テストでは10秒）を超えると、本体アプリが録音を捨て、キーボードが知らせるか
  func testCaptureLimit() throws {
    probe.launchArguments += ["-ProbeMaxCaptureSeconds", "10"]
    try startStandby()
    try openNewNote()
    try tap("voice.mic")
    sleep(16)
    // キーボードの案内は、本体アプリを前面に出す前に書かれたものが残る
    let snapshot = readProbe()
    report(
      "limit", "16秒後: 本体アプリの状態 \(snapshot.hostPhase)、キーボードの案内「\(snapshot.presence?.hint ?? "-")」")
    for session in analyze(snapshot.events) { report("limit", session.line) }
    backToNote()
    testStarted = Date()
    let added = try runCycle(speakSeconds: 4)
    let after = analyze(readProbe().events)
    if let last = after.last { report("limit", "その後の1回: \(last.line)、増えた文字数 \(added)") }
    clearNote()
  }

  // MARK: 5. 自動挿入をオフにする

  func testPreviewThenInsert() throws {
    try startStandby()
    try openNewNote()
    if layout?.autoInsert == true { try tap("voice.autoInsert") }
    // 1回目: プレビューが出たときの「挿入」の位置を読む（アプリを切り替えるとキーボードが作り直され、プレビューは消える）
    try tap("voice.mic")
    sleep(5)
    try tap("voice.mic")
    sleep(5)
    let snapshot = readProbe()
    guard let insertFrame = snapshot.presence?.frames["voice.insert"] else {
      XCTFail("プレビューの「挿入」が出ない（案内「\(snapshot.presence?.hint ?? "-")」）")
      return
    }
    report("preview", "1回目: アプリを切り替えて戻ると、キーボードの案内は「\(snapshot.presence?.hint ?? "-")」")
    backToNote()
    // 2回目: 切り替えずに、プレビュー → 「挿入」
    testStarted = Date()
    let before = noteText().count
    try tap("voice.mic")
    sleep(5)
    try tap("voice.mic")
    sleep(5)
    let addedBeforeInsert = noteText().count - before
    try tap(frame: insertFrame)
    sleep(2)
    let added = noteText().count - before
    let after = readProbe()
    for session in analyze(after.events) { report("preview", session.line) }
    report("preview", "2回目: 挿入前に増えた文字数 \(addedBeforeInsert)、「挿入」後に増えた文字数 \(added)")
    backToNote()
    if after.presence?.autoInsert == false { try tap("voice.autoInsert") }
    clearNote()
  }

  // MARK: 6. キーボードから本体アプリを開けるか

  func testOpenHostFromKeyboard() throws {
    probe.launch()
    try openNewNote()
    try tap("debug.toggle")
    sleep(1)
    let debugLayout = readProbe().presence
    report("open", "検証の表示の位置: \(debugLayout?.frames.keys.sorted() ?? [])")
    backToNote()
    for identifier in ["debug.openContext", "debug.openSwiftUI"] {
      guard let frame = debugLayout?.frames[identifier] else {
        report("open", "\(identifier) の位置が分からない")
        continue
      }
      try tap(frame: frame)
      let opened = probe.wait(for: .runningForeground, timeout: 5)
      let viaURL = probe.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "URL から起動された")
      ).allElementsBoundByIndex.map(\.label)
      report("open", "\(identifier): 本体アプリが前面に出た \(opened)、本体アプリの記録 \(viaURL)")
      backToNote()
    }
    let snapshot = readProbe()
    report("open", "キーボードの表示「\(snapshot.presence?.openLine ?? "-")」")
    backToNote()
    if let frame = debugLayout?.frames["debug.toggle"] { try tap(frame: frame) }
    clearNote()
  }

  // MARK: 手で試した後の記録を読む

  /// 直近10分の計測の記録を、時刻つきで出す（手で試した割り込みなどの確認用。本体アプリは起動し直される）
  func testDumpRecentEvents() throws {
    probe.launch()
    let snapshot = readProbe()
    let since = Date().addingTimeInterval(-600)
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    for event in snapshot.events where event.at >= since {
      report(
        "dump",
        "\(formatter.string(from: event.at)) \(event.source) \(event.name) "
          + "\(event.session.map { String($0.prefix(8)) } ?? "-") \(event.detail ?? "")")
    }
    report("dump", "本体アプリの状態 \(snapshot.hostPhase)")
  }

  // MARK: 7. 待機中のマイクの表示（方式ごと）

  /// 待機中・録音中のスクリーンショットを残す（オレンジの点はスクリーンショットで見る）。ミュートの方式でも入力できるかを見る
  func testMicIndicatorByMode() throws {
    for mode in ["holdMicrophone", "mutedMicrophone"] {
      probe.launchArguments = [
        "-ProbeIdleTimeoutMinutes", "0", "-ProbeUITest", "YES", "-ProbeStandbyMode", mode,
      ]
      try startStandby()
      try openNewNote()
      sleep(3)
      screenshot("\(mode)-standby")
      try tap("voice.mic")
      sleep(3)
      screenshot("\(mode)-recording")
      sleep(1)
      try tap("voice.mic")
      sleep(4)
      screenshot("\(mode)-after")
      let sessions = analyze(readProbe().events)
      if let last = sessions.last { report("indicator-\(mode)", last.line) }
      probe.buttons["待機を終える"].tap()
      testStarted = Date()
      clearNote()
    }
  }

  private func screenshot(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  // MARK: 手順

  /// 🎤 → 話す → 🎤 の1回分。話す間は Mac から合成音声が流れている前提。増えた文字数を返す
  private func runCycle(speakSeconds: UInt32) throws -> Int {
    let before = noteText().count
    try tap("voice.mic")
    sleep(1 + speakSeconds)
    try tap("voice.mic")
    sleep(4)
    return noteText().count - before
  }

  private func startStandby() throws {
    probe.launch()
    // 前のテストの記録が残っていると読み取りの表示が大きくなりすぎるため、先に消す
    let clear = probe.buttons["計測の記録を消す"]
    if clear.waitForExistence(timeout: 5) {
      clear.tap()
    }
    let start = probe.buttons["待機を始める"]
    XCTAssertTrue(start.waitForExistence(timeout: 10), "待機を始めるボタンがない")
    start.tap()
    XCTAssertTrue(
      probe.buttons["待機を終える"].waitForExistence(timeout: 60), "待機を始められなかった")
  }

  /// メモアプリで新しいメモを開き、utter Probe のキーボードに切り替えて、ボタンの位置を読む
  private func openNewNote() throws {
    notes.activate()
    XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
    let compose = notes.buttons.matching(
      NSPredicate(format: "label IN %@", ["新規メモ", "New Note", "メモを作成"])
    ).firstMatch
    // 前のテストのメモやメニューが開いたままなら、一覧の画面まで戻る
    for _ in 0..<4 {
      if compose.waitForExistence(timeout: 2) { break }
      let back = notes.buttons["BackButton"]
      if back.exists {
        back.tap()
      } else {
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      }
    }
    XCTAssertTrue(compose.waitForExistence(timeout: 5), "新規メモのボタンが見つからない")
    compose.tap()
    XCTAssertTrue(notes.textViews.firstMatch.waitForExistence(timeout: 5))
    var snapshot = try switchToProbeKeyboard()
    // 前のテストで検証の表示が開いたままなら閉じる
    if let presence = snapshot.presence, presence.frames["voice.mic"] == nil,
      presence.frames["debug.toggle"] != nil
    {
      layout = presence
      backToNote()
      try tap("debug.toggle")
      sleep(1)
      snapshot = readProbe()
    }
    guard let presence = snapshot.presence, presence.frames["voice.mic"] != nil
    else {
      XCTFail(
        "utter Probe のキーボードの位置を読めない（フルアクセスがオフだと書けない）: "
          + "\(snapshot.presence.map { "\($0.at)" } ?? "なし")")
      return
    }
    layout = presence
    backToNote()
    report(
      "layout",
      "キーボードの大きさ \(presence.rootSize.width)x\(presence.rootSize.height)、"
        + "画面上の位置 \(presence.rootInScreen.map { "\($0.x),\($0.y)" } ?? "なし")、"
        + "入力欄の下の領域 \(notes.otherElements["inputView"].firstMatch.frame)")
  }

  /// utter Probe のキーボードに切り替え、出ていることを本体アプリの読み取りで確かめる。
  /// 他社製キーボードの中は見えないため、キーボードが App Group に書いた表示の時刻が新しく、表示中であることで判断する
  private func switchToProbeKeyboard() throws -> Probe.Snapshot {
    let next = notes.buttons["次のキーボード"]
    for attempt in 0..<8 {
      let marker = Date().addingTimeInterval(-1)
      if attempt > 0 {
        guard next.exists else { break }
        // 短く押すと直前のキーボードに戻るだけなので、長押しで一覧を出して選ぶ
        next.press(forDuration: 1.0)
        let item = notes.descendants(matching: .any).matching(
          NSPredicate(format: "label == %@", "utter Probe")
        ).firstMatch
        if item.waitForExistence(timeout: 3) {
          item.tap()
        } else {
          report("debug", "キーボードの一覧に utter Probe がない: \(notes.debugDescription.suffix(3000))")
          next.tap()
        }
      } else {
        // 開いたばかりの入力欄は、前に使ったキーボードで出る
        sleep(1)
      }
      sleep(2)
      screenshot("switch\(attempt)")
      if notes.keyboards.count > 0 { continue }  // 標準のキーボード
      let snapshot = readProbe()
      if let presence = snapshot.presence, presence.at >= marker {
        backToNote()
        return snapshot
      }
      backToNote()
    }
    XCTFail("utter Probe のキーボードに切り替えられない（フルアクセスがオフだと表示を書けない）")
    return readProbe()
  }

  /// メモに戻り、utter Probe のキーボードが出るのを待つ
  private func backToNote() {
    notes.activate()
    _ = notes.wait(for: .runningForeground, timeout: 5)
    sleep(2)
    if notes.keyboards.count > 0 {
      report("debug", "メモに戻ったら標準のキーボードが出ている")
    }
  }

  /// テスト用のメモを、メモの「さらに表示」メニューから削除する
  private func clearNote() {
    notes.activate()
    _ = notes.wait(for: .runningForeground, timeout: 5)
    let more = notes.buttons["TopOverflowBarButtonItem"]
    if more.waitForExistence(timeout: 5) {
      more.tap()
      let delete = notes.buttons.matching(NSPredicate(format: "label IN %@", ["削除", "Delete"]))
        .firstMatch
      if delete.waitForExistence(timeout: 3) {
        delete.tap()
        report("cleanup", "テスト用のメモを削除した")
        return
      }
      report("debug", notes.debugDescription)
    }
    report("cleanup", "テスト用のメモを削除できなかった（手で消す）")
  }

  private func tap(_ identifier: String) throws {
    guard let frame = layout?.frames[identifier] else {
      XCTFail("キーボードの \(identifier) の位置が分からない")
      return
    }
    try tap(frame: frame)
  }

  /// キーボードの根のビューの座標を、画面の座標に直してタップする
  private func tap(frame: Probe.Frame) throws {
    guard let layout else { return }
    let origin = keyboardOrigin(layout)
    let point = CGVector(
      dx: origin.x + frame.x + frame.width / 2, dy: origin.y + frame.y + frame.height / 2)
    notes.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
  }

  /// キーボードの根のビューの左上の、画面の座標。キーボードからは画面上の位置が取れない（窓の座標で 0 になる）ため、
  /// メモの入力欄の下の領域（inputView）の下端から、OS が下に出す地球儀・音声入力の段の高さだけ上にそろえる。
  /// 段の高さ 75pt は iPhone 17 Pro（iOS 27）のスクリーンショットで測った値
  private func keyboardOrigin(_ presence: Probe.Presence) -> CGPoint {
    let systemBarHeight = 75.0
    let input = notes.otherElements["inputView"].firstMatch
    let bottom = input.exists ? input.frame.maxY : notes.windows.firstMatch.frame.maxY
    return CGPoint(x: 0, y: bottom - systemBarHeight - presence.rootSize.height)
  }

  private func noteText() -> String {
    (notes.textViews.firstMatch.value as? String) ?? ""
  }

  /// 本体アプリを前面に出して、読み取り用の表示を読む（読んだ後は本体アプリが前面のまま）
  private func readProbe(launch: Bool = false) -> Probe.Snapshot {
    if launch { probe.launch() } else { probe.activate() }
    _ = probe.wait(for: .runningForeground, timeout: 10)
    let presence = probe.staticTexts["test.presence"]
    _ = presence.waitForExistence(timeout: 5)
    sleep(1)
    return Probe.Snapshot(
      presenceJSON: presence.label, hostJSON: probe.staticTexts["test.host"].label,
      eventsJSONL: probe.staticTexts["test.events"].label)
  }

  struct SessionResult {
    let outcome: String
    let insertEvents: Int
    let startMs: Int
    let stopToEndMs: Int
    let names: [String]

    var line: String {
      "結果 \(outcome)、挿入のイベント \(insertEvents)回、🎤→録音開始 \(startMs)ms、停止→終わり \(stopToEndMs)ms、"
        + "流れ \(names.joined(separator: "→"))"
    }
  }

  /// このテストの間にキーボードが始めたセッションごとに、結果と区間をまとめる
  private func analyze(_ events: [Probe.Event]) -> [SessionResult] {
    let recent = events.filter { $0.at >= testStarted }
    let sessions = recent.filter { $0.name == "tapStart" }.compactMap(\.session)
    return sessions.map { session in
      let mine = recent.filter { $0.session == session }
      func first(_ name: String) -> Probe.Event? { mine.first { $0.name == name } }
      func ms(_ from: Probe.Event?, _ to: Probe.Event?) -> Int {
        guard let from, let to else { return -1 }
        return Int(to.at.timeIntervalSince(from.at) * 1000)
      }
      let inserts = mine.filter { $0.name == "inserted" }
      let end = inserts.first ?? first("resultTimeout") ?? first("captureAbandoned")
      let outcome: String
      if let insert = inserts.first {
        outcome =
          (insert.detail ?? "").hasPrefix("inserted") ? "inserted" : "挿入 \(insert.detail ?? "-")"
      } else if let abandoned = first("captureAbandoned") {
        outcome = "録音を捨てた: \(abandoned.detail ?? "-")"
      } else if let failed = first("failed") {
        outcome = "本体アプリの失敗: \(failed.detail ?? "-")"
      } else if first("resultTimeout") != nil {
        outcome = "結果が届かない"
      } else {
        outcome = "終わりの記録なし"
      }
      return SessionResult(
        outcome: outcome, insertEvents: inserts.count,
        startMs: ms(first("tapStart"), first("captureStarted")),
        stopToEndMs: ms(first("tapStop"), end),
        names: mine.map { "\($0.source == "host" ? "本体" : "キー"):\($0.name)" })
    }
  }

  /// 画面が自動でロックされないよう、1分ごとにメモの日付の行（何も起きない場所）をタップしながら待つ
  private func waitKeepingScreenOn(until deadline: Date) {
    while Date() < deadline {
      notes.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.3))
        .tap()
      let remaining = deadline.timeIntervalSinceNow
      sleep(UInt32(max(1, min(60, remaining))))
    }
  }

  private func summary(_ values: [Int]) -> String {
    let valid = values.filter { $0 >= 0 }.sorted()
    guard !valid.isEmpty else { return "-" }
    return "中央値 \(valid[valid.count / 2])ms・最大 \(valid.last ?? 0)ms"
  }

  private func report(_ tag: String, _ message: String) {
    print("UTTER-RESULT [\(tag)] \(message)")
    XCTContext.runActivity(named: "[\(tag)] \(message)") { _ in }
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// 本体アプリの読み取り用の表示（App/VoiceView.swift の UITestReadout）の中身を読む
enum Probe {
  struct Frame: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  /// Shared/VoiceShared.swift の VoiceKeyboardPresence と同じ形
  struct Presence: Decodable {
    let at: Date
    let visible: Bool
    let rootSize: Frame
    let rootInScreen: Frame?
    let frames: [String: Frame]
    let hint: String
    let autoInsert: Bool
    let openLine: String
  }

  struct Event {
    let at: Date
    let source: String
    let name: String
    let session: String?
    let detail: String?
  }

  struct Snapshot {
    let presenceJSON: String
    let hostJSON: String
    let eventsJSONL: String

    var presence: Presence? {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try? decoder.decode(Presence.self, from: Data(presenceJSON.utf8))
    }

    var hostPhase: String {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(hostJSON.utf8))
          as? [String: Any]
      else { return "読めない" }
      return "\(object["phase"] as? String ?? "-")（\(object["detail"] as? String ?? "")）"
    }

    var events: [Event] {
      eventsJSONL.split(separator: "\n").compactMap { line in
        guard
          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let at = object["at"] as? Double, let source = object["source"] as? String,
          let name = object["name"] as? String
        else { return nil }
        return Event(
          at: Date(timeIntervalSince1970: at), source: source, name: name,
          session: (object["sessionID"] as? [String: Any])?["rawValue"] as? String,
          detail: object["detail"] as? String)
      }
    }
  }
}
