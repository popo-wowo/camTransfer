import SwiftUI
import UIKit

@main
struct RunnerApp: App {
  init() {
    AppLifecycleDiagnostics.install()
  }

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

private enum AppLifecycleDiagnostics {
  private static var didInstall = false

  static func install() {
    guard !didInstall else { return }
    didInstall = true
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      log("didBecomeActive")
    }
    center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      log("willResignActive")
    }
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      log("didEnterBackground")
    }
    center.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      log("willEnterForeground")
    }
    CameraVendorFileLogger.log("[APP_LIFECYCLE] installed")
  }

  private static func log(_ event: String) {
    CameraVendorFileLogger.log(
      "[APP_LIFECYCLE] event=\(event) state=\(applicationStateDescription) " +
      "backgroundRemaining=\(NativeGalleryBackgroundRuntimePolicy.formattedBackgroundTimeRemaining(UIApplication.shared.backgroundTimeRemaining))"
    )
  }

  private static var applicationStateDescription: String {
    switch UIApplication.shared.applicationState {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown"
    }
  }
}
