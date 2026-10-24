import Testing
import UtterCore
import UtterText

@testable import UtterAI

struct EditRequestTests {
  @Test("CTX-03: Edit の入力は送信先・選択テキスト・音声指示・辞書語だけを持つ")
  func holdsOnlyAllowedContext() {
    // customMirror は手書きのため、実際の格納項目はサイズで検査する。
    #expect(
      MemoryLayout<EditRequest>.size
        == MemoryLayout<(CloudAIProviderKind, String, String, [String])>.size)
  }

  @Test("AC-14: 同意を確認した送信内容から、選択テキストと送信先を受け取る")
  func takesSelectionFromTransmission() throws {
    let request = try EditRequest.make(
      selection: "選択した文", instruction: "短くして", dictionaryTerms: ["SwiftUI"],
      destination: .chatGPT)

    #expect(request.destination == .chatGPT)
    #expect(request.selection == "選択した文")
    #expect(request.instruction == "短くして")
    #expect(request.dictionaryTerms == ["SwiftUI"])
  }

  @Test("AC-14: 文字列表現とリフレクションに選択テキスト・音声指示・辞書語を含めない")
  func redactsContent() throws {
    let request = try EditRequest.make(
      selection: "秘密の選択テキスト", instruction: "秘密の音声指示", dictionaryTerms: ["社外秘プロジェクト"])
    let outputs = [
      String(describing: request),
      String(reflecting: request),
      String(describing: Mirror(reflecting: request).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の選択テキスト"))
      #expect(!output.contains("秘密の音声指示"))
      #expect(!output.contains("社外秘プロジェクト"))
    }
    #expect(String(describing: request).contains("selectionLength: 9"))
    #expect(
      Mirror(reflecting: request).children.compactMap(\.label) == [
        "destination", "selectionLength", "instructionLength", "dictionaryTerms",
      ])
  }

  @Test("AC-14: 結果の文字列表現に編集案を含めない")
  func redactsOutcome() {
    let outcome = EditOutcome(
      content: .proposal("秘密の編集案"), usage: TokenUsage(inputTokens: 1, outputTokens: 2))
    let outputs = [
      String(describing: outcome),
      String(reflecting: outcome),
      String(describing: Mirror(reflecting: outcome).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の編集案"))
    }
    #expect(String(describing: outcome).contains("length: 6"))
  }

  @Test("AC-14: 編集できなかった結果の文字列表現は理由だけを出す")
  func describesFailureWithoutContent() {
    let outcome = EditOutcome(content: .notEdited(.validationFailed(.unchanged)))

    let description = String(describing: outcome)
    #expect(description.contains("notEdited("))
    #expect(description.contains("unchanged"))
  }
}
