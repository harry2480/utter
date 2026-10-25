import Testing

@testable import UtterCore

struct HUDPresentationTests {
  @Test(
    "REC-03: 各段階の状態を文言にする",
    arguments: [
      (HUDStatus.recording, HUDIndicator.recording, "録音中"),
      (.recognizing, .processing, "認識中"),
      (.refining, .processing, "整形中"),
      (.inserting, .processing, "挿入中"),
    ])
  func statusText(status: HUDStatus, indicator: HUDIndicator, title: String) throws {
    let presentation = try #require(HUDPresentation(HUDContent(status: status, notice: nil)))

    #expect(presentation.indicator == indicator)
    #expect(presentation.title == title)
    #expect(presentation.message == nil)
    #expect(presentation.accessibilityLabel == title)
  }

  @Test(
    "REC-03: 失敗した段階を文言にする",
    arguments: [
      (SessionFailure.recording, "録音に失敗しました"),
      (.recognition, "認識に失敗しました"),
      (.refinement, "整形に失敗しました"),
      (.insertion, "挿入に失敗しました"),
    ])
  func failureText(failure: SessionFailure, title: String) throws {
    let presentation = try #require(
      HUDPresentation(HUDContent(status: .failed(failure), notice: nil)))

    #expect(presentation.indicator == .failure)
    #expect(presentation.title == title)
  }

  @Test(
    "REC-05: 上限到達・割り込みの通知を文言にする",
    arguments: [
      (HUDNotice.maxRecordingDurationReached, "最大録音時間に達したため、録音を停止しました"),
      (.audioBufferLimitReached, "録音できる音声の上限に達したため、録音を停止しました"),
      (.recordingInterrupted(.audioInterruption), "ほかの音声に割り込まれたため、録音を停止しました"),
      (.recordingInterrupted(.inputDeviceLost), "マイクが使えなくなったため、録音を停止しました"),
      (.recordingInterrupted(.mediaServicesReset), "音声システムがリセットされたため、録音を停止しました"),
      (.recordingInterrupted(.movedToBackground), "アプリがバックグラウンドに移ったため、録音を停止しました"),
      (.recordingInterrupted(.thermalState), "端末の温度が上がったため、録音を停止しました"),
      (.recordingInterrupted(.lowPowerMode), "低電力モードになったため、録音を停止しました"),
      (.recordingInterrupted(.inputDeviceChanged), "入力機器が切り替わったため、録音を停止しました"),
      (.recordingInterrupted(.systemSleep), "Mac がスリープしたため、録音を停止しました"),
      (.recordingInterrupted(.microphoneAccessRevoked), "マイクの使用許可が取り消されたため、録音を停止しました"),
      (.refinementFellBack(.timeout), "クラウド整形の応答が時間内に届かなかったため、ローカルで整形しました"),
      (.refinementFellBack(.sensitiveInput), "入力先が機密入力のため、ローカルで整形しました"),
    ])
  func noticeText(notice: HUDNotice, text: String) throws {
    let processing = try #require(
      HUDPresentation(HUDContent(status: .recognizing, notice: notice)))
    #expect(processing.indicator == .processing)
    #expect(processing.title == "認識中")
    #expect(processing.message == text)

    // セッション終了後に通知だけを残しているときは、通知を1行目に出す
    let lingering = try #require(HUDPresentation(HUDContent(status: nil, notice: notice)))
    #expect(lingering.indicator == .notice)
    #expect(lingering.title == text)
    #expect(lingering.message == nil)
  }

  @Test("AC-16: 録音停止と退避の通知が重なったときは先頭の1件だけを表示する")
  func showsOnlyFirstNotice() throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(
          status: nil,
          notices: [.maxRecordingDurationReached, .refinementFellBack(.networkUnavailable)])))

    #expect(presentation.title == "最大録音時間に達したため、録音を停止しました")
    #expect(presentation.message == nil)
  }

  @Test("REC-03: 状態も通知もなければ表示しない")
  func emptyContentShowsNothing() {
    #expect(HUDPresentation(HUDContent(status: nil, notice: nil)) == nil)
  }

  @Test(
    "REC-03: 読み上げを依頼するのは失敗と通知だけで、録音中・処理中の段階は読み上げない",
    arguments: [
      (HUDContent(status: .recording, notice: nil), nil),
      (HUDContent(status: .recognizing, notice: nil), nil),
      (HUDContent(status: .inserting, notice: nil), nil),
      (HUDContent(status: .failed(.insertion), notice: nil), "挿入に失敗しました"),
      (
        HUDContent(status: .recognizing, notice: .maxRecordingDurationReached),
        "認識中。最大録音時間に達したため、録音を停止しました"
      ),
      (
        HUDContent(status: nil, notice: .audioBufferLimitReached),
        "録音できる音声の上限に達したため、録音を停止しました"
      ),
    ] as [(HUDContent, String?)])
  func announcement(content: HUDContent, expected: String?) throws {
    #expect(try #require(HUDPresentation(content)).announcement == expected)
  }

  @Test("REC-05: VoiceOver では状態と通知を続けて読む")
  func accessibilityLabelJoinsTitleAndMessage() throws {
    let presentation = try #require(
      HUDPresentation(HUDContent(status: .refining, notice: .maxRecordingDurationReached)))

    #expect(presentation.accessibilityLabel == "整形中。最大録音時間に達したため、録音を停止しました")
  }
}
