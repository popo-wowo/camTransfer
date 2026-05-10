import SwiftUI
import UIKit

@main
struct RunnerApp: App {
  var body: some Scene {
    WindowGroup {
      NativeRootViewControllerContainer()
        .ignoresSafeArea()
    }
  }
}

private struct NativeRootViewControllerContainer: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> UINavigationController {
    let controller = NativeNavigationController(rootViewController: NativeConnectViewController())
    controller.overrideUserInterfaceStyle = .light
    return controller
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

private final class NativeNavigationController: UINavigationController {
  override var preferredStatusBarStyle: UIStatusBarStyle {
    topViewController?.preferredStatusBarStyle ?? .darkContent
  }
}
