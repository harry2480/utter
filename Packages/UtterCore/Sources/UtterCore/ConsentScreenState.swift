/// クラウド送信の同意の画面の状態（AC-06, AI-04, CTX-03）。
///
/// 送信先・送信内容ごとの行を並べ、行ごとに同意・撤回する。表示と操作の判定だけを持ち、保存は持たない
/// （保存は UtterPersistence の `ConsentSettingsController`、画面の表示は Apps）。
public struct ConsentScreenState: Hashable, Sendable {
  /// 画面に常に表示する同意対象。送信する機能がある対象に限る。
  ///
  /// 送信する機能がまだないもの（ChatGPT への整形、別のクラウド AI への自動切り替え、クラウド音声認識、
  /// Edit の選択テキスト）は同意を求めない。それらは機能を実装するときにここへ加える。
  /// 同意済みの状態を読んだ場合だけ、撤回できるよう行を表示する
  public static let presentedScopes: [ConsentScope] = [.transmission(.textRefinement(.claude))]

  /// 画面全体の説明（7章, CTX-03）
  public static let summary =
    "音声は原則この端末の中で処理します。クラウドへは、同意した送信先へ、同意した内容だけを送ります。同意していない送信先へは何も送りません。"

  /// 同意の状態。送信の可否の判定（`ConsentState.allows`）には、操作した後のこの値を使う
  public private(set) var consent: ConsentState

  public init(consent: ConsentState = ConsentState()) {
    self.consent = consent
  }

  /// 表示する行。`presentedScopes` の順に並べ、その後ろに同意済みのほかの対象を並べる
  public var rows: [ConsentRow] {
    let scopes =
      Self.presentedScopes
      + ConsentScope.allCases.filter { !Self.presentedScopes.contains($0) && consent.isGranted($0) }
    return scopes.map { ConsentRow(scope: $0, status: consent.status(of: $0)) }
  }

  /// 同意する（`true`）か撤回する（`false`）。撤回は次の送信の判定から反映される
  public mutating func setGranted(_ granted: Bool, for scope: ConsentScope) {
    if granted {
      consent.grant(scope)
    } else {
      consent.revoke(scope)
    }
  }
}

/// 同意の画面の1行。
public struct ConsentRow: Hashable, Sendable, Identifiable {
  public let scope: ConsentScope
  public let status: ConsentStatus
  public let disclosure: ConsentDisclosure

  public init(scope: ConsentScope, status: ConsentStatus) {
    self.scope = scope
    self.status = status
    self.disclosure = ConsentDisclosure(scope: scope)
  }

  public var id: ConsentScope { scope }

  /// 同意しているか（切り替えの表示）
  public var isGranted: Bool { status == .granted }

  /// 状態の表示
  public var statusLabel: String {
    switch status {
    case .notGranted: "未同意"
    case .granted: "同意済み"
    case .revoked: "撤回済み"
    }
  }
}
