import Foundation

/// STT モデルを構成するファイルの一覧と、それぞれのサイズ・SHA-256（PERM-03）。
///
/// 取得したモデルの完全性は、この一覧と照合して判定する（`ModelIntegrityVerifier`）。
/// 照合の基準になるため、マニフェストはモデル本体とは別の信頼できる経路（アプリへの同梱など）で持つ。
/// モデルと同じ取得元から同時に受け取ったマニフェストでは、破損は検出できても改ざんは検出できない。
///
/// 生成時（`init` と `Decodable`）に次を検証し、満たさなければ `ModelManifestError` を投げる。
/// - ファイルが1件以上ある
/// - パスはモデルのディレクトリからの相対パスで、`/` 区切り。絶対パス・空の要素・`.`・`..`・`\`・NUL を含まない
/// - 同じパスが重複しない（APFS の既定に合わせ、大文字・小文字と Unicode 正規化の違いも重複とみなす）
/// - サイズが0以上で合計が `Int64` に収まり、SHA-256 が16進数64桁（大文字は小文字にそろえる）
public struct ModelManifest: Hashable, Sendable, Codable {
  /// モデルを構成する1ファイル
  public struct File: Hashable, Sendable, Codable {
    /// モデルのディレクトリからの相対パス（`/` 区切り）
    public let path: String
    /// バイト数
    public let byteCount: Int64
    /// SHA-256 の16進数表記（小文字64桁）
    public let sha256: String

    public init(path: String, byteCount: Int64, sha256: String) throws(ModelManifestError) {
      guard Self.isSafeRelativePath(path) else {
        throw .unsafePath(path)
      }
      guard byteCount >= 0 else {
        throw .negativeByteCount(path)
      }
      let digest = sha256.lowercased()
      guard digest.utf8.count == 64, digest.utf8.allSatisfy(Self.isHexDigit) else {
        throw .invalidDigest(path)
      }
      self.path = path
      self.byteCount = byteCount
      self.sha256 = digest
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        path: container.decode(String.self, forKey: .path),
        byteCount: container.decode(Int64.self, forKey: .byteCount),
        sha256: container.decode(String.self, forKey: .sha256))
    }

    /// ディレクトリの外を指さない相対パスか。`..` による走査と絶対パスを拒否する
    static func isSafeRelativePath(_ path: String) -> Bool {
      guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
        return false
      }
      return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
  }

  /// モデルを構成するファイル。順序は生成時のまま
  public let files: [File]
  /// モデル全体のバイト数。取得前にサイズを示すために使う（PERM-03）
  public let totalByteCount: Int64

  public init(files: [File]) throws(ModelManifestError) {
    guard !files.isEmpty else {
      throw .empty
    }
    var seen = Set<String>()
    var total: Int64 = 0
    for file in files {
      guard seen.insert(Self.collisionKey(file.path)).inserted else {
        throw .duplicatePath(file.path)
      }
      let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
      guard !overflow else {
        throw .totalByteCountOverflow
      }
      total = sum
    }
    self.files = files
    self.totalByteCount = total
  }

  private enum CodingKeys: String, CodingKey {
    case files
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(files: container.decode([File].self, forKey: .files))
  }

  /// 大文字・小文字と Unicode 正規化を区別しないファイルシステムで、同じファイルを指すパスを同じ値にする
  static func collisionKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
  }
}

/// マニフェストが不正な理由。値に含むのはモデルのファイルのパスだけ
public enum ModelManifestError: Error, Hashable, Sendable {
  /// ファイルが1件もない
  case empty
  /// 絶対パス、`..` などでディレクトリの外を指しうるパス
  case unsafePath(String)
  /// 同じパス（大文字・小文字、Unicode 正規化の違いを含む）が重複している
  case duplicatePath(String)
  /// サイズが負
  case negativeByteCount(String)
  /// SHA-256 が16進数64桁でない
  case invalidDigest(String)
  /// 合計サイズが `Int64` に収まらない
  case totalByteCountOverflow
}
