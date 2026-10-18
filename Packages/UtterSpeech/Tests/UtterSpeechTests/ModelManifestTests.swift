import Foundation
import Testing

@testable import UtterSpeech

struct ModelManifestTests {
  static let digest = String(repeating: "a", count: 64)

  @Test("PERM-03: ファイルの一覧から合計サイズを求め、SHA-256 を小文字にそろえる")
  func buildsManifest() throws {
    let manifest = try ModelManifest(files: [
      ModelManifest.File(
        path: "model/weights.bin", byteCount: 100, sha256: Self.digest.uppercased()),
      ModelManifest.File(path: "config.json", byteCount: 20, sha256: Self.digest),
    ])

    #expect(manifest.totalByteCount == 120)
    #expect(manifest.files.map(\.path) == ["model/weights.bin", "config.json"])
    #expect(manifest.files[0].sha256 == Self.digest)
  }

  @Test(
    "PERM-03: 絶対パスや `..` などディレクトリの外を指しうるパスを拒否する",
    arguments: [
      "", "/etc/passwd", "../outside.bin", "model/../../outside.bin", "./weights.bin", "model/.",
      "model//weights.bin", "model/", "..", "model\\weights.bin", "model\0.bin",
    ])
  func rejectsUnsafePath(_ path: String) {
    #expect(throws: ModelManifestError.unsafePath(path)) {
      try ModelManifest.File(path: path, byteCount: 1, sha256: Self.digest)
    }
  }

  @Test("PERM-03: `..` を含むだけの名前は通常のファイル名として受け付ける")
  func acceptsDotsInsideName() throws {
    let file = try ModelManifest.File(
      path: "model/..weights..bin", byteCount: 1, sha256: Self.digest)

    #expect(file.path == "model/..weights..bin")
  }

  @Test(
    "PERM-03: 同じファイルを指すパスの重複を拒否する（大文字・小文字、Unicode 正規化の違いを含む）",
    arguments: [
      ("weights.bin", "weights.bin"), ("Weights.bin", "weights.BIN"),
      ("caf\u{E9}.bin", "cafe\u{301}.bin"),
    ])
  func rejectsDuplicatePath(_ first: String, _ second: String) throws {
    let files = try [
      ModelManifest.File(path: first, byteCount: 1, sha256: Self.digest),
      ModelManifest.File(path: second, byteCount: 1, sha256: Self.digest),
    ]

    #expect(throws: ModelManifestError.duplicatePath(second)) {
      try ModelManifest(files: files)
    }
  }

  @Test("PERM-03: ファイルが1件もないマニフェストを拒否する")
  func rejectsEmptyManifest() {
    #expect(throws: ModelManifestError.empty) {
      try ModelManifest(files: [])
    }
  }

  @Test("PERM-03: 負のサイズを拒否する")
  func rejectsNegativeByteCount() {
    #expect(throws: ModelManifestError.negativeByteCount("weights.bin")) {
      try ModelManifest.File(path: "weights.bin", byteCount: -1, sha256: Self.digest)
    }
  }

  @Test(
    "PERM-03: 16進数64桁でない SHA-256 を拒否する",
    arguments: [
      "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
      String(repeating: "g", count: 64), String(repeating: "\u{FF41}", count: 64),
    ])
  func rejectsInvalidDigest(_ digest: String) {
    #expect(throws: ModelManifestError.invalidDigest("weights.bin")) {
      try ModelManifest.File(path: "weights.bin", byteCount: 1, sha256: digest)
    }
  }

  @Test("PERM-03: 合計サイズが Int64 に収まらないマニフェストを拒否する")
  func rejectsTotalByteCountOverflow() throws {
    let files = try [
      ModelManifest.File(path: "a.bin", byteCount: .max, sha256: Self.digest),
      ModelManifest.File(path: "b.bin", byteCount: 1, sha256: Self.digest),
    ]

    #expect(throws: ModelManifestError.totalByteCountOverflow) {
      try ModelManifest(files: files)
    }
  }

  @Test("PERM-03: JSON から読み込み、書き出した JSON を読み直すと同じ値になる")
  func decodesAndRoundTrips() throws {
    let json = Data(
      """
      {"files": [{"path": "model/weights.bin", "byteCount": 100, "sha256": "\(Self.digest.uppercased())"}]}
      """.utf8)

    let manifest = try JSONDecoder().decode(ModelManifest.self, from: json)
    let encoded = try JSONEncoder().encode(manifest)

    #expect(
      manifest.files == [
        try ModelManifest.File(path: "model/weights.bin", byteCount: 100, sha256: Self.digest)
      ])
    #expect(try JSONDecoder().decode(ModelManifest.self, from: encoded) == manifest)
  }

  @Test("PERM-03: JSON から読み込むときも不正なパス・空の一覧を拒否する")
  func rejectsInvalidJSON() {
    let unsafe = Data(
      #"{"files": [{"path": "../outside.bin", "byteCount": 1, "sha256": "\#(Self.digest)"}]}"#.utf8)
    let empty = Data(#"{"files": []}"#.utf8)

    #expect(throws: ModelManifestError.unsafePath("../outside.bin")) {
      try JSONDecoder().decode(ModelManifest.self, from: unsafe)
    }
    #expect(throws: ModelManifestError.empty) {
      try JSONDecoder().decode(ModelManifest.self, from: empty)
    }
  }
}
