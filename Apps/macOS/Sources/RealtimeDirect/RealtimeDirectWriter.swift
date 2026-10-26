import UtterCore
import UtterSpeech
import UtterText

/// Realtime Direct を始められなかった理由（AC-15）。呼び出し側は Realtime Preview（停止後に一括挿入）で処理する。
enum RealtimeDirectStartFailure: Hashable, Sendable {
  /// 使える条件（実験機能の有効化・許可リスト・ターミナル系・入力欄の状態）を満たさない
  case unavailable(Set<RealtimeDirectUnavailableReason>)
  /// パスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できない（7章, AC-12）
  case sensitiveInput(Set<SensitiveInputReason>)
}

/// 取り消しの結果（AC-15）。
enum RealtimeDirectUndoOutcome: Hashable, Sendable {
  /// 書き込んだテキストを取り除いた
  case reverted
  /// 何も書き込んでいない
  case nothingToRevert
  /// 範囲を確かめられない、または機密入力に変わったため、入力欄に触れなかった
  case unavailable(RealtimeDirectStopReason)
  /// 取り除く書き込みに失敗した。入力欄の状態は確かめられない
  case writeFailed
  /// 取り消せるセッションがない（始めていない・取り消し済み）
  case noSession
}

/// 認識イベントの列を受けて、確定済みチャンクを入力欄へ逐次書き込む（2.2節 Realtime Direct, AC-15）。
///
/// 範囲の追跡・差分・照合は UtterText の `RealtimeDirectSession` が決め、この型は AX での読み書きと
/// 認識イベントの受け付け（`RecognitionEventFilter` / `TranscriptPreview`）をつなぐ。
///
/// - 暫定の認識結果（`partial`）は書き込まない。`confirmed` を受けるたびに確定済みテキスト全体を、`completed` で
///   全体の確定テキストを渡し、差分だけを置き換える
/// - 書き込む直前ごとに、フォーカス中の入力対象・値全体・カーソル位置を読み、記録と合わなければ（範囲外の編集・
///   フォーカスの移動など）入力欄に触れずに直接の書き込みをやめる。機密入力（7章）に変わった場合も同じ
/// - やめた後も認識は続け、終わったら確定テキスト全体をコピー可能なプレビューに出す（AC-09）。
///   それまでの書き込みは入力欄に残す（範囲を確かめられないため取り除かない）
/// - 完了時は書き込んだ直後にもう一度照合し、成功を返して反映しなかった場合もプレビューに出す。完了の確定テキストが
///   空なら、確定済みのチャンクを消さない
/// - 認識の失敗では、それまでの書き込みを確定済みとして残す（Realtime Preview と同じく確定済みテキストは残す）
/// - セッションのキャンセルでは、書き込んだテキストを照合のうえ取り除く。照合に失敗したら入力欄に触れない
///
/// 読み取りと置き換えは `@MainActor` の同期処理の中で続けて行い、間に利用者の入力を挟まない。
/// 入力欄の値・認識テキストはメモリ上の照合にだけ使い、ログ・`description` に出さない。
@MainActor
final class RealtimeDirectWriter {
  private let inspector: any InsertionTargetInspector
  private let field: any RealtimeDirectFieldAccess
  private let preview: any InsertionPreviewPresenting
  private let allowlist: RealtimeDirectAllowlist
  private let policy: InsertionPolicy
  private let sensitivePolicy: SensitiveInputPolicy

  private var filter = RecognitionEventFilter()
  private var transcript = TranscriptPreview()
  /// 書き込み中・書き込み後のセッション。始められなかった・取り消した後は `nil`
  private(set) var session: RealtimeDirectSession?
  /// このセッションで入力欄へ送った書き込みがあるか（送信後の失敗を含む）。プレビューの文言に使う
  private var sentWrite = false

  init(
    inspector: any InsertionTargetInspector,
    field: any RealtimeDirectFieldAccess,
    preview: any InsertionPreviewPresenting,
    allowlist: RealtimeDirectAllowlist,
    policy: InsertionPolicy = InsertionPolicy(),
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy()
  ) {
    self.inspector = inspector
    self.field = field
    self.preview = preview
    self.allowlist = allowlist
    self.policy = policy
    self.sensitivePolicy = sensitivePolicy
  }

  /// 認識セッションの開始時に呼び、Realtime Direct を使えるか確かめて始める（AC-15）。
  ///
  /// 前のセッションは破棄する（その書き込みは取り消せなくなる）。使えなければ以後のイベントを書き込まず、
  /// 失敗の理由を返す。呼び出し側は Realtime Preview で処理する。
  ///
  /// - Parameters:
  ///   - sessionID: 認識イベントのセッション
  ///   - recordedTarget: 録音開始時に `InsertionTargetInspector.recordTarget()` で記録した入力対象
  ///   - isEnabled: 利用者が実験機能を有効にしたか
  func begin(sessionID: SessionID, recordedTarget: InsertionTargetID?, isEnabled: Bool)
    -> RealtimeDirectStartFailure?
  {
    session = nil
    sentWrite = false
    transcript = TranscriptPreview()
    filter = RecognitionEventFilter()

    let focused = inspector.focusedTarget()
    let requirements = RealtimeDirectRequirements(
      isEnabled: isEnabled, appSupport: allowlist.support(for: focused?.app),
      profile: policy.profile(for: focused?.app))
    // 使えないアプリ・無効のときは、入力欄の値を読まずに終える
    let reasons = requirements.unavailableReasons
    guard reasons.isEmpty else { return .unavailable(reasons) }
    // 録音開始時と違う入力対象なら、開始時の入力対象を特定できない扱いにする（INS-01）
    let target = focused?.id == recordedTarget ? focused?.id : nil
    // パスワード欄などは、値を読む前に除く（7章）
    let sensitive = sensitiveReasons(focused, on: target)
    guard sensitive.isEmpty else { return .sensitiveInput(sensitive) }
    do {
      session = try RealtimeDirectSession(
        requirements: requirements, observation: observe(target))
    } catch {
      switch error {
      case .unavailable(let reasons): return .unavailable(reasons)
      case .invalidTransition: return .unavailable([.fieldUnreadable])
      }
    }
    filter.begin(sessionID)
    return nil
  }

  /// 認識イベントを受け取る。別のセッション・順序の古いイベント・始められなかったセッションのイベントは無視する。
  func handle(_ event: RecognitionEvent) {
    guard session != nil, filter.accept(event) == nil else { return }
    let confirmedBefore = transcript.confirmedText
    transcript.apply(event.kind)
    switch event.kind {
    case .partial:
      // 暫定の認識結果は後から変わるため、入力欄には書き込まない（2.2節: 確定済みチャンクだけ）
      break
    case .confirmed:
      write(transcript.confirmedText)
    case .completed(let text):
      // 確定済みのチャンクがあるのに完了の確定テキストが空なら、見えていた文字を消さないよう書き換えない
      let final = text.isEmpty && !confirmedBefore.isEmpty ? confirmedBefore : text
      write(final)
      // 完了後は次の照合の機会がないため、書き込みが反映されたかをここで確かめる（成功を返して反映しないアプリ, INS-05）
      write(final)
      finish(previewText: final)
    case .failed:
      finish(previewText: transcript.confirmedText)
    }
  }

  /// セッションをキャンセルし、書き込んだテキストを取り除く。別のセッションなら何もせず `nil` を返す。
  @discardableResult
  func cancel(_ sessionID: SessionID) -> RealtimeDirectUndoOutcome? {
    guard filter.cancel(sessionID) else { return nil }
    return undo()
  }

  /// 書き込んだテキストを取り除き、開始前の入力欄に戻す（AC-15）。認識の終了後か、キャンセルのときに呼ぶ。一度だけ行える。
  @discardableResult
  func undo() -> RealtimeDirectUndoOutcome {
    guard var session, session.state.kind != .undone else { return .noSession }
    defer { self.session = session }
    let focused = inspector.focusedTarget()
    // 機密入力に変わった入力欄には触れない（7章）。書き込み中なら直接の書き込みもやめる
    guard sensitiveReasons(focused, on: session.target).isEmpty else {
      session.stop(.interrupted)
      return .unavailable(.interrupted)
    }
    // 完了後にフォーカスが一時的に別の入力欄にあるだけなら、記録を進めずに後で取り消せるようにする
    if case .finished = session.state, focused?.id != session.target {
      return .unavailable(focused == nil ? .targetMissing : .targetChanged)
    }
    let observation = observe(focused?.id)
    let undo: RealtimeDirectUndo
    do {
      undo = try session.undo(observation: observation)
    } catch {
      return .noSession
    }
    switch undo {
    case .nothingToRevert:
      return .nothingToRevert
    case .unavailable(let reason):
      return .unavailable(reason)
    case .revert(let edit):
      let response = field.replace(
        edit.range, with: edit.replacement, caretLocation: edit.caretLocation,
        in: session.target)
      return response == .succeeded ? .reverted : .writeFailed
    }
  }

  // MARK: - 書き込み

  /// 確定済みテキスト全体を受け取り、差分を書き込む。照合に失敗したら直接の書き込みをやめる。
  private func write(_ text: String) {
    guard var session, case .writing = session.state else { return }
    defer { self.session = session }
    let focused = inspector.focusedTarget()
    // 録音開始時と同じ入力欄でも、セキュア入力などに変わったら書き込まない（7章）
    guard sensitiveReasons(focused, on: session.target).isEmpty else {
      session.stop(.interrupted)
      return
    }
    let step: RealtimeDirectStep
    do {
      step = try session.update(to: text, observation: observe(focused?.id))
    } catch {
      return
    }
    guard case .write(let edit) = step else { return }
    let response = field.replace(
      edit.range, with: edit.replacement, caretLocation: edit.caretLocation, in: session.target)
    if response != .rejectedBeforeSend {
      sentWrite = true
    }
    if response != .succeeded {
      session.stop(.writeFailed)
    }
  }

  /// 認識を終え、直接の書き込みをやめていたら確定テキスト全体をプレビューに出す（AC-09）。
  private func finish(previewText: String) {
    guard var session else { return }
    try? session.finish()
    self.session = session
    if case .stopped(let reason) = session.state, !previewText.isEmpty {
      preview.showPreview(
        text: previewText,
        cause: .realtimeDirectStopped(reason, wroteText: sentWrite))
    }
  }

  // MARK: - 判定

  /// 入力欄の状態を読む。フォーカス中の入力対象が記録した入力対象でなければ、値は読まない（照合で止まる）。
  private func observe(_ focused: InsertionTargetID?) -> RealtimeDirectFieldObservation {
    guard let focused, session.map({ $0.target == focused }) ?? true else {
      return RealtimeDirectFieldObservation(target: focused, value: nil, selectedRange: nil)
    }
    let snapshot = field.snapshot(of: focused)
    return RealtimeDirectFieldObservation(
      target: focused, value: snapshot.value,
      selectedRange: snapshot.selection.flatMap {
        UTF16TextRange(location: $0.location, length: $0.length)
      })
  }

  /// フォーカス中の入力対象が `recorded` のときの機密入力の理由。違う・特定できない入力対象は、
  /// 入力欄に触れないことが照合（入力対象の消失・変更）で決まるため、ここでは理由を返さない。
  private func sensitiveReasons(
    _ target: FocusedInsertionTarget?, on recorded: InsertionTargetID?
  ) -> Set<SensitiveInputReason> {
    guard let target, target.id == recorded else { return [] }
    let context = SensitiveInputContext(
      secureField: target.secureField,
      secureEventInput: inspector.secureEventInput(),
      app: target.app)
    return sensitivePolicy.decide(context).reasons
  }
}

extension RealtimeDirectWriter {
  /// 本番のアダプターで組み立てる。挿入と同じ `AccessibilityInsertionTarget` を渡し、録音開始時の入力対象の記録を共有する。
  ///
  /// 許可リストは `RealtimeDirectAllowlist.launchConfigured()`（#41 の判定前は空。Debug ビルドでだけ起動引数で足せる）。
  /// ターミナル系のアプリ（`KnownTerminalApps`）では使わない。
  static func system(
    target: AccessibilityInsertionTarget,
    preview: any InsertionPreviewPresenting,
    allowlist: RealtimeDirectAllowlist = .launchConfigured(),
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy()
  ) -> RealtimeDirectWriter {
    RealtimeDirectWriter(
      inspector: target, field: target, preview: preview, allowlist: allowlist,
      policy: InsertionPolicy(profiles: KnownTerminalApps.profiles),
      sensitivePolicy: sensitivePolicy)
  }
}
