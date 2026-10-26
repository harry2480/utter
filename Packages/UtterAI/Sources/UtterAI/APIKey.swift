/// 利用者が設定したクラウド AI の API キー（AC-12）。
///
/// 入力の前後の空白・改行は貼り付けで混ざりやすいため取り除く。空のキーと、制御文字（前後を含む）・途中の空白・
/// ASCII 以外の文字を含むキーは拒否する（HTTP ヘッダーに載せられず、貼り付けの誤りの可能性が高いため）。
/// 接頭辞などの形式は提供元が変えうるため確かめず、正しいかどうかは送信時の認証エラーで分かる。
///
/// 値はログに出さないよう、文字列表現とリフレクションでは伏せる。`Codable` にしない。
public struct APIKey: Hashable, Sendable {
  /// 送信に使う値。表示・ログには使わない
  public let value: String

  /// - Throws: 空（空白・改行だけを含む）か、途中に使えない文字を含む場合
  public init(_ input: String) throws(APIKeyValidationError) {
    let trimmed = String(
      input.unicodeScalars
        .drop(while: Self.isTrimmable)
        .reversed().drop(while: Self.isTrimmable).reversed()
        .map(Character.init))
    guard !trimmed.isEmpty else { throw .empty }
    // 印字可能な ASCII（空白を除く）だけを許す
    guard trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
      throw .invalidCharacters
    }
    self.value = trimmed
  }

  static func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
    // 制御文字は前後にあっても取り除かずに拒否する（タブ・改行は空白として取り除く）
    scalar.properties.isWhitespace
  }
}

/// API キーの入力の誤り。入力された値は持たない。
public enum APIKeyValidationError: Error, Hashable, Sendable, CaseIterable {
  /// 空か、空白・改行だけ
  case empty
  /// 途中に空白・制御文字・ASCII 以外の文字を含む
  case invalidCharacters
}

extension APIKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "APIKey(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: []) }
}
