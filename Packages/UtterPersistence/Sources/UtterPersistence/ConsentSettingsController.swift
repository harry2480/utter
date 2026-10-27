import UtterCore

/// 同意の画面の状態を、保存済みの設定から読み、操作のたびに保存する（AC-06, AI-04）。
///
/// 操作のたびに最新の設定を読み直し、同意状態だけを書き換えて保存する（ほかの設定項目を古い値で上書きしない）。
/// 送信側は送信の直前に `currentConsent()`（または `AppSettingsStore.load().consentState`）で最新の同意状態を読むため、
/// 撤回は保存した時点で次の送信から反映される。
/// `AppSettingsStore` と同じく `Sendable` にしない。アプリ側で1つの隔離領域（`@MainActor` など）から使う。
public struct ConsentSettingsController {
  private let store: AppSettingsStore
  private let additionalScopes: [ConsentScope]

  /// - Parameter additionalScopes: 画面に常に表示する、その画面の機能の同意対象
  ///   （`ConsentScreenState.init(consent:additionalScopes:)`。macOS の Edit Mode など）
  public init(store: AppSettingsStore, additionalScopes: [ConsentScope] = []) {
    self.store = store
    self.additionalScopes = additionalScopes
  }

  /// 保存済みの同意状態から画面の状態を作る。未保存・読めない値ならすべて未同意
  public func load() -> ConsentScreenState {
    ConsentScreenState(consent: currentConsent(), additionalScopes: additionalScopes)
  }

  /// 保存済みの最新の同意状態
  public func currentConsent() -> ConsentState {
    store.load().consentState
  }

  /// 同意する（`true`）か撤回する（`false`）。保存した後の画面の状態を返す。
  ///
  /// - Throws: 保存に失敗した場合。保存済みの同意状態は変わらない
  @discardableResult
  public func setGranted(_ granted: Bool, for scope: ConsentScope) throws -> ConsentScreenState {
    var settings = store.load()
    var screen = ConsentScreenState(
      consent: settings.consentState, additionalScopes: additionalScopes)
    screen.setGranted(granted, for: scope)
    settings.consentState = screen.consent
    try store.save(settings)
    return screen
  }
}
