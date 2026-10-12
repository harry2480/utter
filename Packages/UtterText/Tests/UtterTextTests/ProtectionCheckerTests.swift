import Testing

@testable import UtterText

struct ProtectionCheckerTests {
  let checker = ProtectionChecker(dictionaryTerms: ["Kubernetes", "GitHub", "GPT-5", "kubectl"])

  @Test(
    "TXT-02: 保護対象が保持されていれば違反はない",
    arguments: [
      ("えーと会議は3時からです", "会議は3時からです。"),
      ("あの https://example.com/a を見て", "https://example.com/a を見てください。"),
      ("`git status` をえっと実行", "`git status` を実行。"),
      ("Kubernetes とGitHub の設定", "Kubernetes と GitHub の設定。"),
      ("コードは\n```\nlet x = 1\n```\nです", "コードは次のとおりです。\n```\nlet x = 1\n```"),
      ("3と5", "5と3"),
      ("https://example.com を見て", "**https://example.com** を見てください。"),
      ("GPT 5 を使う", "GPT-5 を使う。"),
      ("kubectl で確認", "`kubectl get pods` で確認。"),
      ("1,2,3番", "1、2、3番"),
      ("−5度", "-5度"),
    ]
  )
  func noViolationsWhenPreserved(_ original: String, _ refined: String) {
    #expect(checker.violations(original: original, refined: refined).isEmpty)
  }

  @Test(
    "TXT-02: 数字は全角と半角の違いを同一とみなす",
    arguments: [("１５分後", "15分後"), ("15分後", "１５分後"), ("３．５倍", "3.5倍")]
  )
  func treatsFullWidthDigitsAsSame(_ original: String, _ refined: String) {
    #expect(checker.violations(original: original, refined: refined).isEmpty)
  }

  @Test(
    "TXT-02: 数字の変更を列挙する",
    arguments: [
      ("3時に集合", "4時に集合", "3", "4"),
      ("10個", "100個", "10", "100"),
      ("3.14です", "3です", "3.14", "3"),
    ]
  )
  func reportsAlteredNumber(
    _ original: String, _ refined: String, _ before: String, _ after: String
  ) {
    let violations = checker.violations(original: original, refined: refined)

    #expect(violations.map(\.original.kind) == [.number])
    #expect(violations.map(\.original.text) == [before])
    #expect(violations.map(\.change) == [.altered(to: after)])
  }

  @Test(
    "TXT-02: コードと同じ値が地の文で変わったことを見逃さない",
    arguments: [
      (
        "`ls 3` と 3", "`ls 3` と 4", ProtectedSpan.Kind.number,
        ProtectionViolation.Change.altered(to: "4")
      ),
      (
        "`open https://a.com` と https://a.com", "`open https://a.com` と https://b.com",
        .url, .altered(to: "https://b.com")
      ),
    ]
  )
  func detectsChangeBesideMatchingCode(
    _ original: String, _ refined: String, _ kind: ProtectedSpan.Kind,
    _ change: ProtectionViolation.Change
  ) {
    let violations = checker.violations(original: original, refined: refined)

    #expect(violations.map(\.original.kind) == [kind])
    #expect(violations.map(\.change) == [change])
  }

  @Test("TXT-02: 整形後にコードで囲まれて変わった値は変更として列挙する")
  func reportsAlteredValueWrappedInCode() {
    let violations = checker.violations(original: "3 回", refined: "`4` 回")

    #expect(violations.map(\.original.kind) == [.number])
    #expect(violations.map(\.change) == [.altered(to: "4")])
  }

  @Test("TXT-02: 符号の脱落を列挙する")
  func reportsDroppedSign() {
    let violations = checker.violations(original: "気温は-5度", refined: "気温は5度")

    #expect(violations.map(\.change) == [.altered(to: "5")])
  }

  @Test("TXT-02: コードブロックの変更を列挙する")
  func reportsAlteredCodeBlock() {
    let violations = checker.violations(
      original: "```\nls\n```", refined: "```sh\nls\n```")

    #expect(violations.map(\.original.kind) == [.codeBlock])
    #expect(violations.map(\.change) == [.altered(to: "```sh\nls\n```")])
  }

  @Test("TXT-02: 漢数字への書き換えは欠落として扱う")
  func kanjiNumeralIsMissing() {
    let violations = checker.violations(original: "3人で行く", refined: "三人で行く")

    #expect(violations.map(\.change) == [.missing])
    #expect(violations.map(\.original.text) == ["3"])
  }

  @Test("TXT-02: 同じ数字が複数あれば個数で判定する")
  func countsDuplicateNumbers() {
    let violations = checker.violations(original: "3回と3回", refined: "3回")

    #expect(violations.map(\.change) == [.missing])
    #expect(violations.first?.original.range.lowerBound != "3回と3回".startIndex)
  }

  @Test("TXT-02: URL の変更と欠落を列挙する")
  func reportsURLChanges() {
    let original = "https://example.com/a と https://example.com/b を比較"
    let violations = checker.violations(original: original, refined: "https://example.com/c を比較")

    #expect(violations.map(\.original.text) == ["https://example.com/a", "https://example.com/b"])
    #expect(violations.map(\.change) == [.altered(to: "https://example.com/c"), .missing])
  }

  @Test("TXT-02: 整形後にコードで囲まれた URL・数字は保持とみなす")
  func treatsWrappedInCodeAsPreserved() {
    let violations = checker.violations(
      original: "ポート 3000 で https://localhost を開く",
      refined: "`--port 3000` で `https://localhost` を開く")

    #expect(violations.isEmpty)
  }

  @Test("TXT-02: 整形後に URL の一部になった数字は保持とみなさない")
  func numberAbsorbedIntoURLIsMissing() {
    let violations = checker.violations(
      original: "https://example.com/v を 2 回開く",
      refined: "https://example.com/v2 を開く")

    #expect(violations.map(\.original.kind) == [.url, .number])
    #expect(violations.map(\.change) == [.altered(to: "https://example.com/v2"), .missing])
  }

  @Test(
    "TXT-02: コマンドを含む文でコードの変更・囲みの欠落を列挙する",
    arguments: [
      ("`ls -la` を実行", "`ls -l` を実行", ProtectionViolation.Change.altered(to: "`ls -l`")),
      ("`git status` を実行", "git status を実行", .missing),
    ]
  )
  func reportsCodeChanges(
    _ original: String, _ refined: String, _ change: ProtectionViolation.Change
  ) {
    let violations = checker.violations(original: original, refined: refined)

    #expect(violations.map(\.original.kind) == [.inlineCode])
    #expect(violations.map(\.change) == [change])
  }

  @Test("TXT-02: 辞書語の書き換えを欠落として列挙する")
  func reportsMissingDictionaryTerm() {
    let violations = checker.violations(
      original: "Kubernetes を GitHub で管理", refined: "クバネティスを GitHub で管理")

    #expect(violations.map(\.original.kind) == [.dictionaryTerm])
    #expect(violations.map(\.original.text) == ["Kubernetes"])
    #expect(violations.map(\.change) == [.missing])
  }

  @Test("TXT-02: 日英混在の文で違反を出現順に列挙する")
  func reportsViolationsInOrder() {
    let violations = checker.violations(
      original: "明日10時にGitHubで `make test` を実行",
      refined: "明日11時にGitHubで実行")

    #expect(violations.map(\.original.kind) == [.number, .inlineCode])
    #expect(violations.map(\.change) == [.altered(to: "11"), .missing])
  }

  @Test("TXT-02: 整形後が空なら保護対象はすべて欠落")
  func emptyRefinedLosesAll() {
    let violations = checker.violations(original: "3時に https://example.com", refined: "")

    #expect(violations.map(\.change) == [.missing, .missing])
  }

  @Test("TXT-02: 違反の説明文字列に本文を含めない")
  func descriptionDoesNotContainText() throws {
    let violation = try #require(
      checker.violations(original: "`secret-command`", refined: "`other-command`").first)

    var dumped = ""
    dump(violation, to: &dumped)

    #expect(!violation.description.contains("secret"))
    #expect(!violation.description.contains("other"))
    #expect(violation.description.contains("altered"))
    #expect("\(violation.change)" == "altered")
    #expect(!dumped.contains("secret"))
    #expect(!dumped.contains("other"))
  }
}
