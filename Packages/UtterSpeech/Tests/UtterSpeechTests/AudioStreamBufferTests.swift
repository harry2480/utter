import Testing
import UtterSpeech

struct AudioStreamBufferTests {
  @Test("REC-05: バッファの最大サイズは設定可能")
  func maxBytesIsConfigurable() {
    let buffer = AudioStreamBuffer(maxBytes: 1_000_000)
    #expect(buffer.maxBytes == 1_000_000)
  }

  @Test("REC-05: 既定は5分分のPCM16kHz（9.6MB）")
  func defaultMaxBytesIs5Minutes() {
    let buffer = AudioStreamBuffer()
    #expect(buffer.maxBytes == AudioStreamBuffer.defaultMaxBytes)
    #expect(buffer.maxBytes == 9_600_000)
  }

  @Test("REC-05: 0以下の上限は1バイト以上に修正")
  func nonPositiveMaxBytesAdjusted() {
    #expect(AudioStreamBuffer(maxBytes: 0).maxBytes >= 1)
    #expect(AudioStreamBuffer(maxBytes: -100).maxBytes >= 1)
  }

  @Test("REC-05: 上限到達を判定できる")
  func limitReachedJudgment() {
    let buffer = AudioStreamBuffer(maxBytes: 1000)

    #expect(!buffer.isLimitReached(currentSize: 999))
    #expect(buffer.isLimitReached(currentSize: 1000))
    #expect(buffer.isLimitReached(currentSize: 1001))
  }

  @Test("REC-05: 残り容量を計算できる")
  func remainingBytesCalculation() {
    let buffer = AudioStreamBuffer(maxBytes: 1000)

    #expect(buffer.remainingBytes(currentSize: 0) == 1000)
    #expect(buffer.remainingBytes(currentSize: 500) == 500)
    #expect(buffer.remainingBytes(currentSize: 1000) == 0)
    #expect(buffer.remainingBytes(currentSize: 1500) == 0)
  }

  @Test("REC-05: 負の currentSize は全容量を返す")
  func negativeCurrentSizeHandled() {
    let buffer = AudioStreamBuffer(maxBytes: 1000)
    #expect(buffer.remainingBytes(currentSize: -100) == 1000)
  }

  @Test("REC-05: sizeInBytes は AudioChunk のバイト数を計算（PCM16 = 2 bytes/sample）")
  func sizeInBytesCalculation() {
    let buffer = AudioStreamBuffer()
    let chunk = AudioChunk(samples: [0.0, 0.0, 0.0], sampleRate: 16000)
    #expect(buffer.sizeInBytes(of: chunk) == 6)
  }

  @Test("REC-05: sizeInBytes の負値サンプル数は0を返す")
  func sizeInBytesNegativeHandled() {
    let buffer = AudioStreamBuffer()
    let emptyChunk = AudioChunk(samples: [], sampleRate: 16000)
    #expect(buffer.sizeInBytes(of: emptyChunk) == 0)
  }

  @Test("REC-05: canAccept は容量内でチャンク受け入れ可")
  func canAcceptWhenSpaceAvailable() {
    let buffer = AudioStreamBuffer(maxBytes: 1000)
    let chunk = AudioChunk(samples: Array(repeating: 0.0, count: 100), sampleRate: 16000)
    #expect(buffer.canAccept(chunk, currentSize: 0) == true)
    #expect(buffer.canAccept(chunk, currentSize: 800) == true)
  }

  @Test("REC-05: canAccept は容量満杯でチャンク拒否")
  func canAcceptWhenFull() {
    let buffer = AudioStreamBuffer(maxBytes: 100)
    let chunk = AudioChunk(samples: Array(repeating: 0.0, count: 100), sampleRate: 16000)
    #expect(buffer.canAccept(chunk, currentSize: 0) == false)
    #expect(buffer.canAccept(chunk, currentSize: 50) == false)
  }

  @Test("REC-05: canAccept は境界値（ちょうど上限）で受け入れ可")
  func canAcceptAtExactLimit() {
    let buffer = AudioStreamBuffer(maxBytes: 100)
    let chunk = AudioChunk(samples: Array(repeating: 0.0, count: 50), sampleRate: 16000)
    let chunkSize = buffer.sizeInBytes(of: chunk)
    #expect(buffer.canAccept(chunk, currentSize: 100 - chunkSize) == true)
  }

  @Test("REC-05: canAccept は負の currentSize を 0 として扱う")
  func canAcceptWithNegativeSize() {
    let buffer = AudioStreamBuffer(maxBytes: 1000)
    let chunk = AudioChunk(samples: Array(repeating: 0.0, count: 100), sampleRate: 16000)
    #expect(buffer.canAccept(chunk, currentSize: -100) == true)
  }
}
