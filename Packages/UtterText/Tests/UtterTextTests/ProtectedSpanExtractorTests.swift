import Testing

@testable import UtterText

struct ProtectedSpanExtractorTests {
  @Test(
    "TXT-02: 日本語の文から数字を抽出する",
    arguments: [
      ("会議は3時から15分間です", ["3", "15"]),
      ("全角の１２３円も対象", ["１２３"]),
      ("円周率は3.14、人口は1,000人", ["3.14", "1,000"]),
      ("全角の小数は３．５", ["３．５"]),
      ("気温は-5度、−3度、＋2度", ["-5", "−3", "＋2"]),
      ("1,2,3番を選ぶ", ["1", "2", "3"]),
      ("1,0000件", ["1", "0000"]),
      ("v2-3 と 2026-10-12", ["2", "3", "2026", "10", "12"]),
      ("バージョン1.2.3", ["1.2.3"]),
    ]
  )
  func extractsNumbers(_ text: String, _ expected: [String]) {
    let spans = ProtectedSpanExtractor().extract(from: text)

    #expect(spans.map(\.kind) == Array(repeating: .number, count: expected.count))
    #expect(spans.map(\.text) == expected)
  }

  @Test(
    "TXT-02: URL を含む文から URL を抽出する",
    arguments: [
      ("詳細は https://example.com/path?q=1 を見てください", "https://example.com/path?q=1"),
      ("https://example.com/docsを開いて", "https://example.com/docs"),
      ("See https://example.com.", "https://example.com"),
      ("（参考: https://example.com/a, 以上）", "https://example.com/a"),
      ("(https://example.com)", "https://example.com"),
      (
        "https://en.wikipedia.org/wiki/Swift_(language) を参照",
        "https://en.wikipedia.org/wiki/Swift_(language)"
      ),
      ("http://localhost:3000/#top で確認", "http://localhost:3000/#top"),
      ("**https://example.com** を見て", "https://example.com"),
      ("[https://example.com]", "https://example.com"),
      ("https://example.com/a[0] を参照", "https://example.com/a[0]"),
    ]
  )
  func extractsURL(_ text: String, _ expected: String) {
    let spans = ProtectedSpanExtractor().extract(from: text)

    #expect(spans.map(\.kind) == [.url])
    #expect(spans.map(\.text) == [expected])
  }

  @Test("TXT-02: URL の中の数字は数字として抽出しない")
  func doesNotExtractNumbersInsideURL() {
    let spans = ProtectedSpanExtractor().extract(from: "https://example.com/v2/items/42 の42番")

    #expect(spans.map(\.kind) == [.url, .number])
    #expect(spans.map(\.text) == ["https://example.com/v2/items/42", "42"])
  }

  @Test(
    "TXT-02: コマンドを含む文からインラインコードを抽出する",
    arguments: [
      ("`git push origin main` を実行して", "`git push origin main`"),
      ("`npm run dev -- --port 3000` で起動", "`npm run dev -- --port 3000`"),
      ("`curl https://example.com` を叩く", "`curl https://example.com`"),
    ]
  )
  func extractsInlineCode(_ text: String, _ expected: String) {
    let spans = ProtectedSpanExtractor().extract(from: text)

    #expect(spans.map(\.kind) == [.inlineCode])
    #expect(spans.map(\.text) == [expected])
  }

  @Test("TXT-02: 複数行のコードブロックを抽出する")
  func extractsCodeBlock() {
    let block = "```\nlet x = 1\nprint(`x`)\n```"
    let spans = ProtectedSpanExtractor().extract(from: "次のコードです\n\(block)\n以上")

    #expect(spans.map(\.kind) == [.codeBlock])
    #expect(spans.map(\.text) == [block])
  }

  @Test("TXT-02: 閉じていないバッククォートはコードとして扱わない")
  func ignoresUnclosedBacktick() {
    let spans = ProtectedSpanExtractor().extract(from: "`ls を2回")

    #expect(spans.map(\.kind) == [.number])
  }

  @Test("TXT-02: 渡された辞書語を抽出する")
  func extractsDictionaryTerms() {
    let extractor = ProtectedSpanExtractor(dictionaryTerms: ["Kubernetes", "kubectl"])
    let spans = extractor.extract(from: "Kubernetes は kubectl で操作する")

    #expect(spans.map(\.kind) == [.dictionaryTerm, .dictionaryTerm])
    #expect(spans.map(\.text) == ["Kubernetes", "kubectl"])
  }

  @Test("TXT-02: 重なる辞書語は長いほうを採用する")
  func prefersLongerDictionaryTerm() {
    let extractor = ProtectedSpanExtractor(dictionaryTerms: ["Swift", "SwiftUI", ""])
    let spans = extractor.extract(from: "SwiftUIとSwift")

    #expect(spans.map(\.text) == ["SwiftUI", "Swift"])
    #expect(extractor.dictionaryTerms == ["SwiftUI", "Swift"])
  }

  @Test("TXT-02: 英数字の辞書語は単語の一部には一致させない")
  func dictionaryTermRequiresWordBoundary() {
    let extractor = ProtectedSpanExtractor(dictionaryTerms: ["Go"])
    let spans = extractor.extract(from: "Google と Goで書く、Gopher、(Go)")

    #expect(spans.map(\.text) == ["Go", "Go"])
  }

  @Test("TXT-02: 数字を含む辞書語は辞書語として抽出する")
  func dictionaryTermWithDigits() {
    let extractor = ProtectedSpanExtractor(dictionaryTerms: ["iOS 26"])
    let spans = extractor.extract(from: "iOS 26 で 2 件")

    #expect(spans.map(\.kind) == [.dictionaryTerm, .number])
    #expect(spans.map(\.text) == ["iOS 26", "2"])
  }

  @Test("TXT-02: 日英混在の文から種類ごとに出現順で抽出する")
  func extractsMixedTextInOrder() {
    let extractor = ProtectedSpanExtractor(dictionaryTerms: ["GitHub"])
    let text = "明日10時にGitHubでPR 26を確認し、`swift test` を https://example.com/ci で見る"
    let spans = extractor.extract(from: text)

    #expect(spans.map(\.kind) == [.number, .dictionaryTerm, .number, .inlineCode, .url])
    #expect(spans.map(\.text) == ["10", "GitHub", "26", "`swift test`", "https://example.com/ci"])
    #expect(spans.allSatisfy { String(text[$0.range]) == $0.text })
  }

  @Test("TXT-02: 保護対象がなければ空を返す")
  func returnsEmptyWithoutProtectedSpans() {
    #expect(ProtectedSpanExtractor().extract(from: "えーと、明日はよろしくお願いします").isEmpty)
    #expect(ProtectedSpanExtractor().extract(from: "").isEmpty)
  }

  @Test("TXT-02: 説明文字列に本文を含めない")
  func descriptionDoesNotContainText() throws {
    let span = try #require(
      ProtectedSpanExtractor().extract(from: "https://example.com/secret").first)

    var dumped = ""
    dump(span, to: &dumped)

    #expect(!span.description.contains("secret"))
    #expect(span.description.contains("url"))
    #expect(!dumped.contains("secret"))
  }
}
