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
    "REC-03, REC-04: 失敗の理由を2行目に出し、読み上げる",
    arguments: [
      (
        HUDNotice.speechRecognitionNotConfigured, SessionFailure.recognition, "認識に失敗しました",
        "音声認識が設定されていません"
      ),
      (.microphoneAccessDenied, .recording, "録音に失敗しました", "マイクの使用が許可されていません"),
    ])
  func failureReasonText(
    notice: HUDNotice, failure: SessionFailure, title: String, text: String
  ) throws {
    let presentation = try #require(
      HUDPresentation(HUDContent(status: .failed(failure), notice: notice)))
    #expect(presentation.indicator == .failure)
    #expect(presentation.title == title)
    #expect(presentation.message == text)
    #expect(presentation.announcement == "\(title)。\(text)")
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

  // MARK: - Realtime Preview（2.2節, AC-03）

  private static let transcript = HUDTranscript(confirmedText: "今日は", provisionalText: "いい天気")

  @Test(
    "AC-03: 認識テキストは録音中・認識中だけ持ち、他の段階と通知だけの表示では捨てる",
    arguments: [
      (HUDContent(status: .recording, notice: nil), true),
      (HUDContent(status: .recognizing, notice: .maxRecordingDurationReached), true),
      (HUDContent(status: .refining, notice: nil), false),
      (HUDContent(status: .inserting, notice: nil), false),
      (HUDContent(status: .failed(.recognition), notice: nil), false),
      (HUDContent(status: nil, notice: .audioBufferLimitReached), false),
    ] as [(HUDContent, Bool)])
  func transcriptOnlyWhileRecognizing(content: HUDContent, keeps: Bool) throws {
    let presentation = try #require(HUDPresentation(content, transcript: Self.transcript))
    #expect(presentation.transcript == (keeps ? Self.transcript : nil))
  }

  @Test("AC-03: 表示する文字がない認識テキストは持たない")
  func emptyTranscriptIsDropped() throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(status: .recording, notice: nil),
        transcript: HUDTranscript(confirmedText: "", provisionalText: "")))
    #expect(presentation.transcript == nil)
  }

  @Test("AC-03, REC-03: 認識テキストは VoiceOver のラベル・読み上げに含めない")
  func transcriptIsNotSpoken() throws {
    let recording = try #require(
      HUDPresentation(HUDContent(status: .recording, notice: nil), transcript: Self.transcript))
    #expect(recording.accessibilityLabel == "録音中")
    #expect(recording.announcement == nil)

    let limited = try #require(
      HUDPresentation(
        HUDContent(status: .recognizing, notice: .audioBufferLimitReached),
        transcript: Self.transcript))
    #expect(limited.accessibilityLabel == "認識中。録音できる音声の上限に達したため、録音を停止しました")
  }

  @Test("AC-03, REC-03: 認識テキストだけが変わったときは通知を読み上げ直さない")
  func transcriptUpdateDoesNotReannounce() throws {
    let content = HUDContent(status: .recognizing, notice: .audioBufferLimitReached)
    let first = try #require(HUDPresentation(content))
    let updated = try #require(HUDPresentation(content, transcript: Self.transcript))

    #expect(first.announcement(replacing: nil) == first.announcement)
    #expect(updated.announcement(replacing: first) == nil)

    let failed = try #require(
      HUDPresentation(HUDContent(status: .failed(.recognition), notice: nil)))
    #expect(failed.announcement(replacing: updated) == "認識に失敗しました")
  }

  @Test("AC-03, REC-06: 文字列表現・リフレクションに認識テキストを出さない")
  func descriptionHidesTranscript() throws {
    let presentation = try #require(
      HUDPresentation(HUDContent(status: .recording, notice: nil), transcript: Self.transcript))
    for text in [
      String(describing: presentation), String(reflecting: presentation),
      String(describing: Self.transcript), String(reflecting: Self.transcript),
      String(describing: Mirror(reflecting: presentation).children.map(\.value)),
    ] {
      #expect(!text.contains("今日は"))
      #expect(!text.contains("いい天気"))
    }
  }
}
