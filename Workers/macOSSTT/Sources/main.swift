import Foundation
import UtterSpeech
import XPC

// XPC STT Worker の起動部（Composition Root, 4章 STT Worker）。
//
// メインアプリからの接続ごとに `STTWorkerService` を作り、モデルのロード・推論・解放を任せる。
// 使えるエンジンは `STTWorkerEngines.loaders()` が決める。音声・認識テキストはログに出さない。

guard let serviceName = Bundle.main.bundleIdentifier else {
  fatalError("STT Worker の Bundle ID がない")
}

let listener = try XPCListener(service: serviceName) { request in
  request.accept { session in
    STTWorkerPeer(session: session)
  }
}

dispatchMain()
