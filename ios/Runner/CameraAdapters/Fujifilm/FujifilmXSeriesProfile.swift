import Foundation

struct FujifilmXSeriesProfile: Equatable {
  let id: String
  let ptpStartupDelaySeconds: TimeInterval
  let fileDownloadReadSize: UInt32
  let fileDownloadFallbackReadSize: UInt32
  let parallelDownloadMaxWorkers: Int
  let hiddenHandleMaxOverallRange: UInt32
  let hiddenHandleMaxContiguousGapRange: UInt32
  let shouldResetCompressionModeBeforeObjectInfoList: Bool

  static let xt5Current = FujifilmXSeriesProfile(
    id: "fujifilm-x-series-xt5-current",
    ptpStartupDelaySeconds: CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(
      didCompleteWifiHandoff: true
    ),
    fileDownloadReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
    fileDownloadFallbackReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
    parallelDownloadMaxWorkers: CameraVendorParallelDownloadPolicy.maxWorkers,
    hiddenHandleMaxOverallRange: CameraVendorHiddenObjectHandleProbePolicy.maxOverallRange,
    hiddenHandleMaxContiguousGapRange: CameraVendorHiddenObjectHandleProbePolicy.maxContiguousGapRange,
    shouldResetCompressionModeBeforeObjectInfoList:
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetCompressionModeBeforeObjectInfoList
  )

  func shouldSkipFreshFileInfoProbe(formatLabel: String, cachedExpectedSize: UInt32?) -> Bool {
    CameraVendorOriginalDownloadPolicy.shouldSkipFreshFileInfoProbe(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    )
  }
}
