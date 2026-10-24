import Carbon.HIToolbox
import CoreGraphics
import Testing
import UtterCore

private let allEnabled = ShortcutCapabilities(
  supportsModifierOnly: true, supportsEscapeCapture: true)

private func modifierSetting(_ key: ModifierOnlyKey, _ mode: ShortcutTriggerMode = .toggle)
  -> GlobalShortcutSetting
{
  GlobalShortcutSetting(modifierKey: key, mode: mode)
}

/// 修飾キー単独ショートカットと Esc 捕捉（#51 の判定待ち）を、コントローラーと Stub で確かめる。
@MainActor
struct EventTapShortcutTests {
  // MARK: - 修飾キー単独

  @Test("REC-02: capability が無効なら修飾キー単独は検証で拒否し、タップも権限の確認もしない")
  func modifierOnlyDisabledByDefault() {
    let harness = Harness(
      capabilities: ShortcutCapabilities(supportsModifierOnly: false, supportsEscapeCapture: false))
    harness.permissions.granted = [.inputMonitoring, .accessibility]
    let target = modifierSetting(.rightOption)
    #expect(
      harness.controller.apply(target) == .unavailable(target, .invalid([.modifierOnlyUnsupported]))
    )
    #expect(harness.taps.created.isEmpty)
    #expect(harness.permissions.checked.isEmpty)
  }

  @Test("REC-02: 修飾キー単独は入力監視の listen タップで検出し、Carbon には登録しない")
  func modifierOnlyUsesListenTap() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    let target = modifierSetting(.rightOption)
    #expect(harness.controller.apply(target) == .active(target))
    #expect(harness.registrar.registered.isEmpty)
    let tap = try #require(harness.taps.live(.listen))
    #expect(tap.events == [.flagsChanged, .keyDown])
    #expect(tap.isEnabled)

    // 監視ではイベントを止めない
    #expect(tap.send(flagsChanged(.rightOption, down: true)))
    #expect(tap.send(flagsChanged(.rightOption, down: false)))
    #expect(harness.commands == [.startRecording])
  }

  @Test("REC-02: 修飾キー単独の Push-to-talk は押下で開始、解放で停止する")
  func modifierOnlyPushToTalk() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    harness.controller.apply(modifierSetting(.function, .pushToTalk))
    let tap = try #require(harness.taps.live(.listen))
    tap.send(flagsChanged(.function, down: true))
    #expect(harness.commands == [.startRecording])
    tap.send(flagsChanged(.function, down: false))
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  @Test("PERM-01 / PERM-02: 入力監視の許可がなければタップを作らず、理由を返す。権限は自分から求めない")
  func modifierOnlyWithoutPermission() {
    let harness = Harness(capabilities: allEnabled)
    let target = modifierSetting(.rightOption)
    #expect(
      harness.controller.apply(target)
        == .unavailable(target, .eventTapUnavailable(.permissionMissing(.inputMonitoring))))
    #expect(harness.taps.created.isEmpty)
    #expect(harness.permissions.requested.isEmpty)
    // ショートカットがないため Esc 捕捉も使わない
    #expect(harness.controller.escapeStatus == .off)
  }

  @Test("REC-02: タップを作成できなければ理由を返す")
  func modifierOnlyTapCreationFailure() {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    harness.taps.succeeds = false
    let target = modifierSetting(.rightOption)
    #expect(
      harness.controller.apply(target)
        == .unavailable(target, .eventTapUnavailable(.tapCreationFailed)))
  }

  @Test("PERM-02: 入力監視の許可が取り消されたら修飾キー単独を無効にし、許可されたら戻す")
  func modifierOnlyPermissionRevoked() throws {
    let harness = Harness(
      capabilities: ShortcutCapabilities(supportsModifierOnly: true, supportsEscapeCapture: false))
    harness.permissions.granted = [.inputMonitoring]
    let target = modifierSetting(.rightOption)
    harness.controller.apply(target)
    var changes = 0
    harness.controller.onStatusChange = { changes += 1 }

    harness.permissions.granted = []
    harness.controller.refreshPermissions()
    #expect(
      harness.controller.status
        == .unavailable(target, .eventTapUnavailable(.permissionMissing(.inputMonitoring))))
    #expect(harness.taps.live(.listen) == nil)
    #expect(changes == 1)

    harness.permissions.granted = [.inputMonitoring]
    harness.controller.refreshPermissions()
    #expect(harness.controller.status == .active(target))
    #expect(harness.taps.live(.listen) != nil)
  }

  @Test("PERM-01: 権限はメニューからの操作でだけ求める")
  func requestsPermissionOnDemand() {
    let harness = Harness(capabilities: allEnabled)
    harness.controller.apply(modifierSetting(.rightOption))
    #expect(harness.permissions.requested.isEmpty)
    harness.controller.requestPermission(.inputMonitoring)
    #expect(harness.permissions.requested == [.inputMonitoring])
  }

  @Test("REC-02: OS がタップを無効化したら押下中の状態を破棄して再有効化する")
  func modifierTapDisabledByOS() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    harness.controller.apply(modifierSetting(.function, .pushToTalk))
    let tap = try #require(harness.taps.live(.listen))
    tap.send(flagsChanged(.function, down: true))
    tap.disableByOS()
    #expect(tap.isEnabled)
    // 無効化中に取りこぼした解放の後の押下は、録音中の押下として停止する（ShortcutInterpreter の回復）
    tap.send(flagsChanged(.function, down: true))
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  @Test("REC-02: 修飾キー単独の Toggle は、その修飾キーを含むシステムのショートカットと重なっても登録する")
  func toggleIgnoresModifierOverlap() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    let d = try #require(ShortcutKey(rawValue: "d"))
    harness.systemShortcuts = [
      ShortcutBinding(
        id: "system.index.0", combination: KeyCombination(key: d, modifiers: [.option, .command]))
    ]
    let toggle = modifierSetting(.rightOption)
    #expect(harness.controller.apply(toggle) == .active(toggle))

    // Push-to-talk は押下で開始するため、重なりを競合として残す
    let ptt = modifierSetting(.rightOption, .pushToTalk)
    #expect(
      harness.controller.apply(ptt)
        == .unavailable(
          ptt, .invalid([.conflict(bindingID: "system.index.0", kind: .modifierOverlap)])))
  }

  @Test("REC-02: 左右を指定しない修飾キー単独は登録しない")
  func rejectsUnsidedModifierOnly() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring]
    let target = try setting("option")
    #expect(target.modifierKey == nil)
    #expect(harness.controller.apply(target) == .unavailable(target, .unsupported(.modifierOnly)))
    #expect(harness.taps.created.isEmpty)
  }

  // MARK: - Esc の捕捉

  @Test("REC-01: capability が無効なら Esc のタップを作らず、アクセシビリティも確かめない")
  func escapeCaptureDisabled() throws {
    let harness = Harness(
      capabilities: ShortcutCapabilities(supportsModifierOnly: true, supportsEscapeCapture: false))
    harness.permissions.granted = [.inputMonitoring, .accessibility]
    harness.controller.apply(try setting("ctrl+option+k"))
    #expect(harness.controller.escapeStatus == .off)
    #expect(harness.taps.created.isEmpty)
    #expect(!harness.permissions.checked.contains(.accessibility))
  }

  @Test("REC-01: Esc のタップは待機中は無効で、セッション中だけ有効にして Esc を止めてキャンセルする")
  func escapeCapturedOnlyDuringSession() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    harness.controller.apply(try setting("ctrl+option+k"))
    #expect(harness.controller.escapeStatus == .ready)
    let tap = try #require(harness.taps.live(.filter))
    #expect(tap.events == [.keyDown, .keyUp])
    // 待機中は他アプリの Esc 操作に干渉しない
    #expect(!tap.isEnabled)

    harness.registrar.send(.pressed)
    harness.registrar.send(.released)
    #expect(tap.isEnabled)
    #expect(!tap.send(escape()))
    #expect(harness.commands == [.startRecording, .cancelSession])
    // 止めた Esc の解放までは有効のまま、解放を止めたら無効に戻す
    #expect(tap.isEnabled)
    #expect(!tap.send(escape(.keyUp)))
    #expect(!tap.isEnabled)
  }

  @Test("REC-01: 認識・整形中も Esc を捕捉する。状態の変化は sessionPhaseDidChange で反映する")
  func escapeCapturedWhileProcessing() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    harness.controller.apply(try setting("ctrl+option+k"))
    let tap = try #require(harness.taps.live(.filter))
    harness.registrar.send(.pressed)
    harness.registrar.send(.pressed)
    #expect(harness.phase == .recognizing)
    #expect(tap.isEnabled)

    // 挿入中は捕捉しない
    harness.phase = .inserting
    harness.controller.sessionPhaseDidChange()
    #expect(!tap.isEnabled)
  }

  @Test("REC-01: セッション中でも修飾キー付きの Esc は他アプリへ渡す")
  func modifiedEscapePassesDuringSession() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    harness.controller.apply(try setting("ctrl+option+k"))
    let tap = try #require(harness.taps.live(.filter))
    harness.registrar.send(.pressed)
    #expect(tap.send(escape(flags: [.maskCommand, .maskAlternate])))
    #expect(harness.commands == [.startRecording])
  }

  @Test("REC-01 / REC-02: Push-to-talk ではトリガーの修飾キーを押したままの Esc でキャンセルできる")
  func pushToTalkEscapeWithTriggerModifiers() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.inputMonitoring, .accessibility]
    harness.controller.apply(modifierSetting(.rightOption, .pushToTalk))
    let listen = try #require(harness.taps.live(.listen))
    let filter = try #require(harness.taps.live(.filter))
    listen.send(flagsChanged(.rightOption, down: true))
    #expect(!filter.send(escape(flags: .maskAlternate)))
    #expect(harness.commands == [.startRecording, .cancelSession])
    // キャンセル後の解放では何もしない
    listen.send(flagsChanged(.rightOption, down: false))
    #expect(harness.commands == [.startRecording, .cancelSession])
  }

  @Test("PERM-02: アクセシビリティの許可がなければ Esc 捕捉だけを無効にし、ショートカットは使える")
  func escapeWithoutPermission() throws {
    let harness = Harness(capabilities: allEnabled)
    let target = try setting("ctrl+option+k")
    #expect(harness.controller.apply(target) == .active(target))
    #expect(harness.controller.escapeStatus == .unavailable(.permissionMissing(.accessibility)))
    #expect(harness.taps.created.isEmpty)
    harness.registrar.send(.pressed)
    #expect(harness.commands == [.startRecording])
  }

  @Test("PERM-02: アクセシビリティの許可が取り消されたら Esc 捕捉だけを外し、許可されたら戻す")
  func escapePermissionRevoked() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    let target = try setting("ctrl+option+k")
    harness.controller.apply(target)
    let first = try #require(harness.taps.live(.filter))

    harness.permissions.granted = []
    harness.controller.refreshPermissions()
    #expect(first.isInvalidated)
    #expect(harness.controller.escapeStatus == .unavailable(.permissionMissing(.accessibility)))
    #expect(harness.controller.status == .active(target))

    harness.permissions.granted = [.accessibility]
    harness.controller.refreshPermissions()
    #expect(harness.controller.escapeStatus == .ready)
    #expect(harness.taps.live(.filter) != nil)
  }

  @Test("REC-01: OS が Esc のタップを無効化したら、セッション中だけ再有効化する")
  func escapeTapDisabledByOS() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    harness.controller.apply(try setting("ctrl+option+k"))
    let tap = try #require(harness.taps.live(.filter))
    harness.registrar.send(.pressed)
    tap.disableByOS()
    #expect(tap.isEnabled)

    harness.phase = .idle
    tap.disableByOS()
    #expect(!tap.isEnabled)
  }

  @Test("REC-01: ショートカットを登録できなければ Esc 捕捉も使わない。割当を外すとタップも外す")
  func escapeFollowsShortcut() throws {
    let harness = Harness(capabilities: allEnabled)
    harness.permissions.granted = [.accessibility]
    harness.controller.apply(try setting("esc"))
    #expect(harness.controller.escapeStatus == .off)
    #expect(harness.taps.created.isEmpty)

    harness.controller.apply(try setting("ctrl+option+k"))
    let tap = try #require(harness.taps.live(.filter))
    harness.controller.apply(nil)
    #expect(tap.isInvalidated)
    #expect(harness.controller.escapeStatus == .off)
  }
}
