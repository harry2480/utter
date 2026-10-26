import Testing
import UtterCore

/// HUD の表示・非表示の依頼のまとめ（REC-03, AC-03）。
struct HUDDisplayQueueTests {
  private func presentation(
    _ status: HUDStatus, _ notice: HUDNotice? = nil, transcript: String? = nil
  ) throws -> HUDPresentation {
    try #require(
      HUDPresentation(
        HUDContent(status: status, notice: notice),
        transcript: transcript.map { HUDTranscript(confirmedText: $0, provisionalText: "") }))
  }

  @Test("REC-03: 溜めている間の表示は最後の1件だけを反映する")
  func keepsLastShow() throws {
    var queue = HUDDisplayQueue()
    queue.requestShow(try presentation(.recording, transcript: "一"))
    queue.requestShow(try presentation(.recording, transcript: "一二"))
    #expect(queue.hasPending)

    #expect(
      queue.flush() == [.show(try presentation(.recording, transcript: "一二"), announcement: nil)])
    #expect(!queue.hasPending)
    #expect(queue.flush().isEmpty)
  }

  @Test("REC-03: 表示の後の非表示は、隠すだけにする")
  func showThenHide() throws {
    var queue = HUDDisplayQueue()
    queue.requestShow(try presentation(.recording))
    queue.requestHide()
    #expect(queue.flush() == [.hide])
    #expect(queue.displayed == nil)
  }

  @Test("REC-03: 非表示の後に表示が来たら、隠してから出し直し、同じ通知も読み上げ直す")
  func hideThenShowReannounces() throws {
    var queue = HUDDisplayQueue()
    let failed = try presentation(.failed(.recognition))
    queue.requestShow(failed)
    #expect(queue.flush() == [.show(failed, announcement: "認識に失敗しました")])

    queue.requestHide()
    queue.requestShow(failed)
    #expect(queue.flush() == [.hide, .show(failed, announcement: "認識に失敗しました")])
  }

  @Test("AC-03, REC-03: 認識テキストだけが変わったときは通知を読み上げ直さない")
  func transcriptOnlyChangeIsSilent() throws {
    var queue = HUDDisplayQueue()
    let limited = try presentation(.recognizing, .audioBufferLimitReached)
    queue.requestShow(limited)
    #expect(
      queue.flush().first.map { if case .show(_, let a) = $0 { a != nil } else { false } } == true)

    let updated = try presentation(.recognizing, .audioBufferLimitReached, transcript: "今日は")
    queue.requestShow(updated)
    #expect(queue.flush() == [.show(updated, announcement: nil)])
  }
}
