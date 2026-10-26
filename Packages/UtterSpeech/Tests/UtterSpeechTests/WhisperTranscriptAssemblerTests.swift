import Testing

@testable import UtterSpeech

struct WhisperTranscriptAssemblerTests {
  static let rate = WhisperKitRecognizerConfiguration.sampleRate

  /// 指定した秒数の無音のチャンク
  static func chunk(seconds: Double, sampleRate: Int = rate) -> AudioChunk {
    AudioChunk(
      samples: Array(repeating: 0, count: Int(seconds * Double(sampleRate))), sampleRate: sampleRate
    )
  }

  static func segment(_ text: String, end: Double) -> TranscribedSegment {
    TranscribedSegment(text: text, end: .seconds(end))
  }

  private func assembler(requiredSegments: Int = 2) throws -> WhisperTranscriptAssembler {
    WhisperTranscriptAssembler(
      configuration: try WhisperKitRecognizerConfiguration(
        isEnabled: true, requiredSegmentsForConfirmation: requiredSegments))
  }

  @Test("REC-06: 新しい音声が推論の間隔だけたまったら推論し直す時期と判定する")
  func reportsWhenTranscriptionIsDue() throws {
    var assembler = try assembler()

    #expect(try !assembler.append(Self.chunk(seconds: 0.5)))
    #expect(try assembler.append(Self.chunk(seconds: 0.5)))
    #expect(assembler.pendingSamples.count == Self.rate)

    _ = assembler.applyIntermediate([])
    #expect(try !assembler.append(Self.chunk(seconds: 0.5)))
  }

  @Test("REC-06: サンプリング周波数が 16kHz でない音声は受け付けない")
  func rejectsUnsupportedSampleRate() throws {
    var assembler = try assembler()

    #expect(throws: SpeechRecognitionError.unsupportedAudioFormat) {
      try assembler.append(Self.chunk(seconds: 1, sampleRate: 48_000))
    }
    #expect(!assembler.hasPendingAudio)
  }

  @Test("AC-03: 区間が未確定の数以下なら、すべてを暫定にする")
  func keepsRecentSegmentsProvisional() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 2))

    let events = assembler.applyIntermediate([
      Self.segment(" 明日は", end: 1), Self.segment("晴れ", end: 2),
    ])

    #expect(events == [.partial("明日は晴れ")])
    #expect(assembler.confirmedText.isEmpty)
    #expect(assembler.pendingSamples.count == 2 * Self.rate)
  }

  @Test("AC-03: 末尾の未確定の数より前の区間を確定にし、その終わりまでの音声を捨てる")
  func confirmsOlderSegments() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 3))

    let events = assembler.applyIntermediate([
      Self.segment(" 明日は", end: 1), Self.segment("晴れ", end: 2), Self.segment("です", end: 3),
    ])

    #expect(events == [.confirmed("明日は"), .partial("晴れです")])
    #expect(assembler.confirmedText == "明日は")
    #expect(assembler.pendingSamples.count == 2 * Self.rate)
  }

  @Test("AC-03: 暫定テキストが変わらなければイベントを流さない")
  func skipsUnchangedPartial() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 1))
    #expect(assembler.applyIntermediate([Self.segment("こん", end: 1)]) == [.partial("こん")])

    _ = try assembler.append(Self.chunk(seconds: 1))
    #expect(assembler.applyIntermediate([Self.segment("こん", end: 1)]).isEmpty)
    #expect(assembler.applyIntermediate([]) == [.partial("")])
  }

  @Test("AC-03: 空白だけの区間は無視する")
  func ignoresBlankSegments() throws {
    var assembler = try assembler(requiredSegments: 1)
    _ = try assembler.append(Self.chunk(seconds: 2))

    let events = assembler.applyIntermediate([
      Self.segment("一つ目", end: 1), Self.segment(" ", end: 1.5), Self.segment("二つ目", end: 2),
    ])

    #expect(events == [.confirmed("一つ目"), .partial("二つ目")])
  }

  @Test("AC-03: 確定済みのテキストがあれば、続く区間の先頭の空白を残す")
  func keepsLeadingSpaceAfterConfirmedText() throws {
    var assembler = try assembler(requiredSegments: 1)
    _ = try assembler.append(Self.chunk(seconds: 2))

    let events = assembler.applyIntermediate([
      Self.segment(" Hello", end: 1), Self.segment(" world", end: 2),
    ])

    #expect(events == [.confirmed("Hello"), .partial(" world")])
    #expect(assembler.complete([Self.segment(" world ", end: 1)]) == .completed("Hello world"))
  }

  @Test("REC-06: 区間の終わりが音声の先頭から進まなければ確定しない")
  func doesNotConfirmWithoutProgress() throws {
    var assembler = try assembler(requiredSegments: 1)
    _ = try assembler.append(Self.chunk(seconds: 1))

    let events = assembler.applyIntermediate([
      Self.segment("あ", end: 0), Self.segment("い", end: 1),
    ])

    #expect(events == [.partial("あい")])
    #expect(assembler.confirmedText.isEmpty)
    #expect(assembler.pendingSamples.count == Self.rate)
  }

  @Test("REC-06: 区間の終わりが未確定の音声の終わりに達するなら、残る区間のテキストを失わないよう確定しない")
  func doesNotConfirmUpToEndOfPendingAudio() throws {
    var assembler = try assembler(requiredSegments: 1)
    _ = try assembler.append(Self.chunk(seconds: 1))

    let events = assembler.applyIntermediate([Self.segment("あ", end: 5), Self.segment("い", end: 6)])

    #expect(events == [.partial("あい")])
    #expect(assembler.confirmedText.isEmpty)
    #expect(assembler.pendingSamples.count == Self.rate)
  }

  @Test("REC-06: 未確定の音声が上限を超えたら、末尾の1区間を残して確定する")
  func confirmsAllButLastWhenPendingIsTooLong() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 31))

    let events = assembler.applyIntermediate([
      Self.segment("一つ目", end: 10), Self.segment("二つ目", end: 30),
    ])

    #expect(events == [.confirmed("一つ目"), .partial("二つ目")])
    #expect(assembler.pendingSamples.count == 21 * Self.rate)
  }

  @Test("REC-06: 区間のない（無音の）未確定の音声が上限を超えたら、末尾だけを残して捨てる")
  func dropsLongSilence() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 31))

    let events = assembler.applyIntermediate([Self.segment(" ", end: 31)])

    #expect(events.isEmpty)
    #expect(assembler.confirmedText.isEmpty)
    #expect(assembler.pendingSamples.count == 5 * Self.rate)
  }

  @Test("REC-06: 未確定の音声が上限以下なら、区間がなくても音声を捨てない")
  func keepsSilenceWithinLimit() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 30))

    _ = assembler.applyIntermediate([])

    #expect(assembler.pendingSamples.count == 30 * Self.rate)
  }

  @Test("AC-03: 最後の推論結果を確定済みのテキストに続け、全体を完了にする")
  func completesWithWholeText() throws {
    var assembler = try assembler()
    _ = try assembler.append(Self.chunk(seconds: 3))
    _ = assembler.applyIntermediate([
      Self.segment("明日は", end: 1), Self.segment("晴れ", end: 2), Self.segment("です", end: 3),
    ])

    let completed = assembler.complete([Self.segment("晴れ", end: 1), Self.segment("でしょう\n", end: 2)])

    #expect(completed == .completed("明日は晴れでしょう"))
    #expect(!assembler.hasPendingAudio)
  }

  @Test("REC-06: 文字列表現に認識テキストを含めない")
  func descriptionOmitsText() throws {
    var assembler = try assembler(requiredSegments: 1)
    _ = try assembler.append(Self.chunk(seconds: 2))
    _ = assembler.applyIntermediate([Self.segment("秘密の話", end: 1), Self.segment("続き", end: 2)])
    let segment = Self.segment("秘密の話", end: 1)

    #expect(!String(describing: assembler).contains("秘密"))
    #expect(!String(reflecting: assembler).contains("秘密"))
    #expect(!String(describing: segment).contains("秘密"))
    #expect(!String(reflecting: segment).contains("秘密"))
  }
}
