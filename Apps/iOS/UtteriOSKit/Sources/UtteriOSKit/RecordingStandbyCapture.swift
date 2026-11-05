import Foundation
import UtterCore
import UtterPersistence

/// 待機セッションの録音を、本体アプリの録音セッション（`RecordingSessionModel`）で行う（iOS-04, #247）。
///
/// 録音 → 音声認識 → 整形 → 共有結果の保存は、本体アプリで録音するときと同じ流れを使う。
/// 結果はキーボードが作ったセッションIDで保存し、キーボードはそのIDで結果を見つける。
///
/// 開始の合図を受けてから録音が始まるまでには、マイクの許可の確認などで待ちがある。停止・取り消しの合図が
/// その待ちの間に届いても落とさないよう、開始が済むのを待ってから止める。
/// 渡されたIDのセッションが進行中でなければ、止めない（別のセッションを止めない）。
@MainActor
public final class RecordingStandbyCapture: StandbyCapturing {
  private let model: RecordingSessionModel
  /// 開始の途中の録音。停止・取り消しの前に、開始が済むのを待つ
  private var starting: [SessionID: Task<Void, Never>] = [:]

  public init(model: RecordingSessionModel) {
    self.model = model
  }

  /// キーボードが作ったIDで録音を始める
  public func beginCapture(_ sessionID: SessionID) {
    let model = model
    starting[sessionID] = Task { await model.startRecording(sessionID: sessionID) }
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
    let start = starting.removeValue(forKey: sessionID)
    let model = model
    Task {
      await start?.value
      guard model.activeSessionID == sessionID else { return }
      model.cancel()
    }
  }
}
