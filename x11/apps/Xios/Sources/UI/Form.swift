import UIKit

/// Shared look for every screen except the desktop itself: dark, flat, native
/// controls. The launcher, sheets and settings all build on this.
enum Style {
    static let background = UIColor(white: 0.07, alpha: 1)
    static let card = UIColor(white: 0.14, alpha: 1)
    static let cardPressed = UIColor(white: 0.20, alpha: 1)
    static let separator = UIColor.white.withAlphaComponent(0.10)
    static let secondaryText = UIColor(white: 0.66, alpha: 1)
    static let accent = UIColor.systemBlue

    static func stateColor(_ state: SessionState) -> UIColor {
        switch state {
        case .running: return .systemGreen
        case .starting, .stopping: return .systemOrange
        case .failed, .killed: return .systemRed
        case .stopped, .unknown: return .systemGray
        }
    }
}

/// A scrolling vertical stack with the building blocks the sheets share.
class FormViewController: UIViewController {
    let scroll = UIScrollView()
    let stack = UIStackView()

    var maxContentWidth: CGFloat { 640 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.background
        overrideUserInterfaceStyle = .dark
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        let width = stack.widthAnchor.constraint(equalToConstant: maxContentWidth)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            width,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
        ])
    }

    func clearForm() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    // MARK: building blocks

    func section(_ title: String) {
        let l = label(title.uppercased(), size: 12, weight: .semibold, color: Style.secondaryText)
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(6, after: l)
    }

    @discardableResult
    func note(_ text: String, color: UIColor = Style.secondaryText) -> UILabel {
        let l = label(text, size: 13, color: color)
        stack.addArrangedSubview(l)
        return l
    }

    func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
               color: UIColor = .white) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = color
        l.font = .systemFont(ofSize: size, weight: weight)
        l.numberOfLines = 0
        return l
    }

    /// A full-width tappable row: title, optional detail, optional SF Symbol.
    func row(title: String, detail: String? = nil, symbol: String? = nil,
             selected: Bool = false, destructive: Bool = false,
             enabled: Bool = true, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = selected ? Style.accent.withAlphaComponent(0.35) : Style.card
        config.baseForegroundColor = destructive ? .systemRed : .white
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        config.title = title
        config.subtitle = detail
        config.titleAlignment = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 16, weight: .semibold); return a
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 12); a.foregroundColor = Style.secondaryText; return a
        }
        if let symbol {
            config.image = UIImage(systemName: symbol)
            config.imagePadding = 12
        }
        let b = UIButton(configuration: config)
        b.contentHorizontalAlignment = .leading
        b.isEnabled = enabled
        b.alpha = enabled ? 1 : 0.45
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        stack.addArrangedSubview(b)
        return b
    }

    /// A compact pill button for button rows.
    func pill(_ title: String, selected: Bool = false, destructive: Bool = false,
              action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = selected ? Style.accent.withAlphaComponent(0.85)
            : (destructive ? UIColor.systemRed.withAlphaComponent(0.45) : UIColor(white: 0.24, alpha: 1))
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 14, weight: .semibold); return a
        }
        let b = UIButton(configuration: config)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return b
    }

    @discardableResult
    func buttonRow(_ buttons: [UIButton]) -> UIStackView {
        let r = UIStackView(arrangedSubviews: buttons)
        r.axis = .horizontal
        r.spacing = 8
        r.distribution = .fillEqually
        stack.addArrangedSubview(r)
        return r
    }

    func textField(_ placeholder: String, keyboard: UIKeyboardType = .default) -> UITextField {
        let f = UITextField()
        f.borderStyle = .roundedRect
        f.placeholder = placeholder
        f.keyboardType = keyboard
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.clearButtonMode = .whileEditing
        return f
    }

    func closeButtonItem() -> UIBarButtonItem {
        UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }
}

/// A short-lived message strip at the bottom of a screen.
final class Toast {
    static func show(_ text: String, in view: UIView) {
        let tag = 0x7057
        view.viewWithTag(tag)?.removeFromSuperview()
        let l = PaddedLabel()
        l.tag = tag
        l.text = text
        l.numberOfLines = 3
        l.textAlignment = .center
        l.textColor = .white
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.backgroundColor = UIColor(white: 0.22, alpha: 0.96)
        l.layer.cornerRadius = 12
        l.layer.masksToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        l.alpha = 0
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            l.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
        ])
        UIView.animate(withDuration: 0.2) { l.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak l] in
            UIView.animate(withDuration: 0.3, animations: { l?.alpha = 0 }) { _ in
                l?.removeFromSuperview()
            }
        }
    }

    private final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)))
        }
        override var intrinsicContentSize: CGSize {
            let s = super.intrinsicContentSize
            return CGSize(width: s.width + 32, height: s.height + 20)
        }
    }
}
