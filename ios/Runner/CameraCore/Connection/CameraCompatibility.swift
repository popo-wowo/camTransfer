import Foundation

enum CameraCompatibilityFamily: String, Codable, Equatable {
  case legacy
  case red
  case xHalf
}

enum CameraPtpTransport: String, Codable, Equatable {
  case cameraVendorLegacy
  case standardPtpIp
}

enum CameraSupportStatus: String, Codable, Equatable {
  case verified
  case experimental
  case unsupported
}

enum CameraResponsePredicate: Codable, Equatable {
  case successfulInitStrategy(PtpInitStrategyID)
  case operationTransport(CameraPtpTransport)
  case catalogResponseClassification(CameraCatalogResponseClassification)
  case functionMode(UInt32)
  case cameraFunctionVersion(lowerInclusive: UInt32, upperExclusive: UInt32?)
  case selectedFunctionVersion(lowerInclusive: UInt32, upperExclusive: UInt32?)

  func matches(_ facts: CameraProtocolFacts) -> Bool {
    switch self {
    case .successfulInitStrategy(let strategy):
      return facts.successfulInitStrategy == strategy
    case .operationTransport(let transport):
      return facts.operationTransport == transport
    case .catalogResponseClassification(let classification):
      return facts.catalogResponseFacts?.classification == classification
    case .functionMode(let mode):
      return facts.functionMode == mode
    case .cameraFunctionVersion(let lowerInclusive, let upperExclusive):
      return Self.contains(
        facts.cameraFunctionVersion,
        lowerInclusive: lowerInclusive,
        upperExclusive: upperExclusive
      )
    case .selectedFunctionVersion(let lowerInclusive, let upperExclusive):
      return Self.contains(
        facts.selectedFunctionVersion,
        lowerInclusive: lowerInclusive,
        upperExclusive: upperExclusive
      )
    }
  }

  private static func contains(
    _ value: UInt32?,
    lowerInclusive: UInt32,
    upperExclusive: UInt32?
  ) -> Bool {
    guard let value, value >= lowerInclusive else { return false }
    return upperExclusive.map { value < $0 } ?? true
  }
}

struct PairingStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let unsupported = PairingStrategyID(rawValue: "unsupported")
}

struct ActivationStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let unsupported = ActivationStrategyID(rawValue: "unsupported")
}

enum ActivationWriteStepRole: String, Codable, Equatable {
  case imageTransferSetting
  case imageTransferSettingExtended
  case imageResizeSetting
  case launchRequest
}

struct ActivationWriteStepDefinition: Codable, Equatable {
  let role: ActivationWriteStepRole
  let characteristicUUIDString: String
  let payload: Data
}

enum ActivationCompletionPredicate: String, Codable, Equatable {
  case apStateReadyToJoinWifi
}

struct ActivationRetryTimingPolicy: Codable, Equatable {
  let acknowledgementTimeoutSeconds: TimeInterval
  let responseProgressTimeoutSeconds: TimeInterval
  let maxAttempts: Int
  let retryOwner: CameraConnectionRetryOwner
}

enum ActivationWifiHandoffPolicy: String, Codable, Equatable {
  case requireVerifiedAssociation
  case allowUnverifiedAssociationAfterRecoverableError
}

struct ActivationStrategyDefinition: Codable, Equatable {
  let id: ActivationStrategyID
  let writeSteps: [ActivationWriteStepDefinition]
  let trackedStatusCharacteristicUUIDStrings: [String]
  let completionPredicate: ActivationCompletionPredicate
  let retryTiming: ActivationRetryTimingPolicy
  let wifiHandoffPolicy: ActivationWifiHandoffPolicy
  let supportStatus: CameraSupportStatus

  init(
    id: ActivationStrategyID,
    writeSteps: [ActivationWriteStepDefinition],
    trackedStatusCharacteristicUUIDStrings: [String],
    completionPredicate: ActivationCompletionPredicate,
    retryTiming: ActivationRetryTimingPolicy,
    wifiHandoffPolicy: ActivationWifiHandoffPolicy,
    supportStatus: CameraSupportStatus = .verified
  ) {
    self.id = id
    self.writeSteps = writeSteps
    self.trackedStatusCharacteristicUUIDStrings = trackedStatusCharacteristicUUIDStrings
    self.completionPredicate = completionPredicate
    self.retryTiming = retryTiming
    self.wifiHandoffPolicy = wifiHandoffPolicy
    self.supportStatus = supportStatus
  }

  var launchRequestPayload: Data {
    writeSteps.first(where: { $0.role == .launchRequest })?.payload ?? Data()
  }

  var allowsUnverifiedWifiHandoffAfterRecoverableError: Bool {
    wifiHandoffPolicy == .allowUnverifiedAssociationAfterRecoverableError
  }
}

struct PtpInitStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let unsupported = PtpInitStrategyID(rawValue: "unsupported")
}

enum PtpInitPacketVariantID: String, Codable, Equatable {
  case vendorLegacyWithClientIPv4Guid
  case vendorLegacyWithoutClientIPv4
}

enum PtpInitAckParserID: String, Codable, Equatable {
  case currentLegacyTypeAndConnectionNumber
}

enum CameraConnectionRetryOwner: String, Codable, Equatable {
  case activationStrategy
  case protocolEngine
  case ptpInitStrategy
  case negotiationStrategy
  case galleryBootstrapStrategy
  case catalogRuntime
  case sessionRuntime
}

enum CameraConnectionRetryBackoffID: String, Codable, Equatable {
  case currentLinearHalfSecond
}

struct PtpInitRetryTimingPolicy: Codable, Equatable {
  let perPacketAckTimeoutSeconds: TimeInterval
  let reconnectSocketBetweenPacketVariants: Bool
  let connectionMaxAttempts: Int
  let connectionRetryBackoff: CameraConnectionRetryBackoffID
  let retryOwner: CameraConnectionRetryOwner
}

struct PtpInitStrategyDefinition: Codable, Equatable {
  let id: PtpInitStrategyID
  let packetVariants: [PtpInitPacketVariantID]
  let ackParser: PtpInitAckParserID
  let startupDelaySeconds: TimeInterval
  let retryTiming: PtpInitRetryTimingPolicy
  let supportStatus: CameraSupportStatus

  init(
    id: PtpInitStrategyID,
    packetVariants: [PtpInitPacketVariantID],
    ackParser: PtpInitAckParserID,
    startupDelaySeconds: TimeInterval,
    retryTiming: PtpInitRetryTimingPolicy,
    supportStatus: CameraSupportStatus = .verified
  ) {
    self.id = id
    self.packetVariants = packetVariants
    self.ackParser = ackParser
    self.startupDelaySeconds = startupDelaySeconds
    self.retryTiming = retryTiming
    self.supportStatus = supportStatus
  }
}

struct SessionNegotiationStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let notRequiredCurrentBaseline = SessionNegotiationStrategyID(
    rawValue: "not-required-current-baseline"
  )
  static let unsupported = SessionNegotiationStrategyID(rawValue: "unsupported")
}

enum SessionNegotiationStrategyAction: String, Codable, Equatable {
  case notRequired
}

enum GalleryFunctionInspectionStrategyAction: String, Codable, Equatable {
  case noFacts
}

struct SessionNegotiationStrategyDefinition: Codable, Equatable {
  let id: SessionNegotiationStrategyID
  let action: SessionNegotiationStrategyAction
  let inspectionAction: GalleryFunctionInspectionStrategyAction
  let supportStatus: CameraSupportStatus

  init(
    id: SessionNegotiationStrategyID,
    action: SessionNegotiationStrategyAction,
    inspectionAction: GalleryFunctionInspectionStrategyAction,
    supportStatus: CameraSupportStatus = .verified
  ) {
    self.id = id
    self.action = action
    self.inspectionAction = inspectionAction
    self.supportStatus = supportStatus
  }

  static let currentWireBaseline = SessionNegotiationStrategyDefinition(
    id: .notRequiredCurrentBaseline,
    action: .notRequired,
    inspectionAction: .noFacts
  )
}

struct GalleryBootstrapStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let unsupported = GalleryBootstrapStrategyID(rawValue: "unsupported")
}

enum GalleryBootstrapStrategyAction: String, Codable, Equatable {
  case currentLegacyReferenceAppGalleryMode
}

enum GalleryBootstrapCompletionPredicate: String, Codable, Equatable {
  case legacyReferenceAppGalleryModeConfirmed
  case standardGalleryHandshakeCompleted
}

struct GalleryBootstrapStrategyDefinition: Codable, Equatable {
  let id: GalleryBootstrapStrategyID
  let action: GalleryBootstrapStrategyAction
  let completionPredicate: GalleryBootstrapCompletionPredicate
  let supportStatus: CameraSupportStatus

  init(
    id: GalleryBootstrapStrategyID,
    action: GalleryBootstrapStrategyAction,
    completionPredicate: GalleryBootstrapCompletionPredicate,
    supportStatus: CameraSupportStatus = .verified
  ) {
    self.id = id
    self.action = action
    self.completionPredicate = completionPredicate
    self.supportStatus = supportStatus
  }
}

struct InitialCatalogStrategyID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  static let unsupported = InitialCatalogStrategyID(rawValue: "unsupported")
}

enum InitialCatalogStrategyAction: String, Codable, Equatable {
  case directSpecifiedCatalog
  case storeNotAvailableRecovery
}

struct InitialCatalogStrategyDefinition: Codable, Equatable {
  let id: InitialCatalogStrategyID
  let action: InitialCatalogStrategyAction
  let supportStatus: CameraSupportStatus

  init(
    id: InitialCatalogStrategyID,
    action: InitialCatalogStrategyAction,
    supportStatus: CameraSupportStatus = .verified
  ) {
    self.id = id
    self.action = action
    self.supportStatus = supportStatus
  }
}

enum CameraCatalogResponseClassification: String, Codable, Equatable {
  case storeNotAvailable
}

struct CameraCatalogResponseFacts: Codable, Equatable {
  private enum CodingKeys: String, CodingKey {
    case operationCode
    case responseCode
    case classification
  }

  let operationCode: UInt16
  let responseCode: UInt16
  let classification: CameraCatalogResponseClassification

  private init(
    operationCode: UInt16,
    responseCode: UInt16,
    classification: CameraCatalogResponseClassification
  ) {
    self.operationCode = operationCode
    self.responseCode = responseCode
    self.classification = classification
  }

  static func classify(
    operationCode: UInt16,
    responseCode: UInt16
  ) -> CameraCatalogResponseFacts? {
    guard operationCode == 0x9053, responseCode == 0x2013 else { return nil }
    return CameraCatalogResponseFacts(
      operationCode: operationCode,
      responseCode: responseCode,
      classification: .storeNotAvailable
    )
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let operationCode = try container.decode(UInt16.self, forKey: .operationCode)
    let responseCode = try container.decode(UInt16.self, forKey: .responseCode)
    guard let classified = Self.classify(
      operationCode: operationCode,
      responseCode: responseCode
    ) else {
      throw DecodingError.dataCorruptedError(
        forKey: .responseCode,
        in: container,
        debugDescription: "Unsupported initial Catalog operation/response classification"
      )
    }
    self = classified
  }
}

struct CameraObservedIdentity: Codable, Equatable {
  let modelName: String?
  let firmwareVersion: String?

  init(modelName: String?, firmwareVersion: String?) {
    self.modelName = Self.normalizedOptional(modelName)
    self.firmwareVersion = Self.normalizedOptional(firmwareVersion)
  }

  private static func normalizedOptional(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  static let unknown = CameraObservedIdentity(modelName: nil, firmwareVersion: nil)
}

enum CameraBleEndpointEvidence: String, Codable, Equatable {
  case none
  case rememberedPairedPeripheral
}

struct CameraProtocolFacts: Codable, Equatable {
  private enum CodingKeys: String, CodingKey {
    case compatibilityFamily
    case advertisedServices
    case discoveredCharacteristics
    case successfulInitStrategy
    case operationTransport
    case functionMode
    case cameraFunctionVersion
    case selectedFunctionVersion
    case bleEndpointEvidence
    case catalogResponseFacts
  }

  let compatibilityFamily: CameraCompatibilityFamily?
  let advertisedServices: Set<String>
  let discoveredCharacteristics: Set<String>
  let successfulInitStrategy: PtpInitStrategyID?
  let operationTransport: CameraPtpTransport?
  let functionMode: UInt32?
  let cameraFunctionVersion: UInt32?
  let selectedFunctionVersion: UInt32?
  let bleEndpointEvidence: CameraBleEndpointEvidence
  let catalogResponseFacts: CameraCatalogResponseFacts?

  init(
    compatibilityFamily: CameraCompatibilityFamily?,
    advertisedServices: Set<String>,
    discoveredCharacteristics: Set<String>,
    successfulInitStrategy: PtpInitStrategyID? = nil,
    operationTransport: CameraPtpTransport? = nil,
    functionMode: UInt32? = nil,
    cameraFunctionVersion: UInt32? = nil,
    selectedFunctionVersion: UInt32? = nil,
    bleEndpointEvidence: CameraBleEndpointEvidence = .none,
    catalogResponseFacts: CameraCatalogResponseFacts? = nil
  ) {
    self.compatibilityFamily = compatibilityFamily
    self.advertisedServices = Set(advertisedServices.map(Self.normalize))
    self.discoveredCharacteristics = Set(discoveredCharacteristics.map(Self.normalize))
    self.successfulInitStrategy = successfulInitStrategy
    self.operationTransport = operationTransport
    self.functionMode = functionMode
    self.cameraFunctionVersion = cameraFunctionVersion
    self.selectedFunctionVersion = selectedFunctionVersion
    self.bleEndpointEvidence = bleEndpointEvidence
    self.catalogResponseFacts = catalogResponseFacts
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      compatibilityFamily: try container.decodeIfPresent(
        CameraCompatibilityFamily.self,
        forKey: .compatibilityFamily
      ),
      advertisedServices: try container.decode(Set<String>.self, forKey: .advertisedServices),
      discoveredCharacteristics: try container.decode(
        Set<String>.self,
        forKey: .discoveredCharacteristics
      ),
      successfulInitStrategy: try container.decodeIfPresent(
        PtpInitStrategyID.self,
        forKey: .successfulInitStrategy
      ),
      operationTransport: try container.decodeIfPresent(
        CameraPtpTransport.self,
        forKey: .operationTransport
      ),
      functionMode: try container.decodeIfPresent(UInt32.self, forKey: .functionMode),
      cameraFunctionVersion: try container.decodeIfPresent(
        UInt32.self,
        forKey: .cameraFunctionVersion
      ),
      selectedFunctionVersion: try container.decodeIfPresent(
        UInt32.self,
        forKey: .selectedFunctionVersion
      ),
      bleEndpointEvidence: try container.decodeIfPresent(
        CameraBleEndpointEvidence.self,
        forKey: .bleEndpointEvidence
      ) ?? .none,
      catalogResponseFacts: try container.decodeIfPresent(
        CameraCatalogResponseFacts.self,
        forKey: .catalogResponseFacts
      )
    )
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  func updating(
    successfulInitStrategy: PtpInitStrategyID,
    operationTransport: CameraPtpTransport
  ) -> CameraProtocolFacts {
    CameraProtocolFacts(
      compatibilityFamily: compatibilityFamily,
      advertisedServices: advertisedServices,
      discoveredCharacteristics: discoveredCharacteristics,
      successfulInitStrategy: successfulInitStrategy,
      operationTransport: operationTransport,
      functionMode: functionMode,
      cameraFunctionVersion: cameraFunctionVersion,
      selectedFunctionVersion: selectedFunctionVersion,
      bleEndpointEvidence: bleEndpointEvidence,
      catalogResponseFacts: catalogResponseFacts
    )
  }

  var beforeGattDiscovery: CameraProtocolFacts {
    CameraProtocolFacts(
      compatibilityFamily: compatibilityFamily,
      advertisedServices: advertisedServices,
      discoveredCharacteristics: [],
      bleEndpointEvidence: bleEndpointEvidence
    )
  }

  func updating(functionFacts: CameraGalleryFunctionFacts) -> CameraProtocolFacts {
    CameraProtocolFacts(
      compatibilityFamily: compatibilityFamily,
      advertisedServices: advertisedServices,
      discoveredCharacteristics: discoveredCharacteristics,
      successfulInitStrategy: successfulInitStrategy,
      operationTransport: operationTransport,
      functionMode: functionFacts.functionMode ?? functionMode,
      cameraFunctionVersion: functionFacts.cameraFunctionVersion ?? cameraFunctionVersion,
      selectedFunctionVersion: functionFacts.selectedFunctionVersion ?? selectedFunctionVersion,
      bleEndpointEvidence: bleEndpointEvidence,
      catalogResponseFacts: catalogResponseFacts
    )
  }

  func updating(
    catalogResponseFacts: CameraCatalogResponseFacts?
  ) -> CameraProtocolFacts {
    CameraProtocolFacts(
      compatibilityFamily: compatibilityFamily,
      advertisedServices: advertisedServices,
      discoveredCharacteristics: discoveredCharacteristics,
      successfulInitStrategy: successfulInitStrategy,
      operationTransport: operationTransport,
      functionMode: functionMode,
      cameraFunctionVersion: cameraFunctionVersion,
      selectedFunctionVersion: selectedFunctionVersion,
      bleEndpointEvidence: bleEndpointEvidence,
      catalogResponseFacts: catalogResponseFacts
    )
  }

  static let unknown = CameraProtocolFacts(
    compatibilityFamily: nil,
    advertisedServices: [],
    discoveredCharacteristics: []
  )
}

struct CameraCompatibilityFacts: Codable, Equatable {
  let observedIdentity: CameraObservedIdentity
  let protocolFacts: CameraProtocolFacts

  init(
    observedIdentity: CameraObservedIdentity,
    protocolFacts: CameraProtocolFacts
  ) {
    self.observedIdentity = observedIdentity
    self.protocolFacts = protocolFacts
  }

  init(
    compatibilityFamily: CameraCompatibilityFamily?,
    advertisedServices: Set<String>,
    discoveredCharacteristics: Set<String>,
    modelName: String?,
    firmwareVersion: String?,
    successfulInitStrategy: PtpInitStrategyID? = nil,
    operationTransport: CameraPtpTransport? = nil,
    functionMode: UInt32? = nil,
    cameraFunctionVersion: UInt32? = nil,
    selectedFunctionVersion: UInt32? = nil,
    bleEndpointEvidence: CameraBleEndpointEvidence = .none,
    catalogResponseFacts: CameraCatalogResponseFacts? = nil
  ) {
    observedIdentity = CameraObservedIdentity(
      modelName: modelName,
      firmwareVersion: firmwareVersion
    )
    protocolFacts = CameraProtocolFacts(
      compatibilityFamily: compatibilityFamily,
      advertisedServices: advertisedServices,
      discoveredCharacteristics: discoveredCharacteristics,
      successfulInitStrategy: successfulInitStrategy,
      operationTransport: operationTransport,
      functionMode: functionMode,
      cameraFunctionVersion: cameraFunctionVersion,
      selectedFunctionVersion: selectedFunctionVersion,
      bleEndpointEvidence: bleEndpointEvidence,
      catalogResponseFacts: catalogResponseFacts
    )
  }

  var compatibilityFamily: CameraCompatibilityFamily? { protocolFacts.compatibilityFamily }
  var advertisedServices: Set<String> { protocolFacts.advertisedServices }
  var discoveredCharacteristics: Set<String> { protocolFacts.discoveredCharacteristics }
  var successfulInitStrategy: PtpInitStrategyID? { protocolFacts.successfulInitStrategy }
  var operationTransport: CameraPtpTransport? { protocolFacts.operationTransport }
  var functionMode: UInt32? { protocolFacts.functionMode }
  var cameraFunctionVersion: UInt32? { protocolFacts.cameraFunctionVersion }
  var selectedFunctionVersion: UInt32? { protocolFacts.selectedFunctionVersion }
  var bleEndpointEvidence: CameraBleEndpointEvidence { protocolFacts.bleEndpointEvidence }
  var catalogResponseFacts: CameraCatalogResponseFacts? { protocolFacts.catalogResponseFacts }

  func updating(
    successfulInitStrategy: PtpInitStrategyID,
    operationTransport: CameraPtpTransport
  ) -> CameraCompatibilityFacts {
    CameraCompatibilityFacts(
      observedIdentity: observedIdentity,
      protocolFacts: CameraProtocolFacts(
        compatibilityFamily: protocolFacts.compatibilityFamily,
        advertisedServices: protocolFacts.advertisedServices,
        discoveredCharacteristics: protocolFacts.discoveredCharacteristics,
        successfulInitStrategy: successfulInitStrategy,
        operationTransport: operationTransport,
        functionMode: protocolFacts.functionMode,
        cameraFunctionVersion: protocolFacts.cameraFunctionVersion,
        selectedFunctionVersion: protocolFacts.selectedFunctionVersion,
        bleEndpointEvidence: protocolFacts.bleEndpointEvidence,
        catalogResponseFacts: protocolFacts.catalogResponseFacts
      )
    )
  }

  func updating(
    catalogResponseFacts: CameraCatalogResponseFacts?
  ) -> CameraCompatibilityFacts {
    CameraCompatibilityFacts(
      observedIdentity: observedIdentity,
      protocolFacts: protocolFacts.updating(catalogResponseFacts: catalogResponseFacts)
    )
  }

  var beforeGattDiscovery: CameraCompatibilityFacts {
    CameraCompatibilityFacts(
      observedIdentity: observedIdentity,
      protocolFacts: CameraProtocolFacts(
        compatibilityFamily: protocolFacts.compatibilityFamily,
        advertisedServices: protocolFacts.advertisedServices,
        discoveredCharacteristics: [],
        bleEndpointEvidence: protocolFacts.bleEndpointEvidence
      )
    )
  }

  static let unknown = CameraCompatibilityFacts(
    observedIdentity: .unknown,
    protocolFacts: .unknown
  )

  func updating(
    functionFacts: CameraGalleryFunctionFacts
  ) -> CameraCompatibilityFacts {
    CameraCompatibilityFacts(
      observedIdentity: observedIdentity,
      protocolFacts: CameraProtocolFacts(
        compatibilityFamily: protocolFacts.compatibilityFamily,
        advertisedServices: protocolFacts.advertisedServices,
        discoveredCharacteristics: protocolFacts.discoveredCharacteristics,
        successfulInitStrategy: protocolFacts.successfulInitStrategy,
        operationTransport: protocolFacts.operationTransport,
        functionMode: functionFacts.functionMode ?? protocolFacts.functionMode,
        cameraFunctionVersion:
          functionFacts.cameraFunctionVersion ?? protocolFacts.cameraFunctionVersion,
        selectedFunctionVersion:
          functionFacts.selectedFunctionVersion ?? protocolFacts.selectedFunctionVersion,
        bleEndpointEvidence: protocolFacts.bleEndpointEvidence,
        catalogResponseFacts: protocolFacts.catalogResponseFacts
      )
    )
  }
}

struct CameraGalleryFunctionFacts: Codable, Equatable {
  let functionMode: UInt32?
  let cameraFunctionVersion: UInt32?
  let selectedFunctionVersion: UInt32?

  var hasResolvedFacts: Bool {
    functionMode != nil || cameraFunctionVersion != nil || selectedFunctionVersion != nil
  }
}

struct CameraCompatibilityRuleID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

struct CameraStrategySelection: Codable, Equatable {
  let pairingStrategy: PairingStrategyID
  let activationStrategy: ActivationStrategyID
  let ptpInitStrategy: PtpInitStrategyID
  let negotiationStrategy: SessionNegotiationStrategyID
  let galleryBootstrapStrategy: GalleryBootstrapStrategyID
  let initialCatalogStrategy: InitialCatalogStrategyID

  static let unsupported = CameraStrategySelection(
    pairingStrategy: .unsupported,
    activationStrategy: .unsupported,
    ptpInitStrategy: .unsupported,
    negotiationStrategy: .unsupported,
    galleryBootstrapStrategy: .unsupported,
    initialCatalogStrategy: .unsupported
  )
}

struct CameraCompatibilityRule: Codable, Equatable {
  let id: CameraCompatibilityRuleID
  let priority: Int
  let supportStatus: CameraSupportStatus
  let compatibilityFamily: CameraCompatibilityFamily?
  let requiredServices: Set<String>
  let requiredCharacteristics: Set<String>
  let responsePredicate: CameraResponsePredicate?
  let selection: CameraStrategySelection

  init(
    id: CameraCompatibilityRuleID,
    priority: Int,
    supportStatus: CameraSupportStatus,
    compatibilityFamily: CameraCompatibilityFamily?,
    requiredServices: Set<String>,
    requiredCharacteristics: Set<String>,
    responsePredicate: CameraResponsePredicate?,
    selection: CameraStrategySelection
  ) {
    self.id = id
    self.priority = priority
    self.supportStatus = supportStatus
    self.compatibilityFamily = compatibilityFamily
    self.requiredServices = requiredServices
    self.requiredCharacteristics = requiredCharacteristics
    self.responsePredicate = responsePredicate
    self.selection = selection
  }

  var specificity: Int {
    if responsePredicate != nil { return 3 }
    if !requiredServices.isEmpty || !requiredCharacteristics.isEmpty { return 2 }
    if compatibilityFamily != nil { return 1 }
    return 0
  }

  func rejectionReasons(
    for facts: CameraProtocolFacts
  ) -> [CameraCompatibilityRuleRejectionReason] {
    var reasons: [CameraCompatibilityRuleRejectionReason] = []
    if let compatibilityFamily, facts.compatibilityFamily != compatibilityFamily {
      reasons.append(.compatibilityFamily)
    }
    if !requiredServices.isSubset(of: facts.advertisedServices) {
      reasons.append(.requiredServices)
    }
    if !requiredCharacteristics.isSubset(of: facts.discoveredCharacteristics) {
      reasons.append(.requiredCharacteristics)
    }
    if let responsePredicate, !responsePredicate.matches(facts) {
      reasons.append(.responsePredicate)
    }
    return reasons
  }
}

enum CameraCompatibilityRuleRejectionReason: String, Codable, Equatable {
  case compatibilityFamily = "compatibility-family"
  case requiredServices = "required-services"
  case requiredCharacteristics = "required-characteristics"
  case responsePredicate = "response-predicate"
}

struct CameraCompatibilityRegistry: Codable, Equatable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case version
    case rules
  }

  let schemaVersion: Int
  let version: String
  let rules: [CameraCompatibilityRule]

  init(
    schemaVersion: Int,
    version: String,
    rules: [CameraCompatibilityRule]
  ) {
    precondition(
      rules.allSatisfy { $0.supportStatus == .verified },
      "CameraCompatibilityRegistry accepts verified rules only"
    )
    self.schemaVersion = schemaVersion
    self.version = version
    self.rules = rules
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let version = try container.decode(String.self, forKey: .version)
    let rules = try container.decode([CameraCompatibilityRule].self, forKey: .rules)
    guard rules.allSatisfy({ $0.supportStatus == .verified }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .rules,
        in: container,
        debugDescription: "CameraCompatibilityRegistry accepts verified rules only"
      )
    }
    self.schemaVersion = schemaVersion
    self.version = version
    self.rules = rules
  }

}

struct CameraConnectionPlanID: RawRepresentable, Codable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

struct CameraConnectionPlanVersion: Codable, Equatable, Hashable {
  let id: CameraConnectionPlanID
  let revision: Int
}

enum CameraPlanRevisionReason: String, Codable, Equatable {
  case gattDiscoveryCompleted
  case ptpInitAcknowledged
  case functionFactsInspected
  case catalogResponseClassified
}

struct CameraConnectionPlan: Codable, Equatable {
  let id: CameraConnectionPlanID
  let revision: Int
  let registryVersion: String
  let supportStatus: CameraSupportStatus
  let protocolFacts: CameraProtocolFacts
  let pairingStrategy: PairingStrategyID
  let activationStrategy: ActivationStrategyID
  let ptpInitStrategy: PtpInitStrategyID
  let negotiationStrategy: SessionNegotiationStrategyID
  let galleryBootstrapStrategy: GalleryBootstrapStrategyID
  let initialCatalogStrategy: InitialCatalogStrategyID

  var version: CameraConnectionPlanVersion {
    CameraConnectionPlanVersion(id: id, revision: revision)
  }

}

enum CameraCompatibilityUnresolvedFact: String, Codable, Equatable {
  case compatibilityFamily
  case requiredGattCapabilities
}

enum CameraConnectionDecisionConfidence: String, Codable, Equatable {
  case verified
  case experimental
  case none
}

struct CameraConnectionPlanDecision: Codable, Equatable {
  let plan: CameraConnectionPlan
  let matchedRuleIDs: [CameraCompatibilityRuleID]
  let rejectedRuleIDs: [CameraCompatibilityRuleID]
  let unresolvedFacts: [CameraCompatibilityUnresolvedFact]
  let confidence: CameraConnectionDecisionConfidence
  let decisionTrace: [String]
}

struct CameraConnectionPlanFallback: Equatable {
  let supportStatus: CameraSupportStatus
  let selection: CameraStrategySelection
  let decisionID: String
  let decisionTrace: String
}

enum CameraConnectionPlanResolver {
  static func resolve(
    protocolFacts: CameraProtocolFacts,
    registry: CameraCompatibilityRegistry,
    fallback: CameraConnectionPlanFallback? = nil,
    revising lineage: CameraConnectionPlanVersion? = nil
  ) -> CameraConnectionPlanDecision {
    let orderedRules = registry.rules.sorted { lhs, rhs in
      if lhs.specificity != rhs.specificity {
        return lhs.specificity > rhs.specificity
      }
      if lhs.priority != rhs.priority {
        return lhs.priority > rhs.priority
      }
      return lhs.id.rawValue < rhs.id.rawValue
    }
    var rejectedRuleIDs: [CameraCompatibilityRuleID] = []
    var trace: [String] = []

    for rule in orderedRules {
      let rejectionReasons = rule.rejectionReasons(for: protocolFacts)
      guard rejectionReasons.isEmpty else {
        rejectedRuleIDs.append(rule.id)
        trace.append(
          "rejected=\(rule.id.rawValue) reasons=" +
          rejectionReasons.map(\.rawValue).joined(separator: ",")
        )
        continue
      }

      trace.append("matched=\(rule.id.rawValue) status=\(rule.supportStatus.rawValue)")
      return CameraConnectionPlanDecision(
        plan: makePlan(
          registry: registry,
          protocolFacts: protocolFacts,
          supportStatus: rule.supportStatus,
          selection: rule.selection,
          decisionID: rule.id.rawValue,
          lineage: lineage
        ),
        matchedRuleIDs: [rule.id],
        rejectedRuleIDs: rejectedRuleIDs,
        unresolvedFacts: unresolvedFacts(for: protocolFacts),
        confidence: rule.supportStatus == .verified ? .verified : .experimental,
        decisionTrace: trace
      )
    }

    if let fallback {
      trace.append(fallback.decisionTrace)
      return CameraConnectionPlanDecision(
        plan: makePlan(
          registry: registry,
          protocolFacts: protocolFacts,
          supportStatus: fallback.supportStatus,
          selection: fallback.selection,
          decisionID: fallback.decisionID,
          lineage: lineage
        ),
        matchedRuleIDs: [],
        rejectedRuleIDs: rejectedRuleIDs,
        unresolvedFacts: unresolvedFacts(for: protocolFacts),
        confidence: fallback.supportStatus == .verified ? .verified : .experimental,
        decisionTrace: trace
      )
    }

    trace.append("matched=none status=unsupported")
    return CameraConnectionPlanDecision(
      plan: makePlan(
        registry: registry,
        protocolFacts: protocolFacts,
        supportStatus: .unsupported,
        selection: .unsupported,
        decisionID: "unsupported",
        lineage: lineage
      ),
      matchedRuleIDs: [],
      rejectedRuleIDs: rejectedRuleIDs,
      unresolvedFacts: unresolvedFacts(for: protocolFacts),
      confidence: .none,
      decisionTrace: trace
    )
  }

  private static func makePlan(
    registry: CameraCompatibilityRegistry,
    protocolFacts: CameraProtocolFacts,
    supportStatus: CameraSupportStatus,
    selection: CameraStrategySelection,
    decisionID: String,
    lineage: CameraConnectionPlanVersion?
  ) -> CameraConnectionPlan {
    return CameraConnectionPlan(
      id: lineage?.id ?? CameraConnectionPlanID(rawValue: "\(registry.version):\(decisionID)"),
      revision: (lineage?.revision ?? 0) + 1,
      registryVersion: registry.version,
      supportStatus: supportStatus,
      protocolFacts: protocolFacts,
      pairingStrategy: selection.pairingStrategy,
      activationStrategy: selection.activationStrategy,
      ptpInitStrategy: selection.ptpInitStrategy,
      negotiationStrategy: selection.negotiationStrategy,
      galleryBootstrapStrategy: selection.galleryBootstrapStrategy,
      initialCatalogStrategy: selection.initialCatalogStrategy
    )
  }

  private static func unresolvedFacts(
    for facts: CameraProtocolFacts
  ) -> [CameraCompatibilityUnresolvedFact] {
    var unresolved: [CameraCompatibilityUnresolvedFact] = []
    if facts.compatibilityFamily == nil {
      unresolved.append(.compatibilityFamily)
    }
    if facts.advertisedServices.isEmpty || facts.discoveredCharacteristics.isEmpty {
      unresolved.append(.requiredGattCapabilities)
    }
    return unresolved
  }
}
