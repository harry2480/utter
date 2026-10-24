import Foundation
import PerfProbe
import Testing

@testable import PerfProbeAnalysis

/// xctrace 27 の `OSSignpostIntervals` 書き出しと同じ形（id / ref / sentinel）の最小例。
private let sampleXML = """
  <?xml version="1.0"?>
  <trace-query-result>
  <node xpath='//trace-toc[1]/run[1]/data[1]/table[5]'><schema name="OSSignpostIntervals">\
  <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col>\
  <col><mnemonic>name</mnemonic></col><col><mnemonic>subsystem</mnemonic></col>\
  <col><mnemonic>process</mnemonic></col><col><mnemonic>start-message</mnemonic></col></schema>
  <row><start-time id="1" fmt="00:01.000">1000</start-time><duration id="2" fmt="75.5 ms">75500000</duration>\
  <signpost-name id="3" fmt="RecordingStart">RecordingStart</signpost-name>\
  <subsystem id="4" fmt="utter.perf">utter.perf</subsystem>\
  <process id="5" fmt="perf-probe-demo (42)"><pid id="6" fmt="42">42</pid></process><sentinel/></row>
  <row><start-time id="7" fmt="00:02.000">2000</start-time><duration ref="2"/>\
  <signpost-name ref="3"/><subsystem ref="4"/><process ref="5"/><sentinel/></row>
  <row><start-time id="8" fmt="00:03.000">3000</start-time><sentinel/>\
  <signpost-name id="9" fmt="Insert">Insert</signpost-name><subsystem ref="4"/><process ref="5"/><sentinel/></row>
  </node>
  </trace-query-result>
  """

@Suite("xctrace の書き出しの読み取り")
struct SignpostIntervalExportTests {
  @Test("ref で参照された値を解決し、未終了の区間を除く")
  func resolvesReferences() throws {
    let export = try SignpostIntervalExport(data: Data(sampleXML.utf8))
    let expected = SignpostIntervalRecord(
      name: "RecordingStart",
      subsystem: "utter.perf",
      process: "perf-probe-demo (42)",
      durationNanoseconds: 75_500_000
    )
    #expect(export.records == [expected, expected])
    #expect(export.incompleteRows == 1)
    #expect(export.records[0].durationMilliseconds == 75.5)
  }

  @Test("OSSignpostIntervals 以外の表では列不足として失敗する")
  func rejectsOtherTables() {
    let xml = """
      <?xml version="1.0"?><trace-query-result><node><schema name="tick">\
      <col><mnemonic>time</mnemonic></col></schema></node></trace-query-result>
      """
    #expect(throws: SignpostIntervalExportError.self) {
      try SignpostIntervalExport(data: Data(xml.utf8))
    }
  }

  @Test("空の書き出し（xpath の不一致）は失敗する")
  func rejectsEmptyExport() {
    let xml = "<?xml version=\"1.0\"?><trace-query-result></trace-query-result>"
    #expect(throws: SignpostIntervalExportError.self) {
      try SignpostIntervalExport(data: Data(xml.utf8))
    }
  }
}

@Suite("区間の集計")
struct IntervalStatisticsTests {
  @Test("最近傍順位法で p50 / p95 を求める")
  func nearestRankPercentiles() throws {
    let values = (1...20).map(Double.init)
    let stats = try #require(IntervalStatistics(name: "Insert", milliseconds: values.shuffled()))
    #expect(stats.count == 20)
    #expect(stats.p50 == 10)
    #expect(stats.p95 == 19)
    #expect(stats.min == 1)
    #expect(stats.max == 20)
    #expect(stats.mean == 10.5)
  }

  @Test("1件だけでも集計でき、空なら nil")
  func edgeCases() {
    #expect(IntervalStatistics(name: "Insert", milliseconds: [42])?.p95 == 42)
    #expect(IntervalStatistics(name: "Insert", milliseconds: []) == nil)
  }
}

@Suite("区間名と6章の目標")
struct PerfIntervalTests {
  @Test("Signpost の区間名は rawValue と一致する", arguments: PerfInterval.allCases)
  func signpostNameMatchesRawValue(_ interval: PerfInterval) {
    #expect(interval.signpostName.description == interval.rawValue)
  }

  @Test("6章の目標との比較")
  func chapter6Targets() throws {
    let target = try #require(PerfTarget.chapter6(for: .stopToInsertLocal))
    #expect(target.label == "p50≤300 / p95≤700")
    let fast = try #require(
      IntervalStatistics(name: "StopToInsertLocal", milliseconds: [250, 690]))
    let slow = try #require(
      IntervalStatistics(name: "StopToInsertLocal", milliseconds: [250, 701]))
    #expect(target.isMet(by: fast))
    #expect(!target.isMet(by: slow))
    #expect(PerfTarget.chapter6(for: .insert) == nil)
  }
}
