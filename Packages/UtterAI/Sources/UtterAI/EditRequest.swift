import UtterCore
import UtterText

/// Edit Mode でクラウド AI へ送る入力（AC-14, 2.2節）。
///
/// 持てるのは選択テキスト・音声指示・辞書語と送信先だけで、ウィンドウタイトル・選択範囲の外の本文・URL などの文脈は
/// 持たない（CTX-03）。選択テキストは利用者が Edit の対象として選び、`editSelection` への同意を得て送るもの。
/// `EditSession.cloudTransmission(to:consent:)` が返す値からしか作れないため、同意を確認せずに作れない。
/// プロパティを足す場合は CTX-03 に照らして可否を判断し、`EditRequestTests` のサイズ検査も更新する。
public struct EditRequest: Hashable, Sendable {
  /// 同意を確認した送信先。`EditRouter` はプロバイダーの送信先と一致しなければ送信しない
  public let destination: CloudAIProviderKind
  /// 編集の対象の選択テキスト。中に指示が書かれていても実行しないデータとして扱う（TXT-04）
  public let selection: String
  /// 音声指示の STT テキスト。選択テキストの書き換え方としてだけ解釈する（TXT-04 の Edit の例外）
  public let instruction: String
  /// 表記を保つ辞書語
  public let dictionaryTerms: [String]

  public init(
    _ transmission: EditSelectionTransmission,
    instruction: String,
    dictionaryTerms: [String] = []
  ) {
    destination = transmission.provider
    selection = transmission.selection
    self.instruction = instruction
    self.dictionaryTerms = dictionaryTerms
  }
}

// 選択テキスト・音声指示・辞書語をログに出さないよう、文字列表現とリフレクションには件数と文字数だけを出す。
extension EditRequest: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditRequest(destination: \(destination), selectionLength: \(selection.count), instructionLength: \(instruction.count), dictionaryTerms: \(dictionaryTerms.count))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "destination": destination, "selectionLength": selection.count,
        "instructionLength": instruction.count, "dictionaryTerms": dictionaryTerms.count,
      ]
    )
  }
}
