import Foundation

struct FujifilmXSeriesProfile: Equatable {
  let id: String
  let ptpStartupDelaySeconds: TimeInterval
  let fileDownloadReadSize: UInt32
  let fileDownloadFallbackReadSize: UInt32

  static let xt5Current = FujifilmXSeriesProfile(
    id: "fujifilm-x-series-xt5-current",
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
