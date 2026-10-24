import Synchronization

/// STT Worker の中で、エンジンのモデルをロードして認識器を作る（4章 STT Worker）。
///
/// SpeechAnalyzer / WhisperKit の各アダプターがこれに準拠し、STT Worker の起動部で `STTWorkerService` に登録する。
/// 返した認識器の参照を手放すことをモデルの解放とみなすため、認識器は解放されたときにモデルの資源を手放す。
public protocol SpeechModelLoader: Sendable {
  /// モデルの負荷の区分。メモリ圧迫時に高負荷モデルのロードを抑止する判定（AC-11）に使う
  var weight: ModelWeight { get }

  /// モデルをロードし、そのモデルで認識する認識器を返す
  func load() async throws(SpeechRecognitionError) -> any SpeechRecognizer
}

/// `StubSpeechRecognizer` を返すテスト・開発用のローダー。
///
/// ロードの回数を数え、保持ポリシーに従ってモデルを解放・再ロードしたかを確かめられる。
public final class StubSpeechModelLoader: SpeechModelLoader {
  public let weight: ModelWeight
  private let result: Result<StubSpeechRecognizer, SpeechRecognitionError>
  private let count = Mutex(0)

  /// - Parameters:
  ///   - steps: ロードした認識器が流す手順（`StubSpeechRecognizer.Step`）
  ///   - failure: 指定するとロードがこの失敗を投げる
  public init(
    weight: ModelWeight = .light,
    steps: [StubSpeechRecognizer.Step],
    failure: SpeechRecognitionError? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.weight = weight
    if let failure {
      result = .failure(failure)
    } else {
      result = .success(StubSpeechRecognizer(steps: steps, sleep: sleep))
    }
  }

  /// `load()` が呼ばれた回数
  public var loadCount: Int {
    count.withLock { $0 }
  }

  public func load() async throws(SpeechRecognitionError) -> any SpeechRecognizer {
    count.withLock { $0 += 1 }
    return try result.get()
  }
}
