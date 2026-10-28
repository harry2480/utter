import Foundation
import UtterCore

/// 本番と同じ `SessionStateMachine` と `ShortcutInterpreter` で、セッションを模擬する。
///
/// 録音・認識・整形は行わない。録音停止後は認識・整形をそれぞれ `processingSeconds / 2` 秒で完了扱いにし、
/// 挿入は即完了扱いにする。認識・整形中も Esc の捕捉対象（`ShortcutInterpreter.capturesEscape(in:)`）。
@MainActor
final class SessionSimulator {
  private var machine = SessionStateMachine()
  private var interpreter: ShortcutInterpreter
  private let processingSeconds: Double
  private let log: ProbeLog
  /// 状態が変わるたびに呼ぶ。引数は変化後の状態
  var onPhaseChange: (@MainActor (SessionPhase) -> Void)?

  init(mode: ShortcutTriggerMode, processingSeconds: Double, log: ProbeLog) {
    interpreter = ShortcutInterpreter(mode: mode)
    self.processingSeconds = processingSeconds
    self.log = log
  }

  var phase: SessionPhase { machine.phase }

  var capturesEscape: Bool {
    ShortcutInterpreter.capturesEscape(in: machine.phase)
  }

  /// ショートカットの押下・解放・Esc を解釈して実行する。戻り値は Esc 等を捕捉するか。
  @discardableResult
  func handle(_ input: ShortcutInput) -> Bool {
    let decision = interpreter.handle(input, phase: machine.phase)
    log.write("interp", "入力=\(input) 状態=\(machine.phase) → \(decision)")
    guard case .consumed(let command) = decision else { return false }
    switch command {
    case .startRecording:
      machine.start(at: .now)
      changed()
    case .stopRecording:
      if let token = machine.stopRecording(at: .now) {
        changed()
        scheduleProcessing(token: token)
      }
    case .cancelSession:
      machine.cancel()
      changed()
    // 処理中の押下の確認は既定（何もしない）のまま使うため届かない
    case .confirmCancel, nil:
      break
    }
    return true
  }

  /// 押下状態が信用できなくなったとき（タップが無効化された等）に呼ぶ。
  func resetInterpreter() {
    interpreter.reset()
    log.write("interp", "押下状態をリセット")
  }

  private func scheduleProcessing(token: SessionToken) {
    let step = Duration.milliseconds(Int(processingSeconds * 500))
    Task { @MainActor in
      try? await Task.sleep(for: step)
      guard self.apply(SessionEvent(token: token, kind: .recognitionCompleted)) else { return }
      // 待つ前にトークンを取る。待つ間にキャンセル→再開始されても、古いセッション宛てとして破棄される
      let refining = self.machine.currentToken
      try? await Task.sleep(for: step)
      guard let refining,
        self.apply(SessionEvent(token: refining, kind: .refinementCompleted)),
        let inserting = self.machine.currentToken
      else { return }
      _ = self.apply(SessionEvent(token: inserting, kind: .insertionCompleted))
    }
  }

  /// 模擬の完了イベントを反映する。キャンセル済みなら破棄されて `false`。
  private func apply(_ event: SessionEvent) -> Bool {
    do {
      let outcome = try machine.handle(event)
      if case .discarded(let reason) = outcome {
        log.write("session", "模擬イベント \(event.kind) を破棄（\(reason)）")
        return false
      }
      changed()
      return true
    } catch {
      log.write("session", "模擬イベント \(event.kind) の遷移エラー: \(error)")
      return false
    }
  }

  private func changed() {
    log.write(
      "session",
      "状態=\(machine.phase) Esc捕捉=\(ShortcutInterpreter.capturesEscape(in: machine.phase))")
    onPhaseChange?(machine.phase)
  }
}
