import Foundation
import UtterEvaluation

// 評価結果の JSON（EvaluationSample の配列）を読み、区分ごとの件数と結果を Markdown で出力する。
// 使い方: swift run --package-path Packages/UtterEvaluation utter-eval <results.json>
// 処理は EvaluationCommand にあり、ここでは結果を書き出すだけ。

let result = EvaluationCommand.run(arguments: CommandLine.arguments)
// check-logging: allow 本文を含む評価結果を読むが、標準出力には集計表だけを出す
print(result.standardOutput, terminator: "")
// check-logging: allow 固定の文言と、識別子・記入ミスの位置・エラーの型名だけを出す
FileHandle.standardError.write(Data(result.standardError.utf8))
exit(result.exitCode)
