import UtterCore
import UtterPersistence

// 設定画面に出す選択肢の名前。

extension RefinementProviderChoice {
  var label: String {
    switch self {
    case .localBasic: "Local Basic（オフライン）"
    case .claude: "Claude API"
    case .chatGPT: "ChatGPT（準備中）"
    }
  }
}

extension RefinementModeSetting {
  var label: String {
    switch self {
    case .raw: "Raw（認識結果のまま）"
    case .natural: "Natural（自然な文に整える）"
    case .structured: "Structured（箇条書き・段落に整える）"
    }
  }
}

extension ShortcutTriggerMode {
  var label: String {
    switch self {
    case .toggle: "Toggle（押して開始、もう一度押して停止）"
    case .pushToTalk: "Push-to-talk（押している間だけ録音）"
    }
  }
}

extension InputMode {
  var label: String {
    switch self {
    case .instant: "Instant（停止後にまとめて入力）"
    case .realtimePreview: "Realtime Preview（HUD に途中経過を表示）"
    case .realtimeDirect: "Realtime Direct（実験機能。確定した部分から入力欄へ入力）"
    }
  }
}

extension ModelRetentionModeSetting {
  var label: String {
    switch self {
    case .powerSaving: "省電力（使うたびに解放）"
    case .balanced: "バランス（短時間保持・標準）"
    case .performance: "高速（許可とメモリの範囲で保持）"
    }
  }
}

extension RefinementStyle {
  var label: String {
    switch self {
    case .standard: "標準"
    case .concise: "簡潔（チャット）"
    case .polite: "丁寧（メール）"
    case .technical: "技術語を保持（IDE）"
    case .command: "コマンドを保護（ターミナル）"
    case .document: "段落を整形（文書）"
    }
  }
}
