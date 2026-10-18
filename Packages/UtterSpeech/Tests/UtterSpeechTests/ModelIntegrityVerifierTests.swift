import Testing

@testable import UtterSpeech

struct ModelIntegrityVerifierTests {
  static let weightsDigest = String(repeating: "a", count: 64)
  static let configDigest = String(repeating: "b", count: 64)

  let verifier: ModelIntegrityVerifier

  init() throws {
    verifier = ModelIntegrityVerifier(
      manifest: try ModelManifest(files: [
        ModelManifest.File(path: "model/weights.bin", byteCount: 100, sha256: Self.weightsDigest),
        ModelManifest.File(path: "config.json", byteCount: 20, sha256: Self.configDigest),
      ]))
  }

  /// マニフェストのとおりのディレクトリ
  static let completeEntries = [
    ModelDirectoryEntry(path: "model/weights.bin", kind: .regularFile(byteCount: 100)),
    ModelDirectoryEntry(path: "config.json", kind: .regularFile(byteCount: 20)),
  ]

  static let completeDigests: [String: Result<ModelFileDigest, ModelFileSourceError>] = [
    "model/weights.bin": .success(ModelFileDigest(byteCount: 100, sha256: weightsDigest)),
    "config.json": .success(ModelFileDigest(byteCount: 20, sha256: configDigest)),
  ]

  @Test("PERM-03: マニフェストのとおりのファイルがそろえば検証済みにし、ロードを許可する")
  func verifiesCompleteModel() throws {
    let source = StubModelFileSource(
      listing: .success(Self.completeEntries), digests: Self.completeDigests)

    let status = try verifier.verify(source)

    #expect(status == .verified)
    #expect(status.isLoadable)
    #expect(Set(source.requestedPaths) == ["model/weights.bin", "config.json"])
  }

  @Test("PERM-03: 読み込み側が大文字で返した SHA-256 も一致とみなす")
  func comparesDigestCaseInsensitively() throws {
    var digests = Self.completeDigests
    digests["config.json"] = .success(
      ModelFileDigest(byteCount: 20, sha256: Self.configDigest.uppercased()))
    let source = StubModelFileSource(listing: .success(Self.completeEntries), digests: digests)

    #expect(try verifier.verify(source) == .verified)
  }

  @Test("PERM-03: ディレクトリがなければ未取得とし、ロードを許可しない")
  func reportsNotInstalled() throws {
    let status = try verifier.verify(StubModelFileSource(listing: .success(nil)))

    #expect(status == .notInstalled)
    #expect(!status.isLoadable)
  }

  @Test("PERM-03: ディレクトリの一覧を取れなければ検証失敗にする")
  func failsWhenDirectoryUnreadable() throws {
    let status = try verifier.verify(StubModelFileSource(listing: .failure(.unreadable)))

    #expect(status == .failed([.directoryUnreadable]))
    #expect(!status.isLoadable)
  }

  @Test("PERM-03: ファイルの欠落を検出し、ハッシュを計算しない")
  func detectsMissingFile() throws {
    let source = StubModelFileSource(
      listing: .success([Self.completeEntries[1]]), digests: Self.completeDigests)

    #expect(try verifier.verify(source) == .failed([.missingFile("model/weights.bin")]))
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: 一覧のサイズの不一致を検出し、ハッシュを計算しない")
  func detectsSizeMismatchFromListing() throws {
    let source = StubModelFileSource(
      listing: .success([
        ModelDirectoryEntry(path: "model/weights.bin", kind: .regularFile(byteCount: 99)),
        Self.completeEntries[1],
      ]),
      digests: Self.completeDigests)

    #expect(
      try verifier.verify(source)
        == .failed([.sizeMismatch(path: "model/weights.bin", expected: 100, actual: 99)]))
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: 読んだバイト数が一覧と違えば（一覧の後に変わった）サイズの不一致にする")
  func detectsSizeMismatchWhileHashing() throws {
    var digests = Self.completeDigests
    digests["model/weights.bin"] = .success(
      ModelFileDigest(byteCount: 150, sha256: Self.weightsDigest))
    let source = StubModelFileSource(listing: .success(Self.completeEntries), digests: digests)

    #expect(
      try verifier.verify(source)
        == .failed([.sizeMismatch(path: "model/weights.bin", expected: 100, actual: 150)]))
  }

  @Test("PERM-03: SHA-256 の不一致を検出する")
  func detectsDigestMismatch() throws {
    var digests = Self.completeDigests
    digests["config.json"] = .success(ModelFileDigest(byteCount: 20, sha256: Self.weightsDigest))
    let source = StubModelFileSource(listing: .success(Self.completeEntries), digests: digests)

    let status = try verifier.verify(source)

    #expect(status == .failed([.digestMismatch("config.json")]))
    #expect(!status.isLoadable)
  }

  @Test("PERM-03: マニフェストにないファイルを検出する")
  func detectsUnexpectedFile() throws {
    let source = StubModelFileSource(
      listing: .success(
        Self.completeEntries + [
          ModelDirectoryEntry(path: "model/extra.bin", kind: .regularFile(byteCount: 1))
        ]),
      digests: Self.completeDigests)

    #expect(try verifier.verify(source) == .failed([.unexpectedFile("model/extra.bin")]))
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: 大文字・小文字だけが違うパスは同じファイルとみなさず、検証失敗にする")
  func matchesPathCaseSensitively() throws {
    let source = StubModelFileSource(
      listing: .success([
        Self.completeEntries[0],
        ModelDirectoryEntry(path: "Config.json", kind: .regularFile(byteCount: 20)),
      ]),
      digests: Self.completeDigests)

    #expect(
      try verifier.verify(source)
        == .failed([.missingFile("config.json"), .unexpectedFile("Config.json")]))
  }

  @Test("PERM-03: Unicode 正規化だけが違うパスは同じファイルとみなす")
  func matchesCanonicallyEquivalentPath() throws {
    let verifier = ModelIntegrityVerifier(
      manifest: try ModelManifest(files: [
        ModelManifest.File(path: "caf\u{E9}.bin", byteCount: 1, sha256: Self.weightsDigest)
      ]))
    let source = StubModelFileSource(
      listing: .success([
        ModelDirectoryEntry(path: "cafe\u{301}.bin", kind: .regularFile(byteCount: 1))
      ]),
      digests: [
        "caf\u{E9}.bin": .success(ModelFileDigest(byteCount: 1, sha256: Self.weightsDigest))
      ])

    #expect(try verifier.verify(source) == .verified)
  }

  @Test("PERM-03: 一覧に同じパス（正準等価を含む）が重複していたら、2件目以降をマニフェスト外の項目として検証失敗にする")
  func reportsDuplicateListedEntries() throws {
    let source = StubModelFileSource(
      listing: .success(
        Self.completeEntries + [
          ModelDirectoryEntry(path: "config.json", kind: .regularFile(byteCount: 20)),
          ModelDirectoryEntry(path: "model/weights.bin", kind: .other),
        ]),
      digests: Self.completeDigests)

    #expect(
      try verifier.verify(source)
        == .failed([.unexpectedFile("config.json"), .unsupportedEntry("model/weights.bin")]))
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: シンボリックリンクなど通常ファイルでない項目は、マニフェストにあってもなくても検証失敗にする")
  func rejectsUnsupportedEntries() throws {
    let source = StubModelFileSource(
      listing: .success([
        ModelDirectoryEntry(path: "model/weights.bin", kind: .other),
        Self.completeEntries[1],
        ModelDirectoryEntry(path: "link", kind: .other),
      ]),
      digests: Self.completeDigests)

    #expect(
      try verifier.verify(source)
        == .failed([.unsupportedEntry("model/weights.bin"), .unsupportedEntry("link")]))
  }

  @Test("PERM-03: 一覧だけで分かる問題は、すべて報告する")
  func reportsAllListingIssues() throws {
    let source = StubModelFileSource(
      listing: .success([
        ModelDirectoryEntry(path: "config.json", kind: .regularFile(byteCount: 21)),
        ModelDirectoryEntry(path: "b.bin", kind: .regularFile(byteCount: 1)),
        ModelDirectoryEntry(path: "a.bin", kind: .regularFile(byteCount: 1)),
      ]))

    #expect(
      try verifier.verify(source)
        == .failed([
          .missingFile("model/weights.bin"),
          .sizeMismatch(path: "config.json", expected: 20, actual: 21),
          .unexpectedFile("a.bin"),
          .unexpectedFile("b.bin"),
        ]))
  }

  @Test("PERM-03: 読めないファイルがあれば検証失敗にし、残りのファイルも確認する")
  func reportsUnreadableFile() throws {
    var digests = Self.completeDigests
    digests["model/weights.bin"] = .failure(.unreadable)
    digests["config.json"] = .success(ModelFileDigest(byteCount: 20, sha256: Self.weightsDigest))
    let source = StubModelFileSource(listing: .success(Self.completeEntries), digests: digests)

    #expect(
      try verifier.verify(source)
        == .failed([.unreadableFile("model/weights.bin"), .digestMismatch("config.json")]))
  }

  @Test("PERM-03: 読み込み中のキャンセルは判定を返さず CancellationError を投げる")
  func propagatesCancellationFromSource() {
    var digests = Self.completeDigests
    digests["model/weights.bin"] = .failure(.cancelled)
    let source = StubModelFileSource(listing: .success(Self.completeEntries), digests: digests)

    #expect(throws: CancellationError.self) {
      try verifier.verify(source)
    }
  }

  @Test("PERM-03: 一覧の取得中のキャンセルも CancellationError を投げる")
  func propagatesCancellationFromListing() {
    #expect(throws: CancellationError.self) {
      try verifier.verify(StubModelFileSource(listing: .failure(.cancelled)))
    }
  }

  @Test("PERM-03: キャンセル済みのタスクではハッシュを計算せず CancellationError を投げる")
  func stopsWhenTaskCancelled() async {
    let source = StubModelFileSource(
      listing: .success(Self.completeEntries), digests: Self.completeDigests)
    let verifier = verifier
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try verifier.verify(source)
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(source.requestedPaths.isEmpty)
  }
}
