import Carbon.HIToolbox
import Testing
import UtterCore

/// コントローラーと Stub、受け取ったセッション操作をまとめたテスト用の組み立て。
@MainActor
final class Harness {
  let registrar = StubHotKeyRegistrar()
  let taps = StubKeyEventTapFactory()
  let permissions = StubEventTapPermissions()
  var systemShortcuts: [ShortcutBinding] = []
  var phase: SessionPhase = .idle
  private(set) var commands: [ShortcutCommand] = []
  private(set) var systemShortcutLoads = 0
  private(set) var controller: GlobalShortcutController!

  init(capabilities: ShortcutCapabilities = .keyCombinationsOnly) {
    controller = GlobalShortcutController(
      registrar: registrar,
      tapFactory: taps,
      permissions: permissions,
      capabilities: capabilities,
      systemShortcuts: { [unowned self] in
        systemShortcutLoads += 1
        return systemShortcuts
      },
      currentPhase: { [unowned self] in phase },
      perform: { [unowned self] command in
        commands.append(command)
        // 録音の結線の代わりに、状態機械と同じ遷移をする
        switch command {
        case .startRecording: phase = .recording
        case .stopRecording: phase = .recognizing
        case .cancelSession: phase = .idle
        }
      }
    )
  }
}

func setting(_ text: String, _ mode: ShortcutTriggerMode = .toggle) throws
  -> GlobalShortcutSetting
{
  GlobalShortcutSetting(combination: try #require(ShortcutNotation.parse(text)), mode: mode)
}

@MainActor
struct GlobalShortcutControllerTests {
  @Test("REC-01: 割当がなければ何も登録しない")
  func unassigned() {
    let harness = Harness()
    #expect(harness.controller.apply(nil) == .unassigned)
    #expect(harness.registrar.registered.isEmpty)
    #expect(harness.systemShortcutLoads == 0)
  }

  @Test("PERM-01: 既定（修飾キー単独・Esc 捕捉とも無効）ではイベントタップを作らず、権限も確かめない")
  func keyCombinationsOnlyCreatesNoTap() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.registrar.send(.pressed)
    harness.controller.refreshPermissions()
    #expect(!harness.controller.usesEventTaps)
    #expect(harness.taps.created.isEmpty)
    #expect(harness.permissions.checked.isEmpty)
    #expect(harness.controller.escapeStatus == .off)
  }

  @Test("REC-01: 通常のキー組み合わせを登録する")
  func registers() throws {
    let harness = Harness()
    let target = try setting("ctrl+option+k")
    #expect(harness.controller.apply(target) == .active(target))
    #expect(
      Array(harness.registrar.registered.values)
        == [
          CarbonHotKeySpec(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        ])
  }

  @Test("REC-01: 割当を置き換えると前の登録を解除する。nil で解除だけする")
  func replaces() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k"))
    let firstID = try #require(harness.registrar.registered.keys.first)
    harness.controller.apply(try setting("cmd+shift+f5"))
    #expect(harness.registrar.unregisteredIDs == [firstID])
    #expect(
      Array(harness.registrar.registered.values)
        == [CarbonHotKeySpec(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey))])

    #expect(harness.controller.apply(nil) == .unassigned)
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-02: 有効なシステムのショートカットと重なる組み合わせは登録しない")
  func rejectsSystemConflict() throws {
    let harness = Harness()
    let target = try setting("cmd+space")
    harness.systemShortcuts = [
      ShortcutBinding(
        id: "system.index.0", combination: KeyCombination(key: .space, modifiers: .command))
    ]
    #expect(
      harness.controller.apply(target)
        == .unavailable(
          target, .invalid([.conflict(bindingID: "system.index.0", kind: .identical)])))
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-01: Esc 単独はキャンセルに予約されているため登録しない")
  func rejectsEscape() throws {
    let harness = Harness()
    let target = try setting("esc")
    #expect(
      harness.controller.apply(target) == .unavailable(target, .invalid([.reservedForCancel])))
  }

  @Test("REC-02: 修飾キー単独は #51 の判定まで受け付けない")
  func rejectsModifierOnly() throws {
    let harness = Harness()
    let target = try setting("fn")
    #expect(
      harness.controller.apply(target) == .unavailable(target, .invalid([.modifierOnlyUnsupported]))
    )
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-02: RegisterEventHotKey で扱えない組み合わせは登録しない")
  func rejectsUnsupported() throws {
    let harness = Harness()
    let target = try setting("fn+f5")
    #expect(
      harness.controller.apply(target) == .unavailable(target, .unsupported(.functionModifier)))
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-02: 他アプリの排他登録との競合を登録失敗として返す。前の登録は残さない")
  func registrationFailure() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k"))
    harness.registrar.nextFailure = .alreadyRegistered
    let target = try setting("ctrl+option+j")
    #expect(
      harness.controller.apply(target)
        == .unavailable(target, .registrationFailed(.alreadyRegistered)))
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-01: Toggle は押下で開始・停止し、解放では何もしない")
  func toggle() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k"))
    harness.registrar.send(.pressed)
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording])
    harness.registrar.send(.pressed)
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  @Test("REC-02: Push-to-talk は押下で開始し、解放で停止する")
  func pushToTalk() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.registrar.send(.pressed)
    #expect(harness.commands == [.startRecording])
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  @Test("REC-02: Push-to-talk で解放を取りこぼしても、次の押下で録音を停止できる")
  func recoversFromLostRelease() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.registrar.send(.pressed)
    // 解放が届かないまま次の押下
    harness.registrar.send(.pressed)
    #expect(harness.commands == [.startRecording, .stopRecording])
    // その後の解放では何もしない
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  @Test("REC-02: Push-to-talk の押下中に Toggle へ切り替えると、その後の解放では停止しない")
  func modeChangeDropsPushToTalkOwnership() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.registrar.send(.pressed)
    harness.controller.apply(try setting("ctrl+option+k", .toggle))
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording])
  }

  @Test("REC-02: 押下を受けていない解放は捨てる")
  func ignoresOrphanRelease() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.phase = .recording
    harness.registrar.send(.released)
    #expect(harness.commands.isEmpty)
  }

  @Test("REC-02: reset 後は押下中の状態を破棄し、次の押下を新しい押下として扱う")
  func resetDropsPressedState() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k", .pushToTalk))
    harness.registrar.send(.pressed)
    // スリープ中に解放を取りこぼした想定
    harness.controller.reset()
    harness.registrar.send(.pressed)
    // 録音中の押下は取りこぼしからの回復として停止する（ShortcutInterpreter）
    #expect(harness.commands == [.startRecording, .stopRecording])
  }

  // MARK: 設定画面の変更（update）

  @Test("REC-01: 待機中に設定で割当が変わったら、すぐに登録し直す")
  func updateWhileIdleAppliesImmediately() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k"))
    let target = try setting("ctrl+option+j", .pushToTalk)
    harness.controller.update(target)
    #expect(harness.controller.status == .active(target))
    #expect(
      Array(harness.registrar.registered.values)
        == [
          CarbonHotKeySpec(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))
        ])
  }

  @Test("REC-02: 同じ割当なら登録し直さず、登録失敗の表示もそのまま残す")
  func updateWithSameSettingKeepsRegistration() throws {
    let harness = Harness()
    let target = try setting("ctrl+option+k")
    harness.registrar.nextFailure = .alreadyRegistered
    let failed = harness.controller.apply(target)
    harness.controller.update(target)
    #expect(harness.controller.status == failed)
    #expect(harness.registrar.registered.isEmpty)
    #expect(harness.systemShortcutLoads == 1)
  }

  @Test("REC-02: セッション中に割当が変わったら、待機に戻ってから登録し直す（押下中の Push-to-talk を保つ）")
  func updateDuringSessionWaitsForIdle() throws {
    let harness = Harness()
    let original = try setting("ctrl+option+k", .pushToTalk)
    harness.controller.apply(original)
    harness.registrar.send(.pressed)
    #expect(harness.phase == .recording)

    let target = try setting("ctrl+option+j", .toggle)
    harness.controller.update(target)
    harness.controller.sessionPhaseDidChange()
    #expect(harness.controller.status == .active(original))
    #expect(harness.registrar.unregisteredIDs.isEmpty)

    // 押下中の Push-to-talk は元の割当のまま、解放で停止する
    harness.registrar.send(.released)
    #expect(harness.commands == [.startRecording, .stopRecording])
    harness.controller.sessionPhaseDidChange()
    #expect(harness.controller.status == .active(original))

    harness.phase = .idle
    harness.controller.sessionPhaseDidChange()
    #expect(harness.controller.status == .active(target))
    #expect(harness.registrar.unregisteredIDs.count == 1)
  }

  @Test("REC-01: セッション中に割当が外されたら、待機に戻ってから登録を解除する")
  func updateToUnassignedDuringSession() throws {
    let harness = Harness()
    harness.controller.apply(try setting("ctrl+option+k"))
    harness.registrar.send(.pressed)
    harness.controller.update(nil)
    #expect(!harness.registrar.registered.isEmpty)

    harness.phase = .idle
    harness.controller.sessionPhaseDidChange()
    #expect(harness.controller.status == .unassigned)
    #expect(harness.registrar.registered.isEmpty)
  }

  @Test("REC-01: セッション中に割当を元に戻したら、待機に戻っても登録し直さない")
  func updateRevertedDuringSession() throws {
    let harness = Harness()
    let original = try setting("ctrl+option+k")
    harness.controller.apply(original)
    harness.registrar.send(.pressed)
    harness.controller.update(try setting("ctrl+option+j"))
    harness.controller.update(original)

    harness.phase = .idle
    harness.controller.sessionPhaseDidChange()
    #expect(harness.controller.status == .active(original))
    #expect(harness.registrar.unregisteredIDs.isEmpty)
  }
}

struct HotKeyEventTranslatorTests {
  @Test("REC-01: 押下・解放を ShortcutInterpreter の入力に変換する。押下を受けていない解放は捨てる")
  func translates() {
    var translator = HotKeyEventTranslator()
    #expect(translator.translate(.released) == nil)
    #expect(translator.translate(.pressed) == .shortcutPressed(isRepeat: false))
    #expect(translator.translate(.pressed) == .shortcutPressed(isRepeat: false))
    #expect(translator.translate(.released) == .shortcutReleased)
    #expect(translator.translate(.released) == nil)
  }
}
