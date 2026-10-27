import Foundation

/// Sign in with ChatGPT のサインイン・トークン更新の失敗（AI-06）。
///
/// 認可コード・トークン・クライアントID・サーバーが返した説明文は持たない。
public enum ChatGPTSignInError: Error, Hashable, Sendable, CaseIterable {
  /// サインインがキャンセルされた（画面を閉じた・呼び出し元の Task がキャンセルされた）
  case cancelled
  /// ブラウザでのサインインを待つ時間が上限を超えた
  case timedOut
  /// ループバックで待ち受けられない
  case listenerUnavailable
  /// システムブラウザを開けない
  case browserUnavailable
  /// 別のサインインが進行中
  case alreadyInProgress
  /// コールバックの `state` が試行と一致しない（S3）
  case stateMismatch
  /// 利用者が同意しなかった（`error=access_denied`, S3）
  case accessDenied
  /// コールバックが `access_denied` 以外のエラーを返した
  case authorizationFailed
  /// コールバックに認可コードがない・パスが違う
  case invalidCallback
  /// 初回の登録で発行済みのクライアントID が返らなかった（S3）
  case registrationIncomplete
  /// 再認可で保存済みと違うクライアントID が返った（S3）
  case clientIDMismatch
  /// コード交換が `invalid_grant` を返した。コードを捨ててやり直す（S3）
  case invalidGrant
  /// リフレッシュトークンが使えない（S7 の refresh errors）。保存済みのクライアントID でサインインし直す
  case refreshTokenUnusable
  /// `invalid_client`（S7）。クライアントの設定の誤り
  case invalidClient
  /// ID トークンを検証できない（署名・iss・aud・exp・nonce, S3）
  case invalidIDToken
  /// 再認可で、選んだアカウントと別のアカウントの ID トークンが返った（S3）
  case accountMismatch
  /// 認証サーバーがほかのエラーを返した
  case rejected
  /// 応答を解釈できない
  case invalidResponse
  /// 認証サーバーに接続できない・一時的な障害
  case networkUnavailable
  /// 認証情報を保存できない
  case storageFailed
}

/// インストール（ホスト）ごとの安定した不透明な ID（S2 の `ext_agent_host_id`）。
///
/// 最初のサインインの前に一度だけ作って保持し、サインアウトしても消さない（S6）。
/// メールアドレスや利用者 ID から作らない。認証情報ではない。
public struct ChatGPTHostID: Hashable, Sendable, Codable {
  public let rawValue: String

  /// `urn:uuid:` に UUIDv4 をつなげた値（S2 で受け付ける形式の1つ）
  public static func generate() -> ChatGPTHostID {
    ChatGPTHostID(rawValue: "urn:uuid:" + UUID().uuidString.lowercased())
  }
}

/// ChatGPT アカウントごとの登録（S3, S6）。発行済みのクライアントID と、検証済みの ID トークンのアカウントを結びつける。
///
/// サインアウトしても消さず、次のサインインで同じクライアントID を使う（S6）。
public struct ChatGPTRegistration: Hashable, Sendable, Codable {
  /// 発行済みのクライアントID（`oaiapp_…`）。表示・ログに出さない
  let clientID: String
  /// 検証済みの ID トークンの `sub`
  let subject: String
  /// ID トークンのメールアドレス。設定画面でアカウントを示すためと、`login_hint` に使う
  public let email: String?
}

/// 保存するトークン（S3, S8）。アクセストークン・リフレッシュトークン・ID トークンは Keychain にだけ置く。
struct ChatGPTTokens: Hashable, Sendable, Codable {
  let accessToken: String
  let refreshToken: String
  /// 検証済みの ID トークン。次のサインインの `id_token_hint` に使う（S6）
  let idToken: String
  /// アクセストークンの期限
  let expiresAt: Date
  /// 付与されたスコープ
  let scopes: [String]

  /// プラン利用の許可（`chatgpt.tokens.use.direct`）が付与されているか（S3, S7）
  var allowsPlanUsage: Bool {
    scopes.contains(ChatGPTSignIn.planUsageScope)
  }
}

/// このインストールの Sign in with ChatGPT の記録。保存は `ChatGPTAccountStore` が Keychain に行う。
///
/// 1つのアカウントだけを扱う（アカウントの切り替えは後続）。サインアウトではトークンだけを消し、
/// 登録（クライアントID）とホスト ID は残す（S6）。
public struct ChatGPTAccountRecord: Hashable, Sendable, Codable {
  public internal(set) var hostID: ChatGPTHostID
  public internal(set) var registration: ChatGPTRegistration?
  var tokens: ChatGPTTokens?
  /// 初回のサインイン後の説明（「You're using your ChatGPT plan」, S11）を表示したか。一度だけ出す
  public var hasShownPlanWelcome = false
}

/// `ChatGPTAccountRecord` の保存先（AC-12）。本番は macOS アプリの Keychain 実装（本デバイス限定・iCloud 同期なし）、
/// テストは `StubChatGPTAccountStore` を使う。App Group には置かない。
///
/// 実装は記録の中身（トークン・クライアントID）をログ・エラーに出さない。
public protocol ChatGPTAccountStore: Sendable {
  /// 保存済みの記録。保存されていなければ `nil`
  func load() throws(ChatGPTAccountStoreError) -> ChatGPTAccountRecord?
  /// 記録を保存する。保存済みの記録があれば置き換える
  func save(_ record: ChatGPTAccountRecord) throws(ChatGPTAccountStoreError)
}

/// 記録の保存先の失敗。記録の中身は持たない。
public enum ChatGPTAccountStoreError: Error, Hashable, Sendable {
  /// 保存先の操作に失敗した。`code` は保存先の状態コード（Keychain の `OSStatus` など）
  case operationFailed(code: Int32)
  /// 保存されている値を記録として読めない
  case invalidStoredData
}

// トークン・クライアントID・メールアドレスをログに出さないよう、文字列表現とリフレクションでは伏せる。

extension ChatGPTTokens: CustomStringConvertible, CustomReflectable {
  var description: String { "ChatGPTTokens(<redacted>, planUsage: \(allowsPlanUsage))" }
  var customMirror: Mirror { Mirror(self, children: ["allowsPlanUsage": allowsPlanUsage]) }
}

extension ChatGPTRegistration: CustomStringConvertible, CustomReflectable {
  public var description: String { "ChatGPTRegistration(<redacted>)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

extension ChatGPTAccountRecord: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "ChatGPTAccountRecord(registered: \(registration != nil), signedIn: \(tokens != nil))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["registered": registration != nil, "signedIn": tokens != nil])
  }
}
