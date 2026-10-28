# 第三者ソフトウェアの表示（Third-Party Notices）

utter（[Apache License 2.0](LICENSE)）の配布物に含まれる第三者のソフトウェアと、そのライセンス表示。
表示の置き場所はこのファイル（リポジトリ）のみとし、アプリ内の謝辞画面は設けない（[ライセンス・依存関係](docs/ライセンス・依存関係.md) D-3）。

- 確認日：2026-10-27
- 対象：macOS アプリ（`Apps/macOS`、XPC STT Worker を含む）と iOS アプリ（`Apps/iOS`、キーボード拡張を含む）にリンク・同梱される依存。`Packages/*/Package.swift`・各 `Package.resolved`・`Apps/*/project.yml`（`Apps/macOS/Specs/*.yml` を含む）から確かめた
- ライセンス本文は、`Package.resolved` で固定したリビジョンの各リポジトリの `LICENSE` から写した（改変なし）
- 依存の版を上げたときは、このファイルと [ライセンス・依存関係](docs/ライセンス・依存関係.md) の表を見直す

## 一覧

| 名前 | 版（リビジョン） | ライセンス | 組み込み先 |
|---|---|---|---|
| [GRDB.swift](#grdbswift) | 7.11.1（`b83108d10f42680d78f23fe4d4d80fc88dab3212`） | MIT | macOS アプリ・iOS アプリ（UtterPersistence 経由） |
| [Sparkle](#sparkle) | 2.10.0（`eef1a539a373c1f1a320624b1130fc5de7b2e100`） | MIT ＋ 同梱の外部コード（BSD 2条項型・MIT・zlib 型） | macOS アプリ（自動更新。既定で無効だがリンク・同梱する） |

## 現在は配布物に含まれないもの

| 名前 | 理由 |
|---|---|
| WhisperKit（[argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift)）1.1.1（`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`） | `Packages/UtterSpeechWhisperKit` の依存だが、アプリと STT Worker にはリンクしていない（[既知の制限](docs/既知の制限.md)）。ライセンスは MIT（[LICENSE](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/LICENSE)）で、`Sources/ArgmaxCore/External` は huggingface/swift-transformers 由来の Apache-2.0（[NOTICES](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/NOTICES)）。アプリにリンクする時点で、両方の表示をこのファイルに加える |
| swift-argument-parser 1.8.2 | WhisperKit の CLI ターゲットと `Verification/` の検証用ツールだけが使う。アプリには組み込まない |
| STT モデルの重み・トークナイザー（OpenAI Whisper、`argmaxinc/whisperkit-coreml`、`openai/whisper-*`） | アプリに同梱せず、utter も再配布しない（利用者が取得元から取得する）。ライセンスは [ライセンス・依存関係](docs/ライセンス・依存関係.md) 2.2 |
| Apple の OS 標準フレームワーク（Speech、CryptoKit、AppKit、UIKit など） | OS の一部で、utter は再配布しない |

## 対象外

- テスト専用の依存（Swift Testing、XCTest、XCUITest）：テストターゲットだけが使い、配布物に入らない
- ビルド時だけ使う道具（Xcode とツールチェーン、XcodeGen、swift-format、ShellCheck など）と、`Verification/` の検証用パッケージ：配布物に入らない

---

## GRDB.swift

- 取得元：<https://github.com/groue/GRDB.swift>
- 版：7.11.1（リビジョン `b83108d10f42680d78f23fe4d4d80fc88dab3212`）
- ライセンス：MIT
- 本文の出典：<https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/LICENSE>

```text
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Sparkle

- 取得元：<https://github.com/sparkle-project/Sparkle>
- 版：2.10.0（リビジョン `eef1a539a373c1f1a320624b1130fc5de7b2e100`）
- ライセンス：MIT（本体）。同梱の外部コードとして bsdiff/bspatch（Colin Percival、BSD 2条項型）、sais-lite（Yuta Mori、MIT）、ed25519（Orson Peters、zlib 型）、SUSignatureVerifier.m（Mark Hamlin、BSD 2条項型）を含む
- 本文の出典：<https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/LICENSE>
- 本文：[Apps/macOS/Licenses/Sparkle-LICENSE.txt](Apps/macOS/Licenses/Sparkle-LICENSE.txt)（上の `LICENSE` と同一。`scripts/verify.sh` が取得した版の `LICENSE` と一致することを確かめ、アプリの `Contents/Resources/Licenses/` にも同梱する）

本体の著作権表示（同ファイルの冒頭）：

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.
```
