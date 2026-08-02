import Foundation

enum CameraVendorPartialObjectRequestPolicy {
  /// Conservative default for formats/modes not yet verified against XApp.
  static let referenceAppInitialReadSize: UInt32 = 1 * 1_048_576
  static let fileDownloadReadSize: UInt32 = 4 * 1_048_576
  static let fileDownloadFallbackReadSize = referenceAppInitialReadSize
  static let fileDownloadReadTimeoutSeconds: TimeInterval = 60
  static let maxReadBytesWithoutKnownObjectSize = 128 * 1_024 * 1_024

  static func fileDownloadRequestSize(remaining: UInt64, useFallback: Bool = false) -> UInt32 {
    let preferredSize = useFallback ? fileDownloadFallbackReadSize : fileDownloadReadSize
    return UInt32(min(UInt64(preferredSize), remaining))
  }

  static func maximumReadableByteCount(expectedSize: UInt32?) -> UInt64 {
    if let expectedSize, expectedSize > 0 {
      return UInt64(expectedSize)
    }
    return UInt64(maxReadBytesWithoutKnownObjectSize)
  }

  static func extensionPartialObjectParameters(
    handle: UInt32,
    offset: UInt64 = 0,
    size: UInt32 = referenceAppInitialReadSize
  ) -> [UInt32] {
    [
      handle,
      UInt32(offset & 0xFFFF_FFFF),
      size,
      UInt32(offset >> 32),
    ]
  }

  static func standardPartialObjectParameters(
    handle: UInt32,
    offset: UInt64 = 0,
    size: UInt32 = referenceAppInitialReadSize
  ) -> [UInt32] {
    [
      handle,
      UInt32(offset & 0xFFFF_FFFF),
      size,
    ]
  }
}

enum CameraVendorPreviewImageReadPolicy {
  static let maximumScreenPreviewBytes: UInt32 = 12 * 1_048_576
  static let initialReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
  static let fallbackReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize

  static func requestSize(remaining: UInt64, selectedReadSize: UInt32) -> UInt32 {
    UInt32(min(remaining, UInt64(selectedReadSize)))
  }

  static func fallbackReadSize(after currentReadSize: UInt32) -> UInt32? {
    currentReadSize > fallbackReadSize ? fallbackReadSize : nil
  }

  static func supports(formatLabel: String, compressedSize: UInt32) -> Bool {
    let normalizedFormat = formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let isPreviewableFormat = ["JPG", "JPEG", "HEIF", "HEIC", "HIF"].contains(normalizedFormat)
    return isPreviewableFormat && compressedSize > 0 && compressedSize <= maximumScreenPreviewBytes
  }

  static func shouldStopAfterChunk(
    previousLastByte: UInt8?,
    chunk: Data,
    totalBytes: UInt64,
    maximumBytes: UInt64
  ) -> Bool {
    if totalBytes >= maximumBytes { return true }
    guard !chunk.isEmpty else { return true }
    if previousLastByte == 0xFF, chunk.first == 0xD9 { return true }
    return CameraVendorJpegDataPolicy.hasEndMarker(chunk)
  }
}

enum CameraVendorPreviewImageSource: Equatable {
  case compressedObject(handle: UInt32, size: UInt32)
  case standardThumbnail(handle: UInt32)
}

enum CameraVendorPreviewImageSourcePolicy {
  static func companionCandidateHandle(
    for originalInfo: CameraVendorCameraObjectInfo
  ) -> UInt32? {
    guard isRaw(originalInfo),
          !CameraVendorPreviewImageReadPolicy.supports(
            formatLabel: originalInfo.formatLabel,
            compressedSize: originalInfo.compressedSize
          ),
          let handle = UInt32(exactly: originalInfo.handle),
          handle < UInt32.max else {
      return nil
    }
    return handle + 1
  }

  static func source(
    originalInfo: CameraVendorCameraObjectInfo,
    companionInfo: CameraVendorCameraObjectInfo?
  ) -> CameraVendorPreviewImageSource? {
    guard let originalHandle = UInt32(exactly: originalInfo.handle) else { return nil }
    if CameraVendorPreviewImageReadPolicy.supports(
      formatLabel: originalInfo.formatLabel,
      compressedSize: originalInfo.compressedSize
    ) {
      return .compressedObject(
        handle: originalHandle,
        size: originalInfo.compressedSize
      )
    }
    guard isRaw(originalInfo) else { return nil }
    if let companionInfo,
       isValidCompanion(companionInfo, for: originalInfo),
       let companionHandle = UInt32(exactly: companionInfo.handle) {
      return .compressedObject(
        handle: companionHandle,
        size: companionInfo.compressedSize
      )
    }
    return .standardThumbnail(handle: originalHandle)
  }

  private static func isValidCompanion(
    _ companionInfo: CameraVendorCameraObjectInfo,
    for rawInfo: CameraVendorCameraObjectInfo
  ) -> Bool {
    guard let expectedHandle = companionCandidateHandle(for: rawInfo),
          UInt32(exactly: companionInfo.handle) == expectedHandle,
          CameraVendorPreviewImageReadPolicy.supports(
            formatLabel: companionInfo.formatLabel,
            compressedSize: companionInfo.compressedSize
          ),
          filenameStem(rawInfo.filename) == filenameStem(companionInfo.filename),
          !filenameStem(rawInfo.filename).isEmpty,
          datesAreCompatible(rawInfo.captureDate, companionInfo.captureDate) else {
      return false
    }
    return rawInfo.storageID == 0 ||
      companionInfo.storageID == 0 ||
      rawInfo.storageID == companionInfo.storageID
  }

  private static func isRaw(_ info: CameraVendorCameraObjectInfo) -> Bool {
    let format = info.formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let filename = info.filename.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return format == "RAW" ||
      format == "RAF" ||
      filename.hasSuffix(".RAW") ||
      filename.hasSuffix(".RAF")
  }

  private static func filenameStem(_ filename: String) -> String {
    let normalized = filename.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty, !normalized.hasPrefix("0X") else { return "" }
    return (normalized as NSString).deletingPathExtension
  }

  private static func datesAreCompatible(_ left: String, _ right: String) -> Bool {
    let normalizedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedLeft.isEmpty || normalizedRight.isEmpty || normalizedLeft == normalizedRight
  }
}

struct CameraVendorOriginalTransferCapabilityRecord: Codable, Equatable {
  let readSize: UInt32
  let updatedAt: Date
}

final class CameraVendorOriginalTransferCapabilityStore {
  private let defaults: UserDefaults
  private let storageKey = "cameraVendor.originalTransferCapability.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func readSize(serialNumber: String?) -> UInt32? {
    guard let serial = normalizedSerialNumber(serialNumber),
          let record = records()[serial],
          CameraVendorTransferChunkProfile.isSupportedReadSize(record.readSize) else {
      return nil
    }
    return record.readSize
  }

  func persist(readSize: UInt32, serialNumber: String?) {
    guard let serial = normalizedSerialNumber(serialNumber),
          CameraVendorTransferChunkProfile.isSupportedReadSize(readSize) else {
      return
    }
    var updatedRecords = records()
    updatedRecords[serial] = CameraVendorOriginalTransferCapabilityRecord(
      readSize: readSize,
      updatedAt: Date()
    )
    guard let encoded = try? JSONEncoder().encode(updatedRecords) else { return }
    defaults.set(encoded, forKey: storageKey)
  }

  private func records() -> [String: CameraVendorOriginalTransferCapabilityRecord] {
    guard let data = defaults.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode(
            [String: CameraVendorOriginalTransferCapabilityRecord].self,
            from: data
          ) else {
      return [:]
    }
    return decoded
  }

  private func normalizedSerialNumber(_ serialNumber: String?) -> String? {
    let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !serial.isEmpty, serial != "-" else { return nil }
    return serial.uppercased()
  }
}

enum CameraVendorTransferChunkProfile {
  /// Observed in the XApp original-import trace: 12 MiB minus PTP overhead.
  static let maximumReadSize: UInt32 = 0x00BFFFE0

  static func preferredReadSize(cachedReadSize: UInt32?) -> UInt32 {
    guard let cachedReadSize, isSupportedReadSize(cachedReadSize) else {
      return maximumReadSize
    }
    return cachedReadSize
  }

  static func requestSize(remaining: UInt64, selectedReadSize: UInt32) -> UInt32 {
    UInt32(min(remaining, UInt64(selectedReadSize)))
  }

  static func isSupportedReadSize(_ readSize: UInt32) -> Bool {
    readSize == maximumReadSize ||
      readSize == CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize ||
      readSize == CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize
  }

  static func fallbackReadSize(after currentReadSize: UInt32) -> UInt32? {
    if currentReadSize > CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize {
      return CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    }
    if currentReadSize > CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize {
      return CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    }
    return nil
  }

  static func shouldFallback(after error: Error, sessionIsConnected: Bool) -> Bool {
    guard sessionIsConnected else { return false }
    let error = error as NSError
    return error.domain == "CameraVendorPtpSession" && (0x2000...0x2FFF).contains(error.code)
  }
}

enum CameraVendorOriginalTransferCompletionPolicy {
  static func shouldPersistCapability(
    totalBytes: Int,
    expectedBytes: UInt64?,
    hasJpegEndMarker: Bool
  ) -> Bool {
    if let expectedBytes {
      return totalBytes > 0 && UInt64(totalBytes) >= expectedBytes
    }
    return totalBytes > 0 && hasJpegEndMarker
  }
}

struct CameraVendorAdaptiveDownloadChunkState: Equatable {
  var readSize: UInt32 = CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
  var consecutiveFastChunks: Int = 0
  var consecutiveSlowLargeChunks: Int = 0
  var lastSlowLargeBytesPerSecond: Double?
}

enum CameraVendorAdaptiveDownloadChunkPolicy {
  static let isEnabled = false
  static let slowChunkBytesPerSecond: Double = 1.2 * 1_048_576
  static let fastChunkBytesPerSecond: Double = 2.5 * 1_048_576
  static let fastChunksRequiredForUpgrade = 2
  static let slowLargeChunksRequiredForDowngrade = 1
  static let fallbackImprovementFactor = 1.15
  static let strategyName = "android-fixed-4mb"

  static func requestSize(remaining: UInt64, state: CameraVendorAdaptiveDownloadChunkState) -> UInt32 {
    UInt32(min(UInt64(state.readSize), remaining))
  }

  static func recordChunk(
    byteCount: Int,
    elapsedMs: Int,
    state: inout CameraVendorAdaptiveDownloadChunkState
  ) {
    guard isEnabled, byteCount > 0, elapsedMs > 0 else { return }
    let bytesPerSecond = Double(byteCount) / (Double(elapsedMs) / 1000.0)
    let largeReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    let fallbackReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize

    if state.readSize >= largeReadSize {
      if bytesPerSecond < slowChunkBytesPerSecond {
        state.consecutiveSlowLargeChunks += 1
        state.lastSlowLargeBytesPerSecond = bytesPerSecond
        state.consecutiveFastChunks = 0
        if state.consecutiveSlowLargeChunks >= slowLargeChunksRequiredForDowngrade {
          state.readSize = fallbackReadSize
        }
      } else {
        state.consecutiveSlowLargeChunks = 0
        state.lastSlowLargeBytesPerSecond = nil
      }
      return
    }

    if let baseline = state.lastSlowLargeBytesPerSecond,
       bytesPerSecond < baseline * fallbackImprovementFactor {
      state.readSize = largeReadSize
      state.consecutiveFastChunks = 0
      state.consecutiveSlowLargeChunks = 0
      state.lastSlowLargeBytesPerSecond = nil
      return
    }

    if bytesPerSecond < slowChunkBytesPerSecond {
      state.consecutiveFastChunks = 0
      return
    }

    if bytesPerSecond > fastChunkBytesPerSecond {
      state.consecutiveFastChunks += 1
      if state.consecutiveFastChunks >= fastChunksRequiredForUpgrade {
        state.readSize = largeReadSize
        state.consecutiveSlowLargeChunks = 0
        state.lastSlowLargeBytesPerSecond = nil
      }
    } else {
      state.consecutiveFastChunks = 0
    }
  }
}


enum CameraVendorOriginalDownloadPolicy {
  // ReferenceApp only sets this before its ReadImage transfer state machine. Pairing it
  // with plain GetObject leaves this camera waiting without a useful response.
  static let shouldSetForceCompressionBeforeStandardGetObject = false
  static let shouldAttemptStandardGetObjectDownload = false
  static let shouldDownloadUsingPartialObjectFallback = true
  static let shouldPreparePartialObjectFileDownload = true
  static let shouldPreferReferenceAppPreparationForFileDownload = true
  static let referenceAppFileDownloadForceCompressionMode: UInt32 = 2

  static func shouldUseReferenceAppFastStartPreparation(formatLabel: String) -> Bool {
    shouldPreferReferenceAppPreparationForFileDownload && formatLabel == "RAW"
  }

  static func correctFileSizePayload(enabled: Bool) -> Data {
    var value = UInt16(enabled ? 1 : 0).littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  static func expectedDownloadSize(
    formatLabel: String,
    freshCompressedSize: UInt32?,
    cachedExpectedSize: UInt32?
  ) -> UInt32? {
    if formatLabel == "RAW", let cachedExpectedSize {
      return cachedExpectedSize
    }
    return freshCompressedSize ?? cachedExpectedSize
  }

  static func shouldSkipFreshFileInfoProbe(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    guard cachedExpectedSize != nil else { return false }
    return formatLabel == "RAW"
  }

  static func shouldPrepareTransferStateBeforeFileDownload(
    formatLabel _: String,
    cachedExpectedSize _: UInt32?
  ) -> Bool {
    shouldPreparePartialObjectFileDownload
  }

  static func shouldReadReferenceAppContextBeforeDataDownload() -> Bool {
    true
  }

  static func shouldReadCompressionCutOffBeforeDataDownload() -> Bool {
    true
  }

  static func shouldUseCachedObjectInfoForDataDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?,
    mode: CameraVendorTransferDownloadMode
  ) -> Bool {
    false
  }

  static func shouldSetCorrectFileSizeBeforeFileDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && !shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }

  static func shouldSetForceCompressionBeforeFileDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }

  static func shouldReadCompressionCutOffBeforeFreshFileInfo(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldSetCorrectFileSizeBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    )
  }

  static func shouldReadCompressionCutOffAfterFreshFileInfo(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }
}

enum CameraVendorDownloadModePolicy {
  private static let resizeRateS: UInt32 = 1
  private static let forceCompressed: UInt32 = 1
  private static let forceOriginal: UInt32 = 2
  private static let forceReset: UInt32 = 0

  static func prepareProperties(
    mode: CameraVendorTransferDownloadMode
  ) -> [CameraVendorDownloadModeProperty] {
    switch mode {
    case .compressed:
      return [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: resizeRateS,
          width: .uint16
        ),
        imageForceCompressionProperty(forceCompressed),
      ]
    case .original:
      return [imageForceCompressionProperty(forceOriginal)]
    }
  }

  static func resetProperty(
    for property: CameraVendorDownloadModeProperty
  ) -> CameraVendorDownloadModeProperty? {
    guard property.code == CameraVendorDevicePropCode.imageForceCompression else {
      return nil
    }
    return imageForceCompressionProperty(forceReset)
  }

  static func payload(for property: CameraVendorDownloadModeProperty) -> Data {
    switch property.width {
    case .uint16:
      var value = UInt16(property.value).littleEndian
      return withUnsafeBytes(of: &value) { Data($0) }
    case .uint32:
      var value = UInt32(property.value).littleEndian
      return withUnsafeBytes(of: &value) { Data($0) }
    }
  }

  static func imageForceCompressionProperty(_ value: UInt32) -> CameraVendorDownloadModeProperty {
    CameraVendorDownloadModeProperty(
      code: CameraVendorDevicePropCode.imageForceCompression,
      value: value,
      width: .uint16
    )
  }
}

enum CameraVendorThumbnailFetchPolicy {
  static let shouldReadObjectInfoBeforeGetThumb = true
  static let shouldTryStandardGetThumbFirst = true
  static let shouldUsePartialPreviewFallback = false
  static let objectInfoReadTimeoutSeconds: TimeInterval = 1
  static let standardGetThumbReadTimeoutSeconds: TimeInterval = 3
  static let postGetThumbObjectInfoReadTimeoutSeconds: TimeInterval = 1
  static let partialPreviewReadSize: UInt32 = 256 * 1_024
  static let minimumUsefulThumbnailBytes = 100
}

enum CameraVendorPartialObjectDownloadPolicy {
  static func shouldStopAfterChunk(
    totalBytes: Int,
    expectedBytes: UInt64?,
    isJpegObject: Bool,
    hasJpegEndMarker: Bool
  ) -> Bool {
    if hasJpegEndMarker {
      return true
    }
    if let expectedBytes, UInt64(totalBytes) >= expectedBytes {
      return true
    }
    return false
  }
}

enum CameraVendorDownloadSizeSourcePolicy {
  static func resolution(
    freshSize: UInt32,
    cachedSize: UInt32?
  ) -> (size: UInt32?, label: String) {
    if let freshSize = freshSize.nonzero {
      return (freshSize, "fresh-object-info")
    }
    if let cachedSize {
      return (cachedSize, "cached-after-empty-fresh")
    }
    return (nil, "unknown-after-empty-fresh")
  }
}

enum CameraVendorTransferDownloadMode: Equatable {
  case original
  case compressed
}
