import Foundation
import Testing

@testable import UtterEvaluation

struct EvaluationCommandTests {
  private struct ReadFailure: Error {}

  private static func run(json: String) -> EvaluationCommand.Result {
    EvaluationCommand.run(arguments: ["utter-eval", "results.json"]) { _ in Data(json.utf8) }
  }

  @Test("AC-04: utter-eval はフィラー除去・自己訂正の成功率を件数つきで出力する")
  func outputsFillerAndSelfCorrection() {
    let result = Self.run(
      json: """
        [
          {"id": "ja-001", "category": "japanese", "reference": "えー、はい",
           "refinedOutput": "はい。", "fillers": ["えー"]},
          {"id": "self-001", "category": "selfCorrection", "reference": "三時、いや四時",
           "refinedOutput": "3時", "selfCorrections": [{"retracted": "三時", "corrected": "四時"}]},
          {"id": "self-002", "category": "selfCorrection", "reference": "赤、いや青",
           "refinedOutput": "青", "selfCorrections": [{"retracted": "赤", "corrected": "青"}]}
        ]
        """)

    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains("| フィラー 判定件数 | フィラー除去成功率 | 自己訂正 判定件数 | 自己訂正成功率 |"))
    #expect(
      result.standardOutput.contains(
        "| 日本語 | 1 | 0 | - | - | 1 | - | 0 | - | 1 | 100.0% (n=1) | 0 | - |"))
    #expect(
      result.standardOutput.contains(
        "| 自己訂正 | 2 | 0 | - | - | 2 | - | 0 | - | 0 | - | 2 | 50.0% (n=2) |"))
    for text in ["えー、はい", "三時、いや四時", "赤、いや青", "はい。"] {
      #expect(!result.standardOutput.contains(text))
    }
  }

  @Test("AC-04: 注釈の不備は識別子だけを示し、本文を出さない")
  func reportsAnnotationErrorWithoutText() {
    let result = Self.run(
      json: """
        [{"id": "ja-009", "category": "japanese", "reference": "はい", "fillers": ["えーと"]}]
        """)

    #expect(result.exitCode == 65)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("ja-009"))
    #expect(!result.standardError.contains("えーと"))
    #expect(!result.standardError.contains("はい"))
  }

  @Test("AC-04: 注釈の形式の誤りは位置だけを示す")
  func reportsDecodingLocation() {
    let result = Self.run(
      json: """
        [{"id": "s", "category": "selfCorrection", "reference": "赤、いや青",
          "selfCorrections": [{"retracted": "赤"}]}]
        """)

    #expect(result.exitCode == 65)
    #expect(result.standardError.contains("[0].selfCorrections[0] にキー corrected がありません"))
    #expect(!result.standardError.contains("赤"))
  }

  @Test("AC-04: 引数が違えば使い方を示す")
  func usage() {
    let result = EvaluationCommand.run(arguments: ["utter-eval"]) { _ in Data() }

    #expect(result.exitCode == 64)
    #expect(result.standardError == "使い方: utter-eval <results.json>\n")
  }

  @Test("AC-04: 読み込めなければエラーの型名だけを示す")
  func readFailure() {
    let result = EvaluationCommand.run(arguments: ["utter-eval", "x.json"]) { _ in
      throw ReadFailure()
    }

    #expect(result.exitCode == 66)
    #expect(result.standardError == "評価結果を読み込めません: ReadFailure\n")
  }
}
