import Foundation
import PerfProbe
import PerfProbeAnalysis

// xctrace export の XML（OSSignpostIntervals 表）を読み、区間ごとの p50/p95 を Markdown 表で出す。
// 出力は区間名と所要時間だけで、発話本文などは含まない（Signpost に本文を載せていないため）。

let usage = """
  使い方:
    perf-probe-summarize <OSSignpostIntervals.xml> [--subsystem utter.perf] [--process 名前] [--csv 出力.csv]
      --subsystem  集計するサブシステム（既定 utter.perf）
      --process    開始プロセス名の部分一致で絞り込む（例: utter）
      --csv        区間ごとの生の所要時間（ミリ秒）を CSV に書き出す
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var subsystem = PerfSignposts.defaultSubsystem
var processFilter: String?
var csvPath: String?
var inputPath: String?

while !arguments.isEmpty {
  let argument = arguments.removeFirst()
  switch argument {
  case "--subsystem", "--process", "--csv":
    guard !arguments.isEmpty else { fail(usage) }
    let value = arguments.removeFirst()
    if argument == "--subsystem" {
      subsystem = value
    } else if argument == "--process" {
      processFilter = value
    } else {
      csvPath = value
    }
  case "-h", "--help":
    print(usage)
    exit(0)
  default:
    guard inputPath == nil, !argument.hasPrefix("-") else { fail(usage) }
    inputPath = argument
  }
}
guard let inputPath else { fail(usage) }

let export: SignpostIntervalExport
do {
  export = try SignpostIntervalExport(data: Data(contentsOf: URL(fileURLWithPath: inputPath)))
} catch {
  fail("読み込みに失敗しました: \(error)")
}

let records = export.records.filter { record in
  record.subsystem == subsystem && (processFilter.map { record.process.contains($0) } ?? true)
}

if let csvPath {
  var csv = "name,process,duration_ms\n"
  for record in records {
    csv +=
      "\(record.name),\"\(record.process)\",\(String(format: "%.3f", record.durationMilliseconds))\n"
  }
  do {
    try csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
  } catch {
    fail("CSV の書き出しに失敗しました: \(error)")
  }
}

func ms(_ value: Double) -> String { String(format: "%.1f", value) }

print("subsystem: \(subsystem)  対象行: \(records.count)  未終了の区間: \(export.incompleteRows)")
print("")
print("| 区間 | n | min | p50 | p95 | max | mean | 6章の目標 (ms) | 目標内か |")
print("|---|---|---|---|---|---|---|---|---|")
// 6章の区間の定義順に並べ、定義にない区間名はその後ろに置く
let order = PerfInterval.allCases.map(\.rawValue)
let statistics = IntervalStatistics.summarize(records).sorted {
  (order.firstIndex(of: $0.name) ?? order.count, $0.name)
    < (order.firstIndex(of: $1.name) ?? order.count, $1.name)
}
for stats in statistics {
  let target = PerfInterval(rawValue: stats.name).flatMap(PerfTarget.chapter6(for:))
  let verdict = target.map { $0.isMet(by: stats) ? "内" : "超過" } ?? "—"
  let row = [
    stats.name, String(stats.count), ms(stats.min), ms(stats.p50), ms(stats.p95), ms(stats.max),
    ms(stats.mean), target?.label ?? "—", verdict,
  ]
  print("| " + row.joined(separator: " | ") + " |")
}
if statistics.isEmpty {
  print("（該当する区間がありません。subsystem / process の指定と、記録時の instrument を確認してください）")
}
if statistics.contains(where: { $0.count < 20 }) {
  print("")
  print("注: n < 20 の区間は p95 が最大値と同じになります（最近傍順位法）。")
}
