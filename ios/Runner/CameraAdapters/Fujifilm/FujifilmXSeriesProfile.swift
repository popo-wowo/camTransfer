import Foundation

struct FujifilmXSeriesProfile: Equatable {
  let id: String
  let ptpStartupDelaySeconds: TimeInterval
  let fileDownloadReadSize: UInt32
  let fileDownloadFallbackReadSize: UInt32

  static let currentVerifiedBaseline = FujifilmXSeriesProfile(
    id: "fujifilm-x-series-current-verified-baseline",
    ptpStartupDelaySeconds: CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(
      didCompleteWifiHandoff: true
    ),
    fileDownloadReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
    fileDownloadFallbackReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize
  )

  func shouldSkipFreshFileInfoProbe(formatLabel: String, cachedExpectedSize: UInt32?) -> Bool {
    CameraVendorOriginalDownloadPolicy.shouldSkipFreshFileInfoProbe(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    )
  }
}
