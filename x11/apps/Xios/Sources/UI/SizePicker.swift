import UIKit

/// Screen size as one control with one meaning: Default, one of the three
/// profiles, or a custom width, height and DPI. `selection == nil` means "use the
/// desktop's own default size".
final class SizePickerView: UIStackView {
    private(set) var selection: DisplayProfile?
    var onChange: ((DisplayProfile?) -> Void)?

    private var chips: [(button: UIButton, profile: DisplayProfile?)] = []
    private var customOn = false
    private let widthField = UITextField()
    private let heightField = UITextField()
    private let dpiField = UITextField()
    private let customRow = UIStackView()
    private let errorLabel = UILabel()

    init(initial: DisplayProfile?) {
        selection = initial
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8

        let chipRow = UIStackView()
        chipRow.axis = .horizontal
        chipRow.spacing = 8
        chipRow.distribution = .fillEqually
        for (title, profile) in [("Default", nil)] + DisplayProfile.standard.map({ ($0.name, Optional($0)) }) {
            let b = makeChip(title)
            b.addAction(UIAction { [weak self] _ in self?.choose(profile) }, for: .touchUpInside)
            chips.append((b, profile))
            chipRow.addArrangedSubview(b)
        }
        let custom = makeChip("Custom")
        custom.addAction(UIAction { [weak self] _ in self?.chooseCustom() }, for: .touchUpInside)
        chipRow.addArrangedSubview(custom)
        customChip = custom
        addArrangedSubview(chipRow)

        for (f, p) in [(widthField, "Width"), (heightField, "Height"), (dpiField, "DPI")] {
            f.borderStyle = .roundedRect
            f.placeholder = p
            f.keyboardType = .numberPad
            f.addAction(UIAction { [weak self] _ in self?.customEdited() }, for: .editingChanged)
            customRow.addArrangedSubview(f)
        }
        customRow.axis = .horizontal
        customRow.spacing = 8
        customRow.distribution = .fillEqually
        customRow.isHidden = true
        addArrangedSubview(customRow)

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        addArrangedSubview(errorLabel)

        if let initial, !DisplayProfile.standard.contains(initial) {
            customOn = true
            widthField.text = String(initial.width)
            heightField.text = String(initial.height)
            dpiField.text = initial.dpi > 0 ? String(initial.dpi) : ""
            customRow.isHidden = false
        }
        restyle()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var customChip: UIButton?

    private func makeChip(_ title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .large
        config.baseForegroundColor = .white
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 13, weight: .semibold); return a
        }
        let b = UIButton(configuration: config)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return b
    }

    private func restyle() {
        func paint(_ b: UIButton, _ on: Bool) {
            var c = b.configuration
            c?.baseBackgroundColor = on ? Style.accent.withAlphaComponent(0.85) : UIColor(white: 0.24, alpha: 1)
            b.configuration = c
        }
        for chip in chips { paint(chip.button, !customOn && chip.profile == selection) }
        if let customChip { paint(customChip, customOn) }
    }

    private func choose(_ profile: DisplayProfile?) {
        customOn = false
        customRow.isHidden = true
        errorLabel.isHidden = true
        selection = profile
        restyle()
        onChange?(selection)
    }

    private func chooseCustom() {
        customOn = true
        customRow.isHidden = false
        restyle()
        customEdited()
    }

    private func customEdited() {
        let w = Int(widthField.text ?? "") ?? 0
        let h = Int(heightField.text ?? "") ?? 0
        let dpi = Int(dpiField.text ?? "") ?? 0
        guard w >= 640, h >= 480, w <= 4096, h <= 4096 else {
            errorLabel.text = "Use width and height from 640 to 4096."
            errorLabel.isHidden = false
            selection = nil
            onChange?(nil)
            return
        }
        guard dpi == 0 || (72...360).contains(dpi) else {
            errorLabel.text = "Use a DPI from 72 to 360, or leave it empty."
            errorLabel.isHidden = false
            selection = nil
            onChange?(nil)
            return
        }
        errorLabel.isHidden = true
        selection = DisplayProfile(name: "Custom", width: w, height: h, dpi: dpi)
        onChange?(selection)
    }

    /// False while Custom is chosen but its fields do not make a valid size.
    var isValid: Bool { !customOn || selection != nil }
}
