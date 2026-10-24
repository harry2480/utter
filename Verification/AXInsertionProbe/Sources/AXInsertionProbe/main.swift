import Foundation

// Phase 0 検証（#41）: フォーカス中の入力欄へ固定のダミー文字列を挿入し、経路ごとの成否を記録する。
// 手順は README.md と docs/Phase0検証-Accessibility挿入成功率.md を参照。

let command: Command
do {
  command = try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  print("\(error)\n")
  print(ArgumentParser.usage)
  exit(2)
}

switch command {
case .help:
  print(ArgumentParser.usage)
case .check(let prompt):
  exit(Probe.check(prompt: prompt))
case .inspect(let delay):
  exit(Probe.inspect(delay: delay))
case .run(let options):
  exit(Probe.run(options))
}
