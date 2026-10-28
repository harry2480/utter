import Testing

@testable import UtteriOSKit

/// 録音中の音量の波形（#201）。音量の値だけを持ち、音声は持たない。
struct AudioLevelHistoryTests {
  @Test("#201: 無音・空のチャンクの音量は 0")
  func silenceIsZero() {
    #expect(AudioLevelHistory.level(of: []) == 0)
    #expect(AudioLevelHistory.level(of: Array(repeating: 0, count: 1_600)) == 0)
  }

  @Test("#201: 最大の音量のチャンクは 1")
  func fullScaleIsOne() {
    #expect(AudioLevelHistory.level(of: Array(repeating: 1, count: 1_600)) == 1)
    #expect(AudioLevelHistory.level(of: Array(repeating: -1, count: 1_600)) == 1)
  }

  @Test("#201: 大きい音ほど音量が大きく、-50 dB より小さい音は 0 にする")
  func louderIsHigher() {
    let quiet = AudioLevelHistory.level(of: Array(repeating: 0.01, count: 1_600))
    let loud = AudioLevelHistory.level(of: Array(repeating: 0.3, count: 1_600))
    let belowFloor = AudioLevelHistory.level(of: Array(repeating: 0.001, count: 1_600))

    #expect(quiet > 0)
    #expect(loud > quiet)
    #expect(loud < 1)
    #expect(belowFloor == 0)
  }

  @Test("#201: 非有限のサンプルは無音として数える")
  func nonFiniteSamplesAreSilent() {
    #expect(AudioLevelHistory.level(of: [.nan, .infinity, 0]) == 0)
  }

  @Test("#201: 上限を超えたら古い音量から捨てる")
  func dropsOldestBeyondCapacity() {
    var history = AudioLevelHistory(capacity: 3)
    for level: Float in [0.1, 0.2, 0.3, 0.4] {
      history.append(level)
    }

    #expect(history.levels == [0.2, 0.3, 0.4])
  }

  @Test("#201: 範囲外の音量は 0〜1 に収め、非有限の値は 0 にする")
  func clampsLevels() {
    var history = AudioLevelHistory()
    history.append(-0.5)
    history.append(1.5)
    history.append(.nan)

    #expect(history.levels == [0, 1, 0])
  }
}
