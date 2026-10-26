import SwiftUI
import UtterAI
import UtterPersistence
import UtteriOSKit

/// iOS の整形・予算の設定画面（2.3節, AI-03, AI-04, AI-05, iOS-10）。
///
/// 検証・保存・推定費用の表示値は `RefinementSettingsModel` / `RefinementSettingsForm` が持ち、ここは並べるだけにする。
/// 設定値を書くだけで、クラウドへは送信しない（送信の可否は同意から判定する, AC-06）。
struct RefinementSettingsView: View {
  @Bindable var model: RefinementSettingsModel

  var body: some View {
    Form {
      providerSection
      Section("今月の推定費用") {
        EstimatedCostView(state: model.cost)
      }
      budgetSection
      priceTableSection
      Section {
        if model.saveFailed {
          Text("設定を保存できませんでした。もう一度操作してください。").foregroundStyle(.red)
        } else if !model.issues.isEmpty {
          Text("入力に問題があるため保存していません（\(model.issues.count) 件）。赤字を確認してください。")
            .foregroundStyle(.red)
        }
        Button("保存") {
          if model.save() {
            Task { await model.refreshCost() }
          }
        }
        Button("元に戻す", role: .destructive) { model.revert() }
      }
    }
    .navigationTitle("整形と予算")
    .onAppear {
      model.reload()
      Task { await model.refreshCost() }
    }
  }

  private var providerSection: some View {
    Section {
      Picker("処理系", selection: $model.form.provider) {
        ForEach(RefinementProviderChoice.allCases) { choice in
          Text(choice.label).tag(choice)
        }
      }
      TextField("整形用モデル名", text: $model.form.refinementModel)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      IssueText(issues: model.issues(in: [.refinementModelEmpty]))
    } header: {
      Text("処理系")
    } footer: {
      VStack(alignment: .leading) {
        Text("整形用モデル名の既定は \(AppSettings.defaultRefinementModel)。")
        Text("Claude へは、送信の同意・API キー・月次予算・単価表がそろったときだけ送信します。それ以外は端末内で整形します。")
      }
    }
  }

  private var budgetSection: some View {
    Section("月次予算") {
      Toggle("月次予算を設定する", isOn: $model.form.budgetEnabled)
      if model.form.budgetEnabled {
        TextField("上限", text: $model.form.budgetLimit)
          .keyboardType(.decimalPad)
        IssueText(issues: model.issues(in: [.budgetLimit]))
      }
      TextField("通貨（例: USD）", text: $model.form.currencyCode)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.characters)
      IssueText(issues: model.issues(in: [.currencyCode]))
      ForEach(model.form.notices, id: \.self) { notice in
        Text(notice.message).font(.caption).foregroundStyle(.orange)
      }
    }
  }

  private var priceTableSection: some View {
    Section {
      PriceUpdatedOnRow(model: model)
      IssueText(issues: model.issues(in: [.priceUpdatedOnMissing]))
      ForEach($model.form.priceRows) { $row in
        VStack(alignment: .leading) {
          TextField("モデル名", text: $row.model)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
          HStack {
            TextField("入力", text: $row.inputPerMillionTokens)
              .keyboardType(.decimalPad)
            TextField("出力", text: $row.outputPerMillionTokens)
              .keyboardType(.decimalPad)
          }
          IssueText(issues: model.issues(forRow: row.id))
        }
        .swipeActions {
          Button("削除", role: .destructive) { model.form.removePriceRow(id: row.id) }
        }
      }
      Button("単価を追加") { model.form.addPriceRow() }
    } header: {
      Text("単価表（100万トークンあたり）")
    } footer: {
      Text("単価はプロバイダーの公開価格を見て入力し、更新日を合わせて直してください。行は左にスワイプして削除します。")
    }
  }
}

/// 入力欄の下に出す問題の文言
private struct IssueText: View {
  let issues: [RefinementSettingsIssue]

  var body: some View {
    ForEach(issues, id: \.self) { issue in
      Text(issue.message).font(.caption).foregroundStyle(.red)
    }
  }
}

private struct PriceUpdatedOnRow: View {
  @Bindable var model: RefinementSettingsModel
  private let calendar = Calendar.current

  var body: some View {
    if let day = model.form.priceUpdatedOn,
      let date = RefinementSettingsForm.date(of: day, in: calendar)
    {
      DatePicker(
        "更新日",
        selection: Binding(
          get: { date },
          set: {
            model.form.priceUpdatedOn = RefinementSettingsForm.calendarDay(of: $0, in: calendar)
          }),
        displayedComponents: .date)
      Button("更新日を消す", role: .destructive) { model.form.priceUpdatedOn = nil }
    } else {
      LabeledContent("更新日") {
        Button("今日の日付を入れる") {
          model.form.priceUpdatedOn = RefinementSettingsForm.calendarDay(
            of: Date(), in: calendar)
        }
      }
    }
  }
}

private struct EstimatedCostView: View {
  let state: RefinementSettingsModel.CostState

  var body: some View {
    switch state {
    case .loading:
      ProgressView()
    case .summary(let summary):
      let code = summary.currency.code
      LabeledContent("推定費用（\(String(summary.month.year))年\(summary.month.month)月）") {
        Text(summary.estimatedSpent, format: .currency(code: code))
      }
      LabeledContent("月次予算") {
        Text(summary.limitAmount, format: .currency(code: code))
      }
      LabeledContent("予算の推定の残り") {
        Text(summary.estimatedRemaining, format: .currency(code: code))
      }
      LabeledContent("単価表の更新日") {
        Text(Self.text(of: summary.priceTableUpdatedOn))
      }
      Text("トークン使用量と単価表から計算した推定値です。プロバイダーの請求額や API クレジットの残高ではありません。")
        .font(.caption).foregroundStyle(.secondary)
    case .unavailable(let reason):
      Text(Self.message(for: reason)).foregroundStyle(.secondary)
    case .unreadable:
      Text("推定費用の記録を読み込めませんでした。").foregroundStyle(.red)
    }
  }

  private static func text(of day: CivilDate) -> String {
    "\(String(day.year))/\(day.month)/\(day.day)"
  }

  private static func message(for reason: RefinementSettingsModel.CostUnavailableReason) -> String {
    switch reason {
    case .budgetNotSet:
      "月次予算を設定すると、今月の推定費用と予算の残りを表示します。"
    case .priceTableIncomplete:
      "単価表の通貨と更新日を設定すると、推定費用を表示します。"
    case .currencyMismatch:
      "予算と単価表の通貨が異なるため、推定費用を表示できません。"
    case .invalidMonth:
      "今月の年月を集計に使えないため、推定費用を表示できません。"
    }
  }
}

extension RefinementProviderChoice {
  var label: String {
    switch self {
    case .localBasic: "Local Basic（端末内）"
    case .claude: "Claude API"
    }
  }
}
