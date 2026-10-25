import Foundation
import Synchronization
import Testing

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// 受信量の上限で読むのをやめたあと、通信が止まることの確認。
/// 通信の Task は開始（resume）しないか、`URLProtocol` の Stub で応答するため、ネットワークに出ない
struct URLSessionStreamingTransportTests {
  private func unstartedTask() -> URLSessionTask {
    URLSession(configuration: .ephemeral).dataTask(
      with: URL(string: "https://api.openai.com/v1/responses")!)
  }

  @Test("4.1節: 受け取った通信の Task を取り消せる")
  func cancelsCapturedTask() {
    let task = unstartedTask()
    let box = DataTaskBox()

    box.set(task)
    box.cancel()

    #expect(task.state == .canceling || task.state == .completed)
  }

  @Test("4.1節: Task を受け取る前に取り消されていたら、受け取った時点で止める")
  func cancelsTaskSetAfterCancellation() {
    let task = unstartedTask()
    let box = DataTaskBox()

    box.cancel()
    box.set(task)

    #expect(task.state == .canceling || task.state == .completed)
  }

  @Test("4.1節: バイト列の最後の参照が消えたら通信を止める")
  func cancellerCancelsOnDeinit() {
    let task = unstartedTask()
    let box = DataTaskBox()
    box.set(task)
    var canceller: DataTaskCanceller? = DataTaskCanceller(box: box)
    #expect(task.state == .suspended)
    #expect(canceller != nil)

    canceller = nil

    #expect(task.state == .canceling || task.state == .completed)
  }

  @Test("4.1節: delegate は作られた Task を受け取る")
  func delegateCapturesTask() {
    let task = unstartedTask()
    let box = DataTaskBox()
    let session = URLSession(configuration: .ephemeral)

    TaskCapturingDelegate(box: box).urlSession(session, didCreateTask: task)
    box.cancel()

    #expect(task.state == .canceling || task.state == .completed)
  }

  @Test("AC-06: delegate はリダイレクトに従わず、別のホストへ送らない")
  func delegateRefusesRedirection() async {
    let task = unstartedTask()
    let session = URLSession(configuration: .ephemeral)
    let response = HTTPURLResponse(
      url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 307,
      httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/v1/responses"])!

    let next = await TaskCapturingDelegate(box: DataTaskBox()).urlSession(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://example.com/v1/responses")!))

    #expect(next == nil)
  }

  @Test("4.1節: URLSession の本文を受信しながら読み、整形結果を返す", .timeLimit(.minutes(1)))
  func readsStreamThroughURLSession() async throws {
    let provider = OpenAIProvider(
      apiKey: "k", configuration: try .init(model: "m"),
      transport: URLSessionStreamingTransport(session: StubURLProtocol.session(.finite)))

    let response = try await provider.refine(
      RefinementRequest(text: "明日の会議", mode: .natural))

    #expect(response.text == "明日の会議。")
  }

  @Test("4.1節: 文字数の上限で読むのをやめたら、URLSession の通信を止める", .timeLimit(.minutes(1)))
  func stopsURLSessionWhenLimitExceeded() async throws {
    let provider = OpenAIProvider(
      apiKey: "k",
      configuration: try .init(model: "m", minimumOutputLengthLimit: 10),
      transport: URLSessionStreamingTransport(session: StubURLProtocol.session(.endless)))

    let response = try await provider.refine(RefinementRequest(text: "明日", mode: .natural))

    #expect(response.text.isEmpty)
    // 終わりを知らせない Stub は、通信が止められるまで終わらない
    await StubURLProtocol.waitUntilStopped()
  }
}

/// SSE の本文を返す `URLProtocol`。ネットワークに出ない
final class StubURLProtocol: URLProtocol {
  enum Mode: String {
    case finite
    case endless
  }

  private static let stopped = Mutex<[CheckedContinuation<Void, Never>]?>([])

  static func session(_ mode: Mode) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Stub-Mode": mode.rawValue]
    return URLSession(configuration: configuration)
  }

  /// `.endless`（終わりを知らせない本文）の通信が止められるまで待つ
  static func waitUntilStopped() async {
    await withCheckedContinuation { continuation in
      let isStopped = stopped.withLock { waiters in
        guard waiters != nil else { return true }
        waiters?.append(continuation)
        return false
      }
      if isStopped {
        continuation.resume()
      }
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private var isEndless: Bool {
    request.value(forHTTPHeaderField: "X-Stub-Mode") == Mode.endless.rawValue
  }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let delta = #"{"type":"response.output_text.delta","delta":"あいうえお"}"#
    if isEndless {
      // 上限を超える本文を送り、終わりを知らせずに止められるのを待つ
      let chunk = "data: \(delta)\n\n"
      client?.urlProtocol(self, didLoad: Data(String(repeating: chunk, count: 100).utf8))
      return
    }
    let body = """
      data: {"type":"response.output_text.delta","delta":"明日の会議。"}

      data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}

      """
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    guard isEndless else { return }
    let waiters = Self.stopped.withLock { waiters in
      defer { waiters = nil }
      return waiters ?? []
    }
    for waiter in waiters {
      waiter.resume()
    }
  }
}
