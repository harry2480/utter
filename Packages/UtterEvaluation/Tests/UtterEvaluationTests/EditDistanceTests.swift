import Testing

@testable import UtterEvaluation

struct EditDistanceTests {
  @Test(
    "AC-04: 編集距離は置換・挿入・削除の最小回数",
    arguments: [
      ("", "", 0),
      ("", "あい", 2),
      ("あい", "", 2),
      ("かいぎ", "かいぎ", 0),
      ("かいぎ", "かいき", 1),
      ("かいぎ", "かぎ", 1),
      ("かぎ", "かいぎ", 1),
      ("kitten", "sitting", 3),
    ])
  func editDistance(_ reference: String, _ hypothesis: String, _ expected: Int) {
    #expect(EditDistance.between(reference, hypothesis) == expected)
  }
}
