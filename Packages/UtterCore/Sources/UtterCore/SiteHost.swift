import Foundation

/// Web サイト単位のスタイル判定に使うホスト名（CTX-02）。
///
/// URL 全体は持たず、正規化したホスト名だけを持つ。スキーム・利用者情報・ポート・パス・クエリ・フラグメントは捨てる。
/// 正規化の規則は次のとおりで、判定できない値は作らない（`nil`）。作れなければサイト単位の判定には使わない。
/// - 小文字にそろえ、末尾のドット（`example.com.`）を1つ外す
/// - 先頭の `www.` を外す（`www.example.com` と `example.com` を同じサイトとみなす）。残りが1ラベルになる場合は外さない
/// - 使える文字は ASCII の英数字・ハイフン・ドットだけ。国際化ドメイン名（IDN）は Punycode（`xn--`）の形で扱い、
///   それ以外の非 ASCII 文字・空白・`%`・`_`・`:`（ポートや IPv6）・`/` などを含む値は作らない
/// - IP アドレスは名前として扱うだけで、表記をそろえない（`127.0.0.1` と `0x7f.1` は別のサイト）。IPv6 は作らない
/// - 空のラベル（`a..b`）・63文字を超えるラベル・先頭か末尾がハイフンのラベル・253文字を超える名前は作らない
/// - サブドメインは別のサイトとして扱う（`mail.example.com` に `example.com` の上書きは当たらない）
///
/// ホスト名は閲覧先を表すため、文字列表現とリフレクションには出さない（CTX-03）。
/// 保存や設定画面で値が必要な場合だけ `rawValue` を明示的に読む。
public struct SiteHost: Hashable, Sendable {
  /// 正規化したホスト名
  public let rawValue: String

  /// 正規化済みの、またはそれに近いホスト名から作る（保存した設定の読み込みなど）。前後の空白と改行は除く。
  /// ポート・パスなどを含む値や、Punycode でない国際化ドメイン名からは作らない
  /// （URL からは `init?(url:)`、設定画面の入力からは `init?(userInput:)` を使う）。
  public init?(host: String) {
    guard let normalized = Self.normalized(host.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    rawValue = normalized
  }

  /// ブラウザから得た URL のホスト名だけを取り出して作る。
  /// `http` / `https` 以外のスキーム（`file`、`about` など）とホスト名のない URL からは作らない。
  /// 国際化ドメイン名は Foundation が Punycode に変換した形で扱う。
  public init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host(percentEncoded: false),
      let normalized = Self.normalized(host)
    else { return nil }
    rawValue = normalized
  }

  /// 設定画面で利用者が入力したホスト名または URL から作る。前後の空白と改行は除く。
  /// スキームがなければ `https` とみなし、`init?(url:)` と同じ規則でホスト名だけを取る（パス・ポートは捨てる）。
  /// 国際化ドメイン名・全角文字は Foundation が URL と同じ形（Punycode・半角）に変換するため、ブラウザから得た値と照合できる。
  /// 利用者情報（`user@`）を含む入力は、どこがホスト名か取り違えやすいため作らない。
  public init?(userInput: String) {
    let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let urlString = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let url = URL(string: urlString), url.user == nil, url.password == nil else {
      return nil
    }
    self.init(url: url)
  }

  private static let maxLabelLength = 63
  private static let maxNameLength = 253

  private static func normalized(_ host: String) -> String? {
    // 小文字化で ASCII になる文字（ケルビン記号 U+212A → `k` など）を通さないよう、小文字化の前に ASCII に限る。
    guard host.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
    var name = host.lowercased()
    if name.hasSuffix(".") {
      name.removeLast()
    }
    guard !name.isEmpty, name.utf8.count <= maxNameLength else { return nil }

    var labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy(isValidLabel) else { return nil }
    if labels.count > 2, labels[0] == "www" {
      labels.removeFirst()
    }
    return labels.joined(separator: ".")
  }

  private static func isValidLabel(_ label: Substring) -> Bool {
    guard !label.isEmpty, label.utf8.count <= maxLabelLength,
      label.first != "-", label.last != "-"
    else { return false }
    return label.utf8.allSatisfy { byte in
      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "-")
    }
  }
}

// 閲覧先をログに出さないよう、文字列表現とリフレクションにはホスト名を出さない（CTX-03）。
extension SiteHost: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "SiteHost(<redacted>)" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: [:]) }
}
