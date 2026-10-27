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
    #expect(presentation.messages.isEmpty)
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
    #expect(presentation.messages == [text])
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
      (.recordingInterrupted(.inputDeviceChanged), "入力機器が切り替わったため、録音を停止しました"),
      (.recordingInterrupted(.systemSleep), "Mac がスリープしたため、録音を停止しました"),
      (.recordingInterrupted(.microphoneAccessRevoked), "マイクの使用許可が取り消されたため、録音を停止しました"),
    ])
  func noticeText(notice: HUDNotice, text: String) throws {
    let processing = try #require(
      HUDPresentation(HUDContent(status: .recognizing, notice: notice)))
    #expect(processing.indicator == .processing)
    #expect(processing.title == "認識中")
    #expect(processing.messages == [text])

    // セッション終了後に通知だけを残しているときは、通知を1行目に出す
    let lingering = try #require(HUDPresentation(HUDContent(status: nil, notice: notice)))
    #expect(lingering.indicator == .notice)
    #expect(lingering.title == text)
    #expect(lingering.messages.isEmpty)
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

  @Test(
    "AC-16, AI-06: 退避の通知を種類ごとの文言にする",
    arguments: [
      (RefinementFallbackNotice.consentNotGranted, "クラウドへの送信に同意していないため、ローカルで整形しました"),
      (.sensitiveInput, "入力先が機密入力のため、ローカルで整形しました"),
      (.timeout, "クラウド整形の応答が時間内に届かなかったため、ローカルで整形しました"),
      (.authenticationExpired, "クラウド整形の API キーが無効になっているため、ローカルで整形しました"),
      (.quotaExceeded, "クラウド整形の利用枠が不足しているため、ローカルで整形しました"),
      (.budgetExceeded, "月次予算の上限を超えるため、ローカルで整形しました"),
      (.networkUnavailable, "ネットワークに接続できないため、ローカルで整形しました"),
      (.invalidResponse, "クラウド整形の応答を解釈できなかったため、ローカルで整形しました"),
      (.providerCancelled, "クラウド整形が中断されたため、ローカルで整形しました"),
      (.validationFailed, "クラウド整形の結果が検証を通らなかったため、ローカルで整形しました"),
    ])
  func fallbackText(fallback: RefinementFallbackNotice, text: String) throws {
    let presentation = try #require(
      HUDPresentation(HUDContent(status: .inserting, notice: .refinementFellBack(fallback))))
    #expect(presentation.title == "挿入中")
    #expect(presentation.messages == [text])
    // 処理中でも通知があれば読み上げる
    #expect(presentation.announcement == "挿入中。\(text)")
  }

  @Test("AC-16, AI-06: 退避の種類ごとに文言が異なる")
  func fallbackTextsAreDistinct() {
    let texts = Set(
      RefinementFallbackNotice.allCases.map { HUDPresentation.text(for: .refinementFellBack($0)) })
    #expect(texts.count == RefinementFallbackNotice.allCases.count)
  }

  @Test(
    "4章, AC-06, #188: クラウド STT で認識できなかった理由を、認識の失敗の2行目に出す",
    arguments: [
      (
        CloudSpeechRecognitionNotice.consentNotGranted,
        "クラウド音声認識への音声の送信に同意していないため、クラウドで音声認識できませんでした"
      ),
      (.apiKeyNotSet, "OpenAI API キーが保存されていないため、クラウドで音声認識できませんでした"),
      (.budgetExceeded, "月次予算の上限を超えるため、クラウドで音声認識できませんでした"),
    ])
  func cloudSpeechRecognitionFailureText(
    failure: CloudSpeechRecognitionNotice, text: String
  ) throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(
          status: .failed(.recognition), notice: .cloudSpeechRecognitionFailed(failure))))
    #expect(presentation.indicator == .failure)
    #expect(presentation.title == "認識に失敗しました")
    #expect(presentation.messages == [text])
  }

  @Test("4章, AC-06, #188: クラウド STT で認識できなかった理由の種類ごとに文言が異なる")
  func cloudSpeechRecognitionFailureTextsAreDistinct() {
    let texts = Set(
      CloudSpeechRecognitionNotice.allCases.map {
        HUDPresentation.text(for: .cloudSpeechRecognitionFailed($0))
      })
    #expect(texts.count == CloudSpeechRecognitionNotice.allCases.count)
  }

  @Test("REC-05, AC-16: 通知が重なったら、状態の下に通知を順に並べて続けて読む")
  func multipleNoticesWithStatus() throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(
          status: .refining,
          notices: [.maxRecordingDurationReached, .refinementFellBack(.networkUnavailable)])))

    #expect(presentation.indicator == .processing)
    #expect(presentation.title == "整形中")
    #expect(
      presentation.messages == [
        "最大録音時間に達したため、録音を停止しました", "ネットワークに接続できないため、ローカルで整形しました",
      ])
    #expect(presentation.message == "最大録音時間に達したため、録音を停止しました")
    #expect(
      presentation.accessibilityLabel
        == "整形中。最大録音時間に達したため、録音を停止しました。ネットワークに接続できないため、ローカルで整形しました")
    #expect(presentation.announcement == presentation.accessibilityLabel)
  }

  @Test("REC-05, AC-16: 通知だけを残しているときは、先頭の通知を1行目、残りを2行目以降に出す")
  func multipleLingeringNotices() throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(
          status: nil, notices: [.audioBufferLimitReached, .refinementFellBack(.timeout)])))

    #expect(presentation.indicator == .notice)
    #expect(presentation.title == "録音できる音声の上限に達したため、録音を停止しました")
    #expect(presentation.messages == ["クラウド整形の応答が時間内に届かなかったため、ローカルで整形しました"])
    #expect(
      presentation.announcement
        == "録音できる音声の上限に達したため、録音を停止しました。クラウド整形の応答が時間内に届かなかったため、ローカルで整形しました")
  }

  @Test("REC-04, AC-16: 失敗の理由と退避の通知が重なったら、失敗の理由を先に出す")
  func failureReasonPrecedesFallback() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    let t0 = ContinuousClock.now
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    _ = try machine.handle(
      SessionEvent(token: try #require(machine.currentToken), kind: .recognitionCompleted))
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.timeout, for: try #require(machine.activeSession).id)
    _ = try machine.handle(
      SessionEvent(token: try #require(machine.currentToken), kind: .refinementCompleted))
    _ = try machine.handle(
      SessionEvent(token: try #require(machine.currentToken), kind: .failed))
    hud.update(from: machine, failureNotice: .microphoneAccessDenied, at: t0)

    #expect(
      hud.content(at: t0)?.notices == [.microphoneAccessDenied, .refinementFellBack(.timeout)])
  }

  @Test("REC-03, AC-16: 段階が変わっても同じ通知は読み直さず、新しい通知が加わったときと失敗は読み上げる")
  func announcementAfterPrevious() throws {
    func presentation(_ status: HUDStatus?, _ notices: [HUDNotice]) throws -> HUDPresentation {
      try #require(HUDPresentation(HUDContent(status: status, notices: notices)))
    }
    let limit = HUDNotice.audioBufferLimitReached
    let fallback = HUDNotice.refinementFellBack(.timeout)
    let recognizing = try presentation(.recognizing, [limit])
    let refining = try presentation(.refining, [limit])
    let refiningWithFallback = try presentation(.refining, [limit, fallback])
    let inserting = try presentation(.inserting, [limit, fallback])
    let lingering = try presentation(nil, [limit, fallback])

    // 隠していた後は読み上げる
    #expect(recognizing.announcement(after: nil) == recognizing.announcement)
    // 段階だけが変わったときは読み直さない
    #expect(refining.announcement(after: recognizing) == nil)
    #expect(inserting.announcement(after: refiningWithFallback) == nil)
    #expect(lingering.announcement(after: inserting) == nil)
    // 退避の通知が加わったら読み上げる
    #expect(refiningWithFallback.announcement(after: refining) == refiningWithFallback.announcement)
    // 通知のない段階は読み上げない
    #expect(try presentation(.refining, []).announcement(after: nil) == nil)
    // 失敗は直前の通知に含まれていても読み上げる
    let failure = try presentation(.failed(.insertion), [fallback])
    #expect(
      failure.announcement(after: inserting) == "挿入に失敗しました。クラウド整形の応答が時間内に届かなかったため、ローカルで整形しました")
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

    #expect(first.announcement(after: nil) == first.announcement)
    #expect(updated.announcement(after: first) == nil)

    let failed = try #require(
      HUDPresentation(HUDContent(status: .failed(.recognition), notice: nil)))
    #expect(failed.announcement(after: updated) == "認識に失敗しました")
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

  @Test("AC-15: Realtime Direct を無効にした通知は録音中の2行目に出し、理由ごとに文言が異なる")
  func realtimeDirectFallbackText() throws {
    let presentation = try #require(
      HUDPresentation(
        HUDContent(status: .recording, notice: .realtimeDirectDisabled(.unsupportedTarget))))
    #expect(presentation.indicator == .recording)
    #expect(presentation.title == "録音中")
    #expect(
      presentation.messages == ["この入力先は Realtime Direct に対応していないため、停止後にまとめて入力します"])

    let texts = Set(
      RealtimeDirectFallbackNotice.allCases.map {
        HUDPresentation.text(for: .realtimeDirectDisabled($0))
      })
    #expect(texts.count == RealtimeDirectFallbackNotice.allCases.count)
  }
}
