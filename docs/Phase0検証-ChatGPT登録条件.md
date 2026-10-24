# Phase 0 検証: Sign in with ChatGPT の登録条件・制約（#50）

## 目的

要件定義 11章の検証事項「Sign in with ChatGPT の最新 OSS 登録条件、対応モデル、OAuth・Responses API 制約」を、OpenAI の一次情報で確認する。
OSS の配布アプリ（utter）が、他製品のクライアントID の流用や非公開エンドポイントに頼らずに（AI-02）Sign in with ChatGPT を正式に使えるかを判断する材料を残す。

- 不成立時の方針（11章）：MVP から外し、OpenAI API キー方式を代替とする
- 対象外：ChatGPT プロバイダーの実装（結論を受けて別 Issue）
- 認証情報（トークン・クライアントID の実値・API キー）はこの文書にも Issue にも書かない

## 調査の方法

- 確認日：**2026-10-18**（文書全体で1つ。下の出典表のすべての出典をこの日に確認した。再確認したときは、すべての出典を確認し直してこの日付を書き換える）
- 一次情報だけを根拠にする。報道記事・第三者のブログ・第三者のライブラリは根拠にしない
- Codex CLI など OpenAI 公式クライアントの実装（クライアントID・エンドポイント）は根拠にしない。公式クライアントが使っていることは、他のアプリが使ってよいことを意味しない
- 「事実」は出典の記述をそのまま要約したもの、「推測」は出典から utter に当てはめた解釈として分けて書く

## 出典

| ID | 出典 | URL | 取得方法 |
|---|---|---|---|
| S1 | Sign in with ChatGPT Quickstart | https://developers.openai.com/siwc/quickstart | 本文を取得 |
| S2 | ChatGPT plan usage — Overview | https://developers.openai.com/siwc/token-sharing-open-source | 本文を取得 |
| S3 | Registration and sign-in | https://developers.openai.com/siwc/token-sharing-open-source/sign-in | 本文を取得 |
| S4 | Models and inference | https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference | 本文を取得 |
| S5 | Preview limitations | https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations | 本文を取得 |
| S6 | Accounts and sessions | https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions | 本文を取得 |
| S7 | Errors and recovery | https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery | 本文を取得 |
| S8 | Token reference | https://developers.openai.com/siwc/token-sharing-open-source/token-reference | 本文を取得 |
| S9 | Request a client ID | https://developers.openai.com/siwc/request-client-id | 本文を取得 |
| S10 | Cookbook: Integrating Sign in with ChatGPT in your Opensource App | https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt | 本文を取得 |
| S11 | UI/UX guidelines | https://developers.openai.com/siwc/ui-ux-guidelines | 一括版 https://developers.openai.com/siwc/llms-full.txt で取得（S1〜S10 も一括版と照合） |
| S12 | openai/sign-in-with-chatgpt-devkit（README・LICENSE） | https://github.com/openai/sign-in-with-chatgpt-devkit | 本文を取得 |
| S13 | Sign in with ChatGPT Terms | https://openai.com/policies/sign-in-with-chatgpt-terms/ | **本文の直接取得は HTTP 403。検索エンジンの抜粋でのみ確認** |
| S14 | Service terms（15節） | https://openai.com/policies/service-terms/ | **同上（抜粋でのみ確認）** |
| S15 | Help Center: Using your ChatGPT plan in other apps and sites | https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites | **同上（抜粋でのみ確認）** |

S13〜S15 は抜粋しか確認できていない。判定前に人がブラウザで原文を読む（「人が行う確認」参照）。

## 結果（確認できた事実）

### 1. 提供形態と、OSS が使える登録制度

Sign in with ChatGPT には3つの使い方がある [S1]。

| 使い方 | 内容 | 利用できる相手 [S1] |
|---|---|---|
| Website | 自社サービスへの ChatGPT アカウントでのサインイン（ID 連携のみ） | 限定トライアル中の選ばれた商用パートナー |
| ChatGPT plugin | プラグインのコネクタ認可の中で使う | 同上 |
| **ChatGPT plan usage（OSS 向け）** | 利用者の ChatGPT プランで AI リクエスト（Responses API）を実行する | 「all open-source partners and selected private clients」 |

- Website / plugin 向けのクライアントID は申請制で、現在はウェイトリスト（関心フォーム）[S9]
- OSS 向けの plan usage について、出典が書いているのは「available to all open-source partners and selected private clients」[S1] と、有料またはリモートでホストするアプリは関心フォームへ、という案内 [S2][S10] だけである。**OSS 向けの事前申請の手続きは出典に書かれていない**（「申請は不要」とも明記されていない）
- 登録の仕組みとしては、最初のサインイン時に **動的登録**（`client_id=dynamic_agent_client` を入口として送る）を行い、利用者ごと・ワークスペースごとにクライアントID（`oaiapp_…` 形式）が発行される。クライアントシークレットも、パートナー用 API キーも不要 [S1][S2][S3]
- 対象は「open-source and locally hosted apps」。**有料アプリ、またはリモートでホストするアプリ**は、利用者に提供する前に関心フォーム（https://openai.com/form/sign-in-with-chatgpt-interest/ ）でウェイトリストに入る [S2][S10]
- Cookbook はローンチ時の対象を「open-source projects, personal projects that run locally, and selected private apps」と書く [S10]
- 出典の範囲では「OSS」の定義（ライセンスの種類、公開リポジトリの要否）や、OpenAI による審査の手順は書かれていない [S1][S2][S10]
- Cookbook の題材は、コピーした文章を書き換えて別アプリへ貼り付ける OSS のデスクトップアプリ（Paste Perfect）。公式 DevKit にネイティブ macOS アプリの例として収録されている [S10][S12]
- 「Preview limitations」というページ名のとおり、制約はプレビュー段階のものとして示されている [S5]

### 2. OAuth（PKCE）の要件

[S3] の手順。値は公開ドキュメントに載っているものだけを書く。

| 項目 | 内容 |
|---|---|
| 認可エンドポイント | `https://auth.openai.com/api/accounts/authorize`（システムブラウザで開く） |
| トークンエンドポイント | `https://auth.openai.com/api/accounts/oauth/token` |
| 初回 | `client_id=dynamic_agent_client`、`agent_name_hint`（アプリ名。全インストールで統一）、`ext_agent_host_id`（必須）を送る。コールバックで発行済みクライアントID が返る |
| 2回目以降 | 保存した発行済みクライアントID を使う。`agent_name_hint` は送らない。`ext_agent_host_id` は毎回同じ値を送る [S6]。`id_token_hint` / `login_hint` を送れる |
| `ext_agent_host_id` | ホスト（インストール）ごとの安定した不透明 ID。`urn:ietf:params:oauth:jwk-thumbprint:…`（推奨）、`urn:uuid:…`（UUIDv4）、`did:key:…` のいずれか。メールやユーザー ID は使わない。認証情報ではない [S2] |
| PKCE | `code_challenge_method=S256`。チャレンジは検証子の SHA-256 を base64url（パディングなし） |
| `state` / `nonce` | 試行ごとに新しい乱数 |
| `scope` | ID：`openid profile email`。プラン利用：`offline_access resource.invoke chatgpt.tokens.use.direct` |
| `resource` | `https://api.openai.com/v1`（認可要求とコード交換の両方） |
| リダイレクト URI | `http://127.0.0.1:<port>/auth/callback` の HTTP ループバック。ブラウザを開く前にリスナーを起動する。変えてよいのはポートだけで、`localhost` に置き換えない |
| コード交換 | `client_id`・`code`・`code_verifier`・同じ `redirect_uri`・同じ `resource` をフォーム形式で POST。シークレット不要 |
| ID トークン検証 | 署名（公開 JWKS）・`iss`・`aud`（発行済みクライアントID）・`exp`・`nonce` を検証し、`sub` をアカウント識別に使う |
| プラン利用の許可確認 | 有効な ID トークンだけではプラン利用は許可されていない。付与スコープに `chatgpt.tokens.use.direct` があるかを確認する。ない場合はサインインを保持し、プラン利用を無効として扱う [S3][S7] |
| トークン寿命 | アクセストークン1時間（`expires_in: 3600`）。リフレッシュトークン30日で、更新のたびに新しい30日分のトークンに入れ替わる [S8] |
| 保存 | 保護されたローカル領域に保存し、ソース管理・ログ・解析・サポート記録に出さない [S3][S6] |
| サインアウト | `revocation_endpoint` でリフレッシュトークンを失効させる。利用者が ChatGPT の設定で接続を外しても、アプリへの通知はない [S6][S7] |

### 3. 呼べる API・対応モデル・Responses API の制約

- 推論は公開の Responses API（`POST https://api.openai.com/v1/responses`）に、アクセストークンを `Authorization: Bearer` で送る。ChatGPT の `backend-api` 系エンドポイントには送らないこと、と明記されている [S4]
- モデル一覧は同じトークンで `GET https://api.openai.com/v1/models` を呼び、`visibility` が `"list"` のものだけを表示する。対応モデルの固定の一覧は公開されておらず、「サインインしたアカウントで使えるモデル」を使う [S4]
- 必須：`store: false`、`stream: true`。`response.completed` を受け取るまでを成功としない [S4][S5]
- 送ってはいけないフィールド：`background`、`conversation`、`max_output_tokens`、`max_tool_calls`、`metadata`、`moderation`、`multi_agent`、`prompt`、`prompt_cache_retention`、`safety_identifier`、`temperature`、`top_logprobs`、`top_p`、`truncation`、`user` [S5]
- `previous_response_id` は使わず、必要な履歴を毎回 `input` に入れる。`role: "system"` の message 項目は拒否されるため、`instructions` か developer メッセージを使う [S5]
- 非対応ツール：画像生成、file search、Code Interpreter、computer use、ホスト型 MCP/コネクタ、`tool_search` [S5]
- 入力：テキスト・画像・ファイルはモデルが対応していれば可。**音声・動画入力、Files アップロード API、文字起こし API は非対応** [S5]
- 非対応の入力・ツール・モデルを送ると `subscription_sharing_unsupported_capability`（400）、対象外のルートは `subscription_sharing_route_not_supported`（403）[S7]

### 4. 料金の扱い

- 適格な Responses API リクエストは、**利用者の ChatGPT プランの利用枠、または利用者が許可した ChatGPT クレジット**で処理される。開発者の API 課金ではない [S1][S10]
- 対象プランは Plus と Pro と書かれている [S1][S10]。Help Center の抜粋では Go を含める記述もあり、出典間で食い違う [S15]（原文未確認）
- Plus では5時間の利用上限がプラン利用する全アプリで共有され、アプリごとの別枠はない。Pro には5時間上限がない [S6]
- 利用者は ChatGPT の設定（https://chatgpt.com/settings/usage ）でアプリごとの利用可否や上限を管理できる [S6][S11]。上限が「週ごと」で「10%〜100%」で設定できることは、S6 の画面例の説明文（イラストの注記）にしか書かれていないため、仕様としての確度は低い
- 上限到達は `subscription_sharing_usage_limit_exceeded`（429。ストリームの途中で `response.failed` として届くこともある）、不適格は `subscription_sharing_user_not_eligible`（403）[S4][S7]
- OpenAI は別の課金経路へ黙って切り替えない。プラン利用ができないときは「利用者自身の API キーなど別の課金経路を設定する」選択肢を明示的に示すよう案内されている [S7]

### 5. 利用条件（規約）

S13・S14 は抜粋でのみ確認。原文の確認が必要。

- Service terms は、Sign in with ChatGPT を使う場合に Sign in with ChatGPT Terms が適用されると定める [S14]
- Sign in with ChatGPT Terms の抜粋で読めた要点 [S13]
  - トークンは OpenAI が提供するサインインフローでのみ取得し、利用者が許可した範囲で使う
  - ChatGPT のパスワードやセッション Cookie を利用者に求めない
  - トークンを永続保存するのは利用者の管理下のローカルに限る
  - プラン利用は、接続したそのアプリのためだけに使う。バックグラウンド利用には明示の同意が必要
  - プラン利用やトークンのプール・譲渡・転売・共有、複数アカウントでの上限回避を禁止
  - 違反やセキュリティ上のリスクがあれば、OpenAI はアプリのアクセスを停止できる
- Cookbook は、配布前に OpenAI の規約とポリシー（https://openai.com/policies/ ）を確認するよう求めている [S10]
- ボタン文言は「Continue with ChatGPT」、初回サインイン後の説明、「Using ChatGPT plan」の表示、「Manage usage」リンクなど UI/UX ガイドラインがある [S11]

### 6. 公式 DevKit のライセンス

- DevKit は「open-source apps that run on a user's own machine」向けで、Node.js SDK と React コンポーネントを提供する。Swift 用の SDK はない [S12]
- OpenAI が書いたコードは **Sign-in with ChatGPT DevKit Noncommercial License v1.0**。非商用目的に限って利用・再配布でき、改変物も同じライセンスで配布しなければならない [S12]
- ライセンス本文は、インターフェース越しに呼び出したり通信したりするだけの独立したソフトウェアは改変物に当たらないと定義している [S12]

## utter への当てはめ（推測を含む）

| 論点 | 判断 | 根拠と、推測であることの明示 |
|---|---|---|
| 正式な登録制度があるか | **ある見込み（OSS 向け動的登録）** | 事実：OSS 向けに動的登録の手順が公開されており [S2][S3]、plan usage は「all open-source partners」が使えると書かれている [S1]。申請が必要と案内されているのは有料・リモートの場合だけ [S2][S10]。推測：ここから、OSS かつローカル実行なら事前申請なしで使えると読める（出典に「申請不要」とは明記されていない）。utter は Apache-2.0 の OSS（ライセンス・依存関係.md）で、利用者の Mac / iPhone 上で動くため、対象に当たると読める。無料で配布するかは未確定で、結論の条件1で担保する。「OSS」「open-source partners」の定義も書かれていないため、この読みは人が確認する |
| 他製品のクライアントID の流用 | **不要** | 事実：`dynamic_agent_client` は公開ドキュメントが全 OSS アプリに示す登録の入口で、実際に使うクライアントID は utter の利用者ごとに発行される [S3]。Codex 等のクライアントID は一切使わない |
| 非公開エンドポイントへの依存 | **不要** | 事実：認可・トークン・Responses・Models のエンドポイントはすべて公開ドキュメントに載っている [S3][S4]。`backend-api` は使用禁止と明記 [S4] |
| 文章整形（AI-02）に使えるか | **使える見込み** | 事実：テキスト入力と `instructions` は使える。STT 用途（音声入力・文字起こし API）は非対応 [S5] で、AI-02 の「STT ではなく整形に使う」と一致する。推測：`temperature` と `max_output_tokens` を指定できないため、出力長の上限は utter 側で担保する必要がある（受信中に打ち切る。「実装 Issue へ引き継ぐ制約」参照） |
| 料金 | **利用者の ChatGPT プラン** | 事実：開発者の API 課金ではない [S1][S10]。推測：Free プランの利用者は使えないため、API キー方式も並行して必要 |
| 費用制御（AI-05）との関係 | 費用推定は不要 | AI-05 の費用推定は Claude のトークン使用量が対象で、プラン利用には当てはまらない。プラン利用の利用状況は ChatGPT 側の設定（Manage usage）へのリンクで示す [S6][S11] |
| macOS の実装 | 成立する見込み | 事実：ループバック（`127.0.0.1`）でコールバックを受け、システムブラウザで認可する [S3]。推測：utter の macOS 版は App Sandbox を使わない方針（ビルド・配布規約）のため、ループバックで待ち受けることに追加の権限は要らないと見込む。実機で未確認 |
| iOS の実装 | **未確認** | 事実：公開ドキュメントにモバイル向けの手順はなく、HTTP ループバックのリダイレクトのみが記載されている [S3]。推測：`ASWebAuthenticationSession` はカスタムスキームか https のコールバックを前提とするため、iOS で同じ流れを取れるかは別途検証が要る。検証用の仮説（推測・未確認）：`ASWebAuthenticationSession` の表示中はアプリが前面にあるため、アプリ内で `127.0.0.1` を待ち受けておけば、リダイレクトをループバックで受けられる可能性がある。iOS はループバックで受けられなければ API キー方式とする |
| DevKit コードの利用 | **取り込まない** | 事実：DevKit は非商用ライセンスで、改変物も同じライセンスになる [S12]。推測：Apache-2.0 の utter に DevKit のコードを含めると両立しない可能性が高い。公開ドキュメントのプロトコルに沿って Swift で独自に実装する |
| プライバシー規約との整合 | 整合する | 事実：トークンを保護領域に保存し、ログに出さない [S3][S6]、利用者の管理下のローカルに保存 [S13]。utter の Keychain（本デバイス限定）保存・ログ非出力の方針と一致する |
| Keyboard Extension | 対象外 | iAC-08 によりキーボード拡張にはトークンを持たせない。本体アプリだけがサインインと推論を行う |

## 結論の案

**推奨：成立（条件つき、かつ規約原文と対象範囲の確認が済むまで暫定）。Sign in with ChatGPT を MVP に残し、OpenAI API キー方式も代替として並べる。**

- 確認できた事実：OSS かつローカル実行のアプリ向けに、公式の動的登録の流れが公開されており、公開エンドポイントと Responses API だけで完結する。他製品のクライアントID も非公開エンドポイントも必要ない [S2][S3][S4]。plan usage は「all open-source partners」が使えると書かれ、申請が案内されているのは有料・リモートの場合だけ [S1][S2][S10]
- 推測にもとづく部分：OSS かつローカル実行なら事前申請なしで使えること（出典に「申請不要」とは明記されていない）、utter がこの「open-source and locally hosted apps」に当たること、規約の原文にこの読みと矛盾する条件がないこと、iOS でループバックのコールバックが取れること。これらのどれかが崩れた場合は、OpenAI への確認か申請が済むまで、または不成立として扱う
- 条件
  1. utter が無料で、かつ利用者の端末上でだけ動く（リモートでホストしない）間に限る。有料化とリモートホストのどちらか一方にでも当たる場合は、関心フォームで申請し、承認されるまで提供しない [S2][S10]
  2. Free プランの利用者や、プラン利用を許可しなかった利用者のために、OpenAI API キー方式を別の選択肢として用意する（黙って切り替えない）[S7]
  3. iOS は検証が済むまで API キー方式のみとし、Sign in with ChatGPT は macOS から始める
  4. DevKit のコードは取り込まず、独自に実装する [S12]
- 不成立と判定する場合（規約原文で OSS の配布アプリが対象外と読める等）は、11章どおり Sign in with ChatGPT を MVP から外し、OpenAI API キー方式を代替とする

### 判定（人が記入）

| 項目 | 記入欄 |
|---|---|
| 判定（成立／不成立） | |
| 判定日 | |
| 判定者 | |
| 規約原文（S13・S14・S15）の確認結果 | |
| 備考 | |

## 人が行う確認・手続き

- [ ] S13（Sign in with ChatGPT Terms）・S14（Service terms 15節）・S15（Help Center）の原文をブラウザで読み、抜粋と相違がないか、OSS の配布アプリを対象外とする条件がないかを確認する
- [ ] 「open-source partners」に utter が当たるかに疑問が残る場合、関心フォーム（https://openai.com/form/sign-in-with-chatgpt-interest/ ）等で OpenAI に確認する。申請は開発者本人のアカウントで行う
- [ ] 将来、有料化やリモートホストをする場合は、提供前に関心フォームで申請する
- [ ] 判定欄を記入する
- [ ] 成立（条件つき）と判定した場合：要件定義を更新する Issue を作る。OpenAI API キー方式を併記する箇所（1章、3章の技術スタック表、AI-01、AC-05）と、iOS の当面の扱い（検証が済むまで API キー方式のみ）を書く箇所（12章の iOS 技術スタック表など）
- [ ] 不成立と判定した場合：要件定義内の「Sign in with ChatGPT」「ChatGPT」の全出現箇所（1章、3章の技術スタック表、AI-01、AI-02、AC-05、10章 Phase 2、11章、12章の iOS 技術スタック表、iAC-10）を API キー方式に書き換える Issue を作る

## 実装 Issue へ引き継ぐ制約（成立と判定した場合）

- 認可はシステムブラウザ＋ループバック（`127.0.0.1`、パスは `/auth/callback` 固定、ポートのみ可変）。PKCE は S256、`state` と `nonce` は試行ごとに生成する
- 初回は `dynamic_agent_client` で登録し、発行されたクライアントID を ChatGPT アカウントごとに保存する。`ext_agent_host_id` はインストールごとに一度生成して保持する
- アクセストークン・リフレッシュトークン・ID トークンは Keychain（本デバイス限定、iCloud 同期なし）に保存し、OSLog やエラーメッセージに出さない。App Group に置かない
- リフレッシュトークンは更新のたびに入れ替わるため、同じアカウントの更新を直列化する [S6]
- 推論は `POST /v1/responses` に `store: false`・`stream: true`。`temperature`・`max_output_tokens` 等を送らない。整形指示は `instructions` に入れる。`response.completed` まで受け取ってから応答検証（4.1節）に渡す
- `max_output_tokens` を送れないため、出力長の上限はクライアント側で設ける。受信中の累計文字数が STT 結果に対する上限（4.1節の文字数比。閾値は Phase 2 で決める）を超えた時点、または全体のタイムアウトに達した時点でストリームを打ち切り、検証失敗またはタイムアウトとして Local Basic または Raw へ退避する（4.1節、AI-06）
- エラーは S7 の表に沿って、AI-06 の分類（タイムアウト、認証失効、利用枠不足、予算超過、ネットワーク切断）に対応づける。整形はどの場合も Local Basic へ退避する（4.1節）

| S7 のエラー | 状況 | 対応 | AI-06 の分類 |
|---|---|---|---|
| 401 `subscription_sharing_invalid_user` | 利用者の認証を確認できない | 失効が確定したら利用者に再サインインを求める | 認証失効 |
| リフレッシュ時の `invalid_grant`・`invalid_refresh_token`・`token_expired`・`refresh_token_expired`・`refresh_token_invalidated`・`refresh_token_reused` | リフレッシュトークンが使えない | 使えないトークンを消し、保存済みのクライアントID で OAuth をやり直す | 認証失効 |
| 403 `subscription_sharing_user_not_eligible` | 利用者・ワークスペース・ポリシーの点で使えない | 理由を表示する。同じリクエストも OAuth も繰り返さない | 利用枠不足（プラン非対象） |
| 403 `subscription_sharing_route_not_supported` ほか、`chatpass_v2_*` | ルートや許可の設定の誤り | 同じリクエストを繰り返さず、実装を直す | 認証失効とは分ける（設定の不具合） |
| 429 `subscription_sharing_usage_limit_exceeded` | 利用上限に到達 | プラン利用の新しいリクエストを止め、Manage usage へ案内する。回復時刻を推測しない | 利用枠不足 |
| 503 `subscription_sharing_usage_unavailable`・`subscription_sharing_user_unavailable` | 一時的に確認できない | 認証情報を残し、回数を区切ってリトライする | ネットワーク切断に準じる一時障害 |
| 400 `subscription_sharing_unsupported_capability` | 非対応の入力・ツール・モデル | 同じ本文を再送しない。送ったフィールドを直す | 実装の不具合（分類外として記録） |

- API キー方式など別のクラウド送信先へは自動で切り替えない（AI-04、S7）
- UI は「Continue with ChatGPT」ボタン、「Using ChatGPT plan」表示、「Manage usage」リンク（https://chatgpt.com/settings/usage ）を UI/UX ガイドラインに沿って用意する [S11]
- クラウド送信の同意（AC-06）と CTX-03（送るのはスタイル区分と辞書語のみ）はプラン利用でも同じく適用する
- AI-02 に従い、リリース前に本書の出典を再確認し、確認日を更新する

## 付記: OpenAI API キー方式の先行実装（#58）

11章の代替（OpenAI API キー方式）を、判定待ちのまま既定で無効な形で先行実装した（`Packages/UtterAI` の `OpenAIProvider`）。アプリからは組み立てておらず、判定が不成立・不要になったら `OpenAIProvider.swift`・`HTTPStreamingTransport.swift` と、そのテストを消せば外せる。上の出典表（S1〜S15）とは別に、下の出典を **2026-10-24** に確認した。

- 送信先は `https://api.openai.com/v1/responses` に限る（それ以外のホストは設定の時点で拒否する）。認証は利用者自身の API キーを `Authorization: Bearer` で送る。他製品のクライアントID・非公開エンドポイントは使わない（AI-02）
- プラン利用（3節）の制約とそろえ、`store: false`・`stream: true` で送り、`response.completed` まで届いた応答だけを使う。整形指示は `instructions` に入れる。API キー方式では `max_output_tokens` を送れるため送る（プラン利用では送らない）
- 受信量の上限（本文のバイト数）と、整形結果の文字数の上限（発話の文字数 × 4.1節の文字数比の上限。短い発話には下限を設ける）を超えたら、残りを受信せずに打ち切って退避する。上限の値は暫定で、Phase 2 で決める
- エラーは HTTP ステータスと `error.code` で AI-06 に対応づける。ストリームの途中で届いた失敗（`response.failed`・`error`）は課金されている可能性があるため、利用枠・認証の code でも予約を取り消す分類（利用枠不足・認証失効）にせず、見込み費用で予算に記録する（AI-04, AI-05）
- 同意は Sign in with ChatGPT と同じ送信先（`CloudAIProviderKind.chatGPT`）として確認する。どちらも OpenAI へ送るため。ただし API キー方式はトークン課金なので、`RefinementRouter` に予算を必ず渡す
- モデル名と単価はコードに固定しない（AI-05, AI-07）。設定の初期値の候補は **仮置き** で、採用時に公式の料金表で確認し直す

| 項目 | 仮置きの値 | 出典 |
|---|---|---|
| 整形用モデルの候補（低遅延の小型モデル, AI-07） | `gpt-5.4-nano`（ほかに `gpt-5-nano`・`gpt-5-mini` など） | OpenAI API Pricing https://developers.openai.com/api/docs/pricing （本文を取得） |
| 単価（100万トークンあたり、Standard） | `gpt-5.4-nano` 入力 $0.20 / 出力 $1.25、`gpt-5-nano` 入力 $0.05 / 出力 $0.40、`gpt-5-mini` 入力 $0.25 / 出力 $2.00 | 同上 |
| ストリームのイベント名 | `response.output_text.delta`・`response.completed`・`response.incomplete`・`response.failed`・`error`・`response.refusal.delta` | Streaming API responses https://developers.openai.com/api/docs/guides/streaming-responses （本文を取得。イベント名と `delta`・`response.error.code` の読み方は本文で確認した。`usage`・`error` イベントの `code` など残りの JSON の形は、API リファレンスの本文が大きく取得しきれず未確認のため仮置きで、実際の API キーで確認する） |
