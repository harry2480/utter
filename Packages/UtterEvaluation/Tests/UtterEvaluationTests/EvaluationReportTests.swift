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
    #expect(table.contains("| 日本語 | 2 | 2 | 18.8% (n=16) | - | 2 | - | 2 | 50.0% (n=2) |"))
    #expect(
      table.contains("| 日英混在 | 1 | 1 | 50.0% (n=10) | 0.0% (n=1) | 1 | 100.0% (n=1) | 0 | - |"))
    #expect(table.contains("| 騒音 | 0 | 0 | - | - | 0 | - | 0 | - |"))
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
  }

  @Test("AC-04: 評価セットは9章の6区分")
  func categories() {
    #expect(
      EvaluationCategory.allCases.map(\.displayName) == [
        "日本語", "日英混在", "開発用語", "数字", "自己訂正", "騒音",
      ])
  }
}
