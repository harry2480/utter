import AVFoundation
import Foundation
import Speech
import UtterEvaluation

// MARK: - status

/// 日本語モデルの対応・アセットの状態・権限・端末を表示する（副作用なし）
func runStatus(locale: Locale) async {
  let machine = MachineInfo.current()
  print("OS                       : \(machine.osVersion)")
  print(
    "機種                     : \(machine.hardwareModel)（\(machine.cpu)、メモリ \(Int(machine.physicalMemoryGB))GB）"
  )
  print("SpeechTranscriber.isAvailable : \(SpeechTranscriber.isAvailable)")

  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
  let installed = await SpeechTranscriber.installedLocales
  print("対象ロケール             : \(locale.identifier)")
  print("SpeechTranscriber 対応   : \(supported.map { "あり（\($0.identifier)）" } ?? "なし")")
  print(
    "SpeechTranscriber.installedLocales に含まれる: \(contains(installed, supported ?? locale) ? "はい" : "いいえ")"
      + "（\(installed.count) 件）")
  let supportedCount = await SpeechTranscriber.supportedLocales.count
  print("SpeechTranscriber 対応ロケール数: \(supportedCount)")

  let transcriber = SpeechTranscriber(
    locale: supported ?? locale, preset: .progressiveTranscription)
  print(
    "AssetInventory.status    : \(describe(await AssetInventory.status(forModules: [transcriber])))"
  )
  let reserved = await AssetInventory.reservedLocales
  print(
    "予約済みロケール         : \(reserved.map(\.identifier).joined(separator: ", "))"
      + "（上限 \(AssetInventory.maximumReservedLocales)）")
  if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
    print("SpeechAnalyzer の入力形式: \(describe(format))")
  }
  print(
    "プリセット progressive の reportingOptions: \(describe(PresetName.progressive.preset.reportingOptions))"
  )
  print(
    "プリセット transcription の reportingOptions: \(describe(PresetName.transcription.preset.reportingOptions))"
  )

  // SpeechTranscriber が使えない場合の参考（DictationTranscriber は従来の音声入力相当のモデル）
  let dictation = await DictationTranscriber.supportedLocale(equivalentTo: locale)
  print("（参考）DictationTranscriber 対応: \(dictation.map { "あり（\($0.identifier)）" } ?? "なし")")

  print("権限 音声認識            : \(describe(SFSpeechRecognizer.authorizationStatus()))")
  print("権限 マイク              : \(describe(AVCaptureDevice.authorizationStatus(for: .audio)))")
}

private func contains(_ locales: [Locale], _ locale: Locale) -> Bool {
  let target = locale.identifier(.bcp47)
  return locales.contains { $0.identifier(.bcp47) == target }
}

private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
  switch status {
  case .notDetermined: "notDetermined（未確認）"
  case .denied: "denied（拒否）"
  case .restricted: "restricted（制限）"
  case .authorized: "authorized（許可）"
  @unknown default: "unknown"
  }
}

private func describe(_ status: AVAuthorizationStatus) -> String {
  switch status {
  case .notDetermined: "notDetermined（未確認）"
  case .denied: "denied（拒否）"
  case .restricted: "restricted（制限）"
  case .authorized: "authorized（許可）"
  @unknown default: "unknown"
  }
}

// MARK: - authorize

/// 音声認識とマイクの権限を要求する。SpeechAnalyzer に音声認識の権限が要るかも、この結果と実行結果で確認する
func runAuthorize() async {
  let speech = await withCheckedContinuation { continuation in
    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
  }
  print("権限 音声認識: \(describe(speech))")
  let microphone = await AVCaptureDevice.requestAccess(for: .audio)
  print("権限 マイク  : \(microphone ? "許可" : "拒否")")
}

// MARK: - install / release

/// ロケールを予約し、SpeechTranscriber のアセットをダウンロードする（ネットワークを使う。Apple のサーバーから取得）
func runInstall(locale: Locale) async throws {
  guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
    throw ProbeError("\(locale.identifier) は SpeechTranscriber の対応ロケールではありません")
  }
  let reserved = await AssetInventory.reservedLocales
  if !contains(reserved, supported) {
    do {
      let result = try await AssetInventory.reserve(locale: supported)
      print("ロケールを予約しました: \(supported.identifier)（\(result)）")
    } catch {
      // 予約できなくても、ダウンロード要求の側で扱われる場合があるため続ける
      printError("ロケールを予約できません: \(error.localizedDescription)")
    }
  }
  let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
  guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
  else {
    print("ダウンロードは不要です（状態: \(describe(await AssetInventory.status(forModules: [transcriber]))))")
    return
  }
  let start = ContinuousClock.now
  let progressTask = Task {
    while !Task.isCancelled {
      printError("ダウンロード中: \(Int(request.progress.fractionCompleted * 100))%")
      try? await Task.sleep(for: .seconds(2))
    }
  }
  defer { progressTask.cancel() }
  try await request.downloadAndInstall()
  print("ダウンロードとインストールが完了しました（\(fixed(toSeconds(ContinuousClock.now - start), digits: 1))s）")
  print("状態: \(describe(await AssetInventory.status(forModules: [transcriber])))")
}

/// ロケールの予約を解除する（アセットは OS が後で削除する）
func runRelease(locale: Locale) async {
  let target = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
  let released = await AssetInventory.release(reservedLocale: target)
  print("予約の解除: \(released ? "解除しました" : "予約されていません")（\(target.identifier)）")
}

// MARK: - batch

/// 評価セットの1件。`EvaluationSample` のキーに `audio`（音声ファイルのパス）を加えたもの
struct ManifestEntry: Decodable {
  let audio: String
  let sample: EvaluationSample

  private enum CodingKeys: String, CodingKey { case audio }

  init(from decoder: any Decoder) throws {
    audio = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .audio)
    sample = try EvaluationSample(from: decoder)
  }
}

/// manifest の各音声を順に認識し、`sttOutput` を埋めた評価結果（utter-eval の入力）を書く。
/// 標準出力には発話本文を出さず、識別子と計測値だけを出す。
func runBatch(manifestPath: String, outputPath: String, options: RunOptions, log: EventLog)
  async throws -> Int
{
  let manifestURL = URL(fileURLWithPath: manifestPath)
  let entries: [ManifestEntry]
  do {
    entries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
  } catch is DecodingError {
    throw ProbeError("manifest の形式が正しくありません（README の例を参照）")
  }
  do {
    try EvaluationSample.validate(entries.map(\.sample))
  } catch {
    throw ProbeError("評価セットに不備があります: \(error)")
  }

  let baseDirectory = manifestURL.deletingLastPathComponent()
  var results: [EvaluationSample] = []
  var failures = 0
  for entry in entries {
    let sample = entry.sample
    let audioURL =
      entry.audio.hasPrefix("/")
      ? URL(fileURLWithPath: entry.audio) : baseDirectory.appendingPathComponent(entry.audio)
    var sttOutput: String?
    do {
      let output = try await transcribe(
        source: .file(audioURL), options: options, sampleID: sample.id, log: log)
      printSummary(output.summary)
      if output.summary.error == nil {
        // 確定結果が1件もない（発話を認識できなかった）場合も、STT の誤りとして空文字を記録する。
        // 省略すると未実施扱いになり、認識できなかった発話が CER から抜けて良く見えるため
        if output.summary.finalCount == 0 {
          printError("[\(sample.id)] 確定結果がありません。sttOutput を空文字で記録します")
        }
        sttOutput = output.finalText
      } else {
        failures += 1
      }
    } catch {
      printError("[\(sample.id)] 認識できません: \(error)")
      failures += 1
    }
    // 失敗した発話は sttOutput を省略する（utter-eval では未実施として扱われる）
    results.append(
      EvaluationSample(
        id: sample.id, category: sample.category, reference: sample.reference, terms: sample.terms,
        sttOutput: sttOutput))
  }

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let outputURL = URL(fileURLWithPath: outputPath)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try encoder.encode(results).write(to: outputURL)
  print("\n評価結果を書きました: \(outputPath)（\(results.count) 件、失敗 \(failures) 件）")
  print("CER などの計算: swift run --package-path Packages/UtterEvaluation utter-eval \(outputPath)")
  return failures
}
