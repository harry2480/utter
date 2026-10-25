import UtterCore

extension SensitiveInputDecision {
  /// 機密入力に当たらない入力先の判定
  static let allowedInput = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.editor"))
  /// パスワード欄に入力している判定
  static let secureFieldInput = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"))
}
