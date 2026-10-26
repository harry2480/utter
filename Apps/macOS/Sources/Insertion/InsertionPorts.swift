import UtterCore

// 挿入（INS-01〜07）で使う OS の機能の境界。本番は AX / NSPasteboard / CGEvent のアダプター、
// テストは Stub を渡す。どれも入力欄の値・クリップボードの中身を記録・表示しない。

/// 挿入直前の入力対象（INS-01, 7章）。値の中身は持たない。
struct FocusedInsertionTarget: Hashable, Sendable {
  /// 入力対象の識別子。録音開始時に記録した要素と同じなら、同じ値になる
  let id: InsertionTargetID
  /// 前面アプリの識別子（bundle ID）。特定できなければ `nil`
  let app: String?
  /// 入力欄がセキュア属性（パスワード欄）か
  let secureField: SensitiveSignal
}

/// フォーカス中の入力対象を調べる（INS-01）。
@MainActor
protocol InsertionTargetInspector: AnyObject {
  /// 録音開始時に呼び、その時点のフォーカス中の入力対象を記録する。取得できなければ `nil`
  func recordTarget() -> InsertionTargetID?
  /// 今のフォーカス中の入力対象。取得できなければ `nil`
  func focusedTarget() -> FocusedInsertionTarget?
  /// システムのセキュア入力（パスワード入力中など）が有効か（7章）
  func secureEventInput() -> SensitiveSignal
}

/// 入力欄の読み書き（Accessibility, INS-02, INS-05）。
@MainActor
protocol InsertionFieldAccess: AnyObject {
  /// 挿入前の値と選択範囲。読めない項目は `nil`
  func snapshot(of target: InsertionTargetID) -> FieldSnapshot
  /// 今の値。読めなければ `nil`
  func value(of target: InsertionTargetID) -> String?
  /// カーソル位置・選択範囲へ文字列を書き込む（`kAXSelectedTextAttribute`）
  func insertAtSelection(_ text: String, into target: InsertionTargetID) -> InsertionResponse
}

/// クリップボードの読み書き（INS-04, INS-06）。
@MainActor
protocol InsertionPasteboard: AnyObject {
  var changeCount: Int { get }
  /// 今の中身を退避用に読み出す
  func capture() -> PasteboardSnapshot
  /// 中身を消して、文字列と一時データの印を書き込む。成功したら `true`
  func write(_ text: String, markers: [String]) -> Bool
  /// 中身を消して、退避した内容を書き戻す。成功したら `true`
  func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

/// キーイベントの送信（CGEvent, INS-02）。Return キーを送る操作は持たない（INS-03, AC-08）。
@MainActor
protocol InsertionKeyEvents: AnyObject {
  /// Cmd+V を送る。送れたら `true`
  func sendPaste() -> Bool
  /// 文字列をキー入力として1文字ずつ送る。改行・Tab などの制御文字を含む文字列は渡さない。
  ///
  /// 各文字を送る直前に `isStillTargeting` を呼び、`false` なら残りを送らずに止める（途中でフォーカスが移った場合, INS-01）。
  func type(_ text: String, while isStillTargeting: () -> Bool) async -> InsertionResponse
}

/// 経路に必要な権限の状態（PERM-01, PERM-02）。要求はしない（オンボーディングの責務）。
@MainActor
protocol InsertionPermissions: AnyObject {
  /// Accessibility が許可済みか（`AXIsProcessTrusted`）
  func isAccessibilityTrusted() -> Bool
  /// イベントの送信が許可済みか（`CGPreflightPostEventAccess`）
  func canPostEvents() -> Bool
}

/// 経過時間と待ち時間。テストでは実際には待たずに進める。
@MainActor
protocol InsertionClock: AnyObject {
  /// 基準の時点からの経過時間
  func elapsed() -> Duration
  /// 待つ。呼び出し元のタスクが取り消されても最後まで待つ（クリップボードの復元を早めないため）
  func sleep(for duration: Duration) async
}

/// コピー可能なプレビューを表示する（INS-01〜03, AC-09）。
@MainActor
protocol InsertionPreviewPresenting: AnyObject {
  func showPreview(text: String, cause: InsertionPreviewCause)
}
