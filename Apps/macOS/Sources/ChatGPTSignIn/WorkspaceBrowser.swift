import AppKit
import UtterAI

/// 既定のブラウザ（システムブラウザ）で認可要求を開く `ChatGPTBrowserOpening`（S3, #50）。
///
/// アプリ内の Web ビューでは開かない（利用者の ChatGPT のパスワードや Cookie をアプリが扱わない）。
/// URL には ID トークン（`id_token_hint`）が入りうるため、ログに出さない
struct WorkspaceBrowser: ChatGPTBrowserOpening {
  func open(_ url: URL) async -> Bool {
    await MainActor.run { NSWorkspace.shared.open(url) }
  }
}
