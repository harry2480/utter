import Observation
import SwiftUI

/// キーボードから本体アプリを開く要求（iOS-03, iAC-05）。
///
/// 要求を出すのは UIKit 側（`KeyboardViewController`）で、実際に開くのは `HostAppOpenerView`。
/// 開けたかどうかを `completion` で返し、開けなければ手動で切り替える案内を出す。
///
/// 要求には番号を振る。`OpenURLAction` の結果は後から届くため、
/// - 同じ URL を続けて押しても別の要求として見分けられる（URL だけでは変化を見分けられない）
/// - 前の要求の結果が遅れて届いても、次の要求の結果として扱わない
@MainActor
@Observable
final class HostAppOpenRequest {
  /// 開く要求。番号で見分ける
  fileprivate struct Pending {
    let id: Int
    let url: URL
  }

  /// まだ `HostAppOpenerView` が受け取っていない要求。受け取ったら `nil` に戻す
  fileprivate private(set) var pending: Pending?
  /// 結果を待っている要求の番号。待っていなければ `nil`
  @ObservationIgnored private var waitingID: Int?
  @ObservationIgnored private var completion: ((Bool) -> Void)?
  @ObservationIgnored private var lastID = 0

  /// 本体アプリを開く。結果（開けたか）は `completion` で受け取る
  /// - Note: 結果を待っている要求が残っていたら、開けなかったものとして閉じてから置き換える
  func open(_ url: URL, completion: @escaping (Bool) -> Void) {
    finish(waitingID, accepted: false)
    lastID += 1
    waitingID = lastID
    self.completion = completion
    pending = Pending(id: lastID, url: url)
  }

  /// 開く要求を取り出す（同じ要求で二度開かない）
  fileprivate func take() -> Pending? {
    defer { pending = nil }
    return pending
  }

  /// 開いた結果を返す。結果を待っている要求と番号が違えば（遅れて届いた前の要求の結果）捨てる
  fileprivate func finish(_ id: Int?, accepted: Bool) {
    guard let id, id == waitingID, let completion else { return }
    waitingID = nil
    self.completion = nil
    completion(accepted)
  }
}

/// 本体アプリを開くためだけの、大きさを持たない画面（iOS-03, iAC-05）。
///
/// キーボード拡張から本体アプリを開くのは公開 API の `OpenURLAction`（`@Environment(\.openURL)`）で行う。
/// `NSExtensionContext.open(_:)` は、キーボード拡張では開けないことがある（#247, #53）。
/// 非公開 API・responder chain をたどって探した `openURL`・他アプリの URL スキームは使わない（iOS-03）。
///
/// キーボードの見た目を変えないため、大きさを持たず、触れても反応しない画面として重ねる。
struct HostAppOpenerView: View {
  let request: HostAppOpenRequest
  @Environment(\.openURL) private var openURL

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
      // 要求の番号で見る。URL で見ると、同じ URL を続けて押したときに変化を見分けられない
      .onChange(of: request.pending?.id) { _, _ in
        guard let pending = request.take() else { return }
        openURL(pending.url) { accepted in
          request.finish(pending.id, accepted: accepted)
        }
      }
  }
}
