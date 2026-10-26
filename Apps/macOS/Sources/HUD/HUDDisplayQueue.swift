import UtterCore

/// HUD の表示・非表示の依頼を溜めて、まとめて反映する手順に変える（REC-03, AC-03）。
///
/// `HUDPanelPresenter` が依頼をその場で画面に反映せず、メインスレッドの次の処理で `flush()` するために使う。
/// 溜めている間の表示は最後の1件だけを残すが、間に非表示の依頼があれば先に隠す手順を残す
/// （隠してから出し直したときに、通知を読み上げ直し、ポインターのある画面へ置き直すため）。
struct HUDDisplayQueue {
  /// 画面に反映する手順
  enum Step: Equatable {
    case hide
    /// 表示する。`announcement` は VoiceOver へ読み上げを依頼する文言（なければ `nil`）
    case show(HUDPresentation, announcement: String?)
  }

  /// 画面に出している内容。隠していれば `nil`
  private(set) var displayed: HUDPresentation?
  private var pendingHide = false
  private var pendingShow: HUDPresentation?

  /// まだ反映していない依頼があるか
  var hasPending: Bool {
    pendingHide || pendingShow != nil
  }

  mutating func requestShow(_ presentation: HUDPresentation) {
    pendingShow = presentation
  }

  mutating func requestHide() {
    pendingHide = true
    pendingShow = nil
  }

  /// 溜めた依頼を反映する手順を返し、依頼を空にする
  mutating func flush() -> [Step] {
    var steps: [Step] = []
    if pendingHide {
      pendingHide = false
      displayed = nil
      steps.append(.hide)
    }
    if let presentation = pendingShow {
      pendingShow = nil
      // 認識テキストや段階だけが変わったときは、同じ通知を読み上げ直さない
      let announcement = presentation.announcement(after: displayed)
      displayed = presentation
      steps.append(.show(presentation, announcement: announcement))
    }
    return steps
  }
}
