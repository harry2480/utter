# Phase i0 検証: iOS の STT・メモリ・発熱と最低対応バージョン（#54）

## 目的

iOS デバイスでの STT（音声認識）実装可否を確認：
- Speech Recognition Framework の日本語対応
- メモリ・CPU・バッテリーへの影響
- 最低 iOS バージョン（iOS 15.0 以上推奨）

## テスト環境

- OS: iOS 15.0 以上（iPhone 12 以上推奨）
- 権限: Microphone, Speech Recognition

## 検証用アプリ

実機での計測には [Verification/iOSSTTProbe](../Verification/iOSSTTProbe/README.md) を使う（SpeechAnalyzer / SpeechTranscriber・DictationTranscriber の対応状況とアセット、マイク・音声ファイルの認識と遅延、`phys_footprint` と `thermalState` の推移、`utter-eval` が読める結果の書き出し）。
SpeechAnalyzer は iOS 26 以降のため、このアプリの配備ターゲットは iOS 26.0。WhisperKit を足す場合の差し替え点は同 README に書いた。

## テスト項目

### 1. STT フレームワークの選択

| オプション | 特徴 | 対応 |
|----------|------|------|
| **Speech Framework** | 標準、日本語対応 | ✅ iOS 10+ |
| **WhisperKit** | オンデバイス、精度高 | ✅ iOS 15+ |
| **クラウド STT** | 正確だが通信必須 | ✅（ローカル優先） |

**推奨: WhisperKit（iOS 15+）**

### 2. メモリ計測

```
計測環境:
- iPhone 12（4GB RAM）、iPhone SE（3GB RAM）

期待結果:
- モデル初回ロード: < 2GB ピーク
- 認識中: < 1.5GB 平均
- 解放率: ≥ 80%（認識完了後）
```

### 3. 発熱・バッテリー消費

```
計測方法:
- サーマルカメラ OR Xcode Simulator Metrics
- 5分連続認識時の温度変化

期待結果:
- 発熱: 40°C 以下（常温から +5°C 以内）
- バッテリー: < 5%/時間（オンデバイス STT）
```

### 4. 最低 iOS バージョン

```
制約:
- Speech Framework: iOS 10+（ただし日本語は iOS 16+）
- WhisperKit: iOS 15.0+
- AVAudioSession: 全 iOS version 対応

決定: iOS 15.0 以上を目標（iPhone 12 以降の主要デバイス）
```

## Phase i1 での判定

- ✅ iOS 15.0+ で実装可能か
- ✅ メモリ・発熱・バッテリー基準をクリアするか

**Go 条件:** メモリ < 2GB ピーク、発熱 < +5°C、バッテリー < 5%/h
