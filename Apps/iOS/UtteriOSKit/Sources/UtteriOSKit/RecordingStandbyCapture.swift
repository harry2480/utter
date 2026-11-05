import Foundation
import UtterCore
import UtterPersistence

/// 待機セッションの録音を、本体アプリの録音セッション（`RecordingSessionModel`）で行う（iOS-04, #247）。
///
/// 録音 → 音声認識 → 整形 → 共有結果の保存は、本体アプリで録音するときと同じ流れを使う。
/// 結果はキーボードが作ったセッションIDで保存し、キーボードはそのIDで結果を見つける。
///
/// 開始の合図を受けてから録音が始まるまでには、マイクの許可の確認などで待ちがある。開始と取り消しは届いた順に
/// 1つずつ行い、停止はそのセッションの開始が済むのを待ってから行う。別のセッションの開始の合図で前の録音を捨てる
/// とき（`StandbySessionMachine` は取り消し→開始の順に求める）に、取り消しより先に新しい開始が走って断られない
/// ようにするため。渡されたIDのセッションが進行中でなければ、止めない（別のセッションを止めない）。
@MainActor
public final class RecordingStandbyCapture: StandbyCapturing {
  private let model: RecordingSessionModel
  /// 開始の途中の録音。停止の前に、開始が済むのを待つ
  private var starting: [SessionID: Task<Void, Never>] = [:]
  /// 直前に受けた開始・取り消し。次の開始・取り消しはこれが済んでから行う
  private var lastOperation: Task<Void, Never>?
  /// 取り消しを受けたセッション。開始の順番が来ても録音を始めない（iOS-06）。取り消しを終えたら外す
  private var abandoned: Set<SessionID> = []
  /// 今 `startRecording` の中にいる（マイクの許可の確認などを待っている）セッション
  private var startingNow: SessionID?

  public init(model: RecordingSessionModel) {
    self.model = model
  }

  /// キーボードが作ったIDで録音を始める
  public func beginCapture(_ sessionID: SessionID) {
    let model = model
    let previous = lastOperation
    let start = Task { [weak self] in
      await previous?.value
      // 開始の順番を待つ間に取り消されていたら、キーボードが閉じた後にマイクを開かない
      guard let self, !abandoned.contains(sessionID) else { return }
      startingNow = sessionID
      await model.startRecording(sessionID: sessionID)
      if startingNow == sessionID { startingNow = nil }
    }
    starting[sessionID] = start
    lastOperation = start
  }

  /// 録音を止め、認識・整形・共有結果への保存が終わるまで待つ
  /// - Returns: 保存できたら `nil`。認識できる発話がなければ `noSpeech`、それ以外の失敗は `processingFailed`
  public func finishCapture(_ sessionID: SessionID) async -> StandbyFailure? {
    await starting.removeValue(forKey: sessionID)?.value
    if model.activeSessionID == sessionID {
      model.stopRecording()
    }
    switch await model.outcome(of: sessionID) {
    case .saved: return nil
    case .failed(.noSpeech): return .noSpeech
    case .failed, .cancelled: return .processingFailed
    }
  }

  /// 録音を止めて捨てる。認識の結果も保存しない（iOS-06）
  /// - Note: 共有結果への保存を始めた後は取り消せない（`RecordingSessionModel.cancel()` と同じ）
  public func abandonCapture(_ sessionID: SessionID) {
    starting[sessionID] = nil
    abandoned.insert(sessionID)
    // 開始の途中（マイクの許可の確認中など）なら、すぐに取り消しを伝え、許可が返っても録音を始めないようにする
    if startingNow == sessionID { model.cancel() }
    let model = model
    let previous = lastOperation
    lastOperation = Task { [weak self] in
      // このセッションの開始も、これより前に受けた操作に含まれる
      await previous?.value
      self?.abandoned.remove(sessionID)
      guard model.activeSessionID == sessionID else { return }
      model.cancel()
    }
  }
}
