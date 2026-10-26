import Foundation
import UIKit
import UniformTypeIdentifiers
import UtterPersistence

/// 救済画面のコピー先（iOS-07）。他の端末へ同期せず（`localOnly`）、期限つきでクリップボードへ置く。
struct PasteboardCopier: SharedResultTextCopier {
  /// クリップボードに残す時間（仮置き: 共有結果の有効期限の既定値と同じ10分, iOS-IPC-02）
  static let lifetime = SharedResultConfiguration.defaultTimeToLive

  func copy(_ text: String) async {
    await MainActor.run {
      let seconds = Double(Self.lifetime.components.seconds)
      UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: text]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)])
    }
  }
}
