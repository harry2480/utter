import AppKit
import SwiftUI
import UtterCore

/// 権限オンボーディングの画面（PERM-01〜03）。
///
/// 有効な機能に要る権限を順に並べ、次に操作する段階にだけボタンを出す。
/// 開いたとき・アプリが前面に来たときに権限の状態を取り直し、取り消しを示す（PERM-02）。
struct PermissionOnboardingView: View {
  let model: PermissionOnboardingModel

  var body: some View {
    let onboarding = model.onboarding
    Form {
      Section {
        ForEach(Array(onboarding.steps.enumerated()), id: \.element.permission) { index, step in
          PermissionStepRow(
            number: index + 1, step: step,
            isCurrent: step.permission == onboarding.currentStep?.permission
          ) {
            Task { await model.perform(step) }
          }
          .disabled(model.isPerforming)
        }
      } header: {
        Text("権限")
      } footer: {
        Text(Self.footer(onboarding))
      }

      if !onboarding.undecidedFeatures.isEmpty {
        Section {
          Text(AppFeature.displayNames(onboarding.undecidedFeatures))
        } header: {
          Text("確認中")
        } footer: {
          Text("必要な権限を確認中のため、これらの機能はまだ使わず、権限も求めません。")
        }
      }

      Section {
        // 取得処理（SpeechAnalyzer のモデル導入 / WhisperKit）は未接続。置き場所と案内だけを置く
        LabeledContent("状態", value: "未確認")
        Button("モデルを取得…") {}
          .disabled(true)
      } header: {
        Text("音声認識モデル")
      } footer: {
        Text("モデルは、このボタンを押したときにだけ取得します。取得の前に取得元とサイズを示し、取得後に壊れていないか確かめます。")
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 420, minHeight: 360)
    .onAppear { model.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in model.refresh()
    }
  }
}

extension PermissionOnboardingView {
  fileprivate static func footer(_ onboarding: PermissionOnboarding) -> String {
    if onboarding.isComplete {
      // 確認中の機能は権限がそろっても使えないため、「すべての機能が使える」とは書かない
      "ここに並ぶ権限はそろっています。"
    } else if onboarding.currentStep == nil {
      "残りの権限は管理者により制限されているため変更できません。その権限が要る機能だけが使えません。"
    } else {
      "有効な機能に必要な権限だけを、上から順に許可してください。権限のない機能だけが使えなくなります。"
    }
  }
}

/// 段階1つの行。
private struct PermissionStepRow: View {
  let number: Int
  let step: PermissionOnboardingStep
  let isCurrent: Bool
  let action: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(number). \(step.permission.displayName)")
          .font(.headline)
        Text("用途: \(AppFeature.displayNames(step.features))")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let note {
          Text(note)
            .font(.callout)
            .foregroundStyle(isRevoked ? .orange : .secondary)
        }
      }
      Spacer()
      if step.state == .granted {
        Label("許可済み", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else if isCurrent, let buttonTitle {
        Button(buttonTitle, action: action)
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private var isRevoked: Bool {
    if case .needed(_, wasRevoked: true) = step.state { true } else { false }
  }

  private var note: String? {
    guard case .needed(let action, let wasRevoked) = step.state else { return nil }
    let revoked = wasRevoked ? "許可が取り消されました。" : ""
    return switch action {
    case .requestFromSystem: wasRevoked ? revoked : nil
    case .openSystemSettings: revoked + "システム設定で許可してください。"
    case .notChangeableByUser: "管理者により制限されているため変更できません。"
    }
  }

  private var buttonTitle: String? {
    guard case .needed(let action, _) = step.state else { return nil }
    return switch action {
    case .requestFromSystem: "許可する…"
    case .openSystemSettings: "システム設定を開く"
    case .notChangeableByUser: nil
    }
  }
}
