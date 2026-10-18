# Phase 0 検証: 修飾キー単独ショートカットと Esc 捕捉の権限（#51）

## 目的

macOS の Accessibility API（CGEvent、EventMonitor）で以下を確認：
- 修飾キー単独（Cmd、Shift、Option、Control）のショートカット認識可否（REC-01）
- Esc キー捕捉の可否
- 権限要件（Accessibility access）

## 検証用コード

[Verification/HotkeyProbe](../Verification/HotkeyProbe/README.md)（macOS のコマンドラインツール）で、RegisterEventHotKey の登録と競合、CGEventTap / NSEvent による修飾キー単独の検出、セッション中だけの Esc 捕捉、権限の状態を確かめる。ビルド・実行手順とログの読み方は README を参照。
下記「3. 権限要件」の表は検証前の想定であり、HotkeyProbe の結果で確かめてから記録する。

## テスト環境

- OS: macOS 26 以降
- 権限: 入力監視・アクセシビリティの要否は検証項目（システム設定 > プライバシーとセキュリティ で、実行したターミナルアプリごとにオン/オフして確かめる）

## テスト項目

### 1. 修飾キー単独認識

```
テスト対象:
- Cmd キー単独
- Shift キー単独
- Option キー単独
- Control キー単独
- Cmd+Shift 等の組み合わせ

期待結果:
- Event はキー down/up で検出可能
- 権限なしでも基本検出可（ただしアプリの入力欄へのアクセスは要権限）
```

### 2. Esc キー捕捉

```
手順:
1. Esc キー押下時のイベント検出
2. システムのデフォルト動作への影響確認
3. Cmd+Esc 等との組み合わせ

期待結果:
- EventMonitor で検出可能
- 捕捉後の処理（中止 vs 継続）を制御可
```

- Push-to-talk ではトリガー（修飾キー単独・修飾キー付きの組み合わせ）を押したまま Esc を押すため、Esc にトリガーの修飾キーが付く。REC-01 の「Esc でキャンセル」を PTT でも成り立たせるには、トリガーの修飾キーを修飾キー付き Esc の判定から除く必要がある（HotkeyProbe の `session --mode ptt` で確かめる）。本番仕様として扱いを決める

### 3. 権限要件

| 機能 | 権限 | 説明 |
|------|------|------|
| CGEvent キー監視 | ✅ 不要 | Global hotkey 検出 |
| EventMonitor | ✅ 不要 | 標準許可 |
| AX Element アクセス | ❌ **必須** | 入力欄の取得・操作 |

**注意:** CGEvent での検出は権限不要だが、**入力欄へのアクセス（INS-01）には Accessibility 権限が必須**

### 4. メモリ・CPU 影響

```
計測項目:
- EventMonitor アクティブ時の CPU 使用率
- メモリ増加量
- Battery drain（1時間連続稼働）

期待結果（Phase 0 目標）:
- CPU: < 2%
- メモリ: < 5MB
- Battery: 実質的な短縮なし
```

## 実装上の注意

- Global hotkey 登録は CGEvent + EventMonitor の併用推奨（堅牢性）
- Esc キー単独は Terminal 等での用途競合に注意（ユーザー設定で変更可）
- メニューバーアプリの特性上、スクリーンセーバーアクティブ時は停止すべき

## 検証結果の記録

### テスト日: YYYY-MM-DD

macOS バージョン: / キーボード（内蔵・外付け、JIS・US）:

| テスト項目 | ターミナルアプリ | 入力監視 | アクセシビリティ | 結果 | 備考 |
|----------|------|------|------|------|------|
| Cmd 単独 | | オン/オフ | オン/オフ | ✅/❌ | |
| Shift 単独 | | オン/オフ | オン/オフ | ✅/❌ | |
| fn 単独（`modifier fn`） | | オン/オフ | オン/オフ | ✅/❌ | backend / tap |
| right-option 単独（`modifier right-option`） | | オン/オフ | オン/オフ | ✅/❌ | backend / tap |
| 通常の組み合わせ（`hotkey`） | | オン/オフ | オン/オフ | ✅/❌ | 登録結果・競合 |
| Esc: 待機中の非干渉（`session`） | | オン/オフ | オン/オフ | ✅/❌ | strategy |
| Esc: 録音中の捕捉（`session`） | | オン/オフ | オン/オフ | ✅/❌ | toggle / ptt |
| Esc キー捕捉 | | オン/オフ | オン/オフ | ✅/❌ | |
| CPU 使用率 | | | | XX% | EventMonitor 有効時 |
| メモリ増加 | | | | XXmb | |

## 次フェーズ

- ホットキーの UI カスタマイズ（Phase 1 HUD 実装）
- 権限なし時の fallback（再度権限要求）
