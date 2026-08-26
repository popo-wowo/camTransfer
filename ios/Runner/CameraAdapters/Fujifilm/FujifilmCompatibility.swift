import Foundation

enum FujifilmCompatibilityUUID {
  static let securePairService = "123D8F06-62A1-4935-9322-833C531EE225"
  static let legacyPairService = "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8"
  static let connectedDeviceIdentificationCharacteristic =
    "F557D96B-8284-4667-8793-B971C1DECA2A"
  static let transferAuthorizationCharacteristic = "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4"
}

extension PairingStrategyID {
  static let currentBaseline = PairingStrategyID(
    rawValue: "fujifilm-pairing-current-baseline"
  )
}

extension ActivationStrategyID {
  static let currentBaseline = ActivationStrategyID(
    rawValue: "fujifilm-activation-current-baseline"
  )
}

extension ActivationStrategyDefinition {
  static let currentWireBaseline = ActivationStrategyDefinition(
    id: .currentBaseline,
    writeSteps: [
      ActivationWriteStepDefinition(
        role: .imageTransferSetting,
        characteristicUUIDString:
          CameraVendorReferenceAppTransferActivationPlan
            .imageTransferSettingCharacteristicUUIDString,
        payload: Data([0x00])
      ),
      ActivationWriteStepDefinition(
        role: .imageTransferSettingExtended,
        characteristicUUIDString:
          CameraVendorReferenceAppTransferActivationPlan
            .imageTransferSettingExCharacteristicUUIDString,
        payload: Data([0x01])
      ),
      ActivationWriteStepDefinition(
        role: .imageResizeSetting,
        characteristicUUIDString:
          CameraVendorReferenceAppTransferActivationPlan
            .imageResizeSettingCharacteristicUUIDString,
        payload: CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
      ),
      ActivationWriteStepDefinition(
        role: .launchRequest,
        characteristicUUIDString:
          CameraVendorReferenceAppTransferActivationPlan
            .launchRequestCharacteristicUUIDString,
        payload: Data([0x03, 0x00])
      ),
    ],
    trackedStatusCharacteristicUUIDStrings: [
      CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
      CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
    ],
    completionPredicate: .apStateReadyToJoinWifi,
    retryTiming: ActivationRetryTimingPolicy(
      acknowledgementTimeoutSeconds: 12,
      responseProgressTimeoutSeconds: 15,
      maxAttempts: 1,
      retryOwner: .activationStrategy
    ),
    wifiHandoffPolicy: .requireVerifiedAssociation
  )

  init(
    id: ActivationStrategyID,
    launchRequestPayload: Data,
    allowsUnverifiedWifiHandoffAfterRecoverableError: Bool,
    supportStatus: CameraSupportStatus = .verified
  ) {
    let baseline = Self.currentWireBaseline
    self.init(
      id: id,
      writeSteps: baseline.writeSteps.map { step in
        guard step.role == .launchRequest else { return step }
        return ActivationWriteStepDefinition(
          role: step.role,
          characteristicUUIDString: step.characteristicUUIDString,
          payload: launchRequestPayload
        )
      },
      trackedStatusCharacteristicUUIDStrings: baseline.trackedStatusCharacteristicUUIDStrings,
      completionPredicate: baseline.completionPredicate,
      retryTiming: baseline.retryTiming,
      wifiHandoffPolicy: allowsUnverifiedWifiHandoffAfterRecoverableError
        ? .allowUnverifiedAssociationAfterRecoverableError
        : .requireVerifiedAssociation,
      supportStatus: supportStatus
    )
  }
}

extension PtpInitStrategyID {
  static let vendorLegacyCurrentBaseline = PtpInitStrategyID(
    rawValue: "fujifilm-vendor-legacy-current-baseline"
  )
}

extension PtpInitStrategyDefinition {
  static let currentWireBaseline = PtpInitStrategyDefinition(
    id: .vendorLegacyCurrentBaseline,
    packetVariants: [
      .vendorLegacyWithClientIPv4Guid,
      .vendorLegacyWithoutClientIPv4,
    ],
    ackParser: .currentLegacyTypeAndConnectionNumber,
    startupDelaySeconds: 0,
    retryTiming: PtpInitRetryTimingPolicy(
      perPacketAckTimeoutSeconds: CameraVendorOfficialGalleryPtpInitPolicy.initAckTimeoutSeconds,
      reconnectSocketBetweenPacketVariants: true,
      connectionMaxAttempts: CameraVendorPtpConnectionStartupPolicy.maxAttempts,
      connectionRetryBackoff: .currentLinearHalfSecond,
      retryOwner: .ptpInitStrategy
    )
  )
}

extension GalleryBootstrapStrategyID {
  static let currentVerifiedBaseline = GalleryBootstrapStrategyID(
    rawValue: "fujifilm-gallery-bootstrap-current-baseline"
  )
}

extension GalleryBootstrapStrategyDefinition {
  static let currentWireBaseline = GalleryBootstrapStrategyDefinition(
    id: .currentVerifiedBaseline,
    action: .currentLegacyReferenceAppGalleryMode,
    completionPredicate: .legacyReferenceAppGalleryModeConfirmed
  )
}

extension InitialCatalogStrategyID {
  static let directSpecifiedCatalog = InitialCatalogStrategyID(
    rawValue: "fujifilm-initial-catalog-direct-specified"
  )
  static let storeNotAvailableRecovery = InitialCatalogStrategyID(
    rawValue: "fujifilm-initial-catalog-store-not-available-recovery"
  )
  static let currentVerifiedBaseline = directSpecifiedCatalog
}

extension InitialCatalogStrategyDefinition {
  static let directSpecifiedCatalog = InitialCatalogStrategyDefinition(
    id: .directSpecifiedCatalog,
    action: .directSpecifiedCatalog
  )
  static let storeNotAvailableRecovery = InitialCatalogStrategyDefinition(
    id: .storeNotAvailableRecovery,
    action: .storeNotAvailableRecovery
  )
  static let currentWireBaseline = directSpecifiedCatalog
}

extension CameraGalleryFunctionFacts {
  static let currentBaseline = CameraGalleryFunctionFacts(
    functionMode: nil,
    cameraFunctionVersion: nil,
    selectedFunctionVersion: nil
  )
}

extension CameraCompatibilityRuleID {
  static let verifiedCurrentProtocolBaseline = CameraCompatibilityRuleID(
    rawValue: "verified-red-current-protocol-baseline"
  )
  static let verifiedStoreNotAvailableRecovery = CameraCompatibilityRuleID(
    rawValue: "verified-store-not-available-recovery"
  )
}

extension CameraStrategySelection {
  static let currentWireBaseline = CameraStrategySelection(
    pairingStrategy: .currentBaseline,
    activationStrategy: .currentBaseline,
    ptpInitStrategy: .vendorLegacyCurrentBaseline,
    negotiationStrategy: .notRequiredCurrentBaseline,
    galleryBootstrapStrategy: .currentVerifiedBaseline,
    initialCatalogStrategy: .directSpecifiedCatalog
  )

  static let storeNotAvailableRecovery = CameraStrategySelection(
    pairingStrategy: .currentBaseline,
    activationStrategy: .currentBaseline,
    ptpInitStrategy: .vendorLegacyCurrentBaseline,
    negotiationStrategy: .notRequiredCurrentBaseline,
    galleryBootstrapStrategy: .currentVerifiedBaseline,
    initialCatalogStrategy: .storeNotAvailableRecovery
  )

  static let currentBleOnly = CameraStrategySelection(
    pairingStrategy: .currentBaseline,
    activationStrategy: .currentBaseline,
    ptpInitStrategy: .unsupported,
    negotiationStrategy: .unsupported,
    galleryBootstrapStrategy: .unsupported,
    initialCatalogStrategy: .unsupported
  )
}

struct FujifilmProtocolStrategySnapshot: Equatable {
  let activation: ActivationStrategyDefinition
  let ptpInit: PtpInitStrategyDefinition?
  let negotiation: SessionNegotiationStrategyDefinition?
  let galleryBootstrap: GalleryBootstrapStrategyDefinition?
  let initialCatalog: InitialCatalogStrategyDefinition?
  let mediaOperations: FujifilmMediaOperationDefinition
}

enum FujifilmThumbnailOperation: String, Codable, Equatable {
  case standard
}

enum FujifilmMetadataOperation: String, Codable, Equatable {
  case objectInfo
}

enum FujifilmPreviewOperation: String, Codable, Equatable {
  case screenPreview
}

enum FujifilmDownloadOperation: String, Codable, Equatable {
  case original
}

enum FujifilmCatalogMembershipStrategy: String, Codable, Equatable {
  case baselineOnly
  case exactPerFormat
  case subtractBaseline
  case unknown
}

enum FujifilmCatalogChildWorkBarrier: String, Codable, Equatable {
  case awaitIdle
}

enum FujifilmSearchModeEvidence: String, Codable, Equatable {
  case unknown
  case stable
  case unstableAfterChildActivity
}

enum FujifilmD621ReferenceSemantics: String, Codable, Equatable {
  case sessionCatalogOpaque
}

struct FujifilmMediaOperationDefinition: Codable, Equatable {
  let searchMode: CameraVendorCatalogSearchModeStrategy
  let searchModeEvidence: FujifilmSearchModeEvidence
  let failClosedForUnknownSearchMode: Bool
  let catalogMembership: FujifilmCatalogMembershipStrategy
  let catalogChildWorkBarrier: FujifilmCatalogChildWorkBarrier
  let thumbnail: FujifilmThumbnailOperation
  let metadata: FujifilmMetadataOperation
  let preview: FujifilmPreviewOperation
  let download: FujifilmDownloadOperation
  let d621Reference: FujifilmD621ReferenceSemantics
  let modelName: String?
  let firmwareVersion: String?

  var requiresSessionScopedCatalog: Bool {
    d621Reference == .sessionCatalogOpaque
  }

  /// SearchMode safety is deliberately expressed as operation capabilities,
  /// not as a model-specific route. Unknown evidence disables backup-read,
  /// while the known explicit ALL payload remains an allowed conservative
  /// restore path.
  var backupReadAllowed: Bool {
    searchMode == .backupAndRestore && searchModeEvidence == .stable
  }

  var explicitAllRestoreAllowed: Bool {
    searchMode == .explicitAllRestore
  }

  var usesConservativeSearchMode: Bool {
    searchModeEvidence != .stable
  }

  var operationRejectedForUnknownSearchMode: Bool {
    false
  }

  static func current(for facts: CameraCompatibilityFacts) -> FujifilmMediaOperationDefinition {
    let searchModeEvidence: FujifilmSearchModeEvidence
    switch facts.searchModeReadbackStableAfterChildActivity {
    case .some(true): searchModeEvidence = .stable
    case .some(false): searchModeEvidence = .unstableAfterChildActivity
    case .none: searchModeEvidence = .unknown
    }
    let searchMode: CameraVendorCatalogSearchModeStrategy
    switch facts.searchModeReadbackStableAfterChildActivity {
    case .some(true):
      searchMode = .backupAndRestore
    case .some(false), .none:
      // Unknown is deliberately conservative: do not read a possibly stale
      // SearchMode payload after child activity.  An explicit ALL payload is
      // the only operation that does not depend on unverified readback.
      searchMode = .explicitAllRestore
    }
    return FujifilmMediaOperationDefinition(
      // The public baseline is intentionally model-agnostic. An explicit ALL
      // SearchMode transaction may only be selected by a verified current-
      // session evidence rule; model identity alone is not such evidence.
      searchMode: searchMode,
      searchModeEvidence: searchModeEvidence,
      failClosedForUnknownSearchMode: searchModeEvidence == .unknown,
      catalogMembership: .baselineOnly,
      catalogChildWorkBarrier: .awaitIdle,
      thumbnail: .standard,
      metadata: .objectInfo,
      preview: .screenPreview,
      download: .original,
      d621Reference: .sessionCatalogOpaque,
      modelName: facts.observedIdentity.modelName,
      firmwareVersion: facts.observedIdentity.firmwareVersion
    )
  }
}

enum FujifilmStrategyDefinitionFingerprint {
  static func hex<Definition: Encodable>(_ definition: Definition) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(definition) else {
      return "encoding-error"
    }

    var digest: UInt64 = 14695981039346656037
    for byte in data {
      digest ^= UInt64(byte)
      digest &*= 1099511628211
    }
    let value = String(digest, radix: 16)
    return String(repeating: "0", count: max(0, 16 - value.count)) + value
  }
}

enum FujifilmProtocolStrategyRegistryError: Error, Equatable, LocalizedError {
  case unverified(kind: String, id: String)
  case duplicate(kind: String, id: String)
  case unregistered(kind: String, id: String)
  case invalidDefinition(kind: String, id: String, reason: String)

  var errorDescription: String? {
    switch self {
    case let .unverified(kind, id):
      return "Unverified \(kind) strategy cannot enter the production registry: \(id)"
    case let .duplicate(kind, id):
      return "Duplicate \(kind) strategy: \(id)"
    case let .unregistered(kind, id):
      return "Unregistered \(kind) strategy: \(id)"
    case let .invalidDefinition(kind, id, reason):
      return "Invalid \(kind) strategy \(id): \(reason)"
    }
  }
}

struct FujifilmProtocolStrategyRegistry: Equatable {
  private let activationDefinitions: [ActivationStrategyID: ActivationStrategyDefinition]
  private let ptpInitDefinitions: [PtpInitStrategyID: PtpInitStrategyDefinition]
  private let negotiationDefinitions: [
    SessionNegotiationStrategyID: SessionNegotiationStrategyDefinition
  ]
  private let galleryBootstrapDefinitions: [
    GalleryBootstrapStrategyID: GalleryBootstrapStrategyDefinition
  ]
  private let initialCatalogDefinitions: [InitialCatalogStrategyID: InitialCatalogStrategyDefinition]

  init(
    activationDefinitions: [ActivationStrategyDefinition] = [.currentWireBaseline],
    ptpInitDefinitions: [PtpInitStrategyDefinition] = [.currentWireBaseline],
    negotiationDefinitions: [SessionNegotiationStrategyDefinition] = [.currentWireBaseline],
    galleryBootstrapDefinitions: [GalleryBootstrapStrategyDefinition] = [.currentWireBaseline],
    initialCatalogDefinitions: [InitialCatalogStrategyDefinition] = [
      .directSpecifiedCatalog,
      .storeNotAvailableRecovery,
    ]
  ) throws {
    try self.init(
      activationDefinitions: activationDefinitions,
      ptpInitDefinitions: ptpInitDefinitions,
      negotiationDefinitions: negotiationDefinitions,
      galleryBootstrapDefinitions: galleryBootstrapDefinitions,
      initialCatalogDefinitions: initialCatalogDefinitions,
      permitsExperimentalDefinitions: false
    )
  }

  private init(
    activationDefinitions: [ActivationStrategyDefinition],
    ptpInitDefinitions: [PtpInitStrategyDefinition],
    negotiationDefinitions: [SessionNegotiationStrategyDefinition],
    galleryBootstrapDefinitions: [GalleryBootstrapStrategyDefinition],
    initialCatalogDefinitions: [InitialCatalogStrategyDefinition],
    permitsExperimentalDefinitions: Bool
  ) throws {
    let activationCatalog = try Self.makeCatalog(
      kind: "activation",
      definitions: activationDefinitions,
      id: \.id,
      supportStatus: \.supportStatus,
      permitsExperimentalDefinitions: permitsExperimentalDefinitions
    )
    try Self.validateActivationDefinitions(activationCatalog.values)
    self.activationDefinitions = activationCatalog
    let ptpInitCatalog = try Self.makeCatalog(
      kind: "PTP INIT",
      definitions: ptpInitDefinitions,
      id: \.id,
      supportStatus: \.supportStatus,
      permitsExperimentalDefinitions: permitsExperimentalDefinitions
    )
    try Self.validatePtpInitDefinitions(ptpInitCatalog.values)
    self.ptpInitDefinitions = ptpInitCatalog
    self.negotiationDefinitions = try Self.makeCatalog(
      kind: "session negotiation",
      definitions: negotiationDefinitions,
      id: \.id,
      supportStatus: \.supportStatus,
      permitsExperimentalDefinitions: permitsExperimentalDefinitions
    )
    let galleryBootstrapCatalog = try Self.makeCatalog(
      kind: "gallery bootstrap",
      definitions: galleryBootstrapDefinitions,
      id: \.id,
      supportStatus: \.supportStatus,
      permitsExperimentalDefinitions: permitsExperimentalDefinitions
    )
    try Self.validateGalleryBootstrapDefinitions(galleryBootstrapCatalog.values)
    self.galleryBootstrapDefinitions = galleryBootstrapCatalog
    let initialCatalogCatalog = try Self.makeCatalog(
      kind: "initial Catalog",
      definitions: initialCatalogDefinitions,
      id: \.id,
      supportStatus: \.supportStatus,
      permitsExperimentalDefinitions: permitsExperimentalDefinitions
    )
    self.initialCatalogDefinitions = initialCatalogCatalog
  }

  func addingCompatibilityLabDefinition(
    _ definition: CameraCompatibilityLabExperimentalStrategyDefinition
  ) throws -> FujifilmProtocolStrategyRegistry {
    var activationDefinitions = Array(self.activationDefinitions.values)
    var ptpInitDefinitions = Array(self.ptpInitDefinitions.values)
    var negotiationDefinitions = Array(self.negotiationDefinitions.values)
    var galleryBootstrapDefinitions = Array(self.galleryBootstrapDefinitions.values)
    var initialCatalogDefinitions = Array(self.initialCatalogDefinitions.values)

    switch definition {
    case .activation(let value): activationDefinitions.append(value)
    case .ptpInit(let value): ptpInitDefinitions.append(value)
    case .negotiation(let value): negotiationDefinitions.append(value)
    case .galleryBootstrap(let value): galleryBootstrapDefinitions.append(value)
    case .initialCatalog(let value): initialCatalogDefinitions.append(value)
    }

    return try FujifilmProtocolStrategyRegistry(
      activationDefinitions: activationDefinitions,
      ptpInitDefinitions: ptpInitDefinitions,
      negotiationDefinitions: negotiationDefinitions,
      galleryBootstrapDefinitions: galleryBootstrapDefinitions,
      initialCatalogDefinitions: initialCatalogDefinitions,
      permitsExperimentalDefinitions: true
    )
  }

  func activationDefinition(
    for strategy: ActivationStrategyID
  ) throws -> ActivationStrategyDefinition {
    try definition(
      kind: "activation",
      id: strategy.rawValue,
      value: activationDefinitions[strategy]
    )
  }

  func ptpInitDefinition(
    for strategy: PtpInitStrategyID
  ) throws -> PtpInitStrategyDefinition {
    try definition(
      kind: "PTP INIT",
      id: strategy.rawValue,
      value: ptpInitDefinitions[strategy]
    )
  }

  func sessionNegotiationDefinition(
    for strategy: SessionNegotiationStrategyID
  ) throws -> SessionNegotiationStrategyDefinition {
    try definition(
      kind: "session negotiation",
      id: strategy.rawValue,
      value: negotiationDefinitions[strategy]
    )
  }

  func galleryBootstrapDefinition(
    for strategy: GalleryBootstrapStrategyID
  ) throws -> GalleryBootstrapStrategyDefinition {
    try definition(
      kind: "gallery bootstrap",
      id: strategy.rawValue,
      value: galleryBootstrapDefinitions[strategy]
    )
  }

  func initialCatalogDefinition(
    for strategy: InitialCatalogStrategyID
  ) throws -> InitialCatalogStrategyDefinition {
    try definition(
      kind: "initial Catalog",
      id: strategy.rawValue,
      value: initialCatalogDefinitions[strategy]
    )
  }

  func snapshot(
    for plan: CameraConnectionPlan,
    compatibilityFacts: CameraCompatibilityFacts
  ) throws -> FujifilmProtocolStrategySnapshot {
    FujifilmProtocolStrategySnapshot(
      activation: try activationDefinition(for: plan.activationStrategy),
      ptpInit: plan.ptpInitStrategy == .unsupported
        ? nil
        : try ptpInitDefinition(for: plan.ptpInitStrategy),
      negotiation: plan.negotiationStrategy == .unsupported
        ? nil
        : try sessionNegotiationDefinition(for: plan.negotiationStrategy),
      galleryBootstrap: plan.galleryBootstrapStrategy == .unsupported
        ? nil
        : try galleryBootstrapDefinition(for: plan.galleryBootstrapStrategy),
      initialCatalog: plan.initialCatalogStrategy == .unsupported
        ? nil
        : try initialCatalogDefinition(for: plan.initialCatalogStrategy),
      mediaOperations: .current(for: compatibilityFacts)
    )
  }

  func snapshot(for plan: CameraConnectionPlan) throws -> FujifilmProtocolStrategySnapshot {
    try snapshot(
      for: plan,
      compatibilityFacts: CameraCompatibilityFacts(
        observedIdentity: .unknown,
        protocolFacts: plan.protocolFacts
      )
    )
  }

  private static func makeCatalog<ID: Hashable, Definition>(
    kind: String,
    definitions: [Definition],
    id: KeyPath<Definition, ID>,
    supportStatus: KeyPath<Definition, CameraSupportStatus>,
    permitsExperimentalDefinitions: Bool
  ) throws -> [ID: Definition] where ID: RawRepresentable, ID.RawValue == String {
    var catalog: [ID: Definition] = [:]
    for definition in definitions {
      let definitionID = definition[keyPath: id]
      let status = definition[keyPath: supportStatus]
      guard status == .verified || (permitsExperimentalDefinitions && status == .experimental) else {
        throw FujifilmProtocolStrategyRegistryError.unverified(
          kind: kind,
          id: definitionID.rawValue
        )
      }
      guard catalog.updateValue(definition, forKey: definitionID) == nil else {
        throw FujifilmProtocolStrategyRegistryError.duplicate(
          kind: kind,
          id: definitionID.rawValue
        )
      }
    }
    return catalog
  }

  private static func validatePtpInitDefinitions(
    _ definitions: Dictionary<PtpInitStrategyID, PtpInitStrategyDefinition>.Values
  ) throws {
    for definition in definitions {
      guard !definition.packetVariants.isEmpty else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "PTP INIT",
          id: definition.id.rawValue,
          reason: "packetVariants must not be empty"
        )
      }
      guard definition.startupDelaySeconds.isFinite,
            definition.startupDelaySeconds >= 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "PTP INIT",
          id: definition.id.rawValue,
          reason: "startupDelaySeconds must be finite and non-negative"
        )
      }
      guard definition.retryTiming.perPacketAckTimeoutSeconds.isFinite,
            definition.retryTiming.perPacketAckTimeoutSeconds > 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "PTP INIT",
          id: definition.id.rawValue,
          reason: "perPacketAckTimeoutSeconds must be finite and greater than zero"
        )
      }
      guard definition.retryTiming.connectionMaxAttempts > 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "PTP INIT",
          id: definition.id.rawValue,
          reason: "connectionMaxAttempts must be greater than zero"
        )
      }
    }
  }

  private static func validateActivationDefinitions(
    _ definitions: Dictionary<ActivationStrategyID, ActivationStrategyDefinition>.Values
  ) throws {
    let requiredRoles = Set([
      ActivationWriteStepRole.imageTransferSetting.rawValue,
      ActivationWriteStepRole.imageTransferSettingExtended.rawValue,
      ActivationWriteStepRole.imageResizeSetting.rawValue,
      ActivationWriteStepRole.launchRequest.rawValue,
    ])

    for definition in definitions {
      let id = definition.id.rawValue
      guard !definition.writeSteps.isEmpty else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "writeSteps must not be empty"
        )
      }

      let roleValues = definition.writeSteps.map { $0.role.rawValue }
      guard Set(roleValues).count == roleValues.count else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "write step roles must be unique"
        )
      }
      guard definition.writeSteps.filter({ $0.role == .launchRequest }).count == 1 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "writeSteps must contain exactly one launchRequest step"
        )
      }
      guard Set(roleValues) == requiredRoles else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "writeSteps must contain every required role"
        )
      }

      let characteristicUUIDs = definition.writeSteps.map {
        $0.characteristicUUIDString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      }
      guard characteristicUUIDs.allSatisfy({ !$0.isEmpty }) else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "write step characteristic UUIDs must not be empty"
        )
      }
      guard Set(characteristicUUIDs).count == characteristicUUIDs.count else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "write step characteristic UUIDs must be unique"
        )
      }

      let trackedStatusUUIDs = definition.trackedStatusCharacteristicUUIDStrings.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      }
      guard !trackedStatusUUIDs.isEmpty, trackedStatusUUIDs.allSatisfy({ !$0.isEmpty }) else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "tracked status characteristic UUIDs must not be empty"
        )
      }
      switch definition.completionPredicate {
      case .apStateReadyToJoinWifi:
        guard trackedStatusUUIDs.contains(
          CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString
            .uppercased()
        ) else {
          throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
            kind: "activation",
            id: id,
            reason: "completion predicate is not matchable by tracked status characteristics"
          )
        }
      }

      guard definition.retryTiming.acknowledgementTimeoutSeconds.isFinite,
            definition.retryTiming.acknowledgementTimeoutSeconds > 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "acknowledgementTimeoutSeconds must be finite and greater than zero"
        )
      }
      guard definition.retryTiming.responseProgressTimeoutSeconds.isFinite,
            definition.retryTiming.responseProgressTimeoutSeconds > 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "responseProgressTimeoutSeconds must be finite and greater than zero"
        )
      }
      guard definition.retryTiming.maxAttempts > 0 else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "maxAttempts must be greater than zero"
        )
      }
      guard definition.retryTiming.retryOwner == .activationStrategy else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "activation",
          id: id,
          reason: "retryOwner must be activationStrategy"
        )
      }
    }
  }

  private static func validateGalleryBootstrapDefinitions(
    _ definitions: Dictionary<GalleryBootstrapStrategyID, GalleryBootstrapStrategyDefinition>.Values
  ) throws {
    for definition in definitions {
      guard definition.action == .currentLegacyReferenceAppGalleryMode,
            definition.completionPredicate == .legacyReferenceAppGalleryModeConfirmed else {
        throw FujifilmProtocolStrategyRegistryError.invalidDefinition(
          kind: "gallery bootstrap",
          id: definition.id.rawValue,
          reason: "completion predicate is not satisfiable by the selected action"
        )
      }
    }
  }

  private func definition<Definition>(
    kind: String,
    id: String,
    value: Definition?
  ) throws -> Definition {
    guard let value else {
      throw FujifilmProtocolStrategyRegistryError.unregistered(kind: kind, id: id)
    }
    return value
  }
}

enum FujifilmCompatibilityEnvironmentError: Error, Equatable, LocalizedError {
  case duplicateRuleID(CameraCompatibilityRuleID)
  case invalidPairingStrategy(ruleID: CameraCompatibilityRuleID, id: String)
  case unsupportedStrategy(ruleID: CameraCompatibilityRuleID, kind: String)
  case unregisteredStrategy(ruleID: CameraCompatibilityRuleID, kind: String, id: String)
  case invalidFallbackPairingStrategy(fallbackID: String, id: String)
  case unsupportedFallbackStrategy(fallbackID: String, kind: String)
  case unregisteredFallbackStrategy(fallbackID: String, kind: String, id: String)

  var errorDescription: String? {
    switch self {
    case .duplicateRuleID(let ruleID):
      return "Duplicate Fujifilm compatibility rule: \(ruleID.rawValue)"
    case let .invalidPairingStrategy(ruleID, id):
      return "Rule \(ruleID.rawValue) references invalid pairing strategy: \(id)"
    case let .unsupportedStrategy(ruleID, kind):
      return "Verified rule \(ruleID.rawValue) references unsupported \(kind) strategy"
    case let .unregisteredStrategy(ruleID, kind, id):
      return "Verified rule \(ruleID.rawValue) references unregistered \(kind) strategy: \(id)"
    case let .invalidFallbackPairingStrategy(fallbackID, id):
      return "Fujifilm \(fallbackID) references invalid pairing strategy: \(id)"
    case let .unsupportedFallbackStrategy(fallbackID, kind):
      return "Fujifilm \(fallbackID) references unsupported \(kind) strategy"
    case let .unregisteredFallbackStrategy(fallbackID, kind, id):
      return "Fujifilm \(fallbackID) references unregistered \(kind) strategy: \(id)"
    }
  }
}

struct FujifilmCompatibilityEnvironment {
  let compatibilityRegistry: CameraCompatibilityRegistry
  let strategyRegistry: FujifilmProtocolStrategyRegistry
  private let compatibilityLabCandidate: CameraCompatibilityLabCandidate?

  init(
    compatibilityRegistry: CameraCompatibilityRegistry,
    strategyRegistry: FujifilmProtocolStrategyRegistry
  ) throws {
    try self.init(
      compatibilityRegistry: compatibilityRegistry,
      strategyRegistry: strategyRegistry,
      compatibilityLabCandidate: nil
    )
  }

  private init(
    compatibilityRegistry: CameraCompatibilityRegistry,
    strategyRegistry: FujifilmProtocolStrategyRegistry,
    compatibilityLabCandidate: CameraCompatibilityLabCandidate?
  ) throws {
    try Self.validateCompatibilityRules(
      compatibilityRegistry.rules,
      strategyRegistry: strategyRegistry
    )
    try Self.validateSelection(
      .currentWireBaseline,
      context: .fallback(id: "full-GATT fallback", allowsUnsupportedFutureStages: false),
      strategyRegistry: strategyRegistry
    )
    try Self.validateSelection(
      .currentBleOnly,
      context: .fallback(id: "pre-GATT BLE-only fallback", allowsUnsupportedFutureStages: true),
      strategyRegistry: strategyRegistry
    )
    self.compatibilityRegistry = compatibilityRegistry
    self.strategyRegistry = strategyRegistry
    self.compatibilityLabCandidate = compatibilityLabCandidate
  }

  func resolve(
    protocolFacts: CameraProtocolFacts,
    revising lineage: CameraConnectionPlanVersion? = nil
  ) -> CameraConnectionPlanDecision {
    let decision = CameraConnectionPlanResolver.resolve(
      protocolFacts: protocolFacts,
      registry: compatibilityRegistry,
      fallback: fallback(for: protocolFacts),
      revising: lineage
    )
    guard let compatibilityLabCandidate else { return decision }
    return CameraConnectionPlanDecision(
      plan: compatibilityLabCandidate.preservingOverride(in: decision.plan),
      matchedRuleIDs: decision.matchedRuleIDs,
      rejectedRuleIDs: decision.rejectedRuleIDs,
      unresolvedFacts: decision.unresolvedFacts,
      confidence: .experimental,
      decisionTrace: decision.decisionTrace + [
        "compatibility-lab-candidate=\(compatibilityLabCandidate.id)"
      ]
    )
  }

  func strategySnapshot(
    for facts: CameraCompatibilityFacts
  ) throws -> FujifilmProtocolStrategySnapshot {
    let plan = resolve(protocolFacts: facts.protocolFacts).plan
    guard plan.supportStatus != .unsupported else {
      throw NSError(
        domain: "FujifilmCompatibilityEnvironment",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported facts cannot produce a Strategy snapshot"]
      )
    }
    return try strategyRegistry.snapshot(for: plan, compatibilityFacts: facts)
  }

  func addingCompatibilityLabCandidate(
    _ candidate: CameraCompatibilityLabCandidate
  ) throws -> FujifilmCompatibilityEnvironment {
    let labRegistry = try strategyRegistry.addingCompatibilityLabDefinition(
      candidate.strategyDefinition
    )
    return try FujifilmCompatibilityEnvironment(
      compatibilityRegistry: compatibilityRegistry,
      strategyRegistry: labRegistry,
      compatibilityLabCandidate: candidate
    )
  }

  static let production: FujifilmCompatibilityEnvironment = {
    do {
      let compatibilityRegistry = CameraCompatibilityRegistry(
        schemaVersion: 1,
        version: "ios-fujifilm-compatibility-2026-08-07",
        rules: [
          CameraCompatibilityRule(
            id: .verifiedStoreNotAvailableRecovery,
            priority: 300,
            supportStatus: .verified,
            compatibilityFamily: .red,
            requiredServices: [FujifilmCompatibilityUUID.securePairService],
            requiredCharacteristics: [
              FujifilmCompatibilityUUID.connectedDeviceIdentificationCharacteristic,
              FujifilmCompatibilityUUID.transferAuthorizationCharacteristic,
            ],
            responsePredicate: .catalogResponseClassification(.storeNotAvailable),
            selection: .storeNotAvailableRecovery
          ),
          CameraCompatibilityRule(
            id: .verifiedCurrentProtocolBaseline,
            priority: 200,
            supportStatus: .verified,
            compatibilityFamily: .red,
            requiredServices: [FujifilmCompatibilityUUID.securePairService],
            requiredCharacteristics: [
              FujifilmCompatibilityUUID.connectedDeviceIdentificationCharacteristic,
              FujifilmCompatibilityUUID.transferAuthorizationCharacteristic,
            ],
            responsePredicate: nil,
            selection: .currentWireBaseline
          ),
        ]
      )
      return try FujifilmCompatibilityEnvironment(
        compatibilityRegistry: compatibilityRegistry,
        strategyRegistry: FujifilmProtocolStrategyRegistry()
      )
    } catch {
      preconditionFailure("Invalid bundled Fujifilm compatibility environment: \(error)")
    }
  }()

  private func fallback(for facts: CameraProtocolFacts) -> CameraConnectionPlanFallback? {
    if facts.bleEndpointEvidence == .rememberedPairedPeripheral,
       facts.compatibilityFamily == nil,
       facts.discoveredCharacteristics.isEmpty {
      return CameraConnectionPlanFallback(
        supportStatus: .verified,
        selection: .currentBleOnly,
        decisionID: "verified-remembered-endpoint-current-ble-only",
        decisionTrace: "verified-fallback=remembered-endpoint-current-ble-only"
      )
    }
    guard facts.compatibilityFamily == .red,
          facts.advertisedServices.contains(FujifilmCompatibilityUUID.securePairService) else {
      return nil
    }
    if facts.discoveredCharacteristics.contains(
      FujifilmCompatibilityUUID.connectedDeviceIdentificationCharacteristic
    ), facts.discoveredCharacteristics.contains(
      FujifilmCompatibilityUUID.transferAuthorizationCharacteristic
    ) {
      return CameraConnectionPlanFallback(
        supportStatus: .experimental,
        selection: .currentWireBaseline,
        decisionID: "experimental-red-family-fallback",
        decisionTrace: "experimental-fallback=red-family-current-wire-baseline"
      )
    }
    if facts.discoveredCharacteristics.isEmpty {
      return CameraConnectionPlanFallback(
        supportStatus: .experimental,
        selection: .currentBleOnly,
        decisionID: "experimental-red-family-current-ble-only",
        decisionTrace: "experimental-fallback=red-family-current-ble-only"
      )
    }
    return nil
  }

  private static func validateCompatibilityRules(
    _ rules: [CameraCompatibilityRule],
    strategyRegistry: FujifilmProtocolStrategyRegistry
  ) throws {
    var ruleIDs: Set<CameraCompatibilityRuleID> = []
    for rule in rules {
      guard ruleIDs.insert(rule.id).inserted else {
        throw FujifilmCompatibilityEnvironmentError.duplicateRuleID(rule.id)
      }
      try validateSelection(
        rule.selection,
        context: .verifiedRule(rule.id),
        strategyRegistry: strategyRegistry
      )
    }
  }

  private enum SelectionValidationContext {
    case verifiedRule(CameraCompatibilityRuleID)
    case fallback(id: String, allowsUnsupportedFutureStages: Bool)

    var allowsUnsupportedFutureStages: Bool {
      guard case let .fallback(_, allowsUnsupportedFutureStages) = self else { return false }
      return allowsUnsupportedFutureStages
    }
  }

  private static func validateSelection(
    _ selection: CameraStrategySelection,
    context: SelectionValidationContext,
    strategyRegistry: FujifilmProtocolStrategyRegistry
  ) throws {
    guard selection.pairingStrategy == .currentBaseline else {
      if selection.pairingStrategy == .unsupported {
        throw unsupportedError(context: context, kind: "pairing")
      }
      throw invalidPairingError(context: context, id: selection.pairingStrategy.rawValue)
    }
    try validate(
      context: context,
      kind: "activation",
      id: selection.activationStrategy.rawValue,
      isUnsupported: selection.activationStrategy == .unsupported,
      allowsUnsupported: false
    ) {
      _ = try strategyRegistry.activationDefinition(for: selection.activationStrategy)
    }
    try validate(
      context: context,
      kind: "PTP INIT",
      id: selection.ptpInitStrategy.rawValue,
      isUnsupported: selection.ptpInitStrategy == .unsupported,
      allowsUnsupported: context.allowsUnsupportedFutureStages
    ) {
      _ = try strategyRegistry.ptpInitDefinition(for: selection.ptpInitStrategy)
    }
    try validate(
      context: context,
      kind: "session negotiation",
      id: selection.negotiationStrategy.rawValue,
      isUnsupported: selection.negotiationStrategy == .unsupported,
      allowsUnsupported: context.allowsUnsupportedFutureStages
    ) {
      _ = try strategyRegistry.sessionNegotiationDefinition(for: selection.negotiationStrategy)
    }
    try validate(
      context: context,
      kind: "gallery bootstrap",
      id: selection.galleryBootstrapStrategy.rawValue,
      isUnsupported: selection.galleryBootstrapStrategy == .unsupported,
      allowsUnsupported: context.allowsUnsupportedFutureStages
    ) {
      _ = try strategyRegistry.galleryBootstrapDefinition(for: selection.galleryBootstrapStrategy)
    }
    try validate(
      context: context,
      kind: "initial Catalog",
      id: selection.initialCatalogStrategy.rawValue,
      isUnsupported: selection.initialCatalogStrategy == .unsupported,
      allowsUnsupported: context.allowsUnsupportedFutureStages
    ) {
      _ = try strategyRegistry.initialCatalogDefinition(for: selection.initialCatalogStrategy)
    }
  }

  private static func validate(
    context: SelectionValidationContext,
    kind: String,
    id: String,
    isUnsupported: Bool,
    allowsUnsupported: Bool,
    lookup: () throws -> Void
  ) throws {
    if isUnsupported {
      guard allowsUnsupported else {
        throw unsupportedError(context: context, kind: kind)
      }
      return
    }
    do {
      try lookup()
    } catch FujifilmProtocolStrategyRegistryError.unregistered {
      throw unregisteredError(context: context, kind: kind, id: id)
    }
  }

  private static func invalidPairingError(
    context: SelectionValidationContext,
    id: String
  ) -> FujifilmCompatibilityEnvironmentError {
    switch context {
    case .verifiedRule(let ruleID):
      return .invalidPairingStrategy(ruleID: ruleID, id: id)
    case .fallback(let fallbackID, _):
      return .invalidFallbackPairingStrategy(fallbackID: fallbackID, id: id)
    }
  }

  private static func unsupportedError(
    context: SelectionValidationContext,
    kind: String
  ) -> FujifilmCompatibilityEnvironmentError {
    switch context {
    case .verifiedRule(let ruleID):
      return .unsupportedStrategy(ruleID: ruleID, kind: kind)
    case .fallback(let fallbackID, _):
      return .unsupportedFallbackStrategy(fallbackID: fallbackID, kind: kind)
    }
  }

  private static func unregisteredError(
    context: SelectionValidationContext,
    kind: String,
    id: String
  ) -> FujifilmCompatibilityEnvironmentError {
    switch context {
    case .verifiedRule(let ruleID):
      return .unregisteredStrategy(ruleID: ruleID, kind: kind, id: id)
    case .fallback(let fallbackID, _):
      return .unregisteredFallbackStrategy(fallbackID: fallbackID, kind: kind, id: id)
    }
  }
}
