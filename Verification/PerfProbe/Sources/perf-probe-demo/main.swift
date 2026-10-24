import Foundation
import PerfProbe

// 計測パイプライン（xctrace の記録 → 書き出し → 集計、メモリ・CPU のサンプリング）が動くかを確かめるためのデモ。
// マイク・STT・LLM・挿入は一切行わない。区間の長さは乱数で作ったダミーであり、計測結果として記録してはならない。

let usage = """
  使い方:
    perf-probe-demo signposts [--iterations N] [--mode local|ai]
        6章の区間名で、ダミーの長さの Signpost 区間を N 回（既定 20）発行する
    perf-probe-demo idle [--seconds N]
        何もせず N 秒（既定 60）待機する。サンプリングスクリプトの動作確認用
  """

enum DemoMode: String {
  case local
  case ai
}

func value(of option: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
    return nil
  }
  return arguments[index + 1]
}

func exitWithUsage() -> Never {
  FileHandle.standardError.write(Data((usage + "\n").utf8))
  exit(64)
}

/// 指定範囲（ミリ秒）のダミー時間だけ待つ。
func pause(_ range: ClosedRange<Int>) async throws {
  try await Task.sleep(for: .milliseconds(Int.random(in: range)))
}

func runSignposts(iterations: Int, mode: DemoMode) async throws {
  let signposts = PerfSignposts()
  for iteration in 1...iterations {
    try await signposts.measure(.recordingStart) { try await pause(20...120) }
    try await signposts.measure(.realtimeFirstText) { try await pause(300...900) }
    // 発話の代わりの待ち時間
    try await pause(200...400)

    let total = signposts.begin(mode == .ai ? .stopToInsertAI : .stopToInsertLocal)
    try await signposts.measure(.sttFinalize) { try await pause(80...250) }
    if mode == .ai {
      let complete = signposts.begin(.llmComplete)
      try await signposts.measure(.llmFirstToken) { try await pause(150...400) }
      try await pause(100...500)
      signposts.end(complete)
    }
    try await signposts.measure(.insert) { try await pause(10...60) }
    signposts.end(total)

    print("signposts: \(iteration)/\(iterations)")
    try await pause(200...300)
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { exitWithUsage() }

switch command {
case "signposts":
  let iterations = value(of: "--iterations", in: arguments).map { Int($0) } ?? 20
  let mode = value(of: "--mode", in: arguments).map { DemoMode(rawValue: $0) } ?? .local
  guard let iterations, iterations > 0, let mode else { exitWithUsage() }
  print("ダミーの区間を発行します（計測結果として記録しないこと）: pid=\(getpid())")
  try await runSignposts(iterations: iterations, mode: mode)
case "idle":
  let seconds = value(of: "--seconds", in: arguments).map { Int($0) } ?? 60
  guard let seconds, seconds > 0 else { exitWithUsage() }
  print("待機します: pid=\(getpid()) seconds=\(seconds)")
  try await Task.sleep(for: .seconds(seconds))
default:
  exitWithUsage()
}
