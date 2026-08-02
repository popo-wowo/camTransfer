import Foundation
import ImageIO
import UIKit

enum NativeGalleryHDDecodeTarget: Hashable, Sendable {
  case verticalCard(maxPixelSize: Int)
  case fullScreenFit(maxPixelSize: Int)
  case fullScreenNative

  var maxPixelSize: Int? {
    switch self {
    case .verticalCard(let maxPixelSize), .fullScreenFit(let maxPixelSize):
      return max(1, maxPixelSize)
    case .fullScreenNative:
      return nil
    }
  }

  var label: String {
    switch self {
    case .verticalCard: return "vertical"
    case .fullScreenFit: return "fit"
    case .fullScreenNative: return "native"
    }
  }
}

enum NativeGalleryHDDecodeSizingPolicy {
  static func verticalCardMaxPixelSize(
    renderedWidth: CGFloat,
    displayScale: CGFloat
  ) -> Int {
    Int(ceil(max(1, renderedWidth) * max(1, displayScale) * 1.2))
  }

  static func fullScreenFitMaxPixelSize(
    viewport: CGSize,
    displayScale: CGFloat
  ) -> Int {
    Int(ceil(max(1, max(viewport.width, viewport.height)) * max(1, displayScale)))
  }
}

enum NativeGalleryHDFullScreenDecodePolicy {
  static func nextTarget(
    isDisplayedPage: Bool,
    renderedTarget: NativeGalleryHDDecodeTarget?,
    viewport: CGSize,
    displayScale: CGFloat,
    allowsNativeDecode: Bool
  ) -> NativeGalleryHDDecodeTarget? {
    let fitTarget = NativeGalleryHDDecodeTarget.fullScreenFit(
      maxPixelSize: NativeGalleryHDDecodeSizingPolicy.fullScreenFitMaxPixelSize(
        viewport: viewport,
        displayScale: displayScale
      )
    )
    guard isDisplayedPage, allowsNativeDecode else {
      return renderedTarget == fitTarget ? nil : fitTarget
    }
    switch renderedTarget {
    case .fullScreenNative:
      return nil
    case fitTarget:
      return .fullScreenNative
    default:
      return fitTarget
    }
  }
}

final class NativeGalleryHDDecodeCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func performIfActive<Result>(_ body: () -> Result) -> Result? {
    guard !isCancelled else { return nil }
    return body()
  }
}

final class NativeGalleryHDTargetDecoder {
  static let maxConcurrentDecodeCount = 2

  private static let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.camtransfer.hd-preview-decode"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = maxConcurrentDecodeCount
    return queue
  }()

  static func decodedImage(
    from data: Data,
    objectOrientation: Int?,
    target: NativeGalleryHDDecodeTarget,
    diagnosticHandle: Int
  ) async -> UIImage? {
    guard !Task.isCancelled else { return nil }
    let startedAt = Date()
    CameraVendorFileLogger.log(
      "[OBS] HD_DECODE_BEGIN handle=0x\(String(format: "%08X", diagnosticHandle)) " +
      "tier=\(target.label) targetPixels=\(target.maxPixelSize ?? 0)"
    )
    let cancellationToken = NativeGalleryHDDecodeCancellationToken()
    let image: UIImage? = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<UIImage?, Never>) in
        queue.addOperation {
          let decoded: UIImage? = cancellationToken.performIfActive {
            decode(
              data: data,
              objectOrientation: objectOrientation,
              target: target
            )
          } ?? nil
          continuation.resume(
            returning: cancellationToken.isCancelled ? nil : decoded
          )
        }
      }
    } onCancel: {
      cancellationToken.cancel()
    }
    guard !Task.isCancelled else { return nil }
    if let image {
      let decodedWidth = Int(image.size.width)
      let decodedHeight = Int(image.size.height)
      let costBytes = max(1, decodedWidth * decodedHeight * 4)
      let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
      let message = "[OBS] HD_DECODE_END handle=0x\(String(format: "%08X", diagnosticHandle)) " +
        "tier=\(target.label) decodedPixels=\(decodedWidth)x\(decodedHeight) " +
        "costBytes=\(costBytes) elapsedMs=\(elapsedMs)"
      CameraVendorFileLogger.log(message)
    }
    return image
  }

  private static func decode(
    data: Data,
    objectOrientation: Int?,
    target: NativeGalleryHDDecodeTarget
  ) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let cgImage: CGImage?
    if let maxPixelSize = target.maxPixelSize {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    } else {
      let options: [CFString: Any] = [
        kCGImageSourceShouldCache: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
    guard let cgImage else { return nil }
    let decoded = UIImage(cgImage: cgImage)
    let rotation = NativePhotoPreviewRotationPolicy.rotationDecision(
      objectOrientation: objectOrientation,
      decodedWidth: cgImage.width,
      decodedHeight: cgImage.height,
      imageData: data
    )
    return NativePhotoPreviewImageRenderer.rendered(
      image: decoded,
      manualRotationDegrees: rotation.degrees
    )
  }
}
