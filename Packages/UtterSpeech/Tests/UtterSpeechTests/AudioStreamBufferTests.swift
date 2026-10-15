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
}
