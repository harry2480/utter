import SwiftUI
import UtterPersistence
import UtterSpeech

/// 初回セットアップの画面（PERM-01〜03, REC-01, REC-02, AI-03, #198）。
///
/// 最後まで進めていなければ、起動時に開いて続きの手順から始める。一度最後まで進めたら（飛ばした手順があっても）、
/// メニューから開いたときだけ出し、飛ばした手順を続きから済ませられる。
struct PermissionOnboardingScene: Scene {
  static let windowID = "permission-onboarding"

  @State private var model: FirstRunSetupModel
  private let shortcuts: ShortcutCoordinator
  /// 起動時に開くか。最後まで進めていなければ開く
  private let launchBehavior: SceneLaunchBehavior

  /// - Parameters:
  ///   - sttEngine: 使っている STT エンジン（`AppComposition.selectedEngine()`）。未選択なら `nil`
  ///   - shortcuts: 録音ショートカットの登録（`AppComposition` が持つ）。登録の結果と、修飾キー単独のときの権限の要求に使う
  init(sttEngine: STTEngineKind?, shortcuts: ShortcutCoordinator) {
    let permissionDefaults = PermissionDefaults()
    let setupDefaults = FirstRunSetupDefaults()
    // 作るだけで、状態の確認は画面を開いたときにする（どちらもネットワークを使わない）
    let speechModel = STTEngineSetting.makeModelAssets(for: sttEngine).map {
      SpeechModelSettingsModel(assets: $0)
    }
    _model = State(
      initialValue: FirstRunSetupModel(
        permissions: PermissionOnboardingModel(
          configuration: .phase0Pending,
          access: SystemPermissionAccess(defaults: permissionDefaults),
          defaults: permissionDefaults),
        speechModel: speechModel, sttEngine: sttEngine,
        store: AppSettingsStore(defaults: .standard), defaults: setupDefaults,
        loadSystemShortcuts: { SystemShortcuts.loadEnabledBindings() },
        shortcutStatus: { [shortcuts] in shortcuts.status }))
    self.shortcuts = shortcuts
    launchBehavior = setupDefaults.progress.opensAtLaunch ? .presented : .suppressed
  }

  var body: some Scene {
    Window("初回セットアップ", id: Self.windowID) {
      FirstRunSetupView(model: model, shortcuts: shortcuts)
    }
    .windowResizability(.contentSize)
    // 最後まで進めた後は、メニューから開いたときだけ出す。前回終了時の状態の復元では開かない
    .defaultLaunchBehavior(launchBehavior)
    .restorationBehavior(.disabled)
  }
}

/// メニューの「初回セットアップ…」
struct PermissionOnboardingMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("初回セットアップ…") {
      openWindow(id: PermissionOnboardingScene.windowID)
      bringToFront()
    }
  }
}
