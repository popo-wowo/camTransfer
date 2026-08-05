import Foundation

struct CameraVendorGalleryMainlineLoadResult {
  let confirmedSteps: [IOSCameraConnectionStep]
  let ptpSessionID: String
}

final class CameraVendorGalleryMainlineSessionLoader {
  private let galleryService: CameraVendorRealtimeGalleryService

  init(galleryService: CameraVendorRealtimeGalleryService) {
    self.galleryService = galleryService
  }

  func loadGallerySession(
    context: IOSCameraConnectionContext,
    publishStep: @escaping @MainActor (IOSCameraConnectionStep) -> Void
  ) async throws -> CameraVendorGalleryMainlineLoadResult {
    let fetchGeneration = try galleryService.beginMainlineGalleryFetch()
    defer { galleryService.finishMainlineGalleryFetch(generation: fetchGeneration) }

    var didCompleteWifiHandoff = false
    let prePtpCoordinator = IOSCameraGalleryConnectionCoordinator(
      onStepStarted: publishStep,
      runners: [
        IOSCameraConnectionStepRunner(step: .reconnectPairedBle) { [weak self] stepContext in
          guard let self else {
            throw CancellationError()
          }
          return try await self.executeReconnectPairedBleStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .transferAuthorization) { [weak self] stepContext in
          guard let self else {
            throw CancellationError()
          }
          return try await self.executeTransferAuthorizationStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .activateCameraWifi) { [weak self] stepContext in
          guard let self else {
            throw CancellationError()
          }
          return try await self.executeActivateCameraWifiStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .waitCameraWifiReady) { [weak self] stepContext in
          guard let self else {
            throw CancellationError()
          }
          return try await self.executeWaitCameraWifiReadyStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .joinCameraWifi) { [weak self] stepContext in
          guard let self else {
            throw CancellationError()
          }
          let result = try await executeJoinCameraWifiStep(
            context: stepContext,
            communicationGeneration: fetchGeneration,
            route: CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes.first
          )
          didCompleteWifiHandoff = result.didCompleteWifiHandoff
          return result.execution
        },
      ]
    )
    let prePtpContext = try await prePtpCoordinator.connect(context: context)
    let confirmedConnectionSteps = prePtpCoordinator.confirmedSteps()
    galleryService.appendGalleryRuntimeMessage(
      "[OBS] IOS_OFFICIAL_GALLERY_PRE_PTP_CONFIRMED steps=" +
      confirmedConnectionSteps.map(\.androidDisplayName).joined(separator: "->")
    )

    let diagnosticRoutes = CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes
    var lastRouteError: Error?
    var didEstablishGallerySession = false
    var galleryReadyConfirmedSteps = confirmedConnectionSteps
    var galleryReadyPTPSessionID: String?

    for (routeIndex, route) in diagnosticRoutes.enumerated() {
      var diagnostics: [String] = []
      let recorder: (String) -> Void = { [weak self] message in
        diagnostics.append(message)
        self?.galleryService.appendGalleryRuntimeMessage(message)
      }

      do {
        galleryService.prepareGalleryRouteAttempt(
          route,
          didCompleteWifiHandoff: didCompleteWifiHandoff,
          recorder: recorder
        )
        let routeCoordinator = IOSCameraGalleryConnectionCoordinator(
          initialConfirmedSteps: confirmedConnectionSteps,
          onStepStarted: publishStep,
          runners: [
            IOSCameraConnectionStepRunner(step: .connectPtp) { [weak self] stepContext in
              guard let self else {
                throw CancellationError()
              }
              return try executeConnectPtpStep(
                context: stepContext,
                communicationGeneration: fetchGeneration,
                recorder: recorder
              )
            },
            IOSCameraConnectionStepRunner(step: .confirmGalleryMode) { [weak self] stepContext in
              guard let self else {
                throw CancellationError()
              }
              return try self.executeConfirmGalleryModeStep(context: stepContext)
            },
            IOSCameraConnectionStepRunner(step: .loadGallery) { [weak self] stepContext in
              guard let self else {
                throw CancellationError()
              }
              return try executeLoadGalleryStep(context: stepContext)
            },
          ]
        )
        let galleryReadyContext = try await routeCoordinator.connect(context: prePtpContext)
        guard let ptpSessionID = galleryReadyContext.ptpSessionID,
              !ptpSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw IOSCameraConnectionIssue(
            step: .loadGallery,
            reason: "Gallery 主链完成后缺少有效的 PTP session"
          )
        }
        galleryReadyConfirmedSteps = routeCoordinator.confirmedSteps()
        galleryReadyPTPSessionID = ptpSessionID
        galleryService.appendGalleryRuntimeMessage(
          "[OBS] IOS_OFFICIAL_GALLERY_CONFIRMED steps=" +
          galleryReadyConfirmedSteps.map(\.androidDisplayName).joined(separator: "->")
        )
        galleryService.appendGalleryRuntimeMessage("[ROUTE \(route.id.rawValue)] PTP 与 GalleryMode 就绪，目录交由 Catalog Runtime")
        galleryService.completeSuccessfulGalleryRouteSearch()
        didEstablishGallerySession = true
        break
      } catch {
        lastRouteError = galleryService.buildGalleryRouteFailure(
          didCompleteWifiHandoff: didCompleteWifiHandoff,
          diagnostics: diagnostics,
          error: error
        )
        galleryService.appendGalleryRuntimeMessage("[ROUTE \(route.id.rawValue)] 失败: \(error.localizedDescription)")
      }

      if routeIndex < diagnosticRoutes.count - 1 {
        try await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }

    guard didEstablishGallerySession, let galleryReadyPTPSessionID else {
      throw lastRouteError ?? NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "所有 ReferenceApp 路线均未建立可用的 Gallery PTP 会话"]
      )
    }

    return CameraVendorGalleryMainlineLoadResult(
      confirmedSteps: galleryReadyConfirmedSteps,
      ptpSessionID: galleryReadyPTPSessionID
    )
  }

  func executeReconnectPairedBleStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.reconnectPairedBle) else {
      throw IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "必须先完成已配对相机 BLE 重连，不能从页面重试进入相册"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .bleIdentityVerified(cameraID: context.cameraID)
    )
  }

  func executeTransferAuthorizationStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.transferAuthorization) else {
      throw IOSCameraConnectionIssue(
        step: .transferAuthorization,
        reason: "相机没有返回本次官方 Wi-Fi 名称和密码，已停止进入 PTP"
      )
    }
    guard let wifiCredential = galleryService.currentOfficialWifiCredential() else {
      throw IOSCameraConnectionIssue(
        step: .transferAuthorization,
        reason: "当前官方 Wi-Fi 凭据不完整，已停止进入 PTP"
      )
    }
    var updatedContext = context
    updatedContext.wifiCredential = wifiCredential
    return IOSCameraConnectionStepExecution(
      context: updatedContext,
      evidence: .officialWifiCredential(wifiCredential)
    )
  }

  func executeActivateCameraWifiStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.activateCameraWifi) else {
      throw IOSCameraConnectionIssue(
        step: .activateCameraWifi,
        reason: "未确认传图激活命令已按官方流程写入相机"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .cameraWifiActivationAcknowledged
    )
  }

  func executeWaitCameraWifiReadyStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.waitCameraWifiReady) else {
      throw IOSCameraConnectionIssue(
        step: .waitCameraWifiReady,
        reason: "未收到相机进入可连接传图状态的正向信号"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .cameraWifiReady
    )
  }

  func executeJoinCameraWifiStep(
    context: IOSCameraConnectionContext,
    communicationGeneration: UInt64,
    route: CameraVendorGalleryRoute?
  ) async throws -> CameraVendorGalleryWifiHandoffStepResult {
    let handoff = try await galleryService.joinCameraWifi(
      context: context,
      communicationGeneration: communicationGeneration,
      route: route
    )
    return CameraVendorGalleryWifiHandoffStepResult(
      execution: IOSCameraConnectionStepExecution(
        context: context,
        evidence: .joinedCameraWifi(ssid: handoff.joinedSSID)
      ),
      didCompleteWifiHandoff: handoff.didCompleteWifiHandoff
    )
  }

  func executeConnectPtpStep(
    context: IOSCameraConnectionContext,
    communicationGeneration: UInt64,
    recorder: @escaping (String) -> Void
  ) throws -> IOSCameraConnectionStepExecution {
    let ptpEvidence = try galleryService.connectGalleryPtp(
      communicationGeneration: communicationGeneration,
      recorder: recorder
    )
    var updatedContext = context
    updatedContext.ptpSessionID = ptpEvidence.sessionID
    return IOSCameraConnectionStepExecution(
      context: updatedContext,
      evidence: .ptpConnected(ptpEvidence)
    )
  }

  func executeConfirmGalleryModeStep(
    context: IOSCameraConnectionContext
  ) throws -> IOSCameraConnectionStepExecution {
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .galleryModeConfirmed
    )
  }

  func executeLoadGalleryStep(
    context: IOSCameraConnectionContext
  ) throws -> IOSCameraConnectionStepExecution {
    guard let ptpSessionID = context.ptpSessionID,
          !ptpSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IOSCameraConnectionIssue(
        step: .loadGallery,
        reason: "Catalog Runtime 启动前缺少有效的 PTP session"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .galleryLoaded(
        IOSCameraGalleryReadyEvidence(ptpSessionID: ptpSessionID)
      )
    )
  }
}
