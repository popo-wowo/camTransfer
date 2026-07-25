import UIKit
import Photos

/// Provides thumbnails and download-status checks from the local Photo Library.
/// Files saved by CamTransfer use `originalFilename` matching the camera's filename
/// (e.g., "DSCF8103.HEIC"), which can be queried via PHAsset resource attributes.
enum CameraPhotoLibraryProvider {

  /// Check which filenames have already been saved to Photo Library.
  /// Returns a Set of filenames (e.g., {"DSCF8103.HEIC", "DSCF8101.RAF"}).
  static func savedFilenames(candidates: [String]) -> Set<String> {
    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
      return []
    }
    guard !candidates.isEmpty else { return [] }

    // Fetch all assets and check original filenames
    // For efficiency, fetch recent assets within a reasonable window
    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    fetchOptions.fetchLimit = candidates.count * 2

    let assets = PHAsset.fetchAssets(with: fetchOptions)
    var found: Set<String> = []
    let candidateSet = Set(candidates)

    assets.enumerateObjects { asset, _, stop in
      let resources = PHAssetResource.assetResources(for: asset)
      for resource in resources where resource.type == .photo || resource.type == .video {
        if candidateSet.contains(resource.originalFilename) {
          found.insert(resource.originalFilename)
        }
      }
      if found.count == candidateSet.count {
        stop.pointee = true
      }
    }
    return found
  }

  /// Request a thumbnail image for a photo that's already in Photo Library,
  /// matched by originalFilename. Returns nil if not found or not authorized.
  static func thumbnail(
    forFilename filename: String,
    targetSize: CGSize = CGSize(width: 200, height: 200),
    completion: @escaping (UIImage?) -> Void
  ) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      // Request read access if not yet determined
      if status == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
          guard newStatus == .authorized || newStatus == .limited else {
            DispatchQueue.main.async { completion(nil) }
            return
          }
          // Retry after authorization
          Self.fetchThumbnail(forFilename: filename, targetSize: targetSize, completion: completion)
        }
        return
      }
      completion(nil)
      return
    }
    fetchThumbnail(forFilename: filename, targetSize: targetSize, completion: completion)
  }

  private static func fetchThumbnail(
    forFilename filename: String,
    targetSize: CGSize,
    completion: @escaping (UIImage?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      // Find the asset by iterating recent assets
      let fetchOptions = PHFetchOptions()
      fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      fetchOptions.fetchLimit = 500

      let assets = PHAsset.fetchAssets(with: fetchOptions)
      var targetAsset: PHAsset?

      assets.enumerateObjects { asset, _, stop in
        let resources = PHAssetResource.assetResources(for: asset)
        for resource in resources {
          if resource.originalFilename == filename {
            targetAsset = asset
            stop.pointee = true
            return
          }
        }
      }

      guard let asset = targetAsset else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      let options = PHImageRequestOptions()
      options.deliveryMode = .opportunistic
      options.isNetworkAccessAllowed = false
      options.isSynchronous = true

      var resultImage: UIImage?
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: targetSize,
        contentMode: .aspectFill,
        options: options
      ) { image, _ in
        resultImage = image
      }
      DispatchQueue.main.async { completion(resultImage) }
    }
  }

  /// Batch check: returns a dictionary of filename -> PHAsset local identifier
  /// for all filenames that exist in Photo Library.
  static func assetIdentifiers(forFilenames filenames: [String]) -> [String: String] {
    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
      return [:]
    }
    guard !filenames.isEmpty else { return [:] }

    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    fetchOptions.fetchLimit = filenames.count * 3

    let assets = PHAsset.fetchAssets(with: fetchOptions)
    let filenameSet = Set(filenames)
    var result: [String: String] = [:]

    assets.enumerateObjects { asset, _, stop in
      let resources = PHAssetResource.assetResources(for: asset)
      for resource in resources where resource.type == .photo || resource.type == .video {
        if filenameSet.contains(resource.originalFilename) {
          result[resource.originalFilename] = asset.localIdentifier
        }
      }
      if result.count == filenameSet.count {
        stop.pointee = true
      }
    }
    return result
  }
}
