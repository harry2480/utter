import SwiftUI
import UIKit
import UtterSpeech
import UtteriOSKit

/// セットアップ画面（#200）。キーボードを追加 → フルアクセスを許可 → マイクを許可 → 認識モデルを取得 → 整形の実行先 の順に、
/// 済んだ手順が分かる形で出す。手順の状態は `SetupChecklist`（UtteriOSKit）が決める。
///
/// - キーボードの追加・フルアクセスは本体アプリから確かめられないため、キーボードからの報告（App Group を設定したビルドだけ）か、
///   利用者の「済んだ」で済んだことにする
/// - 設定アプリは公開 API（`UIApplication.openSettingsURLString`）で、このアプリの設定のページだけを開く（iOS-03）
/// - 整形の実行先は飛ばせる。飛ばしても端末内の整形（Local Basic）で使え、クラウドへは送らない（AC-06）
/// - 個人署名の期限を読めたときだけ、残り日数を出す（12.6節）
struct SetupView: View {
  let setup: SetupChecklistModel
  let home: HomeSettingsModel
  let refinementSettings: RefinementSettingsModel
  let speechEngine: SpeechEngineSelection
  /// 取得できるモデルがあるエンジンのときだけ
  let speechModel: SpeechModelSettingsModel?
  /// 個人署名の期限。読めなければ `nil`（警告を出さない）
  let signingExpiry: SigningExpiry?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  private var checklist: SetupChecklist {
    setup.checklist(hasSpeechModel: speechModel != nil, speechModel: speechModel?.availability)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text(headline)
              .font(.system(size: 15))
              .lineSpacing(4)
              .foregroundStyle(Color.utterSecondary)
          }
          VStack(spacing: 0) {
            ForEach(Array(SetupStep.allCases.enumerated()), id: \.element) { index, step in
              if index > 0 { Divider().overlay(Color.utterLine) }
              stepRow(step, number: index + 1)
            }
          }
          .background(Color.utterCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          if let signingExpiry {
            signingCard(signingExpiry)
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 34)
      }
      .background(Color.utterBackground)
      .navigationTitle("準備")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("閉じる") { dismiss() }
        }
      }
      .onAppear {
        // 整形と予算の画面から戻ったときに、選んだ実行先を出す
        home.reload()
      }
      .task {
        await setup.refresh()
        await speechModel?.refresh()
      }
      .onChange(of: scenePhase) { _, phase in
        // 設定アプリでキーボード・権限を変えて戻ったときに読み直す
        if phase == .active {
          Task {
            await setup.refresh()
            await speechModel?.refresh()
          }
        }
      }
    }
  }

  /// 見出しの下の一言。残りの手順の数と、必要な手順が済んだことを伝える
  private var headline: String {
    let progress = checklist.progress
    if checklist.isRequiredComplete {
      return "必要な手順は済みました。録音を始められます。（\(progress.total) 手順のうち \(progress.settled) 手順が済んでいます）"
    }
    return
      "残り \(progress.total - progress.settled) つで使い始められます。（\(progress.total) 手順のうち \(progress.settled) 手順が済んでいます）"
  }

  /// 1つの手順。済んだ手順は青いチェック、まだの手順は番号で示し、いま対応する手順は太字で内容とボタンを出す
  private func stepRow(_ step: SetupStep, number: Int) -> some View {
    let state = checklist.state(of: step)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        stepMark(state, number: number)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title)
            .font(.system(size: 16, weight: state.isSettled ? .regular : .bold))
            .foregroundStyle(Color.utterText)
          Text(state.label)
            .font(.system(size: 13))
            .foregroundStyle(
              state == .needsAttention ? Color.utterWarningText : Color.utterSecondary)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 10) {
        switch step {
        case .addKeyboard: addKeyboardContent(state)
        case .fullAccess: fullAccessContent(state)
        case .microphone: microphoneContent(state)
        case .speechModel: speechModelContent(state)
        case .refinementDestination: refinementContent(state)
        }
      }
      .font(.system(size: 13))
      .foregroundStyle(Color.utterSecondary)
      .padding(.leading, 36)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func stepMark(_ state: SetupStepState, number: Int) -> some View {
    if case .done = state {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(Color.utterAccent)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    } else if state.isSettled {
      Image(systemName: state.systemImage)
        .font(.system(size: 22))
        .foregroundStyle(Color.utterSecondary)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    } else if state == .needsAttention {
      Text("\(number)")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Color.utterOnStrongFill)
        .frame(width: 24, height: 24)
        .background(Color.utterStrongFill, in: Circle())
        .accessibilityHidden(true)
    } else {
      Text("\(number)")
        .font(.system(size: 13))
        .foregroundStyle(Color.utterSecondary)
        .frame(width: 24, height: 24)
        .overlay(Circle().stroke(Color.utterIdleDot, lineWidth: 1.5))
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func addKeyboardContent(_ state: SetupStepState) -> some View {
    Text("設定アプリの「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」で utter を選びます。")
    if setup.sharesWithKeyboard {
      Text("追加したら、どこかの入力欄で utter キーボードに切り替えてから戻ると、ここに反映されます。反映されなければ「済んだ」を押してください。")
    }
    if !state.isSettled {
      Button("済んだ") { setup.markDone(.addKeyboard) }
        .buttonStyle(UtterOutlineButtonStyle())
    }
  }

  @ViewBuilder
  private func fullAccessContent(_ state: SetupStepState) -> some View {
    if state == .notApplicable {
      Text("このビルドはキーボードと文章を共有しない設定（App Group 未設定）のため、フルアクセスは要りません。")
    } else {
      Text("utter キーボードが、本体アプリで作った文章を受け取るために必要です。キーボードで打った文字は送りません。")
      Text("「設定を開く」→「キーボード」で「フルアクセスを許可」をオンにします。")
      if state == .needsAttention {
        Text("キーボードからは、フルアクセスがオフと伝えられています。")
          .foregroundStyle(Color.utterWarningText)
      }
      Button("設定を開く") { openSettings() }
        .buttonStyle(UtterFilledButtonStyle(height: 44))
      if !state.isSettled {
        Button("済んだ") { setup.markDone(.fullAccess) }
          .buttonStyle(UtterOutlineButtonStyle())
      }
    }
  }

  @ViewBuilder
  private func microphoneContent(_ state: SetupStepState) -> some View {
    Text("話した内容を文字にするため、録音中だけマイクを使います。音声は保存・送信しません。")
    switch state {
    case .pending:
      Button("マイクを許可") { Task { await setup.requestMicrophone() } }
        .buttonStyle(UtterFilledButtonStyle(height: 44))
        .disabled(setup.isRequestingMicrophone)
    case .needsAttention:
      Text("マイクが許可されていません。設定アプリで utter のマイクをオンにしてください。")
        .foregroundStyle(Color.utterWarningText)
      Button("設定を開く") { openSettings() }
        .buttonStyle(UtterFilledButtonStyle(height: 44))
    case .done, .skipped, .notApplicable:
      EmptyView()
    }
  }

  @ViewBuilder
  private func speechModelContent(_ state: SetupStepState) -> some View {
    if speechModel == nil {
      Text(
        speechEngine == .unconfigured
          ? "iOS の音声認識は検証中のため、既定では使いません。取得するモデルはありません。"
          : "このエンジンでは、取得するモデルはありません。"
      )
    } else if state == .notApplicable {
      Text("この端末・言語では、音声認識モデルを使えません。")
    } else {
      Text("文字にするための音声認識モデルを、端末に取得します。")
      NavigationLink("音声認識の設定を開く") {
        SpeechSettingsView(engine: speechEngine, model: speechModel)
      }
      .font(.system(size: 15, weight: .bold))
    }
  }

  @ViewBuilder
  private func refinementContent(_ state: SetupStepState) -> some View {
    Text("今の実行先: \(home.refinementDestination.name)")
      .font(.system(size: 15))
      .foregroundStyle(Color.utterText)
    Text("この手順は飛ばせます。飛ばしても、端末内の整形（Local Basic）で使えます。クラウド AI は設定で選び、送信に同意したときだけ使います。")
    NavigationLink("整形と予算") {
      RefinementSettingsView(model: refinementSettings)
    }
    .font(.system(size: 15, weight: .bold))
    if !state.isSettled {
      Button("この実行先で使う") { setup.markDone(.refinementDestination) }
        .buttonStyle(UtterOutlineButtonStyle())
      Button("飛ばす") { setup.skip(.refinementDestination) }
        .buttonStyle(UtterOutlineButtonStyle())
    }
  }

  private func signingCard(_ expiry: SigningExpiry) -> some View {
    let status = expiry.status(at: Date())
    return VStack(alignment: .leading, spacing: 4) {
      Text(status.message)
        .font(.system(size: 15, weight: .bold))
      Text("無料の Personal Team で署名したアプリは、通常7日で開けなくなります。期限の前に Xcode からもう一度インストールしてください。")
        .font(.system(size: 13))
        .lineSpacing(3)
    }
    .foregroundStyle(status.isWarning ? Color.utterWarningText : Color.utterText)
    .utterCard()
    .background(
      status.isWarning ? Color.utterWarningFill : Color.utterCard,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  /// このアプリの設定のページを開く（公開 API, iOS-03）
  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(url)
  }
}

extension SetupStep {
  fileprivate var title: String {
    switch self {
    case .addKeyboard: "キーボードを追加"
    case .fullAccess: "フルアクセスを許可"
    case .microphone: "マイクを許可"
    case .speechModel: "認識モデルを取得"
    case .refinementDestination: "整形の実行先"
    }
  }
}

extension SetupStepState {
  fileprivate var label: String {
    switch self {
    case .done(.keyboardReport): "済み（キーボードで確認）"
    case .done: "済み"
    case .pending: "まだ"
    case .needsAttention: "要対応"
    case .skipped: "飛ばした"
    case .notApplicable: "不要"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .done: "checkmark.circle.fill"
    case .pending: "circle"
    case .needsAttention: "exclamationmark.circle"
    case .skipped: "arrow.uturn.forward.circle"
    case .notApplicable: "minus.circle"
    }
  }
}
