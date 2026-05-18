import UIKit
import SwiftUI

@MainActor
final class AsyncLoadingContainer: UIViewController {

    private var placeholderHost: UIHostingController<AnyView>?
    private var contentVC: UIViewController?

    func setPlaceholder<Placeholder: View>(_ placeholder: Placeholder) {
        removePlaceholder()
        let host = UIHostingController(rootView: AnyView(placeholder))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        placeholderHost = host
    }

    func embed(_ vc: UIViewController) {
        removePlaceholder()
        if let current = contentVC {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        vc.didMove(toParent: self)
        contentVC = vc
    }

    private func removePlaceholder() {
        guard let host = placeholderHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        placeholderHost = nil
    }
}
