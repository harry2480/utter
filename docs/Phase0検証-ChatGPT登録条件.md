# Phase 0 検証: Sign in with ChatGPT の登録条件・制約（#50）

## 目的

OpenAI による「Sign in with ChatGPT」の以下を確認：
- アプリ開発者登録の要件・制約
- API キーの取得・管理
- レート制限（API 呼び出し数）
- 価格・費用モデル

## 確認項目

### 1. アプリ登録要件

**OpenAI Platform Dashboard での登録必須:**
- Email 確認
- Phone 番号認証（国別）
- 支払い方法（クレジットカード）
- プロジェクト情報（アプリ名、用途）

参考: https://platform.openai.com/account/api-keys

### 2. API キー管理

| 種類 | 用途 | 制限 | 注意 |
|------|------|------|------|
| Secret Key | サーバー側（本デバイス） | 月間予算設定可 | クライアント公開 NG |
| Organization | 複数プロジェクト管理 | 不要（個人利用） | - |

**実装制約:**
- API キーは Keychain（iCloud 同期なし）に保存
- ローカルデバイス限定、GitHub に含めない（.gitignore）

### 3. レート制限（2024 年時点）

| 料金プラン | 月額上限 | RPM（要求/分） | TPM（トークン/分） |
|----------|--------|-------------|-----------|
| Free | $18 | 3 | 90,000 |
| Pro | $20/月 | 60 | 1,500,000 |

**utter 想定:**
- Free プラン（個人テスト用）
- Pro プラン（実運用）

### 4. 価格・費用モデル（2024年10月）

**Claude API（Anthropic Messages API）:**
```
Input: $3/1M tokens
Output: $15/1M tokens

月額推定（utter 標準用例）:
- 日次10回、100トークン整形
- 月 300回 × 100 = 30,000 tokens
- 費用: ~$0.45/月（入力）+ $2.25/月（出力）≈ $2.7/月
```

**予算制限:**
- utter UI で月額 $5 を既定上限（AppSettings で変更可）
- 超過時は整形中止・ローカル フォールバック

## 非公開 API・悪用の禁止

**遵守事項（AI-02）:**
- ✅ 公開 API のみ使用（REST / Python SDK）
- ❌ 非公開 API 逆エンジニアリング不可
- ❌ 他社のクライアント ID 使用不可
- ❌ Rate limit 回避の自動リトライ無制限化不可

## 検証チェックリスト

- [ ] OpenAI Platform アカウント作成（Email 確認済）
- [ ] Phone 認証完了（日本）
- [ ] 支払い方法設定完了
- [ ] API キー取得・動作確認（test request）
- [ ] 月額予算上限設定確認（ダッシュボード）
- [ ] .gitignore に API キー除外設定

## 次フェーズ

- API キーの Keychain 保存実装（Phase 1）
- 月額予算超過時の UI 通知（Phase 2）
- 複数 AI プロバイダー対応（Phase 2+）
