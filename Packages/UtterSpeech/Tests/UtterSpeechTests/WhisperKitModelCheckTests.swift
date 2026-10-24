import Testing

@testable import UtterSpeech

struct WhisperKitModelCheckTests {
  static let digest = String(repeating: "c", count: 64)

  /// WhisperKit のロードに要るファイルがそろったモデル（各 Core ML モデルは1ファイルに省略）
  static let completePaths = [
    "MelSpectrogram.mlmodelc/coremldata.bin",
    "AudioEncoder.mlmodelc/coremldata.bin",
    "TextDecoder.mlmodelc/coremldata.bin",
    "tokenizer.json",
    "tokenizer_config.json",
  ]

  static func manifest(_ paths: [String]) throws -> ModelManifest {
    try ModelManifest(
      files: paths.map { try ModelManifest.File(path: $0, byteCount: 10, sha256: digest) })
  }

  static func source(_ paths: [String]) -> StubModelFileSource {
    StubModelFileSource(
      listing: .success(
        paths.map { ModelDirectoryEntry(path: $0, kind: .regularFile(byteCount: 10)) }),
      digests: Dictionary(
        uniqueKeysWithValues: paths.map {
          ($0, Result.success(ModelFileDigest(byteCount: 10, sha256: digest)))
        }))
  }

  @Test("PERM-03: マニフェストどおりにそろったフォルダはロードしてよい")
  func readyWhenVerified() throws {
    let check = WhisperKitModelCheck(manifest: try Self.manifest(Self.completePaths))

    let readiness = try check.check(Self.source(Self.completePaths))

    #expect(check.missingRequirements.isEmpty)
    #expect(readiness == .ready)
    #expect(readiness.recognitionError == nil)
  }

  @Test(
    "PERM-03: マニフェストに Core ML モデルかトークナイザーがなければ、ハッシュを計算せずにロードしない",
    arguments: [
      ("MelSpectrogram.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/"),
      ("AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/"),
      ("TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/"),
      ("tokenizer.json", "tokenizer.json"),
      ("tokenizer_config.json", "tokenizer_config.json"),
    ])
  func rejectsIncompleteManifest(removed: String, missing: String) throws {
    let paths = Self.completePaths.filter { $0 != removed }
    let check = WhisperKitModelCheck(manifest: try Self.manifest(paths))
    let source = Self.source(paths)

    let readiness = try check.check(source)

    #expect(readiness == .incompleteManifest([missing]))
    #expect(readiness.recognitionError == .modelUnavailable)
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: トークナイザーはフォルダの直下にあるものだけを数える")
  func requiresTokenizerAtTopLevel() throws {
    let paths = Self.completePaths.map { $0 == "tokenizer.json" ? "openai/tokenizer.json" : $0 }
    let check = WhisperKitModelCheck(manifest: try Self.manifest(paths))

    #expect(check.missingRequirements == ["tokenizer.json"])
  }

  @Test("PERM-03: WhisperKit が直下より先に探す場所のトークナイザーをマニフェストに置かせない")
  func rejectsHubTokenizerLocation() throws {
    let hubPath = "models/openai/whisper-tiny/tokenizer.json"
    let paths = Self.completePaths + [hubPath]
    let check = WhisperKitModelCheck(manifest: try Self.manifest(paths))
    let source = Self.source(paths)

    let readiness = try check.check(source)

    #expect(readiness == .disallowedPaths([hubPath]))
    #expect(readiness.recognitionError == .modelUnavailable)
    #expect(source.requestedPaths.isEmpty)
  }

  @Test("PERM-03: フォルダがなければ未取得とし、ロードしない")
  func notInstalled() throws {
    let check = WhisperKitModelCheck(manifest: try Self.manifest(Self.completePaths))

    let readiness = try check.check(StubModelFileSource(listing: .success(nil)))

    #expect(readiness == .notInstalled)
    #expect(readiness.recognitionError == .modelUnavailable)
  }

  @Test("PERM-03: マニフェストと一致しないフォルダはロードしない")
  func integrityFailed() throws {
    let check = WhisperKitModelCheck(manifest: try Self.manifest(Self.completePaths))
    let source = Self.source(Self.completePaths + ["extra.bin"])

    let readiness = try check.check(source)

    #expect(readiness == .integrityFailed([.unexpectedFile("extra.bin")]))
    #expect(readiness.recognitionError == .modelUnavailable)
  }
}
