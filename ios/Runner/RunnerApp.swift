import SwiftUI
import UIKit

@main
struct RunnerApp: App {
  init() {
    AppLifecycleDiagnostics.install()
    _ = CameraSessionRuntimeAppContainer.shared
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
    let rootViewController = NativeConnectViewController(
      runtime: CameraSessionRuntimeAppContainer.shared.runtime
    )
    let controller = NativeNavigationController(
      rootViewController: rootViewController
    )
    controller.overrideUserInterfaceStyle = .light
    return controller
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

@MainActor
final class CameraSessionRuntimeAppContainer {
  static let shared = CameraSessionRuntimeAppContainer()

  let runtime: CameraSessionRuntime
  private let bridge: CameraVendorConnectFlowBridge
  private let recoveryConnector: CameraSessionRuntimeDeferredRecoveryConnector
  private let executionAuthority: CameraSessionUIKitExecutionAuthority
  private let lifecycleAdapter: CameraSessionRuntimeLifecycleAdapter

  private init() {
    let bridge = CameraVendorConnectFlowBridge()
    let transport = CameraSessionRuntimeDeferredTransport()
    let backgroundMaintainer = CameraSessionRuntimeDeferredBackgroundMaintainer()
    let executionAuthority = CameraSessionUIKitExecutionAuthority()
    let recoveryConnector = CameraSessionRuntimeDeferredRecoveryConnector()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraDownloadSessionRuntimeRecoveryStore(),
      savedHandleStore: CameraSessionRuntimeSavedHandleStore(),
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer,
      activityReporter: CameraSessionLiveActivityController(),
      recoveryConnector: recoveryConnector,
      connectionWorker: CameraSessionRuntimeConnectionWorker(
        flow: IOSCameraConnectFlowRuntime(environment: bridge)
      ),
      gallerySessionActivator: CameraVendorRuntimeGallerySessionActivator(
        bridge: bridge,
        deferredTransport: transport,
        deferredBackgroundMaintainer: backgroundMaintainer
      ),
      connectionController: bridge,
      legacyResumeMigrator: CameraSessionRuntimeLegacyResumeMigrator()
    )
    self.bridge = bridge
    self.recoveryConnector = recoveryConnector
    self.executionAuthority = executionAuthority
    self.runtime = runtime
    self.lifecycleAdapter = CameraSessionRuntimeLifecycleAdapter(runtime: runtime)
    executionAuthority.onExpired = { [weak runtime] in
      runtime?.send(.backgroundExecutionExpired)
    }
    recoveryConnector.attach(
      { [weak runtime] identity, completion in
        guard let runtime,
              let peripheralID = identity.peripheralID,
              let record = runtime.rememberedCameraRecords.first(where: { $0.peripheralID == peripheralID }),
              !runtime.isConnectionWorkerActive,
              !runtime.requiresSystemBluetoothPairingCleanup else {
          completion(false)
          return
        }
        runtime.startRememberedGalleryConnection(record: record) { state in
          if case .gallerySessionPrepared = state {
            completion(true)
          } else {
            completion(false)
          }
        }
      },
      cancellationHandler: { [weak runtime] reason in
        runtime?.cancelConnectionWorker(reason: "runtime-recovery-\(reason)")
      }
    )
  }

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
      "backgroundRemaining=\(CameraSessionRuntimeLifecycleLogPolicy.formattedBackgroundTimeRemaining(UIApplication.shared.backgroundTimeRemaining))"
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
