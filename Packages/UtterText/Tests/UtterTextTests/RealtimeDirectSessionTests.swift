import Testing
import UtterCore

@testable import UtterText

struct RealtimeDirectSessionTests {
  private static let target = InsertionTargetID(rawValue: "field-1")
  private static let supported = RealtimeDirectRequirements(
    isEnabled: true, appSupport: RealtimeDirectAppSupport(tracksRange: true, supportsUndo: true),
    isTerminal: false)

  /// 入力欄を模した値。テストの中でアプリ側の読み書きを再現する。
  private struct Field {
    var units: [UInt16]
    var caret: Int
    var target: InsertionTargetID? = RealtimeDirectSessionTests.target

    init(_ text: String, caret: Int? = nil) {
      units = Array(text.utf16)
      self.caret = caret ?? units.count
    }

    var text: String {
      String(decoding: units, as: UTF16.self)
    }

    var observation: RealtimeDirectFieldObservation {
      RealtimeDirectFieldObservation(
        target: target, value: text, selectedRange: UTF16TextRange(location: caret, length: 0))
    }

    /// アプリ側の置き換え。照合済みの範囲だけを置き換え、カーソルを指定の位置に置く。
    mutating func apply(_ edit: RealtimeDirectEdit) {
      let current = String(
        decoding: units[edit.range.location..<edit.range.upperBound], as: UTF16.self)
      #expect(current.utf16.elementsEqual(edit.expectedText.utf16))
      units.replaceSubrange(
        edit.range.location..<edit.range.upperBound, with: Array(edit.replacement.utf16))
      caret = edit.caretLocation
    }
  }

  private static func start(_ field: Field) throws -> RealtimeDirectSession {
    try RealtimeDirectSession(
      requirements: supported,
      observation: field.observation)
  }

  /// 受け取ったテキストを順に書き込み、最後の結果を返す。
  @discardableResult
  private static func write(
    _ texts: [String], session: inout RealtimeDirectSession, field: inout Field
  ) throws -> RealtimeDirectStep {
    var step = RealtimeDirectStep.unchanged
    for text in texts {
      step = try session.update(to: text, observation: field.observation)
      if case .write(let edit) = step {
        field.apply(edit)
      }
    }
    return step
  }

  // MARK: - 使える条件

  @Test("AC-15: 未検証のアプリでは自動的に無効になる")
  func unsupportedAppIsUnavailable() {
    let requirements = RealtimeDirectRequirements(
      isEnabled: true, appSupport: .unsupported, isTerminal: false)

    #expect(requirements.unavailableReasons == [.rangeTrackingUnsupported, .undoUnsupported])
    #expect(
      throws: RealtimeDirectSessionError.unavailable([.rangeTrackingUnsupported, .undoUnsupported])
    ) {
      try RealtimeDirectSession(
        requirements: requirements,
        observation: Field("").observation)
    }
  }

  @Test(
    "AC-15: 範囲追跡と Undo の両方が確認されたアプリでだけ使える",
    arguments: [false, true], [false, true])
  func requiresBothRangeTrackingAndUndo(_ tracksRange: Bool, _ supportsUndo: Bool) {
    let requirements = RealtimeDirectRequirements(
      isEnabled: true,
      appSupport: RealtimeDirectAppSupport(tracksRange: tracksRange, supportsUndo: supportsUndo),
      isTerminal: false)

    #expect(requirements.unavailableReasons.isEmpty == (tracksRange && supportsUndo))
  }

  @Test("AC-15: 実験機能が無効、またはターミナル系のアプリでは使えない")
  func disabledOrTerminalIsUnavailable() {
    var requirements = Self.supported
    requirements.isEnabled = false
    #expect(requirements.unavailableReasons == [.disabledByUser])

    requirements = Self.supported
    requirements.isTerminal = true
    #expect(requirements.unavailableReasons == [.terminal])
  }

  @Test("AC-15: 開始時に入力対象・値・カーソル位置を確かめられなければ使えない")
  func startRequiresReadableField() {
    let cases: [(RealtimeDirectFieldObservation, Set<RealtimeDirectUnavailableReason>)] = [
      (
        RealtimeDirectFieldObservation(
          target: nil, value: "", selectedRange: UTF16TextRange(location: 0, length: 0)),
        [.targetUnknown]
      ),
      (
        RealtimeDirectFieldObservation(
          target: Self.target, value: nil,
          selectedRange: UTF16TextRange(location: 0, length: 0)),
        [.fieldUnreadable]
      ),
      (
        RealtimeDirectFieldObservation(target: Self.target, value: "abc", selectedRange: nil),
        [.fieldUnreadable]
      ),
      (
        RealtimeDirectFieldObservation(
          target: Self.target, value: "abc", selectedRange: UTF16TextRange(location: 4, length: 0)
        ),
        [.fieldUnreadable]
      ),
      (
        // サロゲートペア（𠮷）の途中
        RealtimeDirectFieldObservation(
          target: Self.target, value: "𠮷", selectedRange: UTF16TextRange(location: 1, length: 0)),
        [.fieldUnreadable]
      ),
      (
        // 結合文字（e + U+0301）の途中
        RealtimeDirectFieldObservation(
          target: Self.target, value: "e\u{301}",
          selectedRange: UTF16TextRange(location: 1, length: 0)),
        [.fieldUnreadable]
      ),
      (
        // ZWJ で連結した絵文字（👨‍👩‍👧）の途中
        RealtimeDirectFieldObservation(
          target: Self.target, value: "👨‍👩‍👧",
          selectedRange: UTF16TextRange(location: 3, length: 0)),
        [.fieldUnreadable]
      ),
      (
        RealtimeDirectFieldObservation(
          target: Self.target, value: "abc", selectedRange: UTF16TextRange(location: 1, length: 2)
        ),
        [.selectionNotEmpty]
      ),
    ]

    for (observation, reasons) in cases {
      #expect(throws: RealtimeDirectSessionError.unavailable(reasons)) {
        try RealtimeDirectSession(requirements: Self.supported, observation: observation)
      }
    }
  }

  @Test(
    "AC-15: 負の値やあふれる範囲は不正として扱い、開始時なら使えない",
    arguments: [(-1, 0), (0, -1), (Int.max, 1)])
  func rejectsInvalidRanges(_ location: Int, _ length: Int) {
    let range = UTF16TextRange(location: location, length: length)

    #expect(range == nil)
    #expect(throws: RealtimeDirectSessionError.unavailable([.fieldUnreadable])) {
      try RealtimeDirectSession(
        requirements: Self.supported,
        observation: RealtimeDirectFieldObservation(
          target: Self.target, value: "abc", selectedRange: range))
    }
  }

  // MARK: - 書き込み

  @Test("2.2節: 確定済みチャンクの連結を受け取るたびに、増えた部分だけをカーソル位置へ書き込む")
  func appendsConfirmedChunks() throws {
    var field = Field("宛先: ", caret: 4)
    var session = try Self.start(field)

    let first = try session.update(to: "明日の", observation: field.observation)
    #expect(
      first
        == .write(
          RealtimeDirectEdit(
            range: UTF16TextRange(validLocation: 4, length: 0), expectedText: "",
            replacement: "明日の", caretLocation: 7)))
    guard case .write(let edit) = first else { return }
    field.apply(edit)

    try Self.write(["明日の会議は", "明日の会議は10時から"], session: &session, field: &field)

    #expect(field.text == "宛先: 明日の会議は10時から")
    #expect(session.writtenText == "明日の会議は10時から")
    #expect(session.trackedRange == UTF16TextRange(location: 4, length: 11))
    #expect(field.caret == 15)
  }

  @Test("2.2節: 書き込み済みの部分が変わったテキストは、変わった部分だけを置き換える")
  func replacesChangedMiddle() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["会議は3時からです"], session: &session, field: &field)

    let step = try session.update(to: "会議は4時からです", observation: field.observation)

    #expect(
      step
        == .write(
          RealtimeDirectEdit(
            range: UTF16TextRange(validLocation: 3, length: 1), expectedText: "3", replacement: "4",
            caretLocation: 9)))
    guard case .write(let edit) = step else { return }
    field.apply(edit)
    #expect(field.text == "会議は4時からです")
    // 途中だけを直してもカーソルは書き込んだ範囲の末尾に置く
    #expect(field.caret == 9)
  }

  @Test("2.2節: 同じテキストなら何もせず、空のテキストなら書き込んだ部分を消す")
  func unchangedAndEmpty() throws {
    var field = Field("前")
    var session = try Self.start(field)
    try Self.write(["本文"], session: &session, field: &field)

    #expect(
      try session.update(to: "本文", observation: field.observation) == .unchanged)

    try Self.write([""], session: &session, field: &field)
    #expect(field.text == "前")
    #expect(session.trackedRange == UTF16TextRange(location: 1, length: 0))
  }

  @Test(
    "AC-15: 位置は UTF-16 で数え、絵文字や結合文字の途中で区切らない",
    arguments: [
      // 肌の色の修飾子が後から付く: 👍 を丸ごと置き換える
      ("A👍", "A👍🏽", 1, 2, "👍🏽"),
      // 家族の ZWJ 連結: 👨 を丸ごと置き換える
      ("👨", "👨‍👩‍👧", 0, 2, "👨‍👩‍👧"),
      // 結合文字が後から付く: e を丸ごと置き換える
      ("cafe", "cafe\u{301}", 3, 1, "e\u{301}"),
      // 濁点の結合文字: か を丸ごと置き換える
      ("か", "か\u{3099}", 0, 1, "か\u{3099}"),
      // サロゲートペアの漢字の後ろに追加する
      ("𠮷野", "𠮷野家", 3, 0, "家"),
      // 国旗（2つの地域指示記号）を別の国旗に置き換える。先頭の 🇯 は共通でも区切らない
      ("🇯🇵", "🇯🇲", 0, 4, "🇯🇲"),
    ])
  func usesUTF16OffsetsOnGraphemeBoundaries(
    _ old: String, _ new: String, _ location: Int, _ length: Int, _ replacement: String
  ) throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write([old], session: &session, field: &field)

    let step = try session.update(to: new, observation: field.observation)

    guard case .write(let edit) = step else {
      Issue.record("書き込みにならない")
      return
    }
    #expect(edit.range == UTF16TextRange(location: location, length: length))
    #expect(edit.replacement == replacement)
    field.apply(edit)
    #expect(field.units == Array(new.utf16))
    #expect(field.caret == new.utf16.count)
  }

  @Test("AC-15: 正準等価でもコード単位が違えば置き換え、入力欄をコード単位まで一致させる")
  func distinguishesCanonicallyEquivalentText() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["caf\u{E9}"], session: &session, field: &field)

    try Self.write(["cafe\u{301}"], session: &session, field: &field)

    #expect(field.units == Array("cafe\u{301}".utf16))
    #expect(session.trackedRange == UTF16TextRange(location: 0, length: 5))
  }

  // MARK: - 退避

  @Test(
    "AC-09: 入力欄の変更・フォーカスの移動・読み取りの失敗を検出したら、書き込まずにプレビューへ退避する",
    arguments: RealtimeDirectStopReason.allCases.filter { $0 != .writeFailed && $0 != .interrupted }
  )
  func stopsOnMismatch(_ reason: RealtimeDirectStopReason) throws {
    var field = Field("宛先 ", caret: 3)
    var session = try Self.start(field)
    try Self.write(["明日の"], session: &session, field: &field)

    var observation = field.observation
    switch reason {
    case .targetMissing: observation.target = nil
    case .targetChanged: observation.target = InsertionTargetID(rawValue: "field-2")
    case .fieldChanged: observation.value = "宛先 明後日"
    case .selectionMoved: observation.selectedRange = UTF16TextRange(location: 0, length: 0)
    case .rangeUnverifiable: observation.value = nil
    case .writeFailed, .interrupted: break
    }

    #expect(try session.update(to: "明日の会議", observation: observation) == .showPreview(reason))
    #expect(session.state == .stopped(reason))
    // 書き込み済みの記録は残し、以降は正しい状態でも書き込まない
    #expect(session.writtenText == "明日の")
    #expect(
      try session.update(to: "明日の会議は", observation: field.observation)
        == .showPreview(reason))
  }

  @Test("AC-09: 書き込んだ範囲の前で入力欄が変わり、長さがずれたら退避する")
  func stopsWhenTextBeforeRangeChanges() throws {
    var field = Field("xx")
    var session = try Self.start(field)
    try Self.write(["xx"], session: &session, field: &field)

    // 利用者が先頭に1文字入力した。書き込んだ範囲の位置から読むと、中身は偶然同じ文字列になる
    field.units.insert(UInt16(UInt8(ascii: "x")), at: 0)
    var observation = field.observation
    observation.selectedRange = UTF16TextRange(location: 4, length: 0)
    #expect(field.text.utf16.dropFirst(2).prefix(2).elementsEqual("xx".utf16))

    #expect(try session.update(to: "xxz", observation: observation) == .showPreview(.fieldChanged))
  }

  @Test("AC-09: アプリが書き込んだテキストを正規化したら、正準等価でも外部の変更として退避する")
  func stopsWhenAppNormalizesText() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["1\u{212B}"], session: &session, field: &field)

    // アプリがオングストローム記号を NFC の Å（同じ長さ）に正規化した
    field.units = Array("1\u{C5}".utf16)
    let observation = field.observation
    #expect(observation.value == "1\u{212B}")

    #expect(
      try session.update(to: "1\u{212B}m", observation: observation) == .showPreview(.fieldChanged))
  }

  @Test("AC-09: 呼び出し側が書き込みの失敗やフォーカスの変化を検出したら止める")
  func stopsOnCallerReport() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["明日の"], session: &session, field: &field)

    session.stop(.writeFailed)
    session.stop(.interrupted)

    // 最初の理由を残す
    #expect(session.state == .stopped(.writeFailed))
    #expect(
      try session.update(to: "明日の会議", observation: field.observation)
        == .showPreview(.writeFailed))
  }

  // MARK: - 取り消し

  @Test("AC-15: 取り消すと書き込んだ範囲を消して開始前の入力欄に戻す")
  func undoRemovesWrittenText() throws {
    var field = Field("宛先: 。", caret: 4)
    var session = try Self.start(field)
    try Self.write(["明日の", "明日の会議👍🏽"], session: &session, field: &field)
    try session.finish()

    let undo = try session.undo(observation: field.observation)

    guard case .revert(let edit) = undo else {
      Issue.record("取り消しにならない")
      return
    }
    #expect(edit.range == UTF16TextRange(location: 4, length: 9))
    #expect(edit.replacement.isEmpty)
    field.apply(edit)
    #expect(field.text == "宛先: 。")
    #expect(field.caret == 4)
    #expect(session.state == .undone)
  }

  @Test("REC-04: 書き込み中のキャンセルでも取り消せ、何も書いていなければ戻すものはない")
  func undoWhileWriting() throws {
    var field = Field("")
    var session = try Self.start(field)

    #expect(try session.undo(observation: field.observation) == .nothingToRevert)
    #expect(session.state == .undone)

    session = try Self.start(field)
    try Self.write(["明日の"], session: &session, field: &field)
    guard case .revert(let edit) = try session.undo(observation: field.observation)
    else {
      Issue.record("取り消しにならない")
      return
    }
    field.apply(edit)
    #expect(field.text.isEmpty)
  }

  @Test("AC-15: 書き込み後に入力欄が変わっていたら取り消さず、入力欄に触れない")
  func undoRefusesWhenFieldChanged() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["明日の会議"], session: &session, field: &field)
    try session.finish()

    // 利用者が書き込んだ範囲を編集した
    field.units = Array("明日の打合せ".utf16)
    field.caret = field.units.count

    #expect(
      try session.undo(observation: field.observation) == .unavailable(.fieldChanged))
    #expect(session.state == .stopped(.fieldChanged))
    #expect(
      try session.undo(observation: field.observation) == .unavailable(.fieldChanged))
  }

  // MARK: - 状態遷移

  @Test("AC-15: 終了後・取り消し後の書き込み、二重の取り消しは段階と操作を示すエラーにする")
  func rejectsInvalidTransitions() throws {
    var field = Field("")
    var session = try Self.start(field)
    try Self.write(["明日の"], session: &session, field: &field)
    try session.finish()

    #expect(throws: RealtimeDirectSessionError.invalidTransition(from: .finished, action: .update))
    {
      _ = try session.update(to: "明日の会議", observation: field.observation)
    }
    #expect(throws: RealtimeDirectSessionError.invalidTransition(from: .finished, action: .finish))
    {
      try session.finish()
    }

    guard case .revert(let edit) = try session.undo(observation: field.observation)
    else { return }
    field.apply(edit)
    let undone = session
    #expect(throws: RealtimeDirectSessionError.invalidTransition(from: .undone, action: .undo)) {
      _ = try session.undo(observation: field.observation)
    }
    #expect(throws: RealtimeDirectSessionError.invalidTransition(from: .undone, action: .update)) {
      _ = try session.update(to: "", observation: field.observation)
    }
    // 失敗した操作は状態を変えない
    #expect(session == undone)
  }

  @Test("AC-09: 書き込みをやめた後の終了は何もせず、止めた理由を保つ")
  func finishAfterStopKeepsReason() throws {
    var session = try Self.start(Field(""))
    session.stop(.interrupted)

    try session.finish()

    #expect(session.state == .stopped(.interrupted))
  }

  @Test("AC-09: 書き込んだ範囲の外が同じ長さのまま書き換えられても退避する")
  func stopsOnSameLengthChangeOutsideRange() throws {
    var field = Field("ab")
    var session = try Self.start(field)
    try Self.write(["xy"], session: &session, field: &field)

    // 自動修正などで、カーソルを動かさずに範囲の前の1文字が置き換わった
    field.units[0] = UInt16(UInt8(ascii: "c"))

    #expect(
      try session.update(to: "xyz", observation: field.observation) == .showPreview(.fieldChanged))
    #expect(session.writtenText == "xy")
  }

  // MARK: - プライバシー

  @Test("AC-15: 文字列表現とリフレクションに入力欄のテキストを含めない")
  func redactsText() throws {
    var field = Field("秘密の宛先")
    var session = try Self.start(field)
    let step = try session.update(to: "秘密の発話", observation: field.observation)
    if case .write(let edit) = step {
      field.apply(edit)
    }
    let observation = field.observation
    let undo = try session.undo(observation: observation)

    let values: [Any] = [session, step, observation, undo]
    for value in values {
      let outputs = [
        String(describing: value),
        String(reflecting: value),
        String(describing: Mirror(reflecting: value).children.map(\.value)),
      ]
      for output in outputs {
        #expect(!output.contains("秘密"))
        #expect(!output.contains("発話"))
      }
    }
  }
}
