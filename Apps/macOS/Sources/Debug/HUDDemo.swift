#if DEBUG
  import UtterCore

  /// HUD の表示を目視で確かめるためのデモ（Debug ビルドのみ）。
  ///
  /// 録音・STT・挿入の代わりに、状態機械を一定の間隔で進めて `HUDController` に反映する。
  /// 本文は扱わず、表示するのは状態と通知の文言だけ。
  @MainActor
  final class HUDDemo {
    private let hud: HUDController
    private var machine = SessionStateMachine()
    private var task: Task<Void, Never>?

    init(hud: HUDController) {
      self.hud = hud
    }

    /// 録音 → 音声バッファの上限到達で自動停止 → 認識 → 整形 → 挿入 → 通知だけを残す、を順に表示する
    func runLimitReached() {
      run { demo in
        demo.machine.start(at: .now)
        demo.reflect()
        try await Task.sleep(for: .seconds(2))
        demo.machine.stopRecordingAtBufferLimit()
        demo.reflect()
        for kind in [
          SessionEvent.Kind.recognitionCompleted, .refinementCompleted, .insertionCompleted,
        ] {
          try await Task.sleep(for: .seconds(1))
          demo.send(kind)
        }
      }
    }

    /// 録音 → 認識 → 認識の失敗を表示し、表示時間が過ぎたら消す
    func runFailure() {
      run { demo in
        demo.machine.start(at: .now)
        demo.reflect()
        try await Task.sleep(for: .seconds(1))
        demo.machine.stopRecording(at: .now)
        demo.reflect()
        try await Task.sleep(for: .seconds(1))
        demo.send(.failed)
      }
    }

    private func run(_ steps: @escaping @MainActor (HUDDemo) async throws -> Void) {
      task?.cancel()
      // 挿入中はキャンセルできないため、デモでは状態機械ごと作り直す。
      // ここで待機を反映すると前のセッションの通知が残るため、最初の録音開始で反映する
      machine = SessionStateMachine()
      hud.onErrorDisplayExpired = { [weak self] in
        guard let self else { return }
        machine.dismissError()
        reflect()
      }
      task = Task { [weak self] in
        guard let self else { return }
        try? await steps(self)
      }
    }

    private func send(_ kind: SessionEvent.Kind) {
      guard let token = machine.currentToken else { return }
      _ = try? machine.handle(SessionEvent(token: token, kind: kind))
      reflect()
    }

    private func reflect() {
      hud.update(from: machine)
    }
  }
#endif
