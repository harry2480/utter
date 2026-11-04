import Observation
import SwiftUI

/// キーボードから本体アプリを開く要求（iOS-03, iAC-05）。
///
/// 要求を出すのは UIKit 側（`KeyboardViewController`）で、実際に開くのは `HostAppOpenerView`。
/// 開けたかどうかを `completion` で返し、開けなければ手動で切り替える案内を出す。
@MainActor
@Observable
final class HostAppOpenRequest {
  /// 開く URL。`HostAppOpenerView` が受け取ったら `nil` に戻す
  fileprivate var pending: URL?
  @ObservationIgnored private var completion: ((Bool) -> Void)?

  /// 本体アプリを開く。結果（開けたか）は `completion` で受け取る
  /// - Note: 前の要求が残っていたら、開けなかったものとして閉じてから置き換える
  func open(_ url: URL, completion: @escaping (Bool) -> Void) {
    finish(false)
    self.completion = completion
    pending = url
  }

  /// 開く URL を取り出す（同じ要求で二度開かない）
  fileprivate func take() -> URL? {
    defer { pending = nil }
    return pending
  }

  /// 開いた結果を返す。要求が残っていなければ何もしない
  fileprivate func finish(_ accepted: Bool) {
    guard let completion else { return }
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
      .onChange(of: request.pending) { _, _ in
        guard let url = request.take() else { return }
        openURL(url) { accepted in request.finish(accepted) }
      }
  }
}
