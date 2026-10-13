import Testing
import UtterCore

@testable import UtterAI

struct RefinementRequestTests {
  @Test("CTX-03: 入力は STT テキスト・整形モード・スタイル区分・辞書語だけを持つ")
  func holdsOnlyAllowedContext() {
    // customMirror は手書きのため、実際の格納項目はサイズで検査する。
    // 文字列や配列などの追加は検出できるが、隙間に収まる小さな型は検出できない。
    #expect(
      MemoryLayout<RefinementRequest>.size
        == MemoryLayout<(String, RefinementMode, RefinementStyle, [String])>.size)
  }

  @Test("CTX-03: リフレクションに出す項目は許可された文脈だけ")
  func reflectsOnlyAllowedContext() {
    let request = RefinementRequest(
      text: "本文", mode: .structured, style: .technical, dictionaryTerms: ["SwiftUI"])

    let labels = Mirror(reflecting: request).children.compactMap(\.label)
    #expect(labels == ["mode", "style", "length", "dictionaryTerms"])
  }

  @Test("CTX-03: スタイル区分の既定は standard、辞書語の既定は空")
  func defaultsToStandardStyleWithoutTerms() {
    let request = RefinementRequest(text: "本文", mode: .raw)

    #expect(request.style == .standard)
    #expect(request.dictionaryTerms.isEmpty)
  }

  @Test("CTX-03: 文字列表現に発話本文と辞書語を含めない")
  func redactsTextAndTerms() {
    let request = RefinementRequest(
      text: "秘密の発話内容", mode: .natural, style: .concise, dictionaryTerms: ["社外秘プロジェクト"])
    let outputs = [
      String(describing: request),
      String(reflecting: request),
      String(describing: Mirror(reflecting: request).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の発話内容"))
      #expect(!output.contains("社外秘プロジェクト"))
    }
    #expect(String(describing: request).contains("length: 7"))
    #expect(String(describing: request).contains("dictionaryTerms: 1"))
  }

  @Test("AI-06: 応答の文字列表現に整形後の本文を含めない")
  func redactsResponseText() {
    let usage = TokenUsage(inputTokens: 3, outputTokens: 4)
    let responses = [
      RefinementResponse(text: "秘密の整形結果", usage: usage),
      RefinementResponse(text: "秘密の整形結果"),
    ]

    for response in responses {
      let outputs = [
        String(describing: response),
        String(reflecting: response),
        String(describing: Mirror(reflecting: response).children.map(\.value)),
      ]
      for output in outputs {
        #expect(!output.contains("秘密の整形結果"))
      }
      #expect(String(describing: response).contains("length: 7"))
    }
  }

  @Test("AI-06: エラーは入力テキストを関連値に持たない", arguments: AIProviderError.allCases)
  func errorDescriptionsHaveNoInput(_ error: AIProviderError) {
    // ケースは関連値を持たないため、入力テキストを含めようがないことを確認する。
    #expect(Mirror(reflecting: error).children.isEmpty)
  }

  @Test("AI-06: 失敗の種類を別々のケースとして区別する")
  func distinguishesFailureKinds() {
    #expect(
      Set(AIProviderError.allCases) == [
        .timeout, .authenticationExpired, .quotaExceeded, .budgetExceeded, .networkUnavailable,
        .invalidResponse, .cancelled,
      ])
  }
}
