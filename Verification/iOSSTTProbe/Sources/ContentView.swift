import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var model: ProbeModel
  @State private var isImportingAudio = false
  @State private var isImportingSamples = false
  @State private var isConfirmingDelete = false

  var body: some View {
    NavigationStack {
      Form {
        if let message = model.message {
          Section { Text(message).font(.footnote) }
        }
        availabilitySection
        settingsSection
        sampleSection
        runSection
        ResourceSection(monitor: model.monitor)
        historySection
        outputSection
      }
      .navigationTitle("STT Probe")
      .fileImporter(
        isPresented: $isImportingAudio,
        allowedContentTypes: [.audio],
        allowsMultipleSelection: true
      ) { result in
        if case .success(let urls) = result {
          Task { await model.recognizeFiles(urls) }
        }
      }
      .fileImporter(
        isPresented: $isImportingSamples,
        allowedContentTypes: [.json],
        allowsMultipleSelection: false
      ) { result in
        if case .success(let urls) = result, let url = urls.first {
          model.importSamples(from: url)
        }
      }
      .confirmationDialog(
        "書き出したファイルと認識結果・計測値をすべて削除します",
        isPresented: $isConfirmingDelete,
        titleVisibility: .visible
      ) {
        Button("削除", role: .destructive) { model.deleteAllOutputs() }
      }
    }
  }

  // MARK: 対応状況

  private var availabilitySection: some View {
    Section("対応状況（\(ProbeModel.targetLocale.identifier)）") {
      LabeledContent("機種", value: DeviceInfo.modelIdentifier)
      LabeledContent("iOS", value: UIDevice.current.systemVersion)
      if let availability = model.availability {
        if let supported = availability.deviceSupported {
          LabeledContent("端末の対応", value: supported ? "対応" : "非対応")
        }
        LabeledContent(
          "ロケール",
          value: availability.supportedLocale?.identifier ?? "非対応")
        LabeledContent(
          "導入済みロケール",
          value: availability.installedLocales.map(\.identifier).joined(separator: ", "))
        LabeledContent("アセット", value: availability.assetStatus ?? "-")
        LabeledContent(
          "予約中ロケール",
          value:
            "\(availability.reservedLocales.map(\.identifier).joined(separator: ", ")) "
            + "(\(availability.reservedLocales.count)/\(availability.maximumReservedLocales))")
      } else {
        ProgressView()
      }
      LabeledContent("音声認識の許可", value: model.speechAuthorization.label)
      if let progress = model.downloadProgress {
        ProgressView(progress)
      }
      Button("状態を更新") { Task { await model.refreshAvailability() } }
      Button("アセットをダウンロード") { Task { await model.downloadAssets() } }
        .disabled(model.downloadProgress != nil || model.isBusy)
      Button("ロケールの予約を解除") { Task { await model.releaseReservedLocales() } }
        .disabled(model.isBusy)
    }
  }

  // MARK: 設定

  private var settingsSection: some View {
    Section("設定") {
      Picker("エンジン", selection: $model.engineKind) {
        ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
      }
      .onChange(of: model.engineKind) {
        Task { await model.refreshAvailability() }
      }
      Toggle("暫定結果（volatile）", isOn: $model.progressiveResults)
      Picker("モデル保持", selection: $model.retention) {
        ForEach(ModelRetentionOption.allCases) { Text($0.rawValue).tag($0) }
      }
      Button("保持中のモデルを解放") { Task { await model.endModelRetention() } }
        .disabled(model.isBusy)
    }
    .disabled(model.isBusy)
  }

  // MARK: 評価サンプル

  private var sampleSection: some View {
    Section {
      Picker("録音の対象", selection: $model.selectedSampleID) {
        Text("新規（mic-NNN）").tag(String?.none)
        ForEach(model.samples) { Text($0.id).tag(Optional($0.id)) }
      }
      Picker("新規の区分", selection: $model.newSampleCategory) {
        ForEach(EvaluationCategoryOption.allCases) { Text($0.displayName).tag($0) }
      }
      Button("評価セット（JSON）を取り込む") { isImportingSamples = true }
      ForEach(model.samples) { sample in
        NavigationLink {
          SampleEditor(record: sample) { model.updateSample($0) }
        } label: {
          HStack {
            Text(sample.id)
            Spacer()
            Text(sample.exportProblem ?? (sample.sttOutput == nil ? "未認識" : "認識済み"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("評価サンプル")
    } footer: {
      Text("音声ファイル名（拡張子なし）が id と一致すると、そのサンプルに認識結果が入ります。正解が未入力のサンプルは書き出しから除外します。")
    }
    .disabled(model.isBusy)
  }

  // MARK: 実行

  private var runSection: some View {
    Section("実行") {
      switch model.phase {
      case .idle:
        Button("録音を開始") { Task { await model.startMicrophoneRun() } }
        Stepper("ファイルの繰り返し: \(model.fileRepeatCount) 回", value: $model.fileRepeatCount, in: 1...50)
        Toggle("ファイルごとに 5 秒待つ（終了 5 秒後のメモリを測る）", isOn: $model.waitAfterEachFile)
        Button("音声ファイルを選んで認識") { isImportingAudio = true }
      case .preparing:
        Label("準備中…", systemImage: "hourglass")
      case .recording:
        Button("停止", role: .destructive) { Task { await model.stopMicrophoneRun() } }
      case .finishing:
        Label("確定待ち…", systemImage: "hourglass")
      case .recognizingFiles(let current, let total):
        Label("ファイル認識中 \(current)/\(total)", systemImage: "waveform")
      }
      Text("\(model.liveFinalText)\(Text(model.liveVolatileText).foregroundStyle(.secondary))")
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .textSelection(.enabled)
    }
  }

  // MARK: 履歴

  private var historySection: some View {
    Section("実行履歴") {
      ForEach(model.runs.reversed()) { run in
        VStack(alignment: .leading, spacing: 2) {
          Text("#\(run.id) \(run.sampleID) [\(run.source) / \(run.engine)]")
            .font(.subheadline)
          Text(summary(of: run))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          if let error = run.error {
            Text(error).font(.caption).foregroundStyle(.red)
          }
        }
      }
    }
  }

  // MARK: 書き出し

  private var outputSection: some View {
    Section {
      Button("書き出す（results.json / metrics.json / timeline.csv）") { model.export() }
        .disabled(model.isBusy)
      if !model.exportedFiles.isEmpty {
        ShareLink(items: model.exportedFiles) {
          Label("書き出したファイルを共有", systemImage: "square.and.arrow.up")
        }
      }
      Button("書き出しと認識結果をすべて削除", role: .destructive) { isConfirmingDelete = true }
        .disabled(model.isBusy)
    } header: {
      Text("書き出し")
    } footer: {
      Text(
        "results.json は発話本文を含みます。端末内（ファイル > このiPhone内 > STT Probe）にのみ保存し、送信しません。共有先はAirDropなど自分の端末に限ってください。"
      )
    }
  }

  private func summary(of run: RunMetrics) -> String {
    var parts: [String] = []
    if let value = run.analyzerPrepareMilliseconds { parts.append("prepare \(Int(value))ms") }
    if let value = run.startToFirstBufferMilliseconds { parts.append("開始 \(Int(value))ms") }
    if let value = run.firstVolatileResultMilliseconds { parts.append("初回暫定 \(Int(value))ms") }
    if let value = run.firstFinalResultMilliseconds { parts.append("初回確定 \(Int(value))ms") }
    if let value = run.stopToFinishMilliseconds { parts.append("停止→確定 \(Int(value))ms") }
    if let value = run.realTimeFactor { parts.append(String(format: "RTF %.2f", value)) }
    if let value = run.footprintPeakSampledMB { parts.append("ピーク \(Int(value))MB") }
    if let value = run.thermalStateMax { parts.append("熱 \(value)") }
    if let value = run.footprintAfter5sMB { parts.append("5秒後 \(Int(value))MB") }
    if run.interrupted { parts.append("割り込み（結果は評価に入れない）") }
    return parts.joined(separator: " / ")
  }

}

/// 資源の表示。0.5 秒ごとに更新されるため、ここだけが再描画されるよう別の View に分ける
struct ResourceSection: View {
  let monitor: ResourceMonitor

  var body: some View {
    Section("資源（0.5 秒ごと）") {
      if let sample = monitor.latest {
        LabeledContent("phys_footprint", value: format(megabytes(sample.footprintBytes)))
        LabeledContent(
          "プロセスのピーク", value: format(megabytes(sample.processPeakFootprintBytes)))
        LabeledContent(
          "残り（jetsam まで）", value: format(Double(sample.availableBytes) / 1_048_576))
        LabeledContent("熱状態", value: sample.thermalState.label)
        LabeledContent(
          "電池",
          value: sample.batteryLevel < 0 ? "-" : "\(Int(sample.batteryLevel * 100))%")
        LabeledContent("低電力モード", value: sample.lowPowerMode ? "オン" : "オフ")
      }
      LabeledContent("記録数", value: "\(monitor.samples.count)")
    }
  }

  private func format(_ megabytes: Double?) -> String {
    megabytes.map { String(format: "%.1f MB", $0) } ?? "-"
  }
}

/// 評価サンプルの正解・区分・用語を端末上で入力する。
struct SampleEditor: View {
  @State var record: EvaluationRecord
  let onSave: (EvaluationRecord) -> Void
  @State private var termsText = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section("id") { Text(record.id) }
      Section("区分") {
        Picker("区分", selection: $record.category) {
          ForEach(EvaluationCategoryOption.allCases) { Text($0.displayName).tag($0.rawValue) }
        }
      }
      Section("正解（発話どおり。フィラー・言い直しも書く）") {
        TextField("正解", text: $record.reference, axis: .vertical)
      }
      Section("用語（カンマ区切り。正解に表記どおり含める）") {
        TextField("SwiftUI, Xcode", text: $termsText)
      }
      Section("STT の結果") {
        Text(record.sttOutput ?? "未認識").textSelection(.enabled)
      }
      if let problem = record.exportProblem {
        Section { Text(problem).foregroundStyle(.red) }
      }
    }
    .navigationTitle(record.id)
    .onAppear { termsText = record.terms?.joined(separator: ", ") ?? "" }
    .onChange(of: termsText) {
      let terms = termsText.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      record.terms = terms.isEmpty ? nil : terms
    }
    .toolbar {
      Button("保存") {
        onSave(record)
        dismiss()
      }
    }
  }
}
