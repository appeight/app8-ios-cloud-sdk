import SwiftUI
import UIKit

/// SwiftUI view that launches a full App8 app, showing `placeholder` while
/// it loads and `fallback` if the launch fails.
@available(iOS 18, *)
public struct App8CloudAppView<Fallback: View>: View {

    let instance: App8Cloud.Instance
    let version: String?
    let placeholder: AnyView?
    let fallback: (App8Cloud.Error) -> Fallback

    public init(
        instance: App8Cloud.Instance,
        version: String? = nil,
        @ViewBuilder placeholder: () -> some View = { Color.clear },
        @ViewBuilder fallback: @escaping (App8Cloud.Error) -> Fallback
    ) {
        self.instance = instance
        self.version = version
        self.placeholder = AnyView(placeholder())
        self.fallback = fallback
    }

    public var body: some View {
        _App8CloudAppViewBridge(
            instance: instance,
            version: version,
            placeholder: placeholder,
            fallback: { error in AnyView(self.fallback(error)) }
        )
    }
}

@available(iOS 18, *)
private struct _App8CloudAppViewBridge: UIViewControllerRepresentable {

    let instance: App8Cloud.Instance
    let version: String?
    let placeholder: AnyView?
    let fallback: (App8Cloud.Error) -> AnyView

    func makeUIViewController(context: Context) -> AsyncLoadingContainer {
        let host = AsyncLoadingContainer()
        if let placeholder {
            host.setPlaceholder(placeholder)
        }
        let fallback = self.fallback
        Task { @MainActor in
            let vc = await instance.startApp(version: version, fallback: { error in
                UIHostingController(rootView: fallback(error))
            })
            host.embed(vc)
        }
        return host
    }

    func updateUIViewController(_ uiViewController: AsyncLoadingContainer, context: Context) { }
}
