import UtterSpeech
import XPC

/// メインアプリとの1つの接続。届いたメッセージを順に `STTWorkerService` へ渡し、認識イベントを送り返す。
///
/// 接続が切れたら（アプリの終了・接続の取り消し）認識を止め、モデルを解放する。
struct STTWorkerPeer: XPCPeerHandler {
  private let requests: AsyncStream<STTWorkerRequest>.Continuation

  init(session: XPCSession) {
    // XPC はメッセージを接続ごとに順に届けるため、届いた順にストリームへ積み、1つのタスクで処理する
    let (incoming, requests) = AsyncStream.makeStream(of: STTWorkerRequest.self)
    self.requests = requests
    let service = STTWorkerService(loaders: STTWorkerEngines.loaders())
    Task {
      await service.run(incoming: incoming) { response in
        // 送れないのは接続が切れたときで、そのときは handleCancellation で後始末する
        try? session.send(response)
      }
    }
  }

  func handleIncomingRequest(_ request: STTWorkerRequest) -> (any Encodable)? {
    requests.yield(request)
    return nil
  }

  func handleCancellation(error: XPCRichError) {
    requests.finish()
  }
}
