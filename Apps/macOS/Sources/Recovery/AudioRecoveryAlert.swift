import AppKit

/// 起動時の復旧を尋ねる小さなダイアログ（7章, AC-10）。件数だけを出し、発話本文・日時・ファイルの場所は出さない。
@MainActor
final class AudioRecoveryAlert: AudioRecoveryPrompting {
  func confirmRecovery(count: Int) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "前回、処理を終える前に止まった録音が \(count) 件あります"
    alert.informativeText =
      "復旧すると、音声をこの Mac で認識し直し、結果をコピーできるパネルに表示します（自動では入力しません）。"
      + "復旧しない場合は、音声を削除します。"
    alert.addButton(withTitle: "復旧する")
    alert.addButton(withTitle: "削除する")
    // メニューバー常駐（Dock に出ない）のため、前面に出してから尋ねる
    NSApplication.shared.activate()
    return alert.runModal() == .alertFirstButtonReturn
  }

  func reportUnrecovered(count: Int) {
    let alert = NSAlert()
    alert.messageText = "\(count) 件の録音を復旧できませんでした"
    alert.informativeText = "音声は残しています。次に utter を起動したときに、もう一度確認します（24時間を過ぎると削除します）。"
    alert.addButton(withTitle: "OK")
    NSApplication.shared.activate()
    alert.runModal()
  }
}
