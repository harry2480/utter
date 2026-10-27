import Testing
import UtterAI

/// 計測区間の名前・区間の記録・整形の送信の計測（6章, #52）。
@MainActor
struct PerfIntervalTests {
  @Test("#52: 区間名は Verification/PerfProbe の PerfInterval と同じ文字列で、Signpost にもその名前を渡す")
  func namesMatchPerfProbe() {
    // Verification/PerfProbe/Sources/PerfProbe/PerfInterval.swift の rawValue（宣言順）
    let perfProbeNames = [
      "RecordingStart", "RealtimeFirstText", "STTFinalize", "LLMFirstToken", "LLMComplete",
      "Insert", "StopToInsertLocal", "StopToInsertAI", "ModelLoad",
    ]
    #expect(PerfInterval.allCases.map(\.rawValue) == perfProbeNames)
    for interval in PerfInterval.allCases {
      #expect(String(describing: interval.signpostName) == interval.rawValue)
    }
    // PerfProbe の PerfSignposts.defaultSubsystem（集計スクリプトが絞り込む値）
    #expect(SignpostPerfIntervals.subsystem == "utter.perf")
  }

  @Test("#52: Signpost の計測器は始めた区間を終えられ、同じ値で2回終えても何もしない")
  func signpostIntervalsEndOnce() {
    let signposts = SignpostPerfIntervals()
    let first = signposts.begin(.insert)
    let second = signposts.begin(.insert)
    // 同じ区間名でも開始ごとに別の値を返す
    #expect(first != second)
    signposts.end(second)
    signposts.end(first)
    signposts.end(first)
  }

  @Test("#52: セッションの区間は区間名ごとに1つだけ開き、閉じ忘れを endAll で宣言順に閉じる")
  func sessionIntervalsCloseRemaining() {
    let measurer = RecordingPerfIntervals()
    let intervals = SessionPerfIntervals(measurer: measurer)

    intervals.begin(.stopToInsertLocal)
    intervals.begin(.recordingStart)
    // 開いている区間は始め直さない
    intervals.begin(.recordingStart)
    intervals.end(.recordingStart)
    // 開いていない区間は終えない
    intervals.end(.recordingStart)
    intervals.end(.insert)
    intervals.begin(.sttFinalize)
    intervals.endAll()

    #expect(
      measurer.events == [
        .begin(.stopToInsertLocal), .begin(.recordingStart), .end(.recordingStart),
        .begin(.sttFinalize), .end(.sttFinalize), .end(.stopToInsertLocal),
      ])
    #expect(measurer.openIntervals.isEmpty)
    #expect(measurer.duplicateEnds == 0)
  }

  @Test("#52: 計測器がなければ何も記録しない")
  func sessionIntervalsWithoutMeasurer() {
    let intervals = SessionPerfIntervals(measurer: nil)
    intervals.begin(.recordingStart)
    intervals.end(.recordingStart)
    intervals.endAll()
  }

  @Test("#52: 整形の送信は LLMComplete の区間で測り、応答を変えずに返す")
  func measuresProviderRefine() async throws {
    let measurer = RecordingPerfIntervals()
    let base = StubAIProvider(behavior: .respond("整形済み"))
    let provider = PerfMeasuredAIProvider(base: base, measurer: measurer)

    let response = try await provider.refine(RefinementRequest(text: "せいけい", mode: .natural))

    #expect(response.text == "整形済み")
    #expect(provider.destination == base.destination)
    #expect(provider.isTokenBilled == base.isTokenBilled)
    #expect(measurer.events == [.begin(.llmComplete), .end(.llmComplete)])
    #expect(await base.callCount == 1)
  }

  @Test("#52: 整形の送信が失敗しても LLMComplete の区間を閉じ、失敗をそのまま投げる")
  func closesProviderIntervalOnFailure() async {
    let measurer = RecordingPerfIntervals()
    let provider = PerfMeasuredAIProvider(
      base: StubAIProvider(behavior: .fail(.timeout)), measurer: measurer)

    await #expect(throws: AIProviderError.timeout) {
      try await provider.refine(RefinementRequest(text: "せいけい", mode: .natural))
    }

    #expect(measurer.events == [.begin(.llmComplete), .end(.llmComplete)])
    #expect(measurer.openIntervals.isEmpty)
  }
}
