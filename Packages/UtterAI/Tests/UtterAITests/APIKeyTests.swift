import Testing

@testable import UtterAI

struct APIKeyTests {
  @Test(
    "AC-12: 前後の空白・改行・タブを取り除く",
    arguments: [
      "sk-ant-abc123", "  sk-ant-abc123", "sk-ant-abc123  ", "\tsk-ant-abc123\n",
      "\r\nsk-ant-abc123\r\n",
      "\u{3000}sk-ant-abc123\u{00A0}",
    ])
  func trimsSurroundingWhitespace(_ input: String) throws {
    #expect(try APIKey(input).value == "sk-ant-abc123")
  }

  @Test("AC-12: 空・空白だけの入力を拒否する", arguments: ["", " ", "\n", " \t\r\n ", "\u{3000}"])
  func rejectsBlank(_ input: String) {
    #expect(throws: APIKeyValidationError.empty) {
      try APIKey(input)
    }
  }

  @Test(
    "AC-12: 途中の空白・改行・制御文字・ASCII 以外の文字を拒否する",
    arguments: [
      "sk-ant abc", "sk-ant\nabc", "sk-ant\u{0}abc", "\u{0}sk-ant-abc", "sk-ant-abc\u{7F}",
      "sk-ant-ａｂｃ",
      "sk-ant-キー",
    ])
  func rejectsInvalidCharacters(_ input: String) {
    #expect(throws: APIKeyValidationError.invalidCharacters) {
      try APIKey(input)
    }
  }

  @Test("AC-12: 文字列表現とリフレクションにキーを出さない")
  func redactsValue() throws {
    let key = try APIKey("sk-ant-secret-value")

    #expect(!String(describing: key).contains("secret"))
    #expect(!String(reflecting: key).contains("secret"))
    #expect(!"\(key)".contains("secret"))
    #expect(Mirror(reflecting: key).children.isEmpty)
  }
}
