import Testing
import UtterCore

@testable import UtterSpeech

struct TranscriptPreviewTests {
  private func preview(_ kinds: [RecognitionEvent.Kind]) -> TranscriptPreview {
    var preview = TranscriptPreview()
    for kind in kinds {
      preview.apply(kind)
    }
    return preview
  }

  @Test("AC-03: 暫定テキストは新しい暫定結果で置き換わり、確定済みテキストとは区別する")
  func replacesProvisionalText() {
    let preview = preview([.confirmed("明日の"), .partial("会議"), .partial("会議は十時")])

    #expect(preview.confirmedText == "明日の")
    #expect(preview.provisionalText == "会議は十時")
    #expect(preview.state == .recognizing)
  }

  @Test("AC-03: 確定した部分は連結し、それまでの暫定テキストを消す")
  func confirmsAndClearsProvisionalText() {
    let preview = preview([.partial("明日"), .confirmed("明日の"), .partial("会"), .confirmed("会議は")])

    #expect(preview.confirmedText == "明日の会議は")
    #expect(preview.provisionalText.isEmpty)
  }

  @Test("2.2節: 完了したら全体の確定テキストに置き換え、以後のイベントは無視する")
  func completesWithFinalText() {
    let preview = preview([
      .confirmed("明日の"), .partial("会議"), .completed("明日の会議は10時からです。"),
      .partial("遅れた暫定"), .confirmed("遅れた確定"),
    ])

    #expect(preview.confirmedText == "明日の会議は10時からです。")
    #expect(preview.provisionalText.isEmpty)
    #expect(preview.state == .completed)
  }

  @Test("REC-04: 失敗したら暫定テキストを消し、確定済みテキストは残す")
  func keepsConfirmedTextOnFailure() {
    let preview = preview([
      .confirmed("明日の"), .partial("会議"), .failed(.engineFailed), .completed("遅れた完了"),
    ])

    #expect(preview.confirmedText == "明日の")
    #expect(preview.provisionalText.isEmpty)
    #expect(preview.state == .failed(.engineFailed))
  }

  @Test("REC-06: 文字列表現に認識テキストを含めない")
  func redactsText() {
    let preview = preview([.confirmed("秘密の"), .partial("発話")])
    let outputs = [
      String(describing: preview),
      String(reflecting: preview),
      String(describing: Mirror(reflecting: preview).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密"))
      #expect(!output.contains("発話"))
    }
    #expect(String(describing: preview).contains("confirmedLength: 3"))
    #expect(String(describing: preview).contains("provisionalLength: 2"))
  }
}
