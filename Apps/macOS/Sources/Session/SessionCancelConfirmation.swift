import UtterCore

/// キャンセルするかの確認の表示（本番は `CancelConfirmationPanel`）。
///
/// 入力先アプリのフォーカスを奪わないよう、アプリをアクティブにせずに出す。発話本文は出さない
@MainActor
protocol SessionCancelConfirmationPresenting: AnyObject {
  /// 確認を出す。利用者が答えたら `onAnswer` を1回だけ呼ぶ（キャンセルするなら `true`）
  func present(onAnswer: @escaping @MainActor (Bool) -> Void)
  /// 答えを待たずに閉じる。閉じた後は `onAnswer` を呼ばない
  func dismiss()
}

/// 認識中・整形中にもう一度ショートカットを押したときの、キャンセルの確認（REC-06, #199）。
///
/// 設定で「キャンセルするか確認する」を選んだときだけ、ショートカットの解釈（`ShortcutInterpreter`）が
/// `ShortcutCommand.confirmCancel` を返し、アプリがここへ渡す。
/// - 確認を出している間も処理は止めない。認識中・整形中でなくなったら（挿入が始まった・終わった・失敗した）、答えを待たずに閉じる
/// - キャンセルするのは、確認を出したセッションがまだ認識中・整形中のときだけ（挿入が始まったら取り消さない, REC-01）
/// - 確認を出している間に同じセッションでもう一度押されたら、キャンセルを選んだとみなす（パネルはキーを受けないため、
///   キーボードだけでも答えられるようにする）。何もしなければ処理を続ける
@MainActor
final class SessionCancelConfirmation {
  private let presenter: any SessionCancelConfirmationPresenting
  private let phase: @MainActor () -> SessionPhase
  private let session: @MainActor () -> SessionID?
  private let cancel: @MainActor () -> Void
  /// 確認を出しているセッション
  private var pending: SessionID?

  /// - Parameters:
  ///   - phase: セッションの現在の状態
  ///   - session: 進行中のセッション。なければ `nil`
  ///   - cancel: セッションをキャンセルする
  init(
    presenter: any SessionCancelConfirmationPresenting,
    phase: @escaping @MainActor () -> SessionPhase,
    session: @escaping @MainActor () -> SessionID?,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.presenter = presenter
    self.phase = phase
    self.session = session
    self.cancel = cancel
  }

  /// 確認を出しているか
  var isPresenting: Bool { pending != nil }

  /// 確認を出す。確認を出している間なら、キャンセルを選んだとみなす。認識中・整形中でなければ何もしない
  func request() {
    guard let current = processingSession() else { return }
    if let pending {
      guard pending == current else { return }
      presenter.dismiss()
      answer(true, for: current)
      return
    }
    pending = current
    presenter.present { [weak self] confirmed in
      self?.answer(confirmed, for: current)
    }
  }

  /// セッションの状態が変わったときに呼ぶ。確認を出したセッションが認識中・整形中でなくなったら閉じる
  func sessionPhaseDidChange() {
    guard let pending, processingSession() != pending else { return }
    self.pending = nil
    presenter.dismiss()
  }

  private func answer(_ confirmed: Bool, for answered: SessionID) {
    guard pending == answered else { return }
    pending = nil
    guard confirmed, processingSession() == answered else { return }
    cancel()
  }

  /// 認識中・整形中のセッション。それ以外の状態なら `nil`
  private func processingSession() -> SessionID? {
    switch phase() {
    case .recognizing, .refining: session()
    case .idle, .recording, .inserting, .error: nil
    }
  }
}
