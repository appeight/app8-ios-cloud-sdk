import UIKit

/// Invisible subview pinned to its superview's edges. Fires `onFirstLayout`
/// once when the superview reaches a non-zero size — the returned VC has
/// no meaningful bounds until the host installs it.
final class LayoutSentinelView: UIView {
    private var onFirstLayout: ((CGSize, UITraitCollection) -> Void)?
    private var fired = false

    static func attach(
        to view: UIView,
        onFirstLayout: @escaping (CGSize, UITraitCollection) -> Void
    ) {
        let sentinel = LayoutSentinelView(frame: .zero)
        sentinel.onFirstLayout = onFirstLayout
        sentinel.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(sentinel, at: 0)
        NSLayoutConstraint.activate([
            sentinel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sentinel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sentinel.topAnchor.constraint(equalTo: view.topAnchor),
            sentinel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayoutSentinelView does not support NSCoder")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !fired else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        fired = true
        let cb = onFirstLayout
        onFirstLayout = nil
        cb?(size, traitCollection)
        removeFromSuperview()
    }
}
