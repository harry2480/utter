import Foundation
import Testing
import UtterCore
import UtterSpeech
import UtterText

extension StubFieldAccess: RealtimeDirectFieldAccess {
  func replace(
    _ range: UTF16TextRange, with replacement: String, caretLocation: Int,
    in target: InsertionTargetID
  ) -> InsertionResponse {
    guard target == self.target, field.axSettable else { return .rejectedBeforeSend }
    log.events.append(
      .axReplace(
        location: range.location, length: range.length, replacement, caret: caretLocation))
    var units = Array(field.value.utf16)
    guard range.upperBound <= units.count else { return .failedAfterSend }
    if field.axBehavior == .ignored { return .succeeded }
    units.replaceSubrange(range.location..<range.upperBound, with: Array(replacement.utf16))
    field.value = String(decoding: units, as: UTF16.self)
    field.selection = FieldSnapshot.Selection(location: caretLocation, length: 0)
    return .succeeded
  }
}

/// 認識イベントの列 → AX の書き込みの列（2.2節 Realtime Direct, AC-15, AC-09）。OS の機能は Stub に置き換える。
@MainActor
final class RealtimeDirectWriterTests {
  private static let recorded = InsertionTargetID(rawValue: "recorded")
  private static let other = InsertionTargetID(rawValue: "other")
  private static let app = "com.example.Editor"
  private static let allowlist = RealtimeDirectAllowlist().adding([app])

  let log = InsertionLog()
  /// 開始時の入力欄。「メモ: 」の後ろ（UTF-16 で 4）にカーソルがある
  let field = FakeTextField(value: "メモ: ")
  let inspector: StubInspector
  let fieldAccess: StubFieldAccess
  let session = SessionID()
  private var sequence: UInt64 = 0

  init() {
    inspector = StubInspector(targets: [Self.target(Self.recorded)], recorded: Self.recorded)
    fieldAccess = StubFieldAccess(field: field, target: Self.recorded, log: log)
  }

  private static func target(
    _ id: InsertionTargetID, app: String? = app, secureField: SensitiveSignal = .off
  ) -> FocusedInsertionTarget {
    FocusedInsertionTarget(id: id, app: app, secureField: secureField)
  }

  private func makeWriter(allowlist: RealtimeDirectAllowlist = RealtimeDirectWriterTests.allowlist)
    -> RealtimeDirectWriter
  {
    RealtimeDirectWriter(
      inspector: inspector, field: fieldAccess, preview: StubPreview(log: log),
      allowlist: allowlist, policy: InsertionPolicy(profiles: KnownTerminalApps.profiles))
  }

  /// 始めて、使えることを確かめる
  private func started() throws -> RealtimeDirectWriter {
    let writer = makeWriter()
    let failure = writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true)
    try #require(failure == nil)
    return writer
  }

  /// 順序番号を振ってイベントを渡す
  private func send(
    _ kinds: [RecognitionEvent.Kind], to writer: RealtimeDirectWriter, session: SessionID? = nil
  ) {
    for kind in kinds {
      writer.handle(
        RecognitionEvent(sessionID: session ?? self.session, sequence: sequence, kind: kind))
      sequence += 1
    }
  }

  // MARK: - 書き込み

  @Test("AC-15: 確定済みチャンクだけを差分で逐次書き込み、暫定結果は書き込まない")
  func writesConfirmedChunks() throws {
    let writer = try started()

    send(
      [
        .partial("こんに"), .confirmed("こんにちは。"), .partial("今日"), .confirmed("今日はいい"),
        .confirmed("天気です。"),
      ], to: writer)
    // 完了時の全体の確定テキストが書き込み済みと違えば、違う部分だけを置き換える
    send([.completed("こんにちは。今日は良い天気です。")], to: writer)

    #expect(
      log.events == [
        .axReplace(location: 4, length: 0, "こんにちは。", caret: 10),
        .axReplace(location: 10, length: 0, "今日はいい", caret: 15),
        .axReplace(location: 15, length: 0, "天気です。", caret: 20),
        .axReplace(location: 13, length: 1, "良", caret: 20),
      ])
    #expect(field.value == "メモ: こんにちは。今日は良い天気です。")
    #expect(field.selection == FieldSnapshot.Selection(location: 20, length: 0))
    #expect(writer.session?.state == .finished)
    #expect(log.previews.isEmpty)
  }

  @Test("AC-15: 書き込んだ範囲の外を利用者が編集したら入力欄に触れずにやめ、完了時に全体をプレビューに出す")
  func stopsWhenEditedOutsideRange() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    // 利用者が先頭に書き足した（カーソルも同じだけずれる）
    field.value = "追記" + field.value
    field.selection = FieldSnapshot.Selection(location: 12, length: 0)
    send([.confirmed("今日は"), .completed("こんにちは。今日は")], to: writer)

    #expect(log.sentInsertions.count == 1)
    #expect(field.value == "追記メモ: こんにちは。")
    #expect(writer.session?.state == .stopped(.fieldChanged))
    #expect(
      log.previews == [
        .preview("こんにちは。今日は", .realtimeDirectStopped(.fieldChanged, wroteText: true))
      ])
  }

  @Test(
    "AC-15: カーソルが書き込んだ範囲の末尾から動いた・テキストを選択したらやめる",
    arguments: [
      FieldSnapshot.Selection(location: 4, length: 0),
      FieldSnapshot.Selection(location: 0, length: 2),
    ])
  func stopsWhenSelectionMoves(_ selection: FieldSnapshot.Selection) throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    field.selection = selection
    send([.confirmed("今日は")], to: writer)

    #expect(log.sentInsertions.count == 1)
    #expect(writer.session?.state == .stopped(.selectionMoved))
  }

  @Test("AC-15, AC-09: 完了時の書き込みが成功を返して反映されなければ、全体をプレビューに出す")
  func verifiesFinalWrite() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    field.axBehavior = .ignored
    send([.completed("こんにちは。今日は")], to: writer)

    #expect(writer.session?.state == .stopped(.fieldChanged))
    #expect(
      log.previews == [
        .preview("こんにちは。今日は", .realtimeDirectStopped(.fieldChanged, wroteText: true))
      ])
  }

  @Test("AC-15: 完了の確定テキストが空なら、書き込んだ確定済みチャンクを消さない")
  func keepsWrittenTextOnEmptyCompletion() throws {
    let writer = try started()

    send([.confirmed("こんにちは。"), .completed("")], to: writer)

    #expect(field.value == "メモ: こんにちは。")
    #expect(log.sentInsertions.count == 1)
    #expect(writer.session?.state == .finished)
  }

  @Test("AC-09: やめた後に認識が失敗しても、確定済みテキストをプレビューに出す")
  func previewsOnFailureAfterStop() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    inspector.targets = [Self.target(Self.other)]
    send([.confirmed("今日は"), .failed(.engineFailed)], to: writer)

    #expect(
      log.previews == [
        .preview("こんにちは。今日は", .realtimeDirectStopped(.targetChanged, wroteText: true))
      ])
  }

  @Test(
    "AC-15, INS-01: フォーカスが別の入力欄に移った・消えたら書き込みをやめる",
    arguments: [
      (Optional(InsertionTargetID(rawValue: "other")), RealtimeDirectStopReason.targetChanged),
      (nil, .targetMissing),
    ])
  func stopsWhenFocusMoves(_ focused: InsertionTargetID?, _ reason: RealtimeDirectStopReason)
    throws
  {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    inspector.targets = [focused.map { Self.target($0) }]
    send([.confirmed("今日は"), .completed("こんにちは。今日は")], to: writer)

    #expect(log.sentInsertions.count == 1)
    #expect(writer.session?.state == .stopped(reason))
    #expect(
      log.previews == [.preview("こんにちは。今日は", .realtimeDirectStopped(reason, wroteText: true))])
  }

  @Test("7章: 書き込みの途中でセキュア入力が有効になったら書き込みをやめる")
  func stopsWhenSecureInputTurnsOn() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    inspector.secure = .on
    send([.confirmed("今日は")], to: writer)

    #expect(log.sentInsertions.count == 1)
    #expect(writer.session?.state == .stopped(.interrupted))
  }

  @Test("AC-15: 何も送らないうちに書き込みに失敗したらやめ、プレビューに出さずに一括の挿入を呼び出し側に任せる")
  func stopsWhenWriteFails() throws {
    let writer = try started()
    field.axSettable = false

    send([.confirmed("こんにちは。"), .confirmed("今日は")], to: writer)
    #expect(writer.completion == .stoppedBeforeWriting(.writeFailed))
    send([.completed("こんにちは。今日は")], to: writer)

    #expect(field.value == "メモ: ")
    #expect(writer.session?.state == .stopped(.writeFailed))
    #expect(writer.completion == .stoppedBeforeWriting(.writeFailed))
    #expect(log.previews.isEmpty)
  }

  @Test("AC-15: 書き込んだ後にやめたら、結果は書き込み後の停止になる")
  func completionAfterWriting() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)
    inspector.targets = [Self.target(Self.other)]
    send([.completed("こんにちは。今日は")], to: writer)

    #expect(writer.completion == .stoppedAfterWriting(.targetChanged))
  }

  @Test("AC-15: 全体を書き込んで終えたら結果は完了になり、取り消した後は結果を持たない")
  func completionWhenFinished() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)
    #expect(writer.completion == .finished)

    #expect(writer.undo() == .reverted)
    #expect(writer.completion == nil)
  }

  @Test("7章, AC-12: 除外アプリはセッションの開始ごとに読み直し、除外したアプリでは始めない")
  func readsExcludedAppsAtBegin() {
    let excluded = ExcludedAppsBox()
    let writer = RealtimeDirectWriter(
      inspector: inspector, field: fieldAccess, preview: StubPreview(log: log),
      allowlist: Self.allowlist,
      sensitivePolicy: { SensitiveInputPolicy(excludedApps: excluded.apps) })
    #expect(writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true) == nil)

    excluded.apps = [Self.app]
    #expect(
      writer.begin(sessionID: SessionID(), recordedTarget: Self.recorded, isEnabled: true)
        == .sensitiveInput([.excludedApp]))
  }

  @Test("AC-15: 認識に失敗したら、それまでの書き込みを確定済みとして残す")
  func keepsWrittenTextOnFailure() throws {
    let writer = try started()

    send([.confirmed("こんにちは。"), .partial("今日"), .failed(.engineFailed)], to: writer)

    #expect(field.value == "メモ: こんにちは。")
    #expect(writer.session?.state == .finished)
    #expect(log.previews.isEmpty)
  }

  @Test("AC-15: 別のセッション・順序の古いイベントは書き込まない")
  func ignoresStaleEvents() throws {
    let writer = try started()

    send([.confirmed("別の発話")], to: writer, session: SessionID())
    send([.confirmed("こんにちは。")], to: writer)
    writer.handle(RecognitionEvent(sessionID: session, sequence: 0, kind: .confirmed("古い")))

    #expect(field.value == "メモ: こんにちは。")
    #expect(log.sentInsertions.count == 1)
  }

  // MARK: - 取り消し

  @Test("AC-15: 完了後の取り消しで、書き込んだテキストだけを取り除く（一度だけ）")
  func undoAfterFinish() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。今日は")], to: writer)

    #expect(writer.undo() == .reverted)
    #expect(log.events.last == .axReplace(location: 4, length: 9, "", caret: 4))
    #expect(field.value == "メモ: ")
    #expect(writer.undo() == .noSession)
  }

  @Test("AC-15: 書き込み後に入力欄が変わっていたら、取り消しで入力欄に触れない")
  func undoRefusesWhenFieldChanged() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)
    field.value += "続き"
    field.selection = FieldSnapshot.Selection(location: 12, length: 0)

    #expect(writer.undo() == .unavailable(.fieldChanged))
    #expect(log.sentInsertions.count == 1)
    #expect(field.value == "メモ: こんにちは。続き")
  }

  @Test("AC-15: 完了後の取り消しでフォーカスが別の入力欄にあれば触れず、戻ってから取り消せる")
  func undoWaitsForFocus() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)

    inspector.targets = [Self.target(Self.other)]
    #expect(writer.undo() == .unavailable(.targetChanged))
    inspector.targets = [Self.target(Self.recorded)]
    #expect(writer.undo() == .reverted)
    #expect(field.value == "メモ: ")
  }

  @Test("7章: 取り消しの時点でセキュア入力が有効なら入力欄に触れない")
  func undoRefusesDuringSecureInput() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)

    inspector.secure = .on
    #expect(writer.undo() == .unavailable(.interrupted))
    #expect(log.sentInsertions.count == 1)
  }

  @Test("AC-15: 取り消しの書き込みに失敗したら、その結果を返す")
  func undoReportsWriteFailure() throws {
    let writer = try started()
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)

    field.axSettable = false
    #expect(writer.undo() == .writeFailed)
    #expect(field.value == "メモ: こんにちは。")
  }

  @Test("AC-15: 何も書き込んでいなければ、取り消しで入力欄に触れない")
  func undoWithoutWrites() throws {
    let writer = try started()
    send([.partial("こんに"), .completed("")], to: writer)

    #expect(writer.undo() == .nothingToRevert)
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("AC-15, REC-04: セッションのキャンセルで書き込みを取り除き、以後のイベントを書き込まない")
  func cancelRevertsWrites() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)

    #expect(writer.cancel(SessionID()) == nil)
    #expect(writer.cancel(session) == .reverted)
    send([.confirmed("今日は")], to: writer)

    #expect(field.value == "メモ: ")
    #expect(log.sentInsertions.count == 2)
    #expect(log.previews.isEmpty)
  }

  @Test("AC-15, REC-04: キャンセル時に入力欄が変わっていたら、書き込みを取り除かない")
  func cancelRefusesWhenFieldChanged() throws {
    let writer = try started()
    send([.confirmed("こんにちは。")], to: writer)
    field.value += "続き"
    field.selection = FieldSnapshot.Selection(location: 12, length: 0)

    #expect(writer.cancel(session) == .unavailable(.fieldChanged))
    #expect(field.value == "メモ: こんにちは。続き")
    #expect(log.sentInsertions.count == 1)
  }

  // MARK: - 使える条件

  @Test("AC-15: 許可リストにないアプリ（既定は全アプリ）では始めず、入力欄に触れない")
  func unavailableWithoutAllowlist() {
    let writer = makeWriter(allowlist: .verified)

    let failure = writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true)
    send([.confirmed("こんにちは。"), .completed("こんにちは。")], to: writer)

    #expect(failure == .unavailable([.rangeTrackingUnsupported, .undoUnsupported]))
    #expect(writer.session == nil)
    #expect(log.events.isEmpty)
  }

  @Test("AC-15: 実験機能が無効、またはターミナル系のアプリでは始めない")
  func unavailableWhenDisabledOrTerminal() {
    var writer = makeWriter()
    #expect(
      writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: false)
        == .unavailable([.disabledByUser]))

    inspector.targets = [Self.target(Self.recorded, app: "com.apple.Terminal")]
    writer = makeWriter(allowlist: Self.allowlist.adding(["com.apple.Terminal"]))
    #expect(
      writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true)
        == .unavailable([.terminal]))
  }

  @Test("AC-15, INS-01: 録音開始時と違う入力欄・入力欄を特定できないときは始めない")
  func unavailableWhenTargetDiffers() {
    let writer = makeWriter()
    #expect(
      writer.begin(sessionID: session, recordedTarget: Self.other, isEnabled: true)
        == .unavailable([.targetUnknown, .fieldUnreadable]))
    #expect(
      writer.begin(sessionID: session, recordedTarget: nil, isEnabled: true)
        == .unavailable([.targetUnknown, .fieldUnreadable]))
  }

  @Test("7章: パスワード欄では始めない")
  func unavailableInSecureField() {
    inspector.targets = [Self.target(Self.recorded, secureField: .on)]
    let writer = makeWriter()

    #expect(
      writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true)
        == .sensitiveInput([.secureField]))
    #expect(writer.session == nil)
  }

  @Test("AC-15: 開始時にテキストが選択されていたら始めない")
  func unavailableWithSelection() {
    field.selection = FieldSnapshot.Selection(location: 0, length: 2)
    let writer = makeWriter()

    #expect(
      writer.begin(sessionID: session, recordedTarget: Self.recorded, isEnabled: true)
        == .unavailable([.selectionNotEmpty]))
  }
}

/// 除外アプリの保存値の代わり。テストの途中で値を変え、開始ごとに読み直すことを確かめる
@MainActor
final class ExcludedAppsBox {
  var apps: Set<String> = []
}
