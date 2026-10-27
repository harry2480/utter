import UtterAI
import UtterCore

/// 整形の送信先（`AIProvider`）の `refine` を `LLMComplete` の区間として計測する（6章, #52）。
///
/// `RefinementRouter` が同意・機密入力・予算の予約を確かめた後に呼ぶ `refine` の呼び出しから戻りまでを測る
/// （API キーの読み出し・要求の組み立て・通信・応答の解釈を含み、応答の検証は含まない）。失敗・上限時間の超過・キャンセルでも、
/// `refine` が戻った時点で区間を閉じる。区間の開始と終了で MainActor へ切り替える分（通常はごく短い）も区間に入る。
/// 応答をストリームで受け取らないため、`LLMFirstToken` は出さない
struct PerfMeasuredAIProvider: AIProvider {
  let base: any AIProvider
  let measurer: any PerfIntervalMeasuring

  var destination: CloudAIProviderKind { base.destination }
  var isTokenBilled: Bool { base.isTokenBilled }

  func refine(_ request: RefinementRequest) async throws(AIProviderError) -> RefinementResponse {
    let token = await measurer.begin(.llmComplete)
    let result: Result<RefinementResponse, AIProviderError>
    do throws(AIProviderError) {
      result = .success(try await base.refine(request))
    } catch {
      result = .failure(error)
    }
    await measurer.end(token)
    return try result.get()
  }
}
