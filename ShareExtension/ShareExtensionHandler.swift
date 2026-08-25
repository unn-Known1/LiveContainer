import SwiftUI
import UIKit

final class ShareExtensionHandler: UIViewController {
    private let viewModel = ShareExtensionViewModel()
    private var host: UIHostingController<ShareExtensionRootView>?
    private var didLoadPayload = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareExtensionRootView(viewModel: viewModel, extensionContext: extensionContext)
        let host = UIHostingController(rootView: root)
        self.host = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        // P2-C3: previously loadPayload was called from BOTH
        // viewDidLoad and beginRequest, racing. Guard with
        // didLoadPayload; the first call wins.
        loadPayloadOnce()
    }

    override func beginRequest(with context: NSExtensionContext) {
        loadPayloadOnce(context: context)
    }

    private func loadPayloadOnce(context: NSExtensionContext? = nil) {
        if didLoadPayload { return }
        didLoadPayload = true
        viewModel.loadPayload(from: context ?? extensionContext)
    }
}
