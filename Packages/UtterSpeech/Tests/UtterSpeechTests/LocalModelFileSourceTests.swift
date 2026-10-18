import Foundation
import Testing

@testable import UtterSpeech

/// テストごとに一時ディレクトリを作り、終わったら消す。
///
/// Swift Testing はテストごとにスイートのインスタンスを作るため、テストの終了時に `deinit` で消える。
final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("utter-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

struct LocalModelFileSourceTests {
  /// "abc" の SHA-256
  static let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  /// 空のデータの SHA-256
  static let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private let directory = TemporaryDirectory()

  private func write(_ contents: String, to path: String) throws {
    let url = directory.url.appendingPathComponent(path, isDirectory: false)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func manifest() throws -> ModelManifest {
    try ModelManifest(files: [
      ModelManifest.File(path: "model/weights.bin", byteCount: 3, sha256: Self.abcDigest),
      ModelManifest.File(path: "empty.bin", byteCount: 0, sha256: Self.emptyDigest),
    ])
  }

  @Test("PERM-03: ディレクトリがなければ一覧の代わりに nil を返す")
  func returnsNilForMissingDirectory() throws {
    #expect(try LocalModelFileSource(directory: directory.url).entries() == nil)
  }

  @Test("PERM-03: ディレクトリの位置にファイルがあれば読めないとする")
  func rejectsFileAsDirectory() throws {
    try Data().write(to: directory.url)

    #expect(throws: ModelFileSourceError.unreadable) {
      try LocalModelFileSource(directory: directory.url).entries()
    }
  }

  @Test("PERM-03: サブディレクトリの中も含めて、通常ファイルを相対パスとサイズで返す")
  func listsNestedFiles() throws {
    try write("abc", to: "model/weights.bin")
    try write("", to: "empty.bin")
    try FileManager.default.createDirectory(
      at: directory.url.appendingPathComponent("unused"), withIntermediateDirectories: true)

    let entries = try #require(try LocalModelFileSource(directory: directory.url).entries())

    #expect(
      Set(entries) == [
        ModelDirectoryEntry(path: "model/weights.bin", kind: .regularFile(byteCount: 3)),
        ModelDirectoryEntry(path: "empty.bin", kind: .regularFile(byteCount: 0)),
      ])
  }

  @Test("PERM-03: シンボリックリンクはたどらず、通常ファイルでない項目として返す")
  func reportsSymbolicLinkAsOther() throws {
    let outside = TemporaryDirectory()
    try FileManager.default.createDirectory(at: outside.url, withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: outside.url.appendingPathComponent("secret.bin"))
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: directory.url.appendingPathComponent("file-link"),
      withDestinationURL: outside.url.appendingPathComponent("secret.bin"))
    try FileManager.default.createSymbolicLink(
      at: directory.url.appendingPathComponent("dir-link"), withDestinationURL: outside.url)
    let source = LocalModelFileSource(directory: directory.url)

    let entries = try #require(try source.entries())

    #expect(
      Set(entries) == [
        ModelDirectoryEntry(path: "file-link", kind: .other),
        ModelDirectoryEntry(path: "dir-link", kind: .other),
      ])
    #expect(throws: ModelFileSourceError.unreadable) {
      try source.digest(of: "file-link")
    }
  }

  @Test("PERM-03: ファイルを小分けに読んで SHA-256 とバイト数を求める", arguments: [1, 2, 1 << 20])
  func computesDigest(chunkSize: Int) throws {
    try write("abc", to: "model/weights.bin")
    try write("", to: "empty.bin")
    let source = LocalModelFileSource(directory: directory.url, chunkSize: chunkSize)

    #expect(
      try source.digest(of: "model/weights.bin")
        == ModelFileDigest(byteCount: 3, sha256: Self.abcDigest))
    #expect(
      try source.digest(of: "empty.bin") == ModelFileDigest(byteCount: 0, sha256: Self.emptyDigest))
  }

  @Test(
    "PERM-03: ディレクトリの外を指しうるパスや、ないファイル・ディレクトリは読まない",
    arguments: ["../outside.bin", "/etc/hosts", "missing.bin", "model"])
  func refusesUnsafeOrMissingPath(_ path: String) throws {
    try write("abc", to: "model/weights.bin")

    #expect(throws: ModelFileSourceError.unreadable) {
      try LocalModelFileSource(directory: directory.url).digest(of: path)
    }
  }

  @Test("PERM-03: 実際のファイルで、マニフェストのとおりなら検証済みにする")
  func verifiesDirectory() throws {
    try write("abc", to: "model/weights.bin")
    try write("", to: "empty.bin")

    let status = try ModelIntegrityVerifier(manifest: manifest())
      .verify(LocalModelFileSource(directory: directory.url))

    #expect(status == .verified)
  }

  @Test("PERM-03: 実際のファイルで、同じサイズの書き換えを SHA-256 の不一致として検出する")
  func detectsTamperedFile() throws {
    try write("abd", to: "model/weights.bin")
    try write("", to: "empty.bin")

    let status = try ModelIntegrityVerifier(manifest: manifest())
      .verify(LocalModelFileSource(directory: directory.url))

    #expect(status == .failed([.digestMismatch("model/weights.bin")]))
  }

  @Test("PERM-03: 実際のファイルで、マニフェストにないファイルを検出する")
  func detectsExtraFileOnDisk() throws {
    try write("abc", to: "model/weights.bin")
    try write("", to: "empty.bin")
    try write("x", to: "model/extra.bin")

    let status = try ModelIntegrityVerifier(manifest: manifest())
      .verify(LocalModelFileSource(directory: directory.url))

    #expect(status == .failed([.unexpectedFile("model/extra.bin")]))
  }
}
