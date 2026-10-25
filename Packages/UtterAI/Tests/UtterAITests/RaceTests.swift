import Testing

@testable import UtterAI

struct RaceTests {
  @Test("AC-16: 待ち始める前に結果が決まっていたら、その結果ですぐに再開する")
  func resumesImmediatelyWhenFinishedBeforeInstall() async {
    let race = Race<RefinementResponse>()
    race.finish(.failure(.cancelled))

    let result = await withCheckedContinuation { continuation in
      race.install(continuation)
    }

    #expect(result == .failure(.cancelled))
  }

  @Test("AC-16: 結果が決まった後に追加した Task はすぐにキャンセルする", .timeLimit(.minutes(1)))
  func cancelsTaskAddedAfterFinish() async {
    let race = Race<RefinementResponse>()
    race.finish(.failure(.timeout))
    let task = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(60))
    }

    race.add(task)
    await task.value

    #expect(task.isCancelled)
  }

  @Test("AC-16: 最初の結果だけを採用し、後から届いた結果は無視する")
  func keepsFirstResult() async {
    let race = Race<RefinementResponse>()

    let result = await withCheckedContinuation { continuation in
      race.install(continuation)
      race.finish(.failure(.timeout))
      race.finish(.success(RefinementResponse(text: "遅れた応答")))
    }

    #expect(result == .failure(.timeout))
  }
}
