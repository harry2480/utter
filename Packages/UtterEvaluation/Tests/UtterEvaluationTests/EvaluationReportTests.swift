import Foundation
import Testing

@testable import UtterEvaluation

struct EvaluationReportTests {
  private static let samples = [
    EvaluationSample(
      id: "ja-001", category: .japanese, reference: "明日は三時に集合です。",
      sttOutput: "明日は3時に集合です", refinedOutput: "明日は3時に集合です。", meaningChanges: []),
    EvaluationSample(
      id: "ja-002", category: .japanese, reference: "雨は降らない",
      sttOutput: "雨は降る", refinedOutput: "雨は降る。", meaningChanges: [.negationFlipped]),
    EvaluationSample(
      id: "mix-001", category: .mixedJapaneseEnglish, reference: "SwiftUI で書く",
      terms: ["SwiftUI"], sttOutput: "スイフトUI で書く", refinedOutput: "SwiftUI で書く。"),
    EvaluationSample(id: "num-001", category: .numbers, reference: "二〇二六年"),
  ]

  @Test("AC-04: 区分ごとに件数と結果を集計する")
  func summarizesByCategory() throws {
    let report = try EvaluationReport(samples: Self.samples)
    let japanese = try #require(report.categories[.japanese])
    let mixed = try #require(report.categories[.mixedJapaneseEnglish])
    let numbers = try #require(report.categories[.numbers])

    #expect(japanese.sampleCount == 2)
    #expect(japanese.sttCount == 2)
    // 「雨は降らない」(6) → 「雨は降る」: 「ら」の置換と「な」「い」の削除で 3
    #expect(japanese.sttCharacterErrors == ErrorCount(errors: 3, total: 16))
    #expect(japanese.meaningChanges == ErrorCount(errors: 1, total: 2))
    #expect(mixed.sttTermErrors == ErrorCount(errors: 1, total: 1))
    #expect(mixed.refinedTermErrors == ErrorCount(errors: 0, total: 1))
    #expect(mixed.meaningChanges == .zero)
    #expect(numbers.sampleCount == 1)
    #expect(numbers.sttCount == 0)
    #expect(report.categories[.noisy] == EvaluationSummary())
    #expect(report.categories.count == EvaluationCategory.allCases.count)
  }

  @Test("AC-04: 合計は全区分を合算する")
  func summarizesOverall() throws {
    let overall = try EvaluationReport(samples: Self.samples).overall

    #expect(overall.sampleCount == 4)
    #expect(overall.sttCount == 3)
    #expect(overall.refinedCount == 3)
    #expect(overall.meaningChanges == ErrorCount(errors: 1, total: 2))
  }

  @Test("AC-04: 表は全区分と合計の件数と結果を出す")
  func markdownTableHasCounts() throws {
    let table = try EvaluationReport(samples: Self.samples).markdownTable()
    let lines = table.split(separator: "\n")

    #expect(lines.count == 2 + EvaluationCategory.allCases.count + 1)
    #expect(
      table.contains("| 日本語 | 2 | 2 | 18.8% (n=16) | - | 2 | - | 2 | 50.0% (n=2) | 0 | - | 0 | - |")
    )
    #expect(
      table.contains(
        "| 日英混在 | 1 | 1 | 50.0% (n=10) | 0.0% (n=1) | 1 | 100.0% (n=1) | 0 | - | 0 | - | 0 | - |"))
    #expect(table.contains("| 騒音 | 0 | 0 | - | - | 0 | - | 0 | - | 0 | - | 0 | - |"))
    #expect(table.contains("| 合計 | 4 | 3 |"))
  }

  @Test("AC-04: 表に発話本文を含めない")
  func markdownTableHasNoText() throws {
    let table = try EvaluationReport(samples: Self.samples).markdownTable()
    let texts = Self.samples.flatMap {
      [$0.reference, $0.sttOutput, $0.refinedOutput].compactMap(\.self)
    }

    for text in texts {
      #expect(!table.contains(text))
    }
  }

  @Test(
    "AC-04: 百分率は小数第1位で四捨五入する",
    arguments: [
      (ErrorCount(errors: 1, total: 3), "33.3% (n=3)"),
      (ErrorCount(errors: 1, total: 80), "1.3% (n=80)"),
      (ErrorCount(errors: 5, total: 2), "250.0% (n=2)"),
      (ErrorCount(errors: 0, total: 5), "0.0% (n=5)"),
    ])
  func formatsPercent(_ count: ErrorCount, _ expected: String) {
    #expect(EvaluationReport.percent(count.errorRate, of: count) == expected)
  }

  @Test("AC-04: 負の値も小数第1位で表す")
  func formatsNegativePercent() {
    #expect(EvaluationReport.percent(-0.05, of: .zero) == "-5.0% (n=0)")
    #expect(EvaluationReport.percent(-0.0004, of: .zero) == "0.0% (n=0)")
  }

  @Test("AC-04: 値がなければ「-」を出す")
  func formatsMissingPercent() {
    #expect(EvaluationReport.percent(nil, of: .zero) == "-")
  }

  @Test(
    "AC-04: 評価セットの不備を識別子つきで拒否する",
    arguments: [
      (
        [
          EvaluationSample(id: "a", category: .japanese, reference: "はい"),
          EvaluationSample(id: "a", category: .japanese, reference: "いいえ"),
        ], EvaluationSampleError.duplicateID("a")
      ),
      ([EvaluationSample(id: "b", category: .japanese, reference: "。")], .emptyReference(id: "b")),
      (
        [
          EvaluationSample(
            id: "c", category: .developerTerms, reference: "swiftui", terms: ["SwiftUI"])
        ],
        .termNotInReference(id: "c")
      ),
      (
        [EvaluationSample(id: "d", category: .japanese, reference: "はい", meaningChanges: [])],
        .meaningChangesWithoutRefinedOutput(id: "d")
      ),
      (
        [EvaluationSample(id: "e", category: .japanese, reference: "はい", fillers: ["えー"])],
        .fillerNotInReference(id: "e")
      ),
      (
        // 正解に1回しかないフィラーを2回注釈している
        [
          EvaluationSample(
            id: "f", category: .japanese, reference: "えー、はい", fillers: ["えー", "えー"])
        ],
        .fillerNotInReference(id: "f")
      ),
      (
        // 正規化すると空になるフィラー
        [EvaluationSample(id: "g", category: .japanese, reference: "えー、はい", fillers: ["、"])],
        .fillerNotInReference(id: "g")
      ),
      (
        [
          EvaluationSample(
            id: "h", category: .selfCorrection, reference: "赤、いや青",
            selfCorrections: [SelfCorrection(retracted: "黄", corrected: "青")])
        ],
        .selfCorrectionNotInReference(id: "h")
      ),
      (
        [
          EvaluationSample(
            id: "i", category: .selfCorrection, reference: "赤、いや青",
            selfCorrections: [SelfCorrection(retracted: "赤", corrected: "緑")])
        ],
        .selfCorrectionNotInReference(id: "i")
      ),
      (
        [
          EvaluationSample(
            id: "j", category: .selfCorrection, reference: "三時、いや3時",
            selfCorrections: [SelfCorrection(retracted: "三時", corrected: "3時")])
        ],
        .selfCorrectionUnchanged(id: "j")
      ),
    ])
  func rejectsInvalidSamples(_ samples: [EvaluationSample], _ expected: EvaluationSampleError) {
    #expect(throws: expected) {
      try EvaluationReport(samples: samples)
    }
  }

  @Test("AC-04: 評価結果を JSON から読み込める")
  func decodesJSON() throws {
    let json = """
      [
        {"id": "ja-001", "category": "japanese", "reference": "はい", "sttOutput": "はい"},
        {"id": "dev-001", "category": "developerTerms", "reference": "Git", "terms": ["Git"],
         "refinedOutput": "Git", "meaningChanges": ["contentAdded"]}
      ]
      """
    let samples = try JSONDecoder().decode([EvaluationSample].self, from: Data(json.utf8))

    #expect(samples.count == 2)
    #expect(samples[0].terms == nil)
    #expect(samples[1].meaningChanges == [.contentAdded])
  }

  @Test("AC-04: 記入例の JSON は読み込めて不備がない")
  func exampleResultsAreValid() throws {
    // Tests/UtterEvaluationTests/ から リポジトリ直下の eval/ へ
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("eval/results.example.json")
    let samples = try JSONDecoder().decode([EvaluationSample].self, from: Data(contentsOf: url))
    let report = try EvaluationReport(samples: samples)
    let developerTerms = try #require(report.categories[.developerTerms])

    #expect(report.overall.sampleCount == 3)
    #expect(developerTerms.sttCharacterErrors == ErrorCount(errors: 9, total: 26))
    #expect(developerTerms.sttTermErrors == ErrorCount(errors: 2, total: 3))
    #expect(report.overall.meaningChanges == ErrorCount(errors: 1, total: 3))
    #expect(report.categories[.japanese]?.fillerRemovals == ErrorCount(errors: 0, total: 1))
    #expect(report.categories[.selfCorrection]?.selfCorrections == ErrorCount(errors: 1, total: 1))
  }

  private static let annotatedSamples = [
    EvaluationSample(
      id: "ja-001", category: .japanese, reference: "えー、明日は三時に集合です",
      refinedOutput: "明日は3時に集合です。", fillers: ["えー"]),
    EvaluationSample(
      id: "ja-002", category: .japanese, reference: "あのー、えーと、雨です",
      refinedOutput: "えーと、雨です。", fillers: ["あのー", "えーと"]),
    // 整形結果がない発話は、注釈があっても分母に入れない
    EvaluationSample(
      id: "ja-003", category: .japanese, reference: "えー、晴れです", sttOutput: "えー晴れです",
      fillers: ["えー"]),
    // 注釈がない発話は分母に入れない（空の注釈も同じ）
    EvaluationSample(
      id: "ja-004", category: .japanese, reference: "えー、曇りです", refinedOutput: "えー曇りです",
      fillers: [], selfCorrections: []),
    EvaluationSample(
      id: "self-001", category: .selfCorrection, reference: "えー、会議は三時、いや四時からです",
      refinedOutput: "会議は4時からです。", fillers: ["えー"],
      selfCorrections: [SelfCorrection(retracted: "三時", corrected: "四時")]),
    EvaluationSample(
      id: "self-002", category: .selfCorrection, reference: "赤、じゃなくて青、いや緑",
      refinedOutput: "青、緑",
      selfCorrections: [
        SelfCorrection(retracted: "赤", corrected: "青"),
        SelfCorrection(retracted: "青", corrected: "緑"),
      ]),
  ]

  @Test("AC-04: フィラー除去・自己訂正は注釈と整形結果がある発話だけを区分ごとに数える")
  func summarizesFillerAndSelfCorrection() throws {
    let report = try EvaluationReport(samples: Self.annotatedSamples)
    let japanese = try #require(report.categories[.japanese])
    let selfCorrection = try #require(report.categories[.selfCorrection])

    #expect(japanese.sampleCount == 4)
    #expect(japanese.fillerRemovals == ErrorCount(errors: 1, total: 2))
    #expect(japanese.selfCorrections == .zero)
    #expect(selfCorrection.fillerRemovals == ErrorCount(errors: 0, total: 1))
    // self-002 は「青」をさらに言い直したのに残っているため失敗
    #expect(selfCorrection.selfCorrections == ErrorCount(errors: 1, total: 2))
    #expect(report.overall.fillerRemovals == ErrorCount(errors: 1, total: 3))
    #expect(report.overall.selfCorrections == ErrorCount(errors: 1, total: 2))
  }

  @Test("AC-04: 表にフィラー除去・自己訂正の判定件数と成功率を出し、本文を含めない")
  func markdownTableHasFillerAndSelfCorrection() throws {
    let table = try EvaluationReport(samples: Self.annotatedSamples).markdownTable()

    #expect(
      table.contains("| 日本語 | 4 | 1 | 0.0% (n=6) | - | 3 | - | 0 | - | 2 | 50.0% (n=2) | 0 | - |"))
    #expect(
      table.contains(
        "| 自己訂正 | 2 | 0 | - | - | 2 | - | 0 | - | 1 | 100.0% (n=1) | 2 | 50.0% (n=2) |"))
    #expect(
      table.contains(
        "| 合計 | 6 | 1 | 0.0% (n=6) | - | 5 | - | 0 | - | 3 | 66.7% (n=3) | 2 | 50.0% (n=2) |"))
    let annotations = Self.annotatedSamples.flatMap {
      ($0.fillers ?? []) + ($0.selfCorrections ?? []).flatMap { [$0.retracted, $0.corrected] }
    }
    for text in annotations where text.count > 1 {
      #expect(!table.contains(text))
    }
  }

  @Test("AC-04: 注釈のない従来の JSON はそのまま読め、書き出しても注釈のキーを足さない")
  func annotationsAreBackwardCompatible() throws {
    let json = """
      [{"id": "ja-001", "category": "japanese", "reference": "はい", "refinedOutput": "はい"}]
      """
    let samples = try JSONDecoder().decode([EvaluationSample].self, from: Data(json.utf8))
    let encoded = try JSONEncoder().encode(samples)
    let object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

    #expect(samples[0].fillers == nil)
    #expect(samples[0].selfCorrections == nil)
    #expect(object[0]["fillers"] == nil)
    #expect(object[0]["selfCorrections"] == nil)
    #expect(try EvaluationReport(samples: samples).overall.fillerRemovals == .zero)
  }

  @Test("AC-04: フィラー・自己訂正の注釈を JSON から読み込める")
  func decodesAnnotations() throws {
    let json = """
      [{"id": "self-001", "category": "selfCorrection", "reference": "えー、三時、いや四時",
        "fillers": ["えー"], "selfCorrections": [{"retracted": "三時", "corrected": "四時"}]}]
      """
    let samples = try JSONDecoder().decode([EvaluationSample].self, from: Data(json.utf8))

    #expect(samples[0].fillers == ["えー"])
    #expect(samples[0].selfCorrections == [SelfCorrection(retracted: "三時", corrected: "四時")])
    #expect(
      try JSONDecoder().decode([EvaluationSample].self, from: JSONEncoder().encode(samples))
        == samples)
  }

  @Test("AC-04: 評価セットは9章の6区分")
  func categories() {
    #expect(
      EvaluationCategory.allCases.map(\.displayName) == [
        "日本語", "日英混在", "開発用語", "数字", "自己訂正", "騒音",
      ])
  }
}
