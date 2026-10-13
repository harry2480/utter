import Foundation
import UtterEvaluation

// 評価結果の JSON（EvaluationSample の配列）を読み、区分ごとの件数と結果を Markdown で出力する。
// 使い方: swift run --package-path Packages/UtterEvaluation utter-eval <results.json>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("使い方: utter-eval <results.json>\n".utf8))
  exit(64)
}

do {
  let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
  let samples = try JSONDecoder().decode([EvaluationSample].self, from: data)
  let report = try EvaluationReport(samples: samples)
  print(report.markdownTable(), terminator: "")
} catch let error as EvaluationSampleError {
  // 発話本文は出さず、識別子だけを示す。
  FileHandle.standardError.write(Data("評価セットに不備があります: \(error)\n".utf8))
  exit(65)
} catch {
  FileHandle.standardError.write(Data("評価結果を読み込めません: \(type(of: error))\n".utf8))
  exit(66)
}
