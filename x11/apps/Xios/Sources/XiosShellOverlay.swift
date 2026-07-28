import UIKit

final class XiosBatteryBadge: UIView {
    private let percentLabel = UILabel()
    private let chargingImage = UIImageView(image: UIImage(systemName: "bolt.fill"))
    private var level: Float = UIDevice.current.batteryLevel
    private var state: UIDevice.BatteryState = UIDevice.current.batteryState

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentLabel.textAlignment = .center
        percentLabel.textColor = .white
        percentLabel.adjustsFontSizeToFitWidth = true
        percentLabel.minimumScaleFactor = 0.75
        addSubview(percentLabel)

        chargingImage.translatesAutoresizingMaskIntoConstraints = false
        chargingImage.tintColor = .systemGreen
        chargingImage.contentMode = .scaleAspectFit
        addSubview(chargingImage)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 54),
            heightAnchor.constraint(equalToConstant: 24),
            percentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chargingImage.widthAnchor.constraint(equalToConstant: 8),
            chargingImage.heightAnchor.constraint(equalToConstant: 12),
            chargingImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chargingImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        update(level: level, state: state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 54, height: 24) }

    func update(level: Float, state: UIDevice.BatteryState) {
        self.level = level
        self.state = state
        if level >= 0 {
            percentLabel.text = "\(Int((level * 100).rounded()))%"
        } else {
            percentLabel.text = "--"
        }
        chargingImage.isHidden = !(state == .charging || state == .full)
        percentLabel.textColor = fillColor
        setNeedsDisplay()
    }

    private var fillColor: UIColor {
        if state == .charging || state == .full { return .systemGreen }
        if level >= 0 && level <= 0.15 { return .systemRed }
        return .white
    }

    override func draw(_ rect: CGRect) {
        let body = CGRect(x: 1, y: 4, width: bounds.width - 7, height: bounds.height - 8)
        let cap = CGRect(x: body.maxX + 1, y: body.midY - 4, width: 4, height: 8)
        let stroke = UIColor.white.withAlphaComponent(0.74)
        stroke.setStroke()
        stroke.setFill()
        UIBezierPath(roundedRect: body, cornerRadius: 5).stroke()
        UIBezierPath(roundedRect: cap, cornerRadius: 2).fill(with: .normal, alpha: 0.74)

        guard level >= 0 else { return }
        let clamped = CGFloat(max(0.05, min(1, level)))
        let fillRect = body.insetBy(dx: 3, dy: 3)
        let filled = CGRect(x: fillRect.minX, y: fillRect.minY,
                            width: fillRect.width * clamped, height: fillRect.height)
        fillColor.withAlphaComponent(0.28).setFill()
        UIBezierPath(roundedRect: filled, cornerRadius: 3).fill()
    }
}

final class XiosSystemStatusView: UIView {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private let clockLabel = UILabel()
    private let batteryBadge = XiosBatteryBadge()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = UIColor(white: 0.06, alpha: 0.70)
        layer.cornerRadius = 15
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)

        clockLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        clockLabel.textColor = .white
        clockLabel.textAlignment = .right

        let stack = UIStackView(arrangedSubviews: [clockLabel, batteryBadge])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        UIDevice.current.isBatteryMonitoringEnabled = true
        timer?.invalidate()
        if window != nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        } else {
            timer = nil
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        clockLabel.text = Self.clockFormatter.string(from: Date())
        batteryBadge.update(level: UIDevice.current.batteryLevel,
                            state: UIDevice.current.batteryState)
    }
}

/// Swift-owned shell chrome that floats above the compositor without stealing
/// desktop touches outside its own controls.
final class XiosShellOverlay: UIView {
    private let statusButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let systemStatusView = XiosSystemStatusView()
    private var chromeVisible = true

    var openPanel: (() -> Void)?
    var fitDisplay: (() -> Void)?
    var dismissOverlay: (() -> Void)?

    var isChromeVisible: Bool { chromeVisible }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        buildStatusButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for view in subviews where view.isUserInteractionEnabled && !view.isHidden && view.alpha > 0.01 {
            let converted = view.convert(point, from: self)
            if view.point(inside: converted, with: event) { return true }
        }
        return false
    }

    private func buildStatusButton() {
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.contentHorizontalAlignment = .left
        statusButton.backgroundColor = UIColor(white: 0.06, alpha: 0.70)
        statusButton.layer.cornerRadius = 15
        statusButton.layer.cornerCurve = .continuous
        statusButton.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        statusButton.layer.borderWidth = 1
        statusButton.layer.shadowColor = UIColor.black.cgColor
        statusButton.layer.shadowOpacity = 0.30
        statusButton.layer.shadowRadius = 18
        statusButton.layer.shadowOffset = CGSize(width: 0, height: 10)
        statusButton.addAction(UIAction { [weak self] _ in self?.openPanel?() }, for: .touchUpInside)
        addSubview(statusButton)
        systemStatusView.translatesAutoresizingMaskIntoConstraints = false
        systemStatusView.isUserInteractionEnabled = false
        addSubview(systemStatusView)

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 1
        stack.isUserInteractionEnabled = false
        statusButton.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = UIColor(white: 0.74, alpha: 1)
        detailLabel.lineBreakMode = .byTruncatingTail

        if #available(iOS 14.0, *) {
            statusButton.menu = UIMenu(children: [
                UIAction(title: "Open Xios") { [weak self] _ in self?.openPanel?() },
                UIAction(title: "Fit to Screen") { [weak self] _ in self?.fitDisplay?() },
                UIAction(title: "Hide This Bar", image: UIImage(systemName: "eye.slash")) {
                    [weak self] _ in self?.dismissOverlay?()
                },
            ])
            statusButton.showsMenuAsPrimaryAction = false
        }

        NSLayoutConstraint.activate([
            statusButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            statusButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            statusButton.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            statusButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            systemStatusView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            systemStatusView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            systemStatusView.leadingAnchor.constraint(greaterThanOrEqualTo: statusButton.trailingAnchor,
                                                      constant: 12),
            stack.topAnchor.constraint(equalTo: statusButton.topAnchor, constant: 7),
            stack.leadingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: statusButton.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: statusButton.bottomAnchor, constant: -7),
        ])
    }

    func update(session: String, detail: String, healthy: Bool) {
        titleLabel.text = session
        detailLabel.text = detail
        statusButton.layer.borderColor = (healthy ? UIColor.systemBlue : UIColor.systemOrange)
            .withAlphaComponent(0.55).cgColor
    }

    func setChromeVisible(_ visible: Bool, animated: Bool) {
        let views = [statusButton, systemStatusView]
        guard chromeVisible != visible || views.contains(where: { $0.isHidden == visible }) else { return }
        chromeVisible = visible

        if visible {
            views.forEach { view in
                view.isHidden = false
                view.transform = CGAffineTransform(translationX: 0, y: -18)
            }
        }

        let apply = {
            views.forEach { view in
                view.alpha = visible ? 1 : 0
                view.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: -18)
            }
        }
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            if !visible && !self.chromeVisible { views.forEach { $0.isHidden = true } }
        }

        if animated {
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                           animations: apply,
                           completion: finish)
        } else {
            apply()
            finish(true)
        }
    }
}
