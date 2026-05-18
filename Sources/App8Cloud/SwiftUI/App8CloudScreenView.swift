import SwiftUI
import UIKit

/// SwiftUI view that renders a single App8 screen, showing `placeholder`
/// while it loads and `fallback` if the render fails.
@available(iOS 18, *)
public struct App8CloudScreenView<Fallback: View>: View {

    let instance: App8Cloud.Instance
    let screenId: String
    let version: String?
    let parameters: [String: Any]
    let placeholder: AnyView?
    let fallback: (App8Cloud.Error) -> Fallback

    public init(
        instance: App8Cloud.Instance,
        screenId: String,
        version: String? = nil,
        parameters: [String: Any] = [:],
        @ViewBuilder placeholder: () -> some View = { Color.clear },
        @ViewBuilder fallback: @escaping (App8Cloud.Error) -> Fallback
    ) {
        self.instance = instance
        self.screenId = screenId
        self.version = version
        self.parameters = parameters
        self.placeholder = AnyView(placeholder())
        self.fallback = fallback
    }

    public var body: some View {
        _App8CloudScreenViewBridge(
            instance: instance,
            screenId: screenId,
            version: version,
            parameters: parameters,
            placeholder: placeholder,
            fallback: { error in AnyView(self.fallback(error)) }
        )
    }
}

@available(iOS 18, *)
private struct _App8CloudScreenViewBridge: UIViewControllerRepresentable {

    let instance: App8Cloud.Instance
    let screenId: String
    let version: String?
    let parameters: [String: Any]
    let placeholder: AnyView?
    let fallback: (App8Cloud.Error) -> AnyView

    func makeUIViewController(context: Context) -> AsyncLoadingContainer {
        let host = AsyncLoadingContainer()
        if let placeholder {
            host.setPlaceholder(placeholder)
        }
        let fallback = self.fallback
        Task { @MainActor in
            let vc = await instance.screen(
                id: screenId,
                version: version,
                parameters: parameters,
                fallback: { error in
                    UIHostingController(rootView: fallback(error))
                }
            )
            host.embed(vc)
        }
        return host
    }

    func updateUIViewController(_ uiViewController: AsyncLoadingContainer, context: Context) { }
}
