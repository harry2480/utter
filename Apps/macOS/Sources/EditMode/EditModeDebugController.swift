#if DEBUG
  import AppKit
  import SwiftUI
  import UtterAI
  import UtterCore

  /// Edit Mode（AC-14）を実機で確かめるための Debug ビルド専用の組み立てと、音声指示の入力欄。
  ///
  /// 録音・STT の結線と、Keychain・設定からのクラウドプロバイダー・同意の組み立ては別の PR で行う。それまでの間、
  /// - 音声指示は入力欄の文字列を `EditModeCoordinator.submit(instruction:)` に渡す
  /// - プロバイダーはネットワークに出ない `StubAIProvider` で、入力欄に書いた編集案をそのまま返す
  /// - 同意は入力欄のトグルで、この Debug セッションのメモリ上だけで付与する（保存しない。既定は未同意）
  /// 選択範囲の読み取り・差分プレビュー・置き換え・元に戻すは本番と同じ AX のアダプターとパネルを使う。
  @MainActor
  final class EditModeDebugController {
    private let coordinator: EditModeCoordinator
    private let provider: StubAIProvider
    private let input: EditModeDebugInput
    private var inputPanel: NSPanel?

    private init(
      coordinator: EditModeCoordinator, provider: StubAIProvider, input: EditModeDebugInput,
      panel: EditModePanel
    ) {
      self.coordinator = coordinator
      self.provider = provider
      self.input = input
      panel.onCommit = { [weak self] in
        guard let self else { return }
        Task { await self.coordinator.commit() }
      }
      panel.onCancel = { [weak self] in self?.coordinator.cancel() }
    }

    /// 組み立てる。`EditRouter` を作れなければ `nil`
    static func make() -> EditModeDebugController? {
      let provider = StubAIProvider(destination: .claude)
      guard let router = try? EditRouter(provider: provider) else { return nil }
      let target = AccessibilityInsertionTarget()
      let panel = EditModePanel(fallback: InsertionPreviewPanel())
      let input = EditModeDebugInput()
      let coordinator = EditModeCoordinator(
        inspector: target,
        field: target,
        permissions: SystemInsertionPermissions(),
        presenter: panel,
        clock: ContinuousInsertionClock(),
        router: router,
        consent: { input.consent })
      return EditModeDebugController(
        coordinator: coordinator, provider: provider, input: input, panel: panel)
    }

    /// フォーカス中の入力欄の選択テキストで Edit を始め、音声指示の入力欄を開く
    func start() {
      guard coordinator.begin() == nil else { return }
      showInputPanel()
    }

    /// 直前に確定した Edit を元に戻す
    func undo() async {
      await coordinator.undo()
    }

    private func submit() {
      let instruction = input.instruction
      let proposal = input.stubProposal
      Task {
        await provider.setBehavior(.respond(proposal))
        await coordinator.submit(instruction: instruction)
      }
    }

    private func showInputPanel() {
      let panel = inputPanel ?? makeInputPanel()
      panel.contentView = NSHostingView(
        rootView: EditModeDebugInputView(
          input: input,
          submit: { [weak self] in self?.submit() },
          close: { [weak self] in
            self?.coordinator.cancel()
            self?.closeInputPanel()
          }))
      inputPanel = panel
      // 文字を入力できるようキーウィンドウにする。アプリは前面にしない（nonactivatingPanel）
      panel.makeKeyAndOrderFront(nil)
    }

    private func closeInputPanel() {
      inputPanel?.contentView = nil
      inputPanel?.orderOut(nil)
    }

    private func makeInputPanel() -> NSPanel {
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
        styleMask: [.titled, .resizable, .nonactivatingPanel, .utilityWindow],
        backing: .buffered, defer: true)
      panel.title = "utter — Edit（Debug: 音声指示の代わりの入力）"
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.center()
      return panel
    }
  }

  /// Debug の入力欄の値。同意はメモリ上だけで持ち、保存しない
  @MainActor
  @Observable
  final class EditModeDebugInput {
    var instruction = ""
    var stubProposal = ""
    var consent = ConsentState()

    var consentGranted: Bool {
      get { consent.isGranted(.transmission(.editSelection(.claude))) }
      set {
        if newValue {
          consent.grant(.transmission(.editSelection(.claude)))
        } else {
          consent.revoke(.transmission(.editSelection(.claude)))
        }
      }
    }
  }

  private struct EditModeDebugInputView: View {
    @Bindable var input: EditModeDebugInput
    let submit: () -> Void
    let close: () -> Void

    var body: some View {
      Form {
        TextField("音声指示（STT テキストの代わり）", text: $input.instruction)
        TextField("編集案（Stub の応答）", text: $input.stubProposal, axis: .vertical)
          .lineLimit(3...8)
        Toggle("選択テキストの送信に同意する（この Debug セッションだけ。Stub 宛てで外部へは出ない）", isOn: $input.consentGranted)
        HStack {
          Spacer()
          Button("閉じる", action: close)
          Button("送信", action: submit)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
      .frame(minWidth: 380)
    }
  }
#endif
