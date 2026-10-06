import UIKit

/// A small label over the desktop: which desktop this is and what it is doing.
/// Shows while a desktop is connecting or reconnecting, briefly on entry, and
/// hides itself once the desktop is live. Never takes touches.
final class StatusPill: UIView {
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 0.06, alpha: 0.72)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        layer.borderWidth = 1
        alpha = 0
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `sticky`: keep showing until the next update (still connecting).
    func show(_ text: String, sticky: Bool, for seconds: TimeInterval = 3) {
        label.text = text
        hideWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.alpha = 0 }
    }
}
