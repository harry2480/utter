import Foundation
import UtterEvaluation

// 評価結果の JSON（EvaluationSample の配列）を読み、区分ごとの件数と結果を Markdown で出力する。
// 使い方: swift run --package-path Packages/UtterEvaluation utter-eval <results.json>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  // check-logging: allow 使い方の固定の文言だけを出す
  FileHandle.standardError.write(Data("使い方: utter-eval <results.json>\n".utf8))
  exit(64)
}

do {
  let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
  let samples = try JSONDecoder().decode([EvaluationSample].self, from: data)
  let report = try EvaluationReport(samples: samples)
  // check-logging: allow 本文を含む評価結果を読むが、標準出力には集計表だけを出す
  print(report.markdownTable(), terminator: "")
} catch let error as EvaluationSampleError {
  // 発話本文は出さず、識別子だけを示す。check-logging: allow
  FileHandle.standardError.write(Data("評価セットに不備があります: \(error)\n".utf8))
  exit(65)
} catch let error as DecodingError {
  // 値は出さず、記入ミスの位置（配列の番号とキー）だけを示す。check-logging: allow
  FileHandle.standardError.write(Data("評価結果の形式が正しくありません: \(location(of: error))\n".utf8))
  exit(65)
} catch {
  // check-logging: allow エラーの型名だけを出す
  FileHandle.standardError.write(Data("評価結果を読み込めません: \(type(of: error))\n".utf8))
  exit(66)
}

func location(of error: DecodingError) -> String {
  let path: [any CodingKey]
  switch error {
  case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
    .dataCorrupted(let context):
    path = context.codingPath
  @unknown default:
    path = []
  }
  let keys = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
  if case .keyNotFound(let key, _) = error {
    return keys + " にキー \(key.stringValue) がありません"
  }
  return keys.isEmpty ? "ルート" : keys
}
