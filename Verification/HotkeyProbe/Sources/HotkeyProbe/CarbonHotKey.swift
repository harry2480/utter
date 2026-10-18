import Carbon.HIToolbox
import Foundation
import UtterCore

/// RegisterEventHotKey による通常の組み合わせの登録。権限は不要とされる（本検証で確かめる）。
@MainActor
final class CarbonHotKeys {
  enum Phase: Sendable {
    case pressed
    case released
  }

  /// 引数は登録時に返した ID
  typealias Handler = @MainActor (UInt32, Phase) -> Void

  private let handler: Handler
  private var handlerRef: EventHandlerRef?
  private var hotKeys: [UInt32: EventHotKeyRef] = [:]
  private var nextID: UInt32 = 1
  /// 'UTPR'
  private static let signature: OSType = 0x5554_5052

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// ハンドラを登録する。押下・解放の両方を受け取る。
  func installHandler() -> OSStatus {
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    return InstallEventHandler(
      GetApplicationEventTarget(),
      hotKeyCallback,
      specs.count,
      &specs,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )
  }

  /// 登録して `(OSStatus, ID)` を返す。失敗時の ID は `nil`。
  ///
  /// `exclusive` は kEventHotKeyExclusive。他のプロセスが同じ組み合わせを登録済みなら
  /// eventHotKeyExistsErr（-9878）で失敗することを期待する（本検証で確かめる）。
  func register(keyCode: Int, carbonModifiers: UInt32, exclusive: Bool) -> (OSStatus, UInt32?) {
    let id = nextID
    nextID += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      carbonModifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      OptionBits(exclusive ? kEventHotKeyExclusive : kEventHotKeyNoOptions),
      &ref
    )
    guard status == noErr, let ref else { return (status, nil) }
    hotKeys[id] = ref
    return (status, id)
  }

  isolated deinit {
    unregisterAll()
  }

  func unregisterAll() {
    for ref in hotKeys.values {
      UnregisterEventHotKey(ref)
    }
    hotKeys.removeAll()
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
    handlerRef = nil
  }

  fileprivate func dispatch(id: UInt32, phase: Phase) {
    handler(id, phase)
  }

  static func describe(_ status: OSStatus) -> String {
    switch status {
    case OSStatus(noErr): "noErr（登録成功）"
    case OSStatus(eventHotKeyExistsErr): "eventHotKeyExistsErr（\(status)。同じ組み合わせが排他登録済み）"
    case OSStatus(eventHotKeyInvalidErr): "eventHotKeyInvalidErr（\(status)）"
    default: "OSStatus \(status)"
    }
  }
}

private func hotKeyCallback(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr else { return status }
  let phase: CarbonHotKeys.Phase =
    GetEventKind(event) == UInt32(kEventHotKeyReleased) ? .released : .pressed
  let id = hotKeyID.id
  let hotKeys = Unmanaged<CarbonHotKeys>.fromOpaque(userInfo).takeUnretainedValue()
  // アプリケーションのイベントターゲットへの配送はメインスレッドで行われる
  MainActor.assumeIsolated { hotKeys.dispatch(id: id, phase: phase) }
  return noErr
}

/// システムのショートカット（システム設定 > キーボード > キーボードショートカット）の一覧。
///
/// CopySymbolicHotKeys で取得する。他のアプリが独自に登録したショートカットやメニューの
/// ショートカットは含まれない。
enum SystemShortcuts {
  struct Entry {
    let binding: ShortcutBinding
    let enabled: Bool
    let rawModifiers: Int
  }

  static func load() -> [Entry] {
    var unmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&unmanaged) == noErr, let unmanaged else { return [] }
    let array = unmanaged.takeRetainedValue() as NSArray
    return array.enumerated().compactMap { index, element in
      guard let dict = element as? [String: Any],
        let code = (dict["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
        let rawModifiers = (dict["kHISymbolicHotKeyModifiers"] as? NSNumber)?.intValue,
        let key = KeyNames.shortcutKey(forCode: code)
      else { return nil }
      let enabled = (dict["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue ?? true
      let combination = KeyCombination(key: key, modifiers: modifiers(fromRaw: rawModifiers))
      return Entry(
        // ID は CopySymbolicHotKeys の配列上の位置。システム設定の項目名は取得できない
        binding: ShortcutBinding(id: "system.index.\(index)", combination: combination),
        enabled: enabled,
        rawModifiers: rawModifiers
      )
    }
  }

  /// 修飾キーの値を UtterCore の型へ変換する。
  ///
  /// Carbon 形式（cmdKey = 0x100 等）か NSEvent 形式（command = 0x100000 等）かが
  /// 確かでないため、Carbon 形式のビット（0x1F00）の有無で判別する。生の値もログに出す。
  /// 0x20000 だけの値は Carbon の Fn（kEventKeyModifierFnMask）と NSEvent の Shift を区別できない。
  /// その場合は NSEvent の Shift として扱い、`isAmbiguous` で判別不能として表示する。
  static func isAmbiguous(_ raw: Int) -> Bool {
    raw == Int(kEventKeyModifierFnMask)
  }

  static func modifiers(fromRaw raw: Int) -> ShortcutModifiers {
    var result: ShortcutModifiers = []
    if raw & 0x1F00 == 0 {
      if raw & 0x10_0000 != 0 { result.insert(.command) }
      if raw & 0x08_0000 != 0 { result.insert(.option) }
      if raw & 0x04_0000 != 0 { result.insert(.control) }
      if raw & 0x02_0000 != 0 { result.insert(.shift) }
      if raw & 0x80_0000 != 0 { result.insert(.function) }
    } else {
      if raw & cmdKey != 0 { result.insert(.command) }
      if raw & optionKey != 0 { result.insert(.option) }
      if raw & controlKey != 0 { result.insert(.control) }
      if raw & shiftKey != 0 { result.insert(.shift) }
      if raw & Int(kEventKeyModifierFnMask) != 0 { result.insert(.function) }
    }
    return result
  }
}
