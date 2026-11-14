import UIKit

/// 通常の文字入力・削除・改行・地球儀キー（iOS-08）。
///
/// 英字と数字・記号の2面だけを持つ。日本語の変換・予測変換は持たない（iOS-08 で保証しない。標準キーボードへの切り替えを案内する）。
/// 入力は呼び出し側が `UITextDocumentProxy` へ渡す。入力した文字はここにも呼び出し側にも保持しない。
@MainActor
final class KeyboardKeysView: UIView {
  /// 文字（空白・改行を含む）を入力する
  var onText: ((String) -> Void)?
  /// 1文字削除する
  var onDelete: (() -> Void)?

  /// 地球儀キー。キーボードの切り替えは呼び出し側（`UIInputViewController`）の操作に結ぶ
  let globeButton = KeyboardKeysView.makeKey(
    title: nil, symbol: "globe", accessibilityLabel: "キーボードを切り替える", isFunction: true)

  private enum Plane {
    case letters
    case symbols
  }

  private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  private static let symbolRows = ["1234567890", "-/:;()¥&@\"", ".,?!'、。"]

  private static let functionKeyWidth: CGFloat = 44
  private static let newlineKeyWidth: CGFloat = 76

  private let rows = UIStackView()
  private var plane = Plane.letters
  /// 次の1文字だけ大文字にする
  private var isShifted = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    rows.axis = .vertical
    rows.spacing = 10
    rows.distribution = .fillEqually
    rows.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rows)
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: leadingAnchor),
      rows.trailingAnchor.constraint(equalTo: trailingAnchor),
      rows.topAnchor.constraint(equalTo: topAnchor),
      rows.bottomAnchor.constraint(equalTo: bottomAnchor),
      // 地球儀キーは面を切り替えても同じものを使うため、幅の制約は1回だけ付ける
      globeButton.widthAnchor.constraint(equalToConstant: Self.functionKeyWidth),
    ])
    rebuild()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) は使わない")
  }

  /// 地球儀キーを出すか（`needsInputModeSwitchKey`）
  func setGlobeKeyVisible(_ visible: Bool) {
    globeButton.isHidden = !visible
  }

  private func rebuild() {
    for row in rows.arrangedSubviews {
      row.removeFromSuperview()
    }
    let characterRows = plane == .letters ? Self.letterRows : Self.symbolRows
    for (index, characters) in characterRows.enumerated() {
      var keys = characters.map { character in
        let text = displayed(String(character))
        return characterKey(text)
      }
      if index == characterRows.count - 1 {
        if plane == .letters {
          let shift = Self.makeKey(
            title: nil, symbol: isShifted ? "shift.fill" : "shift", accessibilityLabel: "大文字",
            isFunction: true)
          shift.addAction(UIAction { [weak self] _ in self?.toggleShift() }, for: .touchUpInside)
          keys.insert(shift, at: 0)
        }
        let delete = Self.makeKey(
          title: nil, symbol: "delete.left", accessibilityLabel: "1文字消す", isFunction: true)
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        keys.append(delete)
      }
      rows.addArrangedSubview(Self.row(keys))
    }

    let planeKey = Self.makeKey(
      title: plane == .letters ? "123" : "ABC",
      accessibilityLabel: plane == .letters ? "数字と記号" : "英字", isFunction: true)
    planeKey.addAction(UIAction { [weak self] _ in self?.togglePlane() }, for: .touchUpInside)
    let space = Self.makeKey(title: "空白", accessibilityLabel: "空白")
    space.addAction(UIAction { [weak self] _ in self?.onText?(" ") }, for: .touchUpInside)
    let newline = Self.makeKey(title: "改行", accessibilityLabel: "改行", isFunction: true)
    newline.addAction(UIAction { [weak self] _ in self?.onText?("\n") }, for: .touchUpInside)
    let bottom = UIStackView(arrangedSubviews: [planeKey, globeButton, space, newline])
    bottom.axis = .horizontal
    bottom.spacing = 6
    bottom.distribution = .fill
    space.setContentHuggingPriority(.defaultLow, for: .horizontal)
    planeKey.widthAnchor.constraint(equalToConstant: Self.functionKeyWidth).isActive = true
    newline.widthAnchor.constraint(equalToConstant: Self.newlineKeyWidth).isActive = true
    rows.addArrangedSubview(bottom)
  }

  private func displayed(_ text: String) -> String {
    plane == .letters && isShifted ? text.uppercased() : text
  }

  private func characterKey(_ text: String) -> UIButton {
    let key = Self.makeKey(title: text, accessibilityLabel: text)
    key.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        onText?(text)
        if isShifted {
          isShifted = false
          rebuild()
        }
      }, for: .touchUpInside)
    return key
  }

  private func toggleShift() {
    isShifted.toggle()
    rebuild()
  }

  private func togglePlane() {
    plane = plane == .letters ? .symbols : .letters
    isShifted = false
    rebuild()
  }

  private static func row(_ keys: [UIView]) -> UIStackView {
    let row = UIStackView(arrangedSubviews: keys)
    row.axis = .horizontal
    row.spacing = 6
    row.distribution = .fillEqually
    return row
  }

  private static func makeKey(
    title: String?, symbol: String? = nil, accessibilityLabel: String, isFunction: Bool = false
  ) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.title = title
    if let symbol { configuration.image = UIImage(systemName: symbol) }
    configuration.baseForegroundColor = UtterPalette.text
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 2, leading: 0, bottom: 2, trailing: 0)
    configuration.background.backgroundColor =
      isFunction ? UtterPalette.functionKey : UtterPalette.key
    configuration.background.cornerRadius = 6
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = UIFont.systemFont(ofSize: title.map { $0.count > 1 ? 15 : 20 } ?? 20)
      return attributes
    }
    let key = KeyButton(configuration: configuration)
    key.accessibilityLabel = accessibilityLabel
    key.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    return key
  }
}

/// キーの下に1ptの影を引くボタン（ライト/ダークで色が変わるため、描くたびに解決し直す）
private final class KeyButton: UIButton {
  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowColor = UtterPalette.keyShadow.resolvedColor(with: traitCollection).cgColor
    layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.shadowRadius = 0
    layer.shadowOpacity = 1
  }
}
