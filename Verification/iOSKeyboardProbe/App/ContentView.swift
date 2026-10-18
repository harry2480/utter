// Phase i0 検証用（#56, #53）の本体アプリ画面。本番コードではない。

import SwiftUI
import UIKit

struct ContentView: View {
  @Bindable var model: AppProbeModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      Form {
        configurationSection
        writeSection
        lockTestSection
        navigationSection
        eventSection
        outcomeSection
      }
      .navigationTitle("Keyboard Probe")
      .toolbar {
        Button("記録をコピー") { model.copyReport() }
      }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      model.appendEvent("scenePhase: \(String(describing: phase))")
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: UIApplication.protectedDataWillBecomeUnavailableNotification)
    ) { _ in
      model.appendEvent("保護データが利用不可になる（ロック）")
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: UIApplication.protectedDataDidBecomeAvailableNotification)
    ) { _ in
      model.appendEvent("保護データが利用可能になった（解除）")
    }
  }

  private var configurationSection: some View {
    Section("設定（#56）") {
      LabeledContent("App Group ID", value: ProbeConfig.appGroupID ?? "未設定")
      if ProbeConfig.isPlaceholderAppGroupID {
        Text("既定値のまま。Config/Local.xcconfig で自分の App Group ID に上書きする")
          .foregroundStyle(.red)
      }
      LabeledContent("コンテナ", value: ProbeStore.containerStatus)
      LabeledContent("isProtectedDataAvailable", value: String(model.protectedDataAvailable))
    }
  }

  private var writeSection: some View {
    Section("共有結果の書き込み・読み込み") {
      TextField("ダミー結果", text: $model.text)
      Text("実際の発話・個人情報は入れない（App Group に平文で置かれる）")
        .font(.footnote).foregroundStyle(.secondary)
      Picker("保護クラス", selection: $model.selectedProtection) {
        ForEach(ProbeProtection.allCases) { Text($0.label).tag($0) }
      }
      Button("選んだ保護クラスで書き込む") { model.writeSelected() }
      Button("全保護クラスで書き込む（クラスごとに別ファイル）") { model.writeAllClasses() }
      Button("全保護クラスのファイルを読む") { model.readAllClasses() }
      Button("キーボードが書いたファイルを読む") { model.readKeyboardWrite() }
      Button("プローブのファイルをすべて削除", role: .destructive) { model.deleteAll() }
    }
  }

  private var lockTestSection: some View {
    Section("ロック中の読み書き（iOS-IPC-05）") {
      Stepper(
        "待ち時間 \(model.lockTestDelaySeconds) 秒", value: $model.lockTestDelaySeconds,
        in: 5...60, step: 5)
      Button("開始（直後にサイドボタンでロック）") { model.startLockTest() }
        .disabled(model.isLockTestRunning)
      Text(model.lockTestStatus).font(.footnote)
      Text(
        "先に「全保護クラスで書き込む」を実行しておく。complete はロックの約10秒後に読めなくなる想定。"
          + "バックグラウンド実行は通常30秒前後で打ち切られるため、待ち時間は20秒前後にする"
      )
      .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var navigationSection: some View {
    Section("キーボードからの導線と復帰（#53）") {
      Text(
        "キーボードの「開く」ボタンで起動されると、下のイベントに「URL から起動された」と残る。"
          + "元のアプリへ戻るボタンはこのアプリに作らない（公開 API がないため）。"
          + "左上の「◀ 元のアプリ名」、ホームインジケータの左右スワイプ、App スイッチャーで戻れるかを手順書に記録する"
      )
      .font(.footnote)
    }
  }

  private var eventSection: some View {
    Section("イベント（新しい順）") {
      ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
        Text(event).font(.caption.monospaced())
      }
    }
  }

  private var outcomeSection: some View {
    Section("操作結果（新しい順）") {
      ForEach(model.outcomes) { outcome in
        Text(outcome.line)
          .font(.caption.monospaced())
          .foregroundStyle(outcome.succeeded ? Color.primary : Color.red)
      }
    }
  }
}
