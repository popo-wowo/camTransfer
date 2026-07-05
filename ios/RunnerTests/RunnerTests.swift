import CoreLocation
import ImageIO
import Network
import NetworkExtension
import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  func testWiredCameraImportPolicyAcceptsPhotosAndVideos() {
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0001.JPG", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0002.RAF", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0003.MOV", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "image.heic", uti: "public.heic"))
    XCTAssertFalse(WiredCameraImportPolicy.isSupportedMedia(filename: "camera.db", uti: "public.data"))
  }

  func testWiredCameraImportStateSelectsOnlyImportableItems() {
    let first = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )
    let second = WiredCameraImportItem(
      id: "2",
      name: "README.TXT",
      uti: "public.text",
      fileSize: 512,
      createdAt: nil,
      thumbnail: nil,
      isImportable: false
    )

    var state = WiredCameraImportState()
    state.replaceItems([first, second])
    state.selectAllImportable()

    XCTAssertEqual(state.selectedItemIDs, ["1"])
    XCTAssertEqual(state.selectedImportableItems, [first])
  }

  func testWiredCameraImportStateDropsSelectionsWhenItemsRefresh() {
    let first = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )
    let next = WiredCameraImportItem(
      id: "2",
      name: "DSCF0002.JPG",
      uti: "public.jpeg",
      fileSize: 2048,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )

    var state = WiredCameraImportState()
    state.replaceItems([first])
    state.toggleSelection(for: first)
    state.replaceItems([next])

    XCTAssertTrue(state.selectedItemIDs.isEmpty)
  }

  func testWiredCameraImportItemIdentityDoesNotUseTemporaryPtpHandleAlone() {
    let first = WiredCameraImportItemIdentity.make(
      ptpObjectHandle: 1,
      filename: "DSCF0001.JPG",
      fileSize: 1_024,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let second = WiredCameraImportItemIdentity.make(
      ptpObjectHandle: 1,
      filename: "DSCF0999.JPG",
      fileSize: 2_048,
      createdAt: Date(timeIntervalSince1970: 1_800_000_500)
    )

    XCTAssertNotEqual(first, "1")
    XCTAssertNotEqual(first, second)
  }

  func testWiredCameraImportStateDropsImportedStatusForItemsNoLongerInLiveCatalog() {
    let stale = wiredImportItem(id: "stale", name: "DSCF0001.JPG")
    let current = wiredImportItem(id: "current", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([stale, current], isLiveCatalog: false)
    state.importedItemIDs = ["stale", "current", "missing"]

    state.replaceItems([current], isLiveCatalog: true)

    XCTAssertEqual(state.importedItemIDs, ["current"])
  }

  func testWiredCameraImportFilterPolicyCombinesDateFormatAndImportedStatus() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let todayJpg = wiredImportItem(id: "today-jpg", name: "DSCF0001.JPG", createdAt: now)
    let todayRaw = wiredImportItem(id: "today-raw", name: "DSCF0002.RAF", uti: "com.fuji.raw-image", createdAt: now)
    let oldJpg = wiredImportItem(id: "old-jpg", name: "DSCF0003.JPG", createdAt: yesterday)

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      [todayJpg, todayRaw, oldJpg],
      state: WiredCameraImportFilterState(date: .today, format: .jpg, importedStatus: .notImported),
      importedItemIDs: ["today-raw"],
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["today-jpg"])
  }

  func testWiredCameraImportFilterPolicyMatchesSpecificDay() {
    let calendar = Calendar(identifier: .gregorian)
    let target = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = calendar.date(byAdding: .day, value: -1, to: target)!
    let targetJpg = wiredImportItem(id: "target", name: "DSCF0001.JPG", createdAt: target)
    let previousJpg = wiredImportItem(id: "previous", name: "DSCF0002.JPG", createdAt: previous)

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      [previousJpg, targetJpg],
      state: WiredCameraImportFilterState(date: .specificDay(target), format: .all, importedStatus: .all),
      importedItemIDs: [],
      now: target,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["target"])
  }

  func testWiredCameraImportFilterPolicyMatchesInclusiveDateRange() {
    let calendar = Calendar(identifier: .gregorian)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let middle = calendar.date(byAdding: .day, value: 2, to: start)!
    let end = calendar.date(byAdding: .day, value: 4, to: start)!
    let before = calendar.date(byAdding: .day, value: -1, to: start)!
    let after = calendar.date(byAdding: .day, value: 1, to: end)!
    let items = [
      wiredImportItem(id: "before", name: "DSCF0001.JPG", createdAt: before),
      wiredImportItem(id: "start", name: "DSCF0002.JPG", createdAt: start),
      wiredImportItem(id: "middle", name: "DSCF0003.JPG", createdAt: middle),
      wiredImportItem(id: "end", name: "DSCF0004.JPG", createdAt: end),
      wiredImportItem(id: "after", name: "DSCF0005.JPG", createdAt: after),
    ]

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      items,
      state: WiredCameraImportFilterState(date: .range(end, start), format: .all, importedStatus: .all),
      importedItemIDs: [],
      now: start,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["start", "middle", "end"])
  }

  func testWiredCameraImportStateSelectsOnlyFilteredImportableItems() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let jpg = wiredImportItem(id: "jpg", name: "DSCF0001.JPG", createdAt: now)
    let raw = wiredImportItem(id: "raw", name: "DSCF0002.RAF", uti: "com.fuji.raw-image", createdAt: now)
    let unsupported = wiredImportItem(
      id: "txt",
      name: "README.TXT",
      uti: "public.text",
      createdAt: now,
      isImportable: false
    )

    var state = WiredCameraImportState()
    state.filterState = WiredCameraImportFilterState(format: .raw)
    state.replaceItems([jpg, raw, unsupported])
    state.selectAllFilteredImportable(now: now)

    XCTAssertEqual(state.filteredItems(now: now).map(\.id), ["raw"])
    XCTAssertEqual(state.selectedItemIDs, ["raw"])
    XCTAssertEqual(state.selectedFilteredImportableItems(now: now), [raw])
  }

  func testWiredCameraImportStateTracksImportedItemsAndFiltersThem() {
    let imported = wiredImportItem(id: "saved", name: "DSCF0001.JPG")
    let pending = wiredImportItem(id: "pending", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([imported, pending])
    state.markImported(itemID: imported.id)
    state.filterState = WiredCameraImportFilterState(importedStatus: .imported)

    XCTAssertEqual(state.filteredItems().map(\.id), ["saved"])
    XCTAssertFalse(state.selectedItemIDs.contains(imported.id))
  }

  func testWiredCameraImportStateKeepsProofingFavoritesSeparateFromImportSelectionAndImportedStatus() {
    let imported = wiredImportItem(id: "saved", name: "DSCF0001.JPG")
    let pending = wiredImportItem(id: "pending", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([imported, pending])
    state.markImported(itemID: imported.id)
    state.setProofingFavorite(true, itemID: imported.id)
    state.setProofingFavorite(true, itemID: pending.id)

    XCTAssertEqual(state.proofingFavoriteItemIDs, ["pending", "saved"])
    XCTAssertTrue(state.selectedItemIDs.isEmpty)

    state.filterState = WiredCameraImportFilterState(importedStatus: .proofingFavorite)
    XCTAssertEqual(state.filteredItems().map(\.id), ["saved", "pending"])

    state.setProofingFavorite(false, itemID: imported.id)
    XCTAssertEqual(state.proofingFavoriteItemIDs, ["pending"])
  }

  func testWiredCameraImportCacheSnapshotRoundTripsWithoutThumbnails() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = WiredCameraImportCacheStore(rootDirectory: tempDirectory)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    var item = wiredImportItem(id: "1", name: "DSCF0001.JPG")
    item.thumbnail = image
    let snapshot = WiredCameraImportCacheSnapshot(
      device: WiredCameraImportDevice(id: "camera/1", name: "X-T5", transportName: "USB"),
      items: [item],
      importedItemIDs: ["1"],
      cachedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try store.save(snapshot)
    let restored = try store.load(deviceID: "camera/1")

    XCTAssertEqual(restored?.device.id, "camera/1")
    XCTAssertEqual(restored?.items.map(\.id), ["1"])
    XCTAssertNil(restored?.items.first?.thumbnail)
    XCTAssertEqual(restored?.importedItemIDs, ["1"])
  }

  func testWiredCameraImportStateDisablesSelectionBeforeLiveCatalogIsReady() {
    let item = wiredImportItem(id: "1", name: "DSCF0001.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([item], isLiveCatalog: false)
    state.toggleSelection(for: item)

    XCTAssertTrue(state.selectedItemIDs.isEmpty)
    XCTAssertTrue(state.selectedImportableItems.isEmpty)
  }

  func testWiredCameraDownloadResolutionPolicyHandlesFileURLs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let downloaded = directory.appendingPathComponent("DSCF0001.JPG")
    FileManager.default.createFile(atPath: downloaded.path, contents: Data([1, 2, 3]))

    let resolved = WiredCameraDownloadResolutionPolicy.resolvedURL(
      savedFilename: downloaded.absoluteString,
      requestedFilename: "fallback.JPG",
      directory: directory
    )

    XCTAssertEqual(resolved, downloaded)
  }

  func testWiredCameraAutoImportPolicyRequiresExplicitOptIn() {
    let importable = wiredImportItem(id: "new", name: "DSCF0001.JPG")
    let imported = wiredImportItem(id: "saved", name: "DSCF0002.JPG")
    let unsupported = wiredImportItem(id: "txt", name: "README.TXT", uti: "public.text", isImportable: false)

    var state = WiredCameraImportState()
    state.replaceItems([importable, imported, unsupported], isLiveCatalog: true)
    state.importedItemIDs = ["saved"]

    XCTAssertTrue(WiredCameraAutoImportPolicy.itemsToImport(from: state).isEmpty)
    XCTAssertEqual(WiredCameraAutoImportPolicy.itemsToImport(from: state, isEnabled: true), [importable])

    state.replaceItems([importable], isLiveCatalog: false)
    XCTAssertTrue(WiredCameraAutoImportPolicy.itemsToImport(from: state, isEnabled: true).isEmpty)
  }

  func testWiredCameraImportNavigationPolicyBlocksLeavingWhileImporting() {
    XCTAssertFalse(WiredCameraImportNavigationPolicy.canLeaveImportScreen(isImporting: true))
    XCTAssertTrue(WiredCameraImportNavigationPolicy.canLeaveImportScreen(isImporting: false))
  }

  func testWiredCameraImportNavigationPolicyKeepsImportingOnFilterGrid() {
    XCTAssertFalse(WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: true))
    XCTAssertTrue(WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: false))
  }

  func testNativePhotoPreviewRotationPolicyCyclesManualRotation() {
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(0), 90)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(90), 180)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(180), 270)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(270), 0)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(-90), 0)
  }

  func testNativePhotoPreviewRotationPolicySwapsDisplaySizeForQuarterTurns() {
    let size = CGSize(width: 160, height: 120)

    XCTAssertEqual(NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 0), size)
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 90),
      CGSize(width: 120, height: 160)
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 270),
      CGSize(width: 120, height: 160)
    )
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 180), size)
  }

  func testNativePhotoPreviewRotationPolicyUsesCameraVendorOrientationBeforeDimensionFallback() {
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 2,
        decodedWidth: 160,
        decodedHeight: 120,
        imageData: nil
      ),
      90
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 4,
        decodedWidth: 640,
        decodedHeight: 480,
        imageData: nil
      ),
      270
    )
  }

  func testNativePhotoPreviewRotationPolicyDoesNotDoubleRotateAlreadyAppliedObjectOrientationLikeAndroid() {
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 2,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: nil
      ),
      0
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 4,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: nil
      ),
      0
    )
  }

  func testNativePhotoPreviewRotationPolicyFallsBackToJpegExifOrientation() throws {
    let data = try jpegDataWithExifOrientation(.right)

    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: nil,
        decodedWidth: 160,
        decodedHeight: 120,
        imageData: data
      ),
      90
    )
  }

  func testNativePhotoPreviewRotationPolicyDoesNotDoubleRotateAlreadyAppliedExifLikeAndroid() throws {
    let data = try jpegDataWithExifOrientation(.right)

    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: nil,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: data
      ),
      0
    )
  }

  func testGalleryThumbnailRendererKeepsPixelsVisibleAfterObjectOrientationRotation() throws {
    let data = try jpegData(
      size: CGSize(width: 24, height: 12),
      fill: UIColor.red
    )

    let image = try XCTUnwrap(CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: 2))

    XCTAssertLessThan(image.size.width, image.size.height)
    XCTAssertGreaterThan(try dominantRedValue(in: image), 180)
  }

  func testNativePhotoPreviewInitialImagePolicyUsesGridCachedThumbnailWhenItemDataIsMissing() {
    let cached = UIImage()
    let item = CameraVendorGalleryItem(
      handle: 11,
      filename: "DSCF0011.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:27 16:35:00",
      byteSizeText: "4 MB",
      thumbnailData: nil
    )

    XCTAssertTrue(NativePhotoPreviewInitialImagePolicy.initialImage(item: item, cachedThumbnailImage: cached) === cached)
  }

  func testNativeGalleryPreviewImageLoadPolicyMatchesAndroidJpegAndHeifOnly() {
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertFalse(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertFalse(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 4, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: ""),
      hasPreviewImage: true
    ))
  }

  func testNativeGalleryHighDefinitionPreviewModeQueuesFromCurrentHandleLikeAndroid() {
    let controller = NativeGalleryHighDefinitionPreviewModeController()

    controller.begin(
      orderedHandles: [1, 2, 3, 4],
      currentHandle: 3,
      alreadyLoadedHandles: [4]
    )

    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(controller.pendingHandles, [3, 1, 2])

    controller.markLoaded(3)
    XCTAssertEqual(controller.pendingHandles, [1, 2])

    controller.promoteCurrentHandle(2, alreadyLoadedHandles: [3, 4])
    XCTAssertEqual(controller.pendingHandles, [2, 1])
  }

  func testNativeGalleryHighDefinitionPreviewCacheKeepsLoadedStateAfterMemoryEviction() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(
      maxMemoryImages: 2,
      directory: directory
    )

    cache.store(Data([1]), for: 1)
    cache.store(Data([2]), for: 2)
    cache.store(Data([3]), for: 3)

    XCTAssertEqual(cache.loadedHandles, [1, 2, 3])
    XCTAssertNil(cache.memoryData(for: 1))
    XCTAssertEqual(cache.restoreLoadedData(for: 1), Data([1]))
    XCTAssertEqual(cache.memoryData(for: 1), Data([1]))
    XCTAssertEqual(cache.loadedHandles, [1, 2, 3])
  }

  func testNativePhotoPreviewImageSourcePolicySkipsCameraFetchWhenPreviewCacheIsLoaded() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: ""
    )

    XCTAssertFalse(
      NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
        item: item,
        hasPreviewImage: false,
        hasLoadedPreviewData: true
      )
    )
    XCTAssertTrue(
      NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
        item: item,
        hasPreviewImage: false,
        hasLoadedPreviewData: false
      )
    )
  }

  func testWiredCameraImportStateSetsSelectionForDragOnlyWhenLiveImportableUnsaved() {
    let importable = wiredImportItem(id: "new", name: "DSCF0001.JPG")
    let imported = wiredImportItem(id: "saved", name: "DSCF0002.JPG")
    let unsupported = wiredImportItem(id: "txt", name: "README.TXT", uti: "public.text", isImportable: false)

    var state = WiredCameraImportState()
    state.replaceItems([importable, imported, unsupported], isLiveCatalog: true)
    state.markImported(itemID: imported.id)

    state.setSelection(true, for: importable)
    state.setSelection(true, for: imported)
    state.setSelection(true, for: unsupported)

    XCTAssertEqual(state.selectedItemIDs, ["new"])

    state.setSelection(false, for: importable)
    XCTAssertTrue(state.selectedItemIDs.isEmpty)

    state.replaceItems([importable], isLiveCatalog: false)
    state.setSelection(true, for: importable)
    XCTAssertTrue(state.selectedItemIDs.isEmpty)
  }

  func testLocalProofingWebRendererSerializesPhotosWithFavoriteState() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: true
    )

    let data = try LocalProofingWebRenderer.photosJSON(
      photos: [photo],
      favoriteIDs: ["photo-1"]
    )
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let photos = object?["photos"] as? [[String: Any]]

    XCTAssertEqual(photos?.first?["id"] as? String, "photo-1")
    XCTAssertEqual(photos?.first?["favorite"] as? Bool, true)
    XCTAssertEqual(photos?.first?["previewURL"] as? String, "/preview/photo-1.jpg")
  }

  func testLocalProofingGalleryHTMLSupportsTapToPreviewLargePhoto() throws {
    let html = String(
      data: LocalProofingWebRenderer.galleryHTML(sessionToken: "ABC123"),
      encoding: .utf8
    )

    XCTAssertTrue(html?.contains(#"id="viewer""#) == true)
    XCTAssertTrue(html?.contains("openViewer(photo)") == true)
    XCTAssertTrue(html?.contains("viewerImage") == true)
  }

  func testLocalProofingFavoriteUpdateDecodesJSONBody() throws {
    let body = Data(#"{"id":"photo-1","favorite":true}"#.utf8)

    let update = try LocalProofingWebRenderer.favoriteUpdate(from: body)

    XCTAssertEqual(update, LocalProofingFavoriteUpdate(id: "photo-1", favorite: true))
  }

  func testLocalProofingRouterServesGalleryPhotosPreviewAndFavoriteUpdate() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: true
    )
    var favoriteUpdates: [LocalProofingFavoriteUpdate] = []
    let router = LocalProofingRequestRouter(
      sessionToken: "ABC123",
      photosProvider: { [photo] },
      favoriteIDsProvider: { [] },
      previewProvider: { id in id == "photo-1" ? Data([1, 2, 3]) : nil },
      favoriteHandler: { favoriteUpdates.append($0) }
    )

    let html = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/s/ABC123", body: Data()))
    XCTAssertEqual(html.statusCode, 200)
    XCTAssertTrue(String(data: html.body, encoding: .utf8)?.contains("/api/photos") == true)

    let photos = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/api/photos", body: Data()))
    XCTAssertEqual(photos.contentType, "application/json")
    XCTAssertTrue(String(data: photos.body, encoding: .utf8)?.contains("DSCF0001.JPG") == true)

    let preview = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/preview/photo-1.jpg", body: Data()))
    XCTAssertEqual(preview.contentType, "image/jpeg")
    XCTAssertEqual(preview.body, Data([1, 2, 3]))

    let favorite = router.response(for: LocalProofingHTTPRequest(
      method: "POST",
      path: "/api/favorite",
      body: Data(#"{"id":"photo-1","favorite":true}"#.utf8)
    ))
    XCTAssertEqual(favorite.statusCode, 200)
    XCTAssertEqual(favoriteUpdates, [LocalProofingFavoriteUpdate(id: "photo-1", favorite: true)])
  }

  func testLocalProofingServerHandlesSplitBrowserRequest() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: false
    )
    let router = LocalProofingRequestRouter(
      sessionToken: "ABC123",
      photosProvider: { [photo] },
      favoriteIDsProvider: { [] },
      previewProvider: { _ in nil },
      favoriteHandler: { _ in }
    )
    let server = LocalProofingServer(router: router)
    let url = try server.start(
      preferredPort: 18080,
      advertisedInterface: LocalProofingNetworkInterface(name: "lo0", address: "127.0.0.1")
    )
    defer { server.stop() }

    let responseExpectation = expectation(description: "server responds to split request")
    let connection = NWConnection(
      host: NWEndpoint.Host(url.host ?? "127.0.0.1"),
      port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 0))!,
      using: .tcp
    )
    var response = Data()
    connection.stateUpdateHandler = { state in
      guard case .ready = state else { return }
      connection.send(
        content: Data("GET /s/ABC123 HTTP/1.1\r\nHost:".utf8),
        completion: .contentProcessed { _ in
          connection.send(
            content: Data("127.0.0.1\r\n\r\n".utf8),
            completion: .contentProcessed { _ in }
          )
        }
      )
    }
    func receiveNext() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, _ in
        if let data {
          response.append(data)
        }
        if isComplete || String(data: response, encoding: .utf8)?.contains("</html>") == true {
          responseExpectation.fulfill()
          connection.cancel()
        } else {
          receiveNext()
        }
      }
    }
    receiveNext()
    connection.start(queue: .global())

    wait(for: [responseExpectation], timeout: 3)
    let responseText = try XCTUnwrap(String(data: response, encoding: .utf8))
    XCTAssertTrue(responseText.hasPrefix("HTTP/1.1 200 OK"), responseText)
    XCTAssertTrue(responseText.contains("现场选片"), responseText)
  }

  func testLocalProofingHTTPRequestParsesMethodPathAndBody() throws {
    let raw = Data("""
    POST /api/favorite?cache=0 HTTP/1.1\r
    Host: 192.168.2.2\r
    Content-Type: application/json\r
    \r
    {"id":"photo-1","favorite":false}
    """.utf8)

    let request = try XCTUnwrap(LocalProofingHTTPRequest.parse(raw))

    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/api/favorite")
    XCTAssertEqual(String(data: request.body, encoding: .utf8), #"{"id":"photo-1","favorite":false}"#)
  }

  func testLocalProofingSessionTokenAndQRCodeAreShareable() throws {
    let token = LocalProofingSessionToken.make()

    XCTAssertEqual(token.count, 6)
    XCTAssertNotNil(token.range(of: #"^[A-Z2-9]+$"#, options: .regularExpression))
    XCTAssertNotNil(LocalProofingQRCode.image(for: "http://192.168.2.2:8080/s/\(token)"))
  }

  func testLocalProofingNetworkPrefersWifiThenHotspotAndNeverCellular() {
    let interfaces = [
      LocalProofingNetworkInterface(name: "pdp_ip0", address: "10.12.0.8"),
      LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      LocalProofingNetworkInterface(name: "bridge100", address: "172.20.10.1"),
    ]

    XCTAssertEqual(LocalProofingNetwork.preferredAddress(from: interfaces)?.address, "192.168.1.22")
    XCTAssertEqual(LocalProofingNetwork.preferredAddress(from: Array(interfaces.prefix(2)))?.address, "192.168.1.22")
    XCTAssertNil(LocalProofingNetwork.preferredAddress(from: [interfaces[0]]))
  }

  func testLocalProofingNetworkBuildsSeparateWifiAndHotspotShareEndpoints() {
    let endpoints = LocalProofingNetwork.shareEndpoints(
      port: 8080,
      token: "ABC123",
      interfaces: [
        LocalProofingNetworkInterface(name: "pdp_ip0", address: "10.12.0.8"),
        LocalProofingNetworkInterface(name: "bridge100", address: "172.20.10.1"),
        LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      ]
    )

    XCTAssertEqual(endpoints.map(\.label), ["同一 Wi-Fi", "iPhone 热点"])
    XCTAssertEqual(endpoints.map { $0.url.absoluteString }, [
      "http://192.168.1.22:8080/s/ABC123",
      "http://172.20.10.1:8080/s/ABC123",
    ])
  }

  func testLocalProofingNetworkDoesNotInventHotspotFallback() {
    let token = "ABC123"

    let missingURL = LocalProofingNetwork.url(interface: nil, port: 8080, token: token)
    let wifiURL = LocalProofingNetwork.url(
      interface: LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      port: 8080,
      token: token
    )

    XCTAssertNil(missingURL)
    XCTAssertEqual(wifiURL?.absoluteString, "http://192.168.1.22:8080/s/ABC123")
  }

  func testLocalProofingPhotoMapperUsesWiredImportMetadataAndPreviewState() {
    let item = wiredImportItem(
      id: "photo-1",
      name: "DSCF0001.JPG",
      fileSize: 1_200_000,
      thumbnail: UIImage(systemName: "photo")
    )

    let photo = LocalProofingPhotoMapper.photo(from: item)

    XCTAssertEqual(photo.id, "photo-1")
    XCTAssertEqual(photo.filename, "DSCF0001.JPG")
    XCTAssertEqual(photo.formatLabel, "JPG")
    XCTAssertTrue(photo.detail.contains("JPG"))
    XCTAssertTrue(photo.detail.contains("MB"))
    XCTAssertTrue(photo.hasPreview)
  }

  private func wiredImportItem(
    id: String,
    name: String,
    uti: String? = "public.jpeg",
    fileSize: Int64 = 1024,
    createdAt: Date? = nil,
    thumbnail: UIImage? = nil,
    isImportable: Bool = true
  ) -> WiredCameraImportItem {
    WiredCameraImportItem(
      id: id,
      name: name,
      uti: uti,
      fileSize: fileSize,
      createdAt: createdAt,
      thumbnail: thumbnail,
      isImportable: isImportable
    )
  }

  func testCameraGallerySessionProtocolMatchesCurrentGalleryServiceContract() {
    let session: CameraGallerySession = CameraVendorRealtimeGalleryService()

    XCTAssertTrue(session is CameraVendorRealtimeGalleryService)
  }

  func testCameraAdapterDescriptorCanDescribeFujifilmWithoutUiBrandClaims() {
    let descriptor = CameraAdapterDescriptor(
      id: "fujifilm-x-series",
      displayName: "FUJIFILM X Series",
      legalDisclaimer: "FUJIFILM is a trademark of FUJIFILM Corporation. This app is not affiliated with or endorsed by FUJIFILM Corporation."
    )

    XCTAssertEqual(descriptor.id, "fujifilm-x-series")
    XCTAssertTrue(descriptor.displayName.contains("FUJIFILM"))
    XCTAssertTrue(descriptor.legalDisclaimer?.contains("not affiliated") == true)
  }

  func testFujifilmXSeriesProfilePreservesCurrentXt5GalleryPolicies() {
    let profile = FujifilmXSeriesProfile.xt5Current

    XCTAssertEqual(profile.id, "fujifilm-x-series-xt5-current")
    XCTAssertEqual(
      profile.ptpStartupDelaySeconds,
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true)
    )
    XCTAssertEqual(profile.fileDownloadReadSize, CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize)
    XCTAssertEqual(
      profile.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize
    )
    XCTAssertEqual(profile.parallelDownloadMaxWorkers, CameraVendorParallelDownloadPolicy.maxWorkers)
    XCTAssertEqual(profile.hiddenHandleMaxOverallRange, CameraVendorHiddenObjectHandleProbePolicy.maxOverallRange)
    XCTAssertEqual(
      profile.hiddenHandleMaxContiguousGapRange,
      CameraVendorHiddenObjectHandleProbePolicy.maxContiguousGapRange
    )
    XCTAssertEqual(
      profile.shouldResetCompressionModeBeforeObjectInfoList,
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetCompressionModeBeforeObjectInfoList
    )
  }

  func testFujifilmXSeriesProfilePreservesCurrentObjectSizePolicy() {
    let profile = FujifilmXSeriesProfile.xt5Current

    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: 100))
    XCTAssertTrue(profile.shouldSkipFreshFileInfoProbe(formatLabel: "RAW", cachedExpectedSize: 100))
    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "JPG", cachedExpectedSize: 100))
    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: nil))
  }

  func testThumbnailFallbackStopsAfterPriorityDownloadInterruption() {
    XCTAssertFalse(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: true,
        isConnected: true
      )
    )
    XCTAssertTrue(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: false,
        isConnected: true
      )
    )
    XCTAssertFalse(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: false,
        isConnected: false
      )
    )
  }

  func testFujifilmCameraAdapterCreatesCurrentGallerySession() {
    let adapter = FujifilmCameraAdapter(profile: .xt5Current)
    let session = adapter.makeGallerySession()

    XCTAssertEqual(adapter.descriptor.id, "fujifilm-x-series")
    XCTAssertTrue(session is CameraVendorRealtimeGalleryService)
  }

  func testFujifilmCameraAdapterExposesCurrentProfileForDiagnostics() {
    let adapter = FujifilmCameraAdapter(profile: .xt5Current)

    XCTAssertEqual(adapter.profile.id, FujifilmXSeriesProfile.xt5Current.id)
  }

  func testNativeConnectUsesDefaultFujifilmAdapterDescriptor() {
    let descriptor = NativeCameraAdapterRegistry.defaultAdapterDescriptor

    XCTAssertEqual(descriptor.id, "fujifilm-x-series")
  }

  func testCameraVendorAdvertisementMatcherAcceptsCameraVendorName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "CAMERA-DEVICE-A",
      serviceUUIDs: [],
      manufacturerData: nil
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .unknown)
    XCTAssertNil(match?.pairingToken)
  }

  func testCameraVendorAdvertisementMatcherAcceptsFujifilmXSeriesModelName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "X-T5",
      serviceUUIDs: [],
      manufacturerData: nil
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.resolvedName, "X-T5")
    XCTAssertEqual(match?.appVariant, .unknown)
  }

  func testCameraVendorAdvertisementMatcherAcceptsCameraRemoteUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.legacyRemoteServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .legacyRemote)
    XCTAssertEqual(match?.pairingToken, Data([0x11, 0x22, 0x33, 0x44]))
  }

  func testCameraVendorAdvertisementMatcherAcceptsReferenceAppUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.referenceAppServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0xAA, 0xBB, 0xCC, 0xDD])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .referenceApp)
    XCTAssertEqual(match?.pairingToken, Data([0xAA, 0xBB, 0xCC, 0xDD]))
  }

  func testCameraVendorAdvertisementMatcherAcceptsStandbyUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.standbyServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x01, 0x02, 0x03, 0x04])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .standby)
    XCTAssertEqual(match?.pairingToken, Data([0x01, 0x02, 0x03, 0x04]))
  }

  func testCameraVendorAdvertisementMatcherRejectsUnrelatedAdvertisement() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "Unrelated Camera",
      serviceUUIDs: [],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x10, 0x20, 0x30, 0x40])
    )

    XCTAssertNil(match)
  }

  func testPairingTokenExtractsFromManufacturerDataWithCompanyPrefix() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertEqual(token, Data([0x11, 0x22, 0x33, 0x44]))
  }

  func testPairingTokenExtractsFromFiveBytePayload() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0x02, 0x99, 0x88, 0x77, 0x66])
    )

    XCTAssertEqual(token, Data([0x99, 0x88, 0x77, 0x66]))
  }

  func testPairingTokenRejectsWrongManufacturerType() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0xD8, 0x04, 0x01, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertNil(token)
  }

  func testPairingPayloadUsesTokenBytesUnchanged() {
    let payload = CameraVendorSecureHandshakeCodec.pairingPayload(Data([0x01, 0x02, 0x03, 0x04]))

    XCTAssertEqual(payload, Data([0x01, 0x02, 0x03, 0x04]))
  }

  func testIdentifierPayloadUsesUtf8Encoding() {
    let payload = CameraVendorSecureHandshakeCodec.identifierPayload("CamTransfer Native")

    XCTAssertEqual(payload, Data("CamTransfer Native".utf8))
  }

  func testHandshakeIdentityPolicyUsesStableIPhoneStyleNameForCameraPairing() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "Gold 的 iPhone",
        fallbackAppName: "CamTransfer"
      ),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyAddsStableSuffixForGenericIPhoneName() {
    let name = CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
      preferredDeviceName: "iPhone",
      fallbackAppName: "CamTransfer"
    )

    XCTAssertEqual(name, "iPhone-6970")
  }

  func testHandshakeIdentityPolicyNormalizesStoredGenericIPhoneName() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.normalizedStoredConnectedDeviceName("iPhone-0426"),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyMigratesLegacyPhonePrefixedStoredName() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.normalizedStoredConnectedDeviceName("Phone-0426"),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyStillUsesStableIPhoneStyleNameWhenInputsAreEmpty() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "   ",
        fallbackAppName: "CamTransfer Native"
      ),
      "iPhone-6970"
    )
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: nil,
        fallbackAppName: nil
      ),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyMatchesFallbackIdentifierEncoding() {
    XCTAssertEqual(CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName, "CamTransfer")
    XCTAssertEqual(
      CameraVendorSecureHandshakeCodec.identifierPayload(
        CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
      ),
      Data("CamTransfer".utf8)
    )
  }

  func testStandbyUuidMatchesCurrentCameraVendorDocumentation() {
    XCTAssertEqual(
      CameraVendorDeviceMatcher.standbyServiceUUIDString,
      "A9D2B304-E8D6-4902-8336-352B772D7597"
    )
  }

  func testSecureHandshakeStatusAckReplacesFourthByteWith20() {
    let payload = CameraVendorSecureHandshakeCodec.statusAckPayload(
      from: Data([0x07, 0x96, 0x00, 0x00])
    )

    XCTAssertEqual(payload, Data([0x07, 0x96, 0x00, 0x20]))
  }

  func testSecureHandshakeStatusAckRequiresFourBytes() {
    XCTAssertNil(CameraVendorSecureHandshakeCodec.statusAckPayload(from: Data([0x01, 0x02, 0x03])))
  }

  func testSecureIdentificationAckPolicyDoesNotSkipAckForRememberedPairing() {
    XCTAssertFalse(
      CameraVendorSecureIdentificationAckPolicy.shouldSkipIdentificationAck(
        isRememberedPairing: true
      )
    )
    XCTAssertFalse(
      CameraVendorSecureIdentificationAckPolicy.shouldSkipIdentificationAck(
        isRememberedPairing: false
      )
    )
  }

  func testReferenceAppPairingCodecSetsApplicationIdentifierBit() {
    let payload = CameraVendorReferenceAppPairingCodec.identificationNumberPayload(
      from: Data([0x2B, 0xA1, 0x26, 0x00])
    )

    XCTAssertEqual(payload, Data([0x2B, 0xA1, 0x26, 0x20]))
  }

  func testReferenceAppPairingCodecRejectsNonFourByteIdentificationNumber() {
    XCTAssertNil(
      CameraVendorReferenceAppPairingCodec.identificationNumberPayload(
        from: Data([0x01, 0x02, 0x03])
      )
    )
  }

  func testReferenceAppPairingCodecRecognizesAlreadyPairedIdentificationNumber() {
    XCTAssertTrue(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26, 0x20])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26, 0x00])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26])
      )
    )
  }

  func testReferenceAppPairingPolicyStartsByWritingDeviceName() {
    XCTAssertEqual(
      CameraVendorReferenceAppPairingPolicy.initialStep,
      .writeDeviceName
    )
  }

  func testReferenceAppPairingPolicyReadsIdentificationNumberAfterDeviceNameWrite() {
    XCTAssertEqual(
      CameraVendorReferenceAppPairingPolicy.nextStep(after: .didWriteDeviceName),
      .readIdentificationNumber
    )
  }

  func testHandshakeWaitsForMetadataReadToFinish() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.registerServiceForCharacteristicDiscovery("180A")

    coordinator.completeCharacteristicDiscovery(for: "91F1")
    coordinator.registerMetadataRead("2A25")

    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.completeCharacteristicDiscovery(for: "180A")
    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.completeMetadataRead("2A25")
    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeCanStartImmediatelyWhenOnlyPairServiceIsNeeded() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.completeCharacteristicDiscovery(for: "91F1")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeDoesNotRestartAfterBeginning() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.completeCharacteristicDiscovery(for: "91F1")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.markHandshakeStarted()
    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeCanStartWhenSecureIdentifierIsPresent() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("123D")
    coordinator.completeCharacteristicDiscovery(for: "123D")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testSecureHandshakeWaitsForAllServicesBeforeWritingConnectedDeviceName() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("123D8F06-62A1-4935-9322-833C531EE225")
    coordinator.registerServiceForCharacteristicDiscovery("4E941240-D01D-46B9-A5EA-67636806830B")

    coordinator.completeCharacteristicDiscovery(for: "123D8F06-62A1-4935-9322-833C531EE225")

    XCTAssertFalse(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )

    coordinator.completeCharacteristicDiscovery(for: "4E941240-D01D-46B9-A5EA-67636806830B")

    XCTAssertTrue(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )
  }

  func testSecureHandshakeWaitsForNotificationSubscriptionsBeforeWritingConnectedDeviceName() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerNotificationSubscription("A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

    XCTAssertFalse(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )

    coordinator.completeNotificationSubscription(for: "A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

    XCTAssertTrue(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )
  }

  func testEncryptionRecoveryRetriesOnlyOnce() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    XCTAssertTrue(policy.registerEncryptionFailureAndShouldRetry())
    XCTAssertFalse(policy.registerEncryptionFailureAndShouldRetry())
  }

  func testEncryptionRecoveryRequiresSystemBluetoothCleanupAfterRetryIsUsed() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()

    XCTAssertTrue(policy.shouldRequireSystemBluetoothCleanupAfterRetryExhausted())
  }

  func testEncryptionRecoveryResetAllowsFutureRetry() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()
    policy.reset()

    XCTAssertTrue(policy.registerEncryptionFailureAndShouldRetry())
  }

  func testEncryptionRecoveryGuidesUserToCameraPairingModeAfterDisconnect() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()

    XCTAssertEqual(
      policy.consumeDisconnectAction(),
      .requireManualCameraPairingMode
    )
  }

  func testPairingReadyAdvertisementRequiresNonStandbySignal() {
    XCTAssertFalse(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: [CameraVendorDeviceMatcher.standbyServiceUUIDString],
        manufacturerData: Data([0xD8, 0x04, 0x01, 0x31, 0x30, 0x30, 0x33, 0x42])
      )
    )

    XCTAssertTrue(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: [CameraVendorDeviceMatcher.referenceAppServiceUUIDString],
        manufacturerData: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
      )
    )
  }

  func testPairingReadyAdvertisementAcceptsSecurePairServiceUuid() {
    XCTAssertTrue(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: ["123D8F06-62A1-4935-9322-833C531EE225"],
        manufacturerData: Data([0xD8, 0x04, 0x01, 0x31, 0x30, 0x30, 0x33, 0x42])
      )
    )
  }

  func testWifiJoinDiagnosticsIncludesNamedHotspotError() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "internal error."]
    )

    XCTAssertEqual(
      CameraVendorWifiJoinDiagnostics.describeHotspotError(error),
      "\(NEHotspotConfigurationErrorDomain) code=8 internal error. | hotspot=internal"
    )
  }

  func testWifiJoinDiagnosticsLeavesUnknownDomainsUntouched() {
    let error = NSError(
      domain: "ExampleDomain",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "boom"]
    )

    XCTAssertEqual(
      CameraVendorWifiJoinDiagnostics.describeHotspotError(error),
      "ExampleDomain code=42 boom"
    )
  }

  func testWifiJoinDiagnosticsTreatsInternalHotspotErrorAsRecoverable() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "internal error."]
    )

    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
  }

  func testWifiJoinDiagnosticsTreatsMissingApplyCallbackAsRecoverableForEvidenceCheck() {
    let error = CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutError(
      ssid: "FUJIFILM-X-T5-003B"
    )

    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.isApplyCallbackTimeout(error))
    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutSeconds, 8)
    XCTAssertTrue(
      CameraVendorWifiJoinDiagnostics
        .describeHotspotError(error)
        .contains("等待系统 Wi-Fi 连接回调超时")
    )
  }

  func testWifiJoinDiagnosticsDoesNotTreatUnrelatedErrorAsRecoverable() {
    let error = NSError(
      domain: "ExampleDomain",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "boom"]
    )

    XCTAssertFalse(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
  }

  func testWifiJoinDiagnosticsRequestsLocationAuthorizationWhenNeeded() {
    XCTAssertTrue(
      CameraVendorWifiJoinDiagnostics.shouldRequestLocationAuthorization(for: CLAuthorizationStatus.notDetermined)
    )
    XCTAssertFalse(
      CameraVendorWifiJoinDiagnostics.shouldRequestLocationAuthorization(
        for: CLAuthorizationStatus.authorizedWhenInUse
      )
    )
  }

  func testWifiAssociationReadinessDoesNotUsePtpProbeBeforeGallerySession() {
    XCTAssertFalse(
      CameraVendorWifiAssociationReadiness.isReadyToProceed(
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil,
        isCameraPtpReachable: true
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadiness.isReadyToProceed(
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil,
        isCameraPtpReachable: false
      )
    )
  }

  func testHiddenGalleryRoutePolicyOnlyRunsStrictReferenceAppAfterBleHandoff() {
    let routes = CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes

    XCTAssertEqual(
      routes.map(\.id),
      [.strictReferenceApp]
    )
    XCTAssertEqual(routes.count, 1)
    XCTAssertEqual(routes[0].launchRequestPayload, Data([0x03, 0x00]))
    XCTAssertEqual(routes[0].ptpStartupDelaySeconds, 0)
  }

  func testHiddenGalleryRoutePolicyStopsAfterSuccessfulItems() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:04:30 14:00:00",
      byteSizeText: "1 MB"
    )

    XCTAssertTrue(CameraVendorGalleryRoutePolicy.shouldStopRouteSearch(after: [item]))
    XCTAssertFalse(CameraVendorGalleryRoutePolicy.shouldStopRouteSearch(after: []))
  }

  func testBluetoothConnectFailurePolicyRecognizesRemovedPairingInformation() {
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(
        for: "Peer removed pairing information"
      ),
      CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    )
    XCTAssertTrue(CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus.contains("删除本地蓝牙配对"))
  }

  func testSystemBluetoothCleanupPolicyPersistsHardBlockUntilUserConfirmsCleanup() throws {
    let suiteName = "CameraVendorSystemBluetoothPairingCleanupPolicyTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    XCTAssertFalse(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))

    CameraVendorSystemBluetoothPairingCleanupPolicy.markCleanupRequired(
      reason: "Peer removed pairing information",
      defaults: defaults
    )
    XCTAssertTrue(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))

    CameraVendorSystemBluetoothPairingCleanupPolicy.clearCleanupRequired(defaults: defaults)
    XCTAssertFalse(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))
  }

  func testBluetoothConnectFailurePolicyTreatsEncryptionErrorsAsSystemPairingCleanupRequired() {
    XCTAssertTrue(
      CameraVendorBluetoothConnectFailurePolicy.requiresSystemBluetoothPairingCleanup(
        for: "CBATTErrorDomain Code=15 insufficient encryption"
      )
    )
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(
        for: "Insufficient Encryption"
      ),
      CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    )
  }

  func testBluetoothConnectFailurePolicyClearsRememberedPairingWhenPeerRemovedPairingInformation() {
    XCTAssertTrue(
      CameraVendorBluetoothConnectFailurePolicy.shouldClearRememberedPairing(
        for: "Peer removed pairing information"
      )
    )
  }

  func testBluetoothConnectFailurePolicyFallsBackToGenericFailure() {
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(for: "timeout"),
      "连接失败"
    )
  }

  func testTransferActivationFailureStatusDoesNotAskForBluetoothCleanup() {
    XCTAssertFalse(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("清除旧配对"))
    XCTAssertFalse(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("删除本地蓝牙"))
    XCTAssertTrue(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("传图模式"))
  }

  func testGalleryPreparationSkipsAutomaticWifiJoinAfterManualRecoveryWasSuggested() {
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
        hasWifiConfigurations: true,
        prefersManualWifiRecovery: true
      )
    )
  }

  func testGalleryPreparationAttemptsAutomaticWifiJoinWhenCameraCredentialsAreAvailable() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
        hasWifiConfigurations: true,
        prefersManualWifiRecovery: false
      )
    )
  }

  func testGalleryPreparationStopsAfterPreferredWifiConfigurationFails() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
        attemptedConfigurationIndex: 0
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
        attemptedConfigurationIndex: 1
      )
    )
  }

  func testWifiJoinDiagnosticsWaitsForSSIDAfterRecoverableApplyFailure() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue
    )

    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.associationTimeout(after: error), 15)
    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.associationTimeout(after: nil), 15)
  }

  func testWifiJoinDiagnosticsDoesNotAllowUnverifiedAssociationWithoutSSIDMatch() {
    XCTAssertFalse(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil
      )
    )
    XCTAssertFalse(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: "YangBaby"
      )
    )
    XCTAssertTrue(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: "CAMERA-DEVICE-A-003B"
      )
    )
  }

  func testWifiJoinDiagnosticsDoesNotRemoveExistingConfigurationBeforeJoin() {
    XCTAssertFalse(CameraVendorWifiJoinDiagnostics.shouldRemoveExistingConfigurationBeforeJoin)
  }

  func testWifiAssociationReadinessWaitsAfterManualRecoverySsidEvidence() {
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: true,
        currentWifiIP: nil
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: true,
        currentWifiIP: "192.168.0.130"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: false,
        currentWifiIP: nil
      )
    )
  }

  func testPtpStartupPolicyAttemptsImmediatelyAfterWifiHandoffLikeAndroid() {
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true),
      0
    )
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: false),
      0
    )
  }

  func testWifiHandoffDoesNotAddExtraStabilizationDelayAfterSSIDMatchLikeAndroid() {
    XCTAssertEqual(CameraVendorWifiHandoffStabilizationPolicy.delayAfterSSIDAssociationSeconds, 0)
  }

  func testPtpConnectionStartupPolicyMatchesAndroidBoundedRetryWindow() {
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds, 1.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.maxAttempts, 5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 1), 0.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 2), 1.0)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 3), 1.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 4), 2.0)
    XCTAssertTrue(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 1))
    XCTAssertTrue(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 4))
    XCTAssertFalse(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 5))
  }

  func testSearchModeDescRetryPolicyOnlyRetriesBusyResponse() {
    let busy = NSError(domain: "CameraVendorPtpSession", code: 0x2019)
    let unsupported = NSError(domain: "CameraVendorPtpSession", code: 0x2005)
    let otherDomain = NSError(domain: "Other", code: 0x2019)

    XCTAssertTrue(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: busy))
    XCTAssertFalse(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: unsupported))
    XCTAssertFalse(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: otherDomain))
    XCTAssertEqual(CameraVendorSearchModeDescRetryPolicy.maxAttempts, 3)
    XCTAssertEqual(CameraVendorSearchModeDescRetryPolicy.retryDelaySeconds(afterFailedAttempt: 2), 1.0)
  }

  func testSpecifiedObjectSnapshotPolicyDoesNotResetSearchModeOnColdStart() {
    XCTAssertFalse(CameraVendorSpecifiedObjectSnapshotPolicy.shouldCompareBeforeAndAfterEmptySearchMode)
  }

  func testPtpCommandSerializationPolicySerializesSingleCommandSocket() {
    XCTAssertTrue(CameraVendorPtpCommandSerializationPolicy.shouldSerializeCommandSocketAccess)
  }

  func testThumbnailLoadPolicyUsesSequentialPtpRequests() {
    XCTAssertTrue(CameraVendorThumbnailLoadPolicy.shouldLoadSequentially)
    XCTAssertTrue(CameraVendorThumbnailLoadPolicy.shouldPauseWhileDownloading)
    XCTAssertTrue(CameraVendorThumbnailLoadPolicy.shouldInterruptInFlightRequestBeforeDownload)
    XCTAssertFalse(CameraVendorThumbnailLoadPolicy.shouldClosePtpSocketForPriorityDownloadInterruption)
  }

  func testCameraVendorPartialObjectRequestPolicyUsesAndroidReferenceReadSizes() {
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize, 1 * 1_024 * 1_024)
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize, 4 * 1_024 * 1_024)
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds, 60)
  }

  func testCameraVendorPartialObjectRequestPolicyUsesEffectiveFileChunksWithSafeFallback() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
      4 * 1_024 * 1_024
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(remaining: 20 * 1_024 * 1_024),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(remaining: 3 * 1_024 * 1_024),
      3 * 1_024 * 1_024
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(
        remaining: 20 * 1_024 * 1_024,
        useFallback: true
      ),
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
  }

  func testAdaptiveDownloadChunkPolicyIsDisabledForAndroidParity() {
    XCTAssertFalse(CameraVendorAdaptiveDownloadChunkPolicy.isEnabled)
    XCTAssertEqual(CameraVendorAdaptiveDownloadChunkPolicy.strategyName, "android-fixed-4mb")
  }

  func testAdaptiveDownloadChunkPolicyKeepsStableEffectiveFileChunks() {
    var state = CameraVendorAdaptiveDownloadChunkState()

    XCTAssertEqual(
      CameraVendorAdaptiveDownloadChunkPolicy.requestSize(remaining: 3 * 1_024 * 1_024, state: state),
      3 * 1_024 * 1_024
    )

    XCTAssertEqual(
      CameraVendorAdaptiveDownloadChunkPolicy.requestSize(remaining: 20 * 1_024 * 1_024, state: state),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )

    CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
      byteCount: 4 * 1_024 * 1_024,
      elapsedMs: 12_000,
      state: &state
    )

    XCTAssertEqual(state.readSize, CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize)
  }

  func testCameraVendorParallelDownloadPolicyUsesSingleWorkerBecauseSecondPtpSessionBreaksCameraTransfer() {
    XCTAssertFalse(CameraVendorParallelDownloadPolicy.isExperimentalSecondPtpSessionEnabled)
    XCTAssertEqual(CameraVendorParallelDownloadPolicy.maxWorkers, 1)
    XCTAssertEqual(CameraVendorParallelDownloadPolicy.desiredWorkerCount(for: 1), 1)
    XCTAssertEqual(CameraVendorParallelDownloadPolicy.desiredWorkerCount(for: 2), 1)
    XCTAssertEqual(CameraVendorParallelDownloadPolicy.desiredWorkerCount(for: 10), 1)
  }

  func testPartialObjectRequestPolicyUsesExpectedSizeAsReadLimit() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(expectedSize: 625_558),
      625_558
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(expectedSize: nil),
      UInt64(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize)
    )
  }

  func testDownloadDataDiagnosticPolicyReportsHeadAndHeifFtypOffset() {
    let heifLikeHead = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8)

    XCTAssertEqual(
      CameraVendorDownloadDataDiagnosticPolicy.headHex(from: heifLikeHead, byteCount: 8),
      "0000001866747970"
    )
    XCTAssertEqual(CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: heifLikeHead), 4)
    XCTAssertNil(CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: Data([0xFF, 0xD8, 0xFF])))
  }

  func testDiagnosticLogRedactorMasksPasswordsAndPassphrases() {
    let raw = """
    SSID: FUJIFILM-X-T5-003B
    密码: 12345678
    passphrase=87654321
    password: camera-secret
    """

    let redacted = CamTransferDiagnosticLogRedactor.redacted(raw)

    XCTAssertTrue(redacted.contains("SSID: FUJIFILM-X-T5-003B"))
    XCTAssertTrue(redacted.contains("密码: ********"))
    XCTAssertTrue(redacted.contains("passphrase=********"))
    XCTAssertTrue(redacted.contains("password: ********"))
    XCTAssertFalse(redacted.contains("12345678"))
    XCTAssertFalse(redacted.contains("87654321"))
    XCTAssertFalse(redacted.contains("camera-secret"))
  }

  func testDiagnosticExportPayloadIncludesMetadataAndRedactedLog() {
    let payload = CamTransferDiagnosticExportPayload.compose(
      appVersion: "1.2.3",
      buildNumber: "45",
      deviceModel: "iPhone15,3",
      systemVersion: "iOS 18.5",
      generatedAt: "2026-05-30T12:00:00Z",
      logText: "密码: 12345678\n连接失败: timeout"
    )

    XCTAssertTrue(payload.contains("CamTransfer Diagnostic Log"))
    XCTAssertTrue(payload.contains("App Version: 1.2.3 (45)"))
    XCTAssertTrue(payload.contains("Device: iPhone15,3"))
    XCTAssertTrue(payload.contains("System: iOS 18.5"))
    XCTAssertTrue(payload.contains("Generated At: 2026-05-30T12:00:00Z"))
    XCTAssertTrue(payload.contains("密码: ********"))
    XCTAssertTrue(payload.contains("连接失败: timeout"))
    XCTAssertFalse(payload.contains("12345678"))
  }

  func testCameraVendorOriginalDownloadPolicyUsesFreshHeifSizeForOriginalDownloads() {
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.expectedDownloadSize(
        formatLabel: "HEIF",
        freshCompressedSize: 16_560_640,
        cachedExpectedSize: 688_423
      ),
      16_560_640
    )
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.expectedDownloadSize(
        formatLabel: "RAW",
        freshCompressedSize: 16_560_640,
        cachedExpectedSize: 688_423
      ),
      688_423
    )
  }

  func testCameraVendorOriginalDownloadPolicyPreparesHeifTransferAndReadsFreshInfo() {
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldPrepareTransferStateBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseReferenceAppFastStartPreparation(
        formatLabel: "HEIF"
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSkipFreshFileInfoProbe(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeFreshFileInfo(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffAfterFreshFileInfo(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
  }

  func testCameraVendorDownloadModePolicyMatchesAndroidOriginalAndCompressedProperties() {
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.prepareProperties(mode: .original),
      [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 2,
          width: .uint16
        )
      ]
    )
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.prepareProperties(mode: .compressed),
      [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: 1,
          width: .uint16
        ),
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 1,
          width: .uint16
        )
      ]
    )
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.resetProperty(
        for: CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 2,
          width: .uint16
        )
      ),
      CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 0,
        width: .uint16
      )
    )
    XCTAssertNil(
      CameraVendorDownloadModePolicy.resetProperty(
        for: CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: 1,
          width: .uint16
        )
      )
    )
  }

  func testCameraVendorThumbnailFallbackUsesSmallPreviewReadSize() {
    XCTAssertLessThan(
      CameraVendorThumbnailFetchPolicy.partialPreviewReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.partialPreviewReadSize, 256 * 1_024)
  }

  func testCameraVendorPartialObjectRequestPolicyBuildsExtensionParameters() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.extensionPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0x00000001_00000020,
        size: 0x00100000
      ),
      [
        0x000003CA,
        0x00000020,
        0x00100000,
        0x00000001,
      ]
    )
  }

  func testCameraVendorPartialObjectRequestPolicyBuildsStandardParameters() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: 0x00100000
      ),
      [
        0x000003CA,
        0x00000000,
        0x00100000,
      ]
    )
  }

  func testCameraVendorPartialObjectRequestPolicyHasFiniteUnknownSizeLimit() {
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize, 128 * 1_024 * 1_024)
  }

  func testCameraVendorJpegDataPolicyRecognizesEndMarker() {
    XCTAssertTrue(CameraVendorJpegDataPolicy.hasEndMarker(Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])))
    XCTAssertFalse(CameraVendorJpegDataPolicy.hasEndMarker(Data([0xFF, 0xD8, 0x01])))
  }

  func testCameraVendorJpegDataPolicyRecognizesStartMarker() {
    XCTAssertTrue(CameraVendorJpegDataPolicy.hasStartMarker(Data([0xFF, 0xD8, 0xFF, 0xE1])))
    XCTAssertFalse(CameraVendorJpegDataPolicy.hasStartMarker(Data([0x00, 0x00, 0xFF, 0xD8])))
  }

  func testCameraVendorPreviewImageValidationRejectsIncompleteJpegLikeAndroid() {
    let completeJpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
    let incompleteJpeg = Data([0xFF, 0xD8, 0x01, 0x02])

    XCTAssertTrue(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(completeJpeg))
    XCTAssertFalse(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(incompleteJpeg))
    XCTAssertTrue(CameraVendorPreviewImageValidationPolicy.shouldRejectIncompletePartialPreview(incompleteJpeg))
  }

  func testCameraVendorPreviewImageValidationRejectsUnknownHeifBrandLikeAndroid() {
    let unknownBrand = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypzzzz".utf8) + Data([0x00, 0x00])

    XCTAssertFalse(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(unknownBrand))
  }

  func testImageDataNormalizerStripsCameraVendorPrefixBeforeJpegHeader() {
    let data = Data([0x15, 0x00, 0x10, 0x00, 0xFF, 0xD8, 0xFF, 0xE1, 0x01])

    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: data), Data([0xFF, 0xD8, 0xFF, 0xE1, 0x01]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.imageData(from: data), Data([0xFF, 0xD8, 0xFF, 0xE1, 0x01]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: Data([0xFF, 0xD8, 0xAA])), Data([0xFF, 0xD8, 0xAA]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: Data([0x00, 0x01, 0x02])), Data([0x00, 0x01, 0x02]))
  }

  func testImageDataNormalizerStripsCameraVendorPrefixBeforeHeifFtypBox() {
    let heif = Data([
      0xAA, 0xBB, 0xCC,
      0x00, 0x00, 0x00, 0x18,
      0x66, 0x74, 0x79, 0x70,
      0x68, 0x65, 0x69, 0x63,
      0x00, 0x00,
    ])

    XCTAssertEqual(
      CameraVendorImageDataNormalizer.imageData(from: heif),
      Data([
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70,
        0x68, 0x65, 0x69, 0x63,
        0x00, 0x00,
      ])
    )
  }

  func testImageDataNormalizerRecognizesAndroidVerifiedHeifBrands() {
    for brand in ["heic", "heix", "hevc", "hevx", "heis", "hevm", "heif", "mif1", "msf1"] {
      let prefixedHeif = Data([0xAA, 0xBB, 0xCC]) +
        Data([0x00, 0x00, 0x00, 0x18]) +
        Data("ftyp".utf8) +
        Data(brand.utf8) +
        Data([0x00, 0x00])

      XCTAssertEqual(
        CameraVendorImageDataNormalizer.imageData(from: prefixedHeif),
        prefixedHeif.dropFirst(3),
        "brand \(brand) should strip CameraVendor prefix before HEIF ftyp box"
      )
    }
  }

  func testGalleryPreparationPausesBeforePtpWhileWaitingForManualWifiJoin() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: false
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: true,
        isCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: true,
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryPreparationPausesBeforePtpWithoutCurrentOfficialWifiCredentials() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: false,
        skippedAutoJoinBecauseManual: false,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true,
        hasCurrentWifiConfigurations: false
      )
    )
  }

  func testGalleryPreparationPausesExplicitManualRetryWithoutNetworkEvidence() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryPreparationAllowsManualRecoveryFromCameraSubnetEvidence() {
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true
      )
    )
  }

  func testTransferFlowDoesNotAutomaticallyEnterGalleryAfterPairing() {
    XCTAssertFalse(CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing)
  }

  func testPairingCompletionWaitsForExplicitCameraConfirmation() {
    XCTAssertFalse(
      CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
        hasWrittenIdentifier: true,
        hasUserConfirmedCameraSuccess: false
      )
    )
    XCTAssertTrue(
      CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
        hasWrittenIdentifier: true,
        hasUserConfirmedCameraSuccess: true
      )
    )
  }

  func testPairingCompletionRequiresPhoneConfirmationBeforeAutoTransfer() {
    XCTAssertTrue(
      CameraVendorCameraPairingConfirmationPolicy.shouldWaitForPhoneConfirmationAfterIdentifierWrite(
        shouldBypassManualConfirmation: false
      )
    )
    XCTAssertFalse(
      CameraVendorCameraPairingConfirmationPolicy.shouldStartAutoTransferBeforePhoneConfirmation(
        shouldBypassManualConfirmation: false,
        shouldAutomaticallyPrepareTransferAfterPairing: true
      )
    )
  }

  func testPhonePairingConfirmationCanBeQueuedUntilCameraAckIsReady() {
    XCTAssertTrue(
      CameraVendorCameraPairingConfirmationPolicy.shouldQueuePhoneConfirmation(
        hasWrittenIdentifier: false,
        hasPendingHandshakeSummary: false,
        hasUserConfirmedCameraSuccess: true
      )
    )
    XCTAssertFalse(
      CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
        hasWrittenIdentifier: false,
        hasPendingHandshakeSummary: false,
        hasQueuedPhoneConfirmation: true
      )
    )
    XCTAssertTrue(
      CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        hasQueuedPhoneConfirmation: true
      )
    )
  }

  func testPhonePairingConfirmationReconnectsBeforeCompletingNewPairing() {
    XCTAssertTrue(
      CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        shouldBypassManualConfirmation: false
      )
    )
    XCTAssertFalse(
      CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        shouldBypassManualConfirmation: true
      )
    )
  }

  func testHomeScreenWaitsForExplicitPairingWhenNoRememberedCamera() {
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldStartScanningOnLaunch(
        hasRememberedCamera: false
      )
    )
  }

  func testHomeScreenValidatesRememberedCameraOnLaunchWhileKeepingCardVisible() {
    XCTAssertTrue(
      NativeCameraSearchStartupPolicy.shouldStartScanningOnLaunch(
        hasRememberedCamera: true
      )
    )
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldHideRememberedCameraWhileScanning(
        hasRememberedCamera: true
      )
    )
  }

  func testHomeScreenShowsInlineDiscoveredCamerasAndRemovesManualAddButton() {
    XCTAssertTrue(
      NativeCameraSearchStartupPolicy.shouldShowInlineDiscoveredCameraList(
        discoveredCameraCount: 1
      )
    )
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldShowInlineDiscoveredCameraList(
        discoveredCameraCount: 0
      )
    )
    XCTAssertFalse(NativeCameraSearchStartupPolicy.shouldShowManualAddCameraButton)
  }

  func testHomeScreenRestartsDiscoveryAfterDeletingRememberedCamera() {
    XCTAssertTrue(NativeCameraSearchStartupPolicy.shouldRestartScanningAfterRememberedCameraDeletion)
  }

  func testRememberedReconnectPolicyStopsAtReconnectPairedBleWhenTargetIsNotFound() {
    XCTAssertFalse(CameraVendorRememberedReconnectPolicy.shouldStartNormalDiscoveryAfterTargetTimeout)
  }

  func testRememberedReconnectPolicyDoesNotTrustSystemRetrievedPeripheralBeforeScanning() {
    XCTAssertFalse(CameraVendorRememberedReconnectPolicy.shouldTrySystemRetrievedPeripheralBeforeScanning)
  }

  func testPairingConfirmationStatusRequiresVisiblePrompt() {
    XCTAssertTrue(
      NativePairingConfirmationPresentationPolicy.shouldPresentPhoneConfirmationPrompt(
        status: CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus,
        isBusy: false
      )
    )
    XCTAssertFalse(
      NativePairingConfirmationPresentationPolicy.shouldPresentPhoneConfirmationPrompt(
        status: CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus,
        isBusy: true
      )
    )
  }

  func testPairingSuccessCleanupDismissesPairingUiAfterSuccessCallbacks() {
    XCTAssertTrue(
      NativePairingSuccessCleanupPolicy.shouldDismissPairingUI(
        event: .didCompletePairing
      )
    )
    XCTAssertTrue(
      NativePairingSuccessCleanupPolicy.shouldDismissPairingUI(
        event: .didCompleteHandshake
      )
    )
  }

  func testTransferFlowRequiresExplicitGalleryEntryAfterPairing() {
    XCTAssertFalse(
      CameraVendorPostPairingTransferPolicy.canStartTransfer(
        hasCompletedPairing: false,
        hasUserInitiatedTransfer: true
      )
    )
    XCTAssertFalse(
      CameraVendorPostPairingTransferPolicy.canStartTransfer(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: false
      )
    )
    XCTAssertTrue(
      CameraVendorPostPairingTransferPolicy.canStartTransfer(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true
      )
    )
  }

  func testTransferActivationEntryStatusDoesNotClaimWifiIsStillOpening() {
    XCTAssertEqual(CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus, "正在进入相机相册")
    XCTAssertFalse(CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus.contains("打开相机 Wi"))
  }

  func testGalleryEntryNavigationWaitsForPreloadBeforeEnteringAlbumPage() {
    XCTAssertTrue(
      NativeGalleryEntryNavigationPolicy.shouldEnterGalleryAfterPreload(fetchSucceeded: true)
    )
    XCTAssertFalse(
      NativeGalleryEntryNavigationPolicy.shouldEnterGalleryAfterPreload(fetchSucceeded: false)
    )
    XCTAssertFalse(NativeGalleryEntryNavigationPolicy.preloadingStatus.contains("等待相机 Wi-Fi"))
    XCTAssertFalse(NativeGalleryEntryNavigationPolicy.waitingForWifiStatus.contains("Wi-Fi"))
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.waitingForWifiStatus.contains("相册"))
  }

  func testGalleryEntryNavigationPushesGalleryBeforeCleanupToAvoidHomeFlash() {
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.shouldPushGalleryBeforeDismissingPairingUI)
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.shouldHideConnectingOverlayAfterGalleryPush)
  }

  func testGalleryStartupCoordinatorUsesGalleryFetchAsHardReadyEvidence() async throws {
    let coordinator = CameraVendorGalleryStartupCoordinator()
    let evidence = try await coordinator.loadGalleryReadyEvidence(using: CameraVendorGalleryStubService())

    XCTAssertFalse(evidence.items.isEmpty)
    XCTAssertTrue(evidence.hasGalleryReadyEvidence)
  }

  func testGalleryStartupCoordinatorRejectsEmptyGalleryAsReadyEvidence() {
    let evidence = CameraVendorGalleryReadyEvidence(items: [])

    XCTAssertFalse(evidence.hasGalleryReadyEvidence)
  }

  func testGalleryStartupCoordinatorAcceptsPlaceholderHandlesAsReadyEvidence() {
    let evidence = CameraVendorGalleryReadyEvidence(items: [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "0x00000001",
        formatLabel: "",
        captureDate: "",
        byteSizeText: ""
      )
    ])

    XCTAssertTrue(evidence.hasGalleryReadyEvidence)
  }

  func testGalleryEntryCoordinatorAcceptsPlaceholderHandlesBeforeMetadataResolves() async throws {
    let coordinator = CameraVendorGalleryEntryCoordinator()

    let evidence = try await coordinator.loadEntryEvidence(using: CameraVendorPlaceholderOnlyGalleryService())

    XCTAssertEqual(evidence.items.map(\.handle), [1])
  }

  func testConnectAndTransferReadyPagesDoNotStartGalleryProtocolDirectly() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let connectStart = try XCTUnwrap(source.range(of: "final class NativeConnectViewController")?.lowerBound)
    let transferReadyStart = try XCTUnwrap(source.range(of: "private final class NativeTransferReadyViewController")?.lowerBound)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let connectPage = String(source[connectStart..<transferReadyStart])
    let transferReadyPage = String(source[transferReadyStart..<galleryStart])

    XCTAssertFalse(connectPage.contains(".fetchGallery("))
    XCTAssertFalse(transferReadyPage.contains(".fetchGallery("))
    XCTAssertFalse(source.contains(".fetchGallery("))
    XCTAssertTrue(source.contains("CameraVendorGalleryEntryCoordinator"))
  }

  func testConnectAndTransferReadyPagesUseUnifiedGalleryEntryCoordinator() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let connectStart = try XCTUnwrap(source.range(of: "final class NativeConnectViewController")?.lowerBound)
    let transferReadyStart = try XCTUnwrap(source.range(of: "private final class NativeTransferReadyViewController")?.lowerBound)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let connectPage = String(source[connectStart..<transferReadyStart])
    let transferReadyPage = String(source[transferReadyStart..<galleryStart])

    XCTAssertTrue(connectPage.contains("CameraVendorGalleryEntryCoordinator"))
    XCTAssertTrue(connectPage.contains("galleryEntryCoordinator.loadEntryEvidence("))
    XCTAssertFalse(connectPage.contains("galleryStartupCoordinator.loadGalleryReadyEvidence("))

    XCTAssertTrue(transferReadyPage.contains("CameraVendorGalleryEntryCoordinator"))
    XCTAssertTrue(transferReadyPage.contains("galleryEntryCoordinator.loadEntryEvidence("))
    XCTAssertFalse(transferReadyPage.contains("galleryStartupCoordinator.loadGalleryReadyEvidence("))
  }

  func testGalleryEntryCoordinatorLivesInCameraCoreOrchestrationModule() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let bluetoothServiceSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let coordinatorSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraCore/Orchestration/CameraGalleryEntryCoordinator.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(bluetoothServiceSource.contains("final class CameraVendorGalleryEntryCoordinator"))
    XCTAssertTrue(coordinatorSource.contains("final class CameraVendorGalleryEntryCoordinator"))
  }

  func testGalleryPageDoesNotRestartGalleryStartupProtocolAfterEntry() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])

    XCTAssertFalse(galleryPage.contains("CameraVendorGalleryStartupCoordinator"))
    XCTAssertFalse(galleryPage.contains("loadGalleryReadyEvidence("))
    XCTAssertFalse(galleryPage.contains(".fetchGallery("))
  }

  func testNativeTransferSizeSettingPolicyMapsHomeChipSelection() {
    XCTAssertEqual(
      NativeTransferSizeSettingPolicy.selectedID(preferCompressedDownloads: false),
      NativeTransferSizeSettingPolicy.originalID
    )
    XCTAssertEqual(
      NativeTransferSizeSettingPolicy.selectedID(preferCompressedDownloads: true),
      NativeTransferSizeSettingPolicy.compressedID
    )
    XCTAssertFalse(
      NativeTransferSizeSettingPolicy.preferCompressedDownloads(
        for: NativeTransferSizeSettingPolicy.originalID
      )
    )
    XCTAssertTrue(
      NativeTransferSizeSettingPolicy.preferCompressedDownloads(
        for: NativeTransferSizeSettingPolicy.compressedID
      )
    )
  }

  func testNativeTransferSizeSettingPolicyMapsSwitchState() {
    XCTAssertFalse(NativeTransferSizeSettingPolicy.switchIsOn(preferCompressedDownloads: false))
    XCTAssertTrue(NativeTransferSizeSettingPolicy.switchIsOn(preferCompressedDownloads: true))
    XCTAssertFalse(NativeTransferSizeSettingPolicy.preferCompressedDownloads(forSwitchIsOn: false))
    XCTAssertTrue(NativeTransferSizeSettingPolicy.preferCompressedDownloads(forSwitchIsOn: true))
  }

  func testNativeTransferSizeSettingPolicyUsesCompactSwitchLabels() {
    XCTAssertEqual(NativeTransferSizeSettingPolicy.originalLabelText, "原图")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.compressedLabelText, "压缩")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.originalSymbolName, "photo")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.compressedSymbolName, "bolt.fill")
  }

  func testNativeTransferSizeSettingPolicyUsesCompactSwitchMetrics() {
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchWidth, 104)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchHeight, 40)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchLabelFontSize, 9.5)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchSymbolPointSize, 11)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchImagePlacement, .top)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchImagePadding, 1)
  }

  func testNativeGalleryUsesCurrentBottomDownloadModeForQueuedDownloads() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
      .appendingPathComponent("NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])
    let startDownloadStart = try XCTUnwrap(galleryPage.range(of: "private func startDownload(for handles: [Int])")?.lowerBound)
    let startDownloadEnd = try XCTUnwrap(galleryPage.range(of: "Task { @MainActor in", range: startDownloadStart..<galleryPage.endIndex)?.lowerBound)
    let startDownloadBody = String(galleryPage[startDownloadStart..<startDownloadEnd])

    XCTAssertTrue(startDownloadBody.contains("currentTransferDownloadMode"))
    XCTAssertFalse(startDownloadBody.contains("summary.activeTransferDownloadMode"))
  }

  func testGalleryReloadPolicyDoesNotRetryFromGalleryPageAfterFailure() {
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.3.28",
        baselineWifiIP: "192.168.3.28"
      )
    )
  }

  func testGalleryReloadPolicyDoesNotRetryWhileAlreadyLoadingOrWhenGalleryExists() {
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: true,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28"
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 3,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28"
      )
    )
  }

  func testGalleryLoadPolicyBlocksConcurrentLoads() {
    XCTAssertTrue(CameraVendorGalleryLoadPolicy.shouldStartLoad(isLoading: false))
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldStartLoad(isLoading: true))
  }

  func testGalleryLoadPolicyRequiresVerifiedConnectionHandoffForManualReload() {
    XCTAssertTrue(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.0.122",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.0.122",
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: nil,
        hasVerifiedConnectionHandoff: true
      )
    )
  }

  func testGalleryLoadPolicyDoesNotStartFromGalleryIpAlone() {
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldLoadAutomaticallyOnEntry)
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldRetryAutomaticallyWhenAppBecomesActive)
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldLoadOnEntry(hasVerifiedConnectionHandoff: true))
  }

  func testGalleryLoadPolicyNeverAutoLoadsFromGalleryPageLifecycle() {
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.3.28",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 2,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
  }

  func testGalleryPtpReadinessWaitsForCameraIPv4AfterAutomaticWifiJoin() {
    XCTAssertEqual(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds, 8)
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: nil
      )
    )
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: "192.168.3.28"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: "192.168.0.28"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        currentWifiIP: nil
      )
    )
  }

  func testGalleryMainLoadLifecycleTerminatesCameraCommunicationWhenLeavingGallery() {
    XCTAssertTrue(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: true,
        hasActiveGalleryLoadTask: true
      )
    )
    XCTAssertFalse(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: false,
        hasActiveGalleryLoadTask: true
      )
    )
    XCTAssertFalse(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: true,
        hasActiveGalleryLoadTask: false
      )
    )
  }

  func testGalleryExitPolicyRequiresConfirmationBeforeTerminatingCameraCommunication() {
    XCTAssertTrue(
      NativeGalleryExitPolicy.shouldConfirmBeforeLeaving(
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryExitPolicy.shouldConfirmBeforeLeaving(
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertFalse(
      NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
        hasActiveCameraCommunication: true,
        userConfirmedExit: false
      )
    )
    XCTAssertTrue(
      NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
        hasActiveCameraCommunication: true,
        userConfirmedExit: true
      )
    )
  }

  func testGalleryBackgroundRuntimePolicyProtectsDownloadsWithoutKeepingIdleGalleryAlive() {
    XCTAssertEqual(NativeGalleryBackgroundRuntimePolicy.finiteTaskName, "CamTransferCameraTransfer")
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldDisableIdleTimer(
        isLoading: false,
        isDownloading: true,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldDisableIdleTimer(
        isLoading: true,
        isDownloading: false,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRequestFiniteBackgroundTask(
        isLoading: false,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldRequestFiniteBackgroundTask(
        isLoading: false,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRequestFiniteBackgroundTask(
        isLoading: false,
        isDownloading: false,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertEqual(
      NativeGalleryBackgroundRuntimePolicy.formattedBackgroundTimeRemaining(27.8),
      "27s"
    )
    XCTAssertEqual(
      NativeGalleryBackgroundRuntimePolicy.formattedBackgroundTimeRemaining(.greatestFiniteMagnitude),
      "foreground"
    )
  }

  func testGalleryBackgroundRuntimePolicyEndsTaskAfterDownloadWorkCompletes() {
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldEndFiniteBackgroundTaskWhenWorkCompletes(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldEndFiniteBackgroundTaskWhenWorkCompletes(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldEndFiniteBackgroundTaskWhenWorkCompletes(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
  }

  func testGalleryBackgroundRuntimePolicyDoesNotRunIndependentPtpKeepAlive() {
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunPtpKeepAlive(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunPtpKeepAlive(
        applicationState: .active,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunPtpKeepAlive(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunPtpKeepAlive(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertEqual(
      NativeGalleryBackgroundRuntimePolicy.ptpKeepAliveIntervalSeconds,
      CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveIntervalSeconds
    )
  }

  func testGalleryBackgroundRuntimePolicyRunsBleKeepAliveOnlyForBackgroundDownload() {
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldRunBleKeepAlive(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunBleKeepAlive(
        applicationState: .active,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunBleKeepAlive(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRunBleKeepAlive(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertEqual(NativeGalleryBackgroundRuntimePolicy.bleKeepAliveIntervalSeconds, 8)
  }

  func testGalleryBackgroundRuntimePolicyKeepsExistingDownloadBackgroundTaskOnBackgroundEntry() {
    XCTAssertEqual(
      NativeGalleryBackgroundRuntimePolicy.existingFiniteTaskMessage(reason: "download"),
      "[后台] 有限后台任务已在运行，继续覆盖 reason=download"
    )
  }

  func testGalleryBackgroundRuntimePolicyRenewsExpiredTaskOnlyForBackgroundDownload() {
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRenewFiniteBackgroundTaskOnExpiration(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldRenewFiniteBackgroundTaskOnExpiration(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRenewFiniteBackgroundTaskOnExpiration(
        applicationState: .background,
        isDownloading: true,
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRenewFiniteBackgroundTaskOnExpiration(
        applicationState: .active,
        isDownloading: true,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldRenewFiniteBackgroundTaskOnExpiration(
        applicationState: .background,
        isDownloading: false,
        hasActiveCameraCommunication: false
      )
    )
  }

  func testGalleryBackgroundExpirationRenewsFiniteTaskWithoutStartingPtpKeepAlive() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let expirationStart = try XCTUnwrap(source.range(of: "private func finiteBackgroundTaskExpired()")?.lowerBound)
    let nextFunctionStart = try XCTUnwrap(
      source.range(of: "private func protectGalleryExitNavigation()", range: expirationStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[expirationStart..<nextFunctionStart])

    XCTAssertTrue(body.contains("shouldRenewFiniteBackgroundTaskOnExpiration"))
    XCTAssertTrue(body.contains("beginFiniteBackgroundTask(reason: \"renew-\\(reason)\""))
    XCTAssertFalse(body.contains("beginBackgroundKeepAlive(reason: \"renew-\\(reason)\""))
    XCTAssertFalse(body.contains("endBackgroundKeepAlive(reason: \"expired-\\(reason)\""))
  }

  func testGalleryUIDiagnosticsUseSingleFastDeviceLogWriter() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let appendStart = try XCTUnwrap(source.range(of: "private func appendDiagnostic(")?.lowerBound)
    let timerStart = try XCTUnwrap(
      source.range(of: "private func startNetworkStatusTimer()", range: appendStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[appendStart..<timerStart])

    XCTAssertTrue(body.contains("CameraVendorFileLogger.log(\"UI: \\(message)\""))
    XCTAssertFalse(body.contains("CameraVendorGalleryDiagnostics.log(\"UI: \\(message)\""))
    XCTAssertTrue(body.contains("NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(message)"))
  }

  func testNativeGalleryDownloadDiagnosticLogPolicyKeepsDownloadPerformanceSummaries() {
    XCTAssertTrue(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(
        "[主通道] 下载传输完成 handle=1844 source=data-fast-path bytes=16799232 transferMs=3200 speedMBps=5.0，加入保存队列"
      )
    )
    XCTAssertTrue(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(
        "[保存] 完成 handle=1844 source=data-fast-path transferMs=3200 saveQueueDelayMs=0 saveMs=900 totalMs=4100 speedMBps=5.0"
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile("下载进行中，暂停缩略图加载 handle=1844")
    )
  }

  func testPtpSocketReadExactlyReadsDirectlyIntoData() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func readExactly(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func close()", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("var data = Data(count: length)"))
    XCTAssertFalse(body.contains("var buffer = [UInt8](repeating: 0, count: length)"))
    XCTAssertFalse(body.contains("return Data(buffer)"))
  }

  func testIOSProjectDeclaresLiveActivitySupportForOfficialStyleBackgroundSession() throws {
    let iosDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let projectYAML = try String(
      contentsOf: iosDirectory.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let infoPlist = NSDictionary(
      contentsOf: iosDirectory.appendingPathComponent("Runner/Info.plist")
    )

    XCTAssertEqual(infoPlist?["NSSupportsLiveActivities"] as? Bool, true)
    XCTAssertTrue(projectYAML.contains("CameraSessionActivityWidget:"))
    XCTAssertTrue(projectYAML.contains("type: app-extension"))
    XCTAssertTrue(projectYAML.contains("embed: true"))
  }

  func testCameraSessionLiveActivityDoesNotStartGalleryProtocol() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionLiveActivityController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("Activity<CameraSessionActivityAttributes>"))
    XCTAssertTrue(source.contains("Activity.request"))
    XCTAssertTrue(source.contains(".update("))
    XCTAssertTrue(source.contains(".end("))
    XCTAssertFalse(source.contains("loadGallery("))
    XCTAssertFalse(source.contains("startPhotoTransfer("))
    XCTAssertFalse(source.contains("beginUserInitiatedGalleryFlow("))
  }

  func testIOSRuntimeGalleryEntryUsesOfficialMainlineAdapterInsteadOfOldDirectConnect() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let beginStart = try XCTUnwrap(source.range(of: "func beginUserInitiatedGalleryFlow(peripheralID: UUID)")?.lowerBound)
    let approveStart = try XCTUnwrap(
      source.range(of: "func approveNextRememberedCameraConnection()", range: beginStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[beginStart..<approveStart])

    XCTAssertTrue(body.contains("startOfficialGalleryMainline(peripheralID: peripheralID)"))
    XCTAssertFalse(body.contains("connectPairedCamera(peripheralID: peripheralID)"))
  }

  func testLegacyPtpConfirmGalleryModeDoesNotLoadGalleryObjects() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let confirmStart = try XCTUnwrap(
      source.range(of: "private func confirmCameraVendorLegacyReferenceAppGalleryMode()")?.lowerBound
    )
    let loadStart = try XCTUnwrap(
      source.range(of: "private func prepareCameraVendorLegacyGalleryLoad()", range: confirmStart..<source.endIndex)?.lowerBound
    )
    let confirmBody = String(source[confirmStart..<loadStart])

    XCTAssertTrue(confirmBody.contains("referenceAppRemoteImageViewerClientState"))
    XCTAssertTrue(confirmBody.contains("referenceAppImageHost"))
    XCTAssertTrue(confirmBody.contains("requestCameraVendorCardSlotStatus()"))
    XCTAssertFalse(confirmBody.contains("requestCameraVendorSearchModeDescAll"))
    XCTAssertFalse(confirmBody.contains("requestCameraVendorSpecifiedObject"))
    XCTAssertFalse(confirmBody.contains("primeCameraVendorCurrent"))
  }

  func testLegacyPtpLoadGalleryOwnsObjectSnapshotReads() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let loadStart = try XCTUnwrap(
      source.range(of: "private func prepareCameraVendorLegacyGalleryLoad()")?.lowerBound
    )
    let reservedStart = try XCTUnwrap(
      source.range(of: "private func performCameraVendorReservedReceiveDiagnosticHandshake()", range: loadStart..<source.endIndex)?.lowerBound
    )
    let loadBody = String(source[loadStart..<reservedStart])

    XCTAssertTrue(loadBody.contains("requestCameraVendorSearchModeDescAll"))
    XCTAssertTrue(loadBody.contains("requestCameraVendorFormatSpecificSpecifiedObjectSnapshotsForInitialList"))
    XCTAssertTrue(loadBody.contains("requestCameraVendorSpecifiedObjectSnapshot"))
  }

  func testRunnerAppInstallsGlobalLifecycleDiagnostics() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("RunnerApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("AppLifecycleDiagnostics.install()"))
    XCTAssertTrue(source.contains("UIApplication.didEnterBackgroundNotification"))
    XCTAssertTrue(source.contains("UIApplication.willEnterForegroundNotification"))
    XCTAssertTrue(source.contains("APP_LIFECYCLE"))
  }

  func testRememberedGalleryFlowWritesHardEvidenceBeforeStartingProtocol() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let flowStart = try XCTUnwrap(source.range(of: "private func connectRememberedCamera")?.lowerBound)
    let overlayStart = try XCTUnwrap(
      source.range(of: "private func showConnectingOverlay", range: flowStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[flowStart..<overlayStart])

    XCTAssertTrue(body.contains("REMEMBERED_GALLERY_FLOW_START"))
    XCTAssertTrue(body.contains("BEGIN_USER_GALLERY_FLOW_RESULT"))
    XCTAssertTrue(body.contains("BEGIN_USER_GALLERY_FLOW_REJECTED"))

    let cleanupGuard = try XCTUnwrap(body.range(of: "service.publishSystemBluetoothCleanupBlockIfNeeded()")?.lowerBound)
    let overlayCall = try XCTUnwrap(body.range(of: "showConnectingOverlay")?.lowerBound)
    let beginFlow = try XCTUnwrap(body.range(of: "service.beginUserInitiatedGalleryFlow")?.lowerBound)
    XCTAssertLessThan(cleanupGuard, overlayCall)
    XCTAssertLessThan(cleanupGuard, beginFlow)
  }

  func testFreshPairingHardBluetoothCleanupBlockDoesNotOfferContinuePairing() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let promptStart = try XCTUnwrap(source.range(of: "private func presentFreshPairingBluetoothCleanupPromptIfNeeded")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "@objc private func wiredImportTapped", range: promptStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[promptStart..<nextFunction])

    let hardBlockGuard = try XCTUnwrap(body.range(of: "service.requiresSystemBluetoothPairingCleanup")?.lowerBound)
    let continueAction = try XCTUnwrap(body.range(of: "NativeFreshPairingSystemBluetoothCleanupPrompt.continueTitle")?.lowerBound)
    let acknowledgeAction = try XCTUnwrap(body.range(of: "acknowledgeSystemBluetoothPairingCleanupForFreshPairing")?.lowerBound)
    XCTAssertLessThan(hardBlockGuard, continueAction)
    XCTAssertLessThan(hardBlockGuard, acknowledgeAction)
  }

  func testGalleryBackgroundRuntimePolicyPausesThumbnailRequestsWhileBackgrounded() {
    XCTAssertTrue(
      NativeGalleryBackgroundRuntimePolicy.shouldPauseThumbnailRequests(
        applicationState: .background,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldPauseThumbnailRequests(
        applicationState: .active,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryBackgroundRuntimePolicy.shouldPauseThumbnailRequests(
        applicationState: .background,
        hasActiveCameraCommunication: false
      )
    )
  }

  func testGalleryAppBackgroundPausesThumbnailsAndForegroundOnlyResumesThumbnails() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])
    let activeStart = try XCTUnwrap(galleryPage.range(of: "@objc private func appDidBecomeActive()")?.lowerBound)
    let backgroundStart = try XCTUnwrap(galleryPage.range(of: "@objc private func appDidEnterBackground()")?.lowerBound)
    let selectAllStart = try XCTUnwrap(galleryPage.range(of: "@objc private func selectAllTapped()", range: backgroundStart..<galleryPage.endIndex)?.lowerBound)
    let activeBody = String(galleryPage[activeStart..<backgroundStart])
    let backgroundBody = String(galleryPage[backgroundStart..<selectAllStart])

    XCTAssertTrue(backgroundBody.contains("pauseVisibleThumbnailLoadingForBackground()"))
    XCTAssertTrue(backgroundBody.contains("GALLERY_APP_DID_ENTER_BACKGROUND"))
    XCTAssertTrue(backgroundBody.contains("locationKeepAlive.stop(reason: \"background-gallery-paused\")"))
    XCTAssertTrue(backgroundBody.contains("logExistingFiniteBackgroundTaskIfNeeded(reason:"))
    XCTAssertTrue(backgroundBody.contains("startGalleryLocationKeepAlive(reason:"))
    XCTAssertTrue(backgroundBody.contains("beginBackgroundBleKeepAlive(reason:"))
    XCTAssertFalse(backgroundBody.contains("beginBackgroundKeepAlive(reason:"))
    XCTAssertTrue(activeBody.contains("GALLERY_APP_DID_BECOME_ACTIVE"))
    XCTAssertTrue(activeBody.contains("endBackgroundBleKeepAlive(reason:"))
    XCTAssertTrue(activeBody.contains("endBackgroundKeepAlive(reason:"))
    XCTAssertTrue(activeBody.contains("scheduleVisibleThumbnailRefresh(after:"))
    XCTAssertFalse(activeBody.contains("loadGallery("))
    XCTAssertFalse(backgroundBody.contains("loadGallery("))
  }

  func testBackgroundReadImageInfoKeepAliveUsesOfficialCurrentImageInfoHandle() throws {
    XCTAssertEqual(
      CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveIntervalSeconds,
      6.0
    )
    XCTAssertEqual(
      CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle,
      CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    )
    XCTAssertFalse(CameraVendorBackgroundMetadataRefreshPolicy.shouldCacheReadImageInfoKeepAliveResult())

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let serviceStart = try XCTUnwrap(source.range(of: "final class CameraVendorRealtimeGalleryService")?.lowerBound)
    let methodStart = try XCTUnwrap(
      source.range(of: "func performBackgroundKeepAlive() async throws", range: serviceStart..<source.endIndex)?.lowerBound
    )
    let nextMethodStart = try XCTUnwrap(
      source.range(of: "func downloadOriginal(for handle:", range: methodStart..<source.endIndex)?.lowerBound
    )
    let methodBody = String(source[methodStart..<nextMethodStart])
    XCTAssertTrue(methodBody.contains("cameraVendorLatestObjectInfo("))
    XCTAssertTrue(methodBody.contains("readImageInfoKeepAliveHandle"))
    XCTAssertFalse(methodBody.contains("nextKeepAliveHandle"))
    XCTAssertFalse(methodBody.contains("session.objectInfo("))
    XCTAssertFalse(methodBody.contains("objectInfoCache.keys"))
  }

  func testOfficialGalleryEntryPassesBluetoothServiceForBackgroundKeepAlive() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let connectStart = try XCTUnwrap(source.range(of: "final class NativeConnectViewController")?.lowerBound)
    let transferReadyStart = try XCTUnwrap(source.range(of: "private final class NativeTransferReadyViewController")?.lowerBound)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let connectPage = String(source[connectStart..<transferReadyStart])
    let transferReadyPage = String(source[transferReadyStart..<galleryStart])

    XCTAssertTrue(connectPage.contains("bluetoothKeepAliveService: self.service"))
    XCTAssertTrue(transferReadyPage.contains("bluetoothKeepAliveService: self.service"))
  }

  func testBleBackgroundKeepAliveIsReadOnlyAndDoesNotWriteCameraState() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(source.range(of: "func performBackgroundBleKeepAlive(reason: String)")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "enum CameraVendorAppVariant", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("peripheral.readValue(for: characteristic)"))
    XCTAssertFalse(body.contains("writeValue"))
  }

  func testBleBackgroundKeepAlivePrefersTransferStateBeforeApStateAndDeviceInfo() {
    let candidates = CameraVendorBleBackgroundKeepAlivePolicy.preferredReadableCharacteristicUUIDStrings
      .map { $0.uppercased() }
    let apState = CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString.uppercased()
    let transferState = CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString.uppercased()
    let imageTransferSetting = CameraVendorReferenceAppTransferActivationPlan
      .imageTransferSettingCharacteristicUUIDString
      .uppercased()
    let serialNumber = "00002A25-0000-1000-8000-00805F9B34FB"
    let officialSettingProbeCandidates = [
      "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4",
      "BD45F887-A6BE-4CB7-8565-390DF38BF5BF",
      "AAB609C4-94DD-4D89-BC60-665D5090B828",
      "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B",
      "75823784-FBB7-4B71-ABAE-CD9A34072E3C",
    ]

    XCTAssertEqual(candidates.prefix(3), [transferState, imageTransferSetting, CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString.uppercased()])
    XCTAssertEqual(CameraVendorBleBackgroundKeepAlivePolicy.readSpacingSeconds, 0.08)
    for uuid in officialSettingProbeCandidates {
      XCTAssertTrue(candidates.contains(uuid))
      XCTAssertLessThan(
        try XCTUnwrap(candidates.firstIndex(of: uuid)),
        try XCTUnwrap(candidates.firstIndex(of: apState))
      )
    }
    XCTAssertLessThan(
      try XCTUnwrap(candidates.firstIndex(of: transferState)),
      try XCTUnwrap(candidates.firstIndex(of: apState))
    )
    XCTAssertLessThan(
      try XCTUnwrap(candidates.firstIndex(of: apState)),
      try XCTUnwrap(candidates.firstIndex(of: serialNumber))
    )
  }

  func testGalleryLocationKeepAliveRequestsAlwaysAuthorizationForBackgroundSession() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private final class NativeGalleryLocationKeepAlive")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "enum NativeGalleryMainLoadLifecyclePolicy", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("manager.allowsBackgroundLocationUpdates = true"))
    XCTAssertTrue(body.contains("manager.requestAlwaysAuthorization()"))
    XCTAssertFalse(body.contains("requestWhenInUseAuthorization()"))
  }

  func testGalleryCommunicationTerminateLogsExplicitReasonForDeviceTriage() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let gallerySource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let pageSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(gallerySource.contains("func terminateCameraCommunication(reason: String)"))
    XCTAssertTrue(gallerySource.contains("GALLERY_COMMUNICATION_TERMINATE_REQUESTED reason=\\(reason)"))
    XCTAssertTrue(pageSource.contains("terminateCameraCommunication(reason: \"user-confirmed-gallery-exit\")"))
    XCTAssertTrue(pageSource.contains("terminateCameraCommunication(reason: reason)"))
  }

  func testGalleryReadyEntryEnablesIdleTimerProtectionBeforeAutoLock() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "private final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])
    let initialItemsStart = try XCTUnwrap(galleryPage.range(of: "if let initialItems {")?.lowerBound)
    let missingEvidenceStart = try XCTUnwrap(galleryPage.range(of: "} else {", range: initialItemsStart..<galleryPage.endIndex)?.lowerBound)
    let initialItemsBranch = String(galleryPage[initialItemsStart..<missingEvidenceStart])
    let viewDidAppearStart = try XCTUnwrap(galleryPage.range(of: "override func viewDidAppear(_ animated: Bool)")?.lowerBound)
    let viewWillDisappearStart = try XCTUnwrap(galleryPage.range(of: "override func viewWillDisappear(_ animated: Bool)")?.lowerBound)
    let viewDidAppearBody = String(galleryPage[viewDidAppearStart..<viewWillDisappearStart])

    XCTAssertTrue(initialItemsBranch.contains("updateIdleTimerProtection()"))
    XCTAssertTrue(viewDidAppearBody.contains("updateIdleTimerProtection()"))
  }

  func testNativeGalleryExitCopyMatchesAndroidDisconnectDialog() {
    XCTAssertEqual(NativeGalleryExitCopy.title, "确认断开相机连接？")
    XCTAssertEqual(NativeGalleryExitCopy.confirmTitle, "确认断开")
    XCTAssertEqual(NativeGalleryExitCopy.cancelTitle, "继续停留")
    XCTAssertTrue(NativeGalleryExitCopy.message.contains("保持在照片筛选页面"))
  }

  func testTransferActivationCompletionPolicyProceedsAfterObservedChange() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: true,
        hasMoreStrategies: false
      )
    )
  }

  func testOfficialImportImageReleasesBluetoothBeforeWifiPtpHandoffAfterApReady() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldWaitForBluetoothDisconnect(
        afterObservedChangeFor: .officialImportImage
      )
    )
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(
        for: .officialImportImage
      )
    )
  }

  func testOfficialImportImageWaitsForApReadyAfterActivationWrites() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFastHandoffAfterCommandWrites(
        for: .officialImportImage
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFastHandoffAfterCommandWrites(
        for: .compatibleRemoteImageView
      )
    )
  }

  func testDebugLaunchPolicyAutoConnectsRememberedCameraOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldAutoConnectRememberedCamera(
        arguments: ["Runner", "--camtransfer-autoconnect-remembered"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldAutoConnectRememberedCamera(
        arguments: ["Runner"]
      )
    )
  }

  func testDebugLaunchPolicyShowsStubGalleryOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldShowStubGallery(
        arguments: ["Runner", "--camtransfer-show-stub-gallery"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldShowStubGallery(
        arguments: ["Runner"]
      )
    )
  }

  func testDebugLaunchPolicyShowsStubDownloadsOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldShowStubDownloads(
        arguments: ["Runner", "--camtransfer-show-stub-downloads"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldShowStubDownloads(
        arguments: ["Runner"]
      )
    )
  }

  func testPassiveConnectionResetSkipsActiveTransferHandoff() {
    XCTAssertTrue(
      CameraVendorConnectionResetPolicy.shouldSkipPassiveResetDuringTransferHandoff(
        force: false,
        didCompleteHandshakeCallback: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        isRunningTransferActivation: false,
        awaitingBluetoothDisconnectForWifiHandoff: false,
        awaitingTransferActivationStateChange: false
      )
    )
    XCTAssertFalse(
      CameraVendorConnectionResetPolicy.shouldSkipPassiveResetDuringTransferHandoff(
        force: true,
        didCompleteHandshakeCallback: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        isRunningTransferActivation: false,
        awaitingBluetoothDisconnectForWifiHandoff: false,
        awaitingTransferActivationStateChange: false
      )
    )
  }

  func testHomeViewWillAppearDoesNotResetWhileRememberedGalleryFlowIsActive() {
    XCTAssertFalse(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: true,
        isEnteringGalleryFromRememberedCamera: true
      )
    )
    XCTAssertTrue(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: true,
        isEnteringGalleryFromRememberedCamera: false
      )
    )
    XCTAssertFalse(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: false,
        isEnteringGalleryFromRememberedCamera: false
      )
    )
  }

  func testSpecifiedObjectEmptySnapshotRecoveryRetriesOnlyEmptyFirstSnapshot() {
    XCTAssertTrue(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: 0,
        isRequiredPrimaryList: true
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: 0,
        isRequiredPrimaryList: false
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.maxRetryCount,
        isRequiredPrimaryList: true
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 2,
        handles: [1, 2],
        retryCount: 0,
        isRequiredPrimaryList: true
      )
    )
  }

  func testHandshakeCompletionKeepsBluetoothWhenTransferActivationObservedChange() {
    XCTAssertFalse(
      CameraVendorHandshakeCompletionPolicy.shouldDisconnectBluetoothBeforeGallery(
        transferActivationObservedChange: true
      )
    )
  }

  func testTransferActivationCompletionPolicyWaitsWhenNoStrategyWorked() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: false,
        hasMoreStrategies: false
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotProceedJustBecauseFallbackStrategiesRemain() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: false,
        hasMoreStrategies: true
      )
    )
  }

  func testTransferActivationCompletionPolicyTriesFallbackWhenCurrentStrategyIsNotGalleryReady() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldTryNextStrategy(
        observedChange: false,
        hasMoreStrategies: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldTryNextStrategy(
        observedChange: true,
        hasMoreStrategies: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotAttemptWifiHandoffWithoutApReady() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: false,
        observedWifiLaunch: false
      )
    )
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: true,
        observedWifiLaunch: false
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: false,
        observedWifiLaunch: true
      )
    )
  }

  func testTransferActivationCompletionPolicyBlocksHandshakeAfterFailedActivationFeature() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: false,
        hadActivationFeature: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotAllowHandshakeAfterWifiLaunchWithoutReadyChange() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: true,
        hadActivationFeature: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotFallbackToWifiLaunchWithoutReadyChange() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFallbackToWifiLaunchAfterCameraResponse(
        observedChange: false,
        observedWifiLaunch: true
      )
    )
  }

  func testTransferActivationCompletionPolicyBlocksHandshakeWithoutActivationFeature() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: false,
        hadActivationFeature: false
      )
    )
  }

  func testHandshakeDoesNotCompleteAfterEmptyActivationPlan() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let emptyPlanStart = try XCTUnwrap(source.range(of: "ACTIVATION_PLAN empty")?.lowerBound)
    let guardStart = try XCTUnwrap(
      source.range(
        of: "guard CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion",
        range: emptyPlanStart..<source.endIndex
      )?.lowerBound
    )
    let emptyPlanRegion = String(source[emptyPlanStart..<guardStart])

    XCTAssertFalse(emptyPlanRegion.contains("直接进入图库"))
    XCTAssertFalse(emptyPlanRegion.contains("completeHandshake("))
  }

  func testGalleryFetchConcurrencyPolicyRejectsDuplicateFetches() {
    XCTAssertTrue(CameraVendorGalleryFetchConcurrencyPolicy.shouldRejectConcurrentFetch)
    XCTAssertEqual(CameraVendorGalleryFetchConcurrencyPolicy.concurrentFetchErrorCode, 7)
  }

  func testGalleryDownloadPolicyBlocksVideoUntilStreamingIsStable() {
    let video = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.MOV",
      formatLabel: "Video",
      captureDate: "",
      byteSizeText: "1 GB"
    )
    let jpeg = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: "1 MB"
    )
    let raw = CameraVendorGalleryItem(
      handle: 3,
      filename: "DSCF0003.RAF",
      formatLabel: "RAW",
      captureDate: "",
      byteSizeText: "83 MB"
    )

    XCTAssertFalse(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(video))
    XCTAssertTrue(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(jpeg))
    XCTAssertTrue(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(raw))
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: video), .video)
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: jpeg), .photo)
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: raw), .raw)
  }

  func testPhotoDownloadsUseProductionFilePathForOriginalDownloadPipeline() {
    XCTAssertFalse(CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadsFromTemporaryFile)
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: nil
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: 30 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: 64 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .video,
        compressedSize: 30 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .raw,
        compressedSize: 83 * 1_024 * 1_024
      )
    )
  }

  func testTemporaryDownloadABDiagnosticsAreRemovedFromProductionPath() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("TEMP_DOWNLOAD_AB_20260705"))
    XCTAssertFalse(source.contains("CameraVendorTemporaryDownloadDiagnosticsPolicy"))
    XCTAssertFalse(source.contains("fileDownloadReadSizeOverrideBytes"))
    XCTAssertFalse(source.contains("effectiveFileDownloadReadSize"))
    XCTAssertFalse(source.contains("socketPacket transport="))
  }

  func testDownloadExecutionRoutePolicyKeepsPathChoiceOutOfGalleryUI() {
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .photo,
        compressedSize: 30 * 1_024 * 1_024
      ),
      .file
    )
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .raw,
        compressedSize: 83 * 1_024 * 1_024
      ),
      .file
    )
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .video,
        compressedSize: 30 * 1_024 * 1_024
      ),
      .file
    )
  }

  func testPhotoLibrarySavePolicyNormalizesHeifDownloadsBeforeSaving() {
    XCTAssertTrue(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIC",
        mediaType: .photo
      )
    )
    XCTAssertTrue(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIF",
        mediaType: .photo
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.JPG",
        mediaType: .photo
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIC",
        mediaType: .video
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.RAF",
        mediaType: .raw
      )
    )
  }

  func testTransferActivationWaitsAfterDisablingResize() {
    XCTAssertEqual(CameraVendorTransferActivationResizePolicy.resizeDisabledPayload, Data([0x00]))
    XCTAssertEqual(CameraVendorTransferActivationResizePolicy.postWriteDelaySeconds, 0.5)
  }

  func testTransferActivationDisconnectPolicyAcceptsPromptDisconnectAfterWaitingForCameraConfirmation() {
    XCTAssertTrue(
      CameraVendorTransferActivationDisconnectPolicy.shouldTreatDisconnectAsWifiHandoff(
        elapsedSinceWaitingForConfirmation: 4
      )
    )
  }

  func testTransferActivationDisconnectPolicyRejectsLateDisconnectAfterWaitingForCameraConfirmation() {
    XCTAssertFalse(
      CameraVendorTransferActivationDisconnectPolicy.shouldTreatDisconnectAsWifiHandoff(
        elapsedSinceWaitingForConfirmation: 35
      )
    )
  }

  func testSecureHandshakeRecoveryRetriesWhenDisconnectHappensDuringIdentificationWrite() {
    XCTAssertTrue(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .awaitingIdentificationNumberWrite,
        retryCount: 0
      )
    )
  }

  func testSecureHandshakeRecoveryStopsRetryingAfterFirstReconnect() {
    XCTAssertFalse(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .awaitingIdentificationNumberWrite,
        retryCount: 1
      )
    )

    XCTAssertFalse(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .completed,
        retryCount: 0
      )
    )
  }

  func testConnectionSummaryKeepsHiddenPreferredWifiAsSingleOfficialCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true,
        bssid: "AA-BB-CC-DD-EE-FF"
      )
    )

    let configurations = summary.wifiConfigurations
    XCTAssertEqual(configurations.count, 1)
    XCTAssertEqual(configurations[0].ssid, "CAMERA-DEVICE-A-003B")
    XCTAssertTrue(configurations[0].isHidden)
    XCTAssertEqual(configurations[0].bssid, "aa:bb:cc:dd:ee:ff")
  }

  func testRunnerInfoPlistIncludesLocationUsageDescription() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let plistURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))

    XCTAssertEqual(
      plist["NSLocationWhenInUseUsageDescription"] as? String,
      "CamTransfer 需要定位权限来确认当前连接的 Wi-Fi 网络名称，以便自动切换到相机热点"
    )
    XCTAssertEqual(
      plist["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String,
      "CamTransfer 需要在相机相册会话期间继续确认相机 Wi-Fi 状态，以便锁屏或切到后台时保持相机传输连接"
    )
    XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
    let appTransportSecurity = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertEqual(appTransportSecurity["NSAllowsLocalNetworking"] as? Bool, true)
  }

  func testRunnerInfoPlistDeclaresBackgroundModesForCameraKeepAlive() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let plistURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
    let backgroundModes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])

    XCTAssertTrue(backgroundModes.contains("bluetooth-central"))
    XCTAssertTrue(backgroundModes.contains("location"))
  }

  func testRunnerTargetSignsWithWifiEntitlements() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let iosDirectory = testsDirectory.deletingLastPathComponent()
    let entitlementsURL = iosDirectory.appendingPathComponent("Runner/Runner.entitlements")
    let entitlements = try XCTUnwrap(NSDictionary(contentsOf: entitlementsURL))

    XCTAssertEqual(entitlements["com.apple.developer.networking.HotspotConfiguration"] as? Bool, true)
    XCTAssertEqual(entitlements["com.apple.developer.networking.wifi-info"] as? Bool, true)

    let projectURL = iosDirectory.appendingPathComponent("Runner.xcodeproj/project.pbxproj")
    let project = try String(contentsOf: projectURL, encoding: .utf8)
    let expectedSetting = "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;"

    XCTAssertEqual(project.components(separatedBy: expectedSetting).count - 1, 2)
    XCTAssertTrue(project.contains("com.apple.AccessWiFi"))
    XCTAssertTrue(project.contains("com.apple.HotspotConfiguration"))
  }

  func testManualWifiJoinInstructionsIncludeHiddenNetworkHint() {
    let instructions = CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(
      for: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "abc12345",
        isHidden: true
      )
    )

    XCTAssertEqual(
      instructions,
      [
        "自动连接失败，请到系统设置手动加入相机 Wi-Fi。",
        "SSID: CAMERA-DEVICE-A-003B",
        "密码: abc12345",
        "这是隐藏网络；如果列表里看不到，请在 Wi‑Fi 的“其他...”里手动输入。",
        "连上后回到 CamTransfer，点“重新加载”。",
      ]
    )
  }

  func testGallerySelectionToggleAndSelectAllFlow() {
    let items = [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 2,
        filename: "B.RAF",
        formatLabel: "RAW",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "20 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.toggleSelection(handle: 1)
    XCTAssertEqual(state.selectedHandles, [1])

    state.selectAll()
    XCTAssertEqual(state.selectedHandles, [1, 2])

    state.clearSelection()
    XCTAssertTrue(state.selectedHandles.isEmpty)
  }

  func testNativeGalleryDragSelectionPolicySelectsUnselectedHandles() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [1, 2, 3, 9])
  }

  func testNativeGalleryDragSelectionPolicyKeepsModeAcrossAlreadySelectedHandles() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [2, 9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [1, 2, 3, 9])
  }

  func testNativeGalleryDragSelectionPolicyDeselectsWhenStartingOnSelectedHandle() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [1, 2, 3, 9])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [1, 2, 3, 9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [9])
  }

  func testNativeGalleryDragSelectionPolicyUsesAndroidHorizontalTouchSlop() {
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 8,
        deltaY: 0,
        touchSlop: 10
      )
    )
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 12,
        deltaY: 10,
        touchSlop: 10
      )
    )
    XCTAssertTrue(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 24,
        deltaY: 6,
        touchSlop: 10
      )
    )
  }

  func testNativeGalleryDragSelectionPolicyCommitsOnlyAfterMovingToAnotherSelectableHandle() {
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 2,
        canSelectEndHandle: true
      )
    )
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 3,
        canSelectEndHandle: false
      )
    )
    XCTAssertTrue(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 3,
        canSelectEndHandle: true
      )
    )
  }

  func testNativeGalleryDragSelectionPolicySelectsContinuousRangeLikeAndroid() {
    let selected = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
      selectedHandles: [9],
      orderedHandles: [1, 2, 3, 4, 5, 6],
      startHandle: 2,
      endHandle: 5,
      selectableHandles: [1, 2, 3, 5, 6],
      mode: .selecting
    )

    XCTAssertEqual(selected, [2, 3, 5, 9])
  }

  func testNativeGalleryDragSelectionPolicyDeselectsContinuousRangeLikeAndroid() {
    let selected = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
      selectedHandles: [1, 2, 3, 4, 5, 9],
      orderedHandles: [1, 2, 3, 4, 5, 6],
      startHandle: 5,
      endHandle: 2,
      selectableHandles: [1, 2, 3, 5, 6],
      mode: .deselecting
    )

    XCTAssertEqual(selected, [1, 4, 9])
  }

  func testNativeGalleryUIInvalidationPolicyRefreshesOnlyChangedSelectionHandles() {
    XCTAssertEqual(
      NativeGalleryUIInvalidationPolicy.changedHandles(before: [1, 2, 9], after: [2, 3, 9]),
      [1, 3]
    )
  }

  func testNativeGallerySelectionRefreshPolicyUsesSelectionOnlyCellUpdates() {
    XCTAssertFalse(NativeGallerySelectionRefreshPolicy.shouldReconfigureImageDuringSelectionChange)
    XCTAssertTrue(NativeGallerySelectionRefreshPolicy.shouldPauseThumbnailLoadingDuringSelectionGesture)
  }

  func testNativeGalleryInteractionPriorityPolicyDoesNotWaitForThumbnailDrainBeforeBack() {
    XCTAssertTrue(NativeGalleryInteractionPriorityPolicy.shouldCancelThumbnailQueueBeforeExitTap)
    XCTAssertTrue(NativeGalleryInteractionPriorityPolicy.shouldSuppressThumbnailRetryAfterInteractionCancel)
    XCTAssertEqual(NativeGalleryInteractionPriorityPolicy.thumbnailResumeDelayAfterSelectionSeconds, 0.2)
  }

  func testNativeGalleryDragSelectionPolicyAutoScrollsNearEdgesLikeAndroid() {
    XCTAssertEqual(
      NativeGalleryDragSelectionPolicy.autoScrollDelta(
        pointerY: 10,
        viewportStart: 0,
        viewportEnd: 600,
        edgeSize: 100,
        maxDelta: 40
      ),
      -36,
      accuracy: 0.001
    )
    XCTAssertEqual(
      NativeGalleryDragSelectionPolicy.autoScrollDelta(
        pointerY: 575,
        viewportStart: 0,
        viewportEnd: 600,
        edgeSize: 100,
        maxDelta: 40
      ),
      30,
      accuracy: 0.001
    )
  }

  func testNativeGallerySelectionSummaryCountsOnlySelectableFilteredItemsLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)
    state.setSelection(handles: [1, 2, 3, 99])
    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 3)

    let summary = NativeGallerySelectionSummaryPolicy.summary(items: state.items, state: state)

    XCTAssertEqual(summary.selectedCount, 1)
    XCTAssertEqual(summary.totalSelectableCount, 1)
    XCTAssertEqual(summary.text, "已选 1 / 共 1 张")
  }

  func testGalleryQueueStartsRequestedDownloadsOnly() {
    let items = [
      CameraVendorGalleryItem(
        handle: 11,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 22,
        filename: "B.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "1 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [11, 22])

    XCTAssertEqual(state.downloadState(for: 11), .queued)
    XCTAssertEqual(state.downloadState(for: 22), .queued)
  }

  func testGalleryDownloadQueuePreservesEnqueueOrderLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1267, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1268, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1265, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1267, 1268, 1265])

    XCTAssertEqual(state.queuedDownloadHandles(), [1267, 1268, 1265])
    XCTAssertEqual(state.nextQueuedDownloadHandle(), 1267)

    state.markDownloadStarted(handle: 1267)
    state.markDownloadFailed(handle: 1267, message: "worker fallback")
    state.enqueueDownloads(for: [1267])

    XCTAssertEqual(state.queuedDownloadHandles(), [1268, 1265, 1267])
  }

  func testGalleryDownloadPauseClearsOnlyPendingQueue() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1, 2, 3], mode: .compressed)
    state.markDownloadStarted(handle: 1)
    let pausedHandles = state.pauseQueuedDownloads()

    XCTAssertEqual(pausedHandles, [2, 3])
    XCTAssertEqual(state.queuedDownloadHandles(), [])
    XCTAssertEqual(state.downloadState(for: 1), .downloading)
    XCTAssertEqual(state.downloadState(for: 2), .idle)
    XCTAssertEqual(state.downloadState(for: 3), .idle)
    XCTAssertEqual(state.downloadableHandles(from: [1, 2, 3]), [2, 3])
  }

  func testGalleryQueueCarriesDownloadModeCapturedAtSelectionTime() {
    let items = [
      CameraVendorGalleryItem(handle: 11, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 22, filename: "B.HEIF", formatLabel: "HEIF", captureDate: "", byteSizeText: "8 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [11], mode: .compressed)
    state.enqueueDownloads(for: [22], mode: .original)

    XCTAssertEqual(state.downloadMode(for: 11), .compressed)
    XCTAssertEqual(state.downloadMode(for: 22), .original)
  }

  func testGalleryQueueClearsSelectionForQueuedDownloads() {
    let items = [
      CameraVendorGalleryItem(handle: 11, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 22, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.setSelection(handles: [11, 22])
    state.enqueueDownloads(for: [11])

    XCTAssertEqual(state.selectedHandles, [22])
  }

  func testGalleryDownloadLifecycleTracksProgressAndFailure() {
    let items = [
      CameraVendorGalleryItem(
        handle: 5,
        filename: "C.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:02:00",
        byteSizeText: "2 MB"
      )
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [5])
    state.markDownloadStarted(handle: 5)
    XCTAssertEqual(state.downloadState(for: 5), .downloading)

    state.markDownloadFinished(handle: 5)
    XCTAssertEqual(state.downloadState(for: 5), .saved)

    state.markDownloadFailed(handle: 5, message: "network")
    XCTAssertEqual(state.downloadState(for: 5), .failed("network"))
  }

  func testGalleryCanClearSavedDownloadCacheForRetry() {
    let item = CameraVendorGalleryItem(
      handle: 5,
      filename: "C.JPG",
      formatLabel: "JPG",
      captureDate: "2026:04:26 17:02:00",
      byteSizeText: "2 MB"
    )
    var state = CameraVendorGalleryState(items: [item])

    state.markDownloadFinished(handle: 5)
    state.clearSavedDownloadCache(handle: 5)

    XCTAssertEqual(state.downloadState(for: 5), .idle)
    XCTAssertEqual(state.downloadableHandles(from: [5]), [5])
  }

  func testGalleryCanClearAllSavedDownloadCacheForRetry() {
    let items = [
      CameraVendorGalleryItem(handle: 5, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 6, filename: "D.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
      CameraVendorGalleryItem(handle: 7, filename: "E.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "4 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.markDownloadFinished(handle: 5)
    state.markDownloadFinished(handle: 6)
    state.enqueueDownloads(for: [7])
    state.clearAllSavedDownloadCache()

    XCTAssertEqual(state.downloadState(for: 5), .idle)
    XCTAssertEqual(state.downloadState(for: 6), .idle)
    XCTAssertEqual(state.downloadState(for: 7), .queued)
    XCTAssertEqual(state.downloadableHandles(from: [5, 6, 7]), [5, 6])
  }

  func testDownloadHistoryStoreClearsSingleSavedHandle() {
    let cameraID = "unit-test-camera-\(UUID().uuidString)"

    CameraVendorDownloadHistoryStore.markSaved(handle: 11, for: cameraID)
    CameraVendorDownloadHistoryStore.markSaved(handle: 22, for: cameraID)
    CameraVendorDownloadHistoryStore.removeSaved(handle: 11, for: cameraID)

    XCTAssertEqual(CameraVendorDownloadHistoryStore.savedHandles(for: cameraID), [22])
    CameraVendorDownloadHistoryStore.clear(for: cameraID)
  }

  func testDownloadHistoryStorePersistsGalleryItemAndThumbnailLikeAndroid() {
    let cameraID = "unit-test-camera-\(UUID().uuidString)"
    let item = CameraVendorGalleryItem(
      handle: 31,
      filename: "DSCF0031.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:05:04 10:31:00",
      byteSizeText: "8 MB",
      orientation: 4,
      thumbnailData: Data([0xFF, 0xD8, 0xFF])
    )

    CameraVendorDownloadHistoryStore.markSaved(item: item, for: cameraID)

    XCTAssertEqual(CameraVendorDownloadHistoryStore.savedHandles(for: cameraID), [31])
    XCTAssertEqual(CameraVendorDownloadHistoryStore.historyItems(for: cameraID), [item])
    CameraVendorDownloadHistoryStore.clear(for: cameraID)
  }

  func testDownloadTimingFormatterComputesMegabytesPerSecond() {
    XCTAssertEqual(
      CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 3 * 1_048_576, elapsedMs: 1500),
      "2.00"
    )
    XCTAssertEqual(CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 0, elapsedMs: 1500), "0.00")
    XCTAssertEqual(CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 1024, elapsedMs: 0), "0.00")
  }

  func testGalleryDownloadStateSurvivesFilteringItems() {
    let originalItems = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
    ]
    var state = CameraVendorGalleryState(items: originalItems)

    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 2)
    state.replaceItems([originalItems[0]])

    XCTAssertEqual(state.downloadState(for: 2), .saved)
  }

  func testGalleryDownloadableHandlesSkipAlreadySavedQueuedAndDownloadingItems() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 2)
    state.enqueueDownloads(for: [3])
    state.markDownloadStarted(handle: 3)

    XCTAssertEqual(state.downloadableHandles(from: [1, 2, 3]), [1])
  }

  func testGalleryDownloadableHandlesAllowFailedItemsToRetry() {
    let item = CameraVendorGalleryItem(handle: 4, filename: "D.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "4 MB")
    var state = CameraVendorGalleryState(items: [item])

    state.enqueueDownloads(for: [4])
    state.markDownloadFailed(handle: 4, message: "network")

    XCTAssertEqual(state.downloadableHandles(from: [4]), [4])
  }

  func testGalleryDownloadFatalConnectionFailureStopsPendingQueueLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)
    state.enqueueDownloads(for: [1, 2, 3])
    state.markDownloadStarted(handle: 1)
    let error = NSError(
      domain: NSPOSIXErrorDomain,
      code: 54,
      userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))

    state.markDownloadFailed(handle: 1, message: error.localizedDescription)
    state.markPendingDownloadsFailedAfterFatalFailure(
      message: NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage
    )

    XCTAssertEqual(state.downloadState(for: 1), .failed("Connection reset by peer"))
    XCTAssertEqual(
      state.downloadState(for: 2),
      .failed(NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage)
    )
    XCTAssertEqual(
      state.downloadState(for: 3),
      .failed(NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage)
    )
    XCTAssertTrue(state.queuedDownloadHandles().isEmpty)
  }

  func testGalleryDownloadPtpSocketReadTimeoutStopsPendingQueue() {
    let error = NSError(
      domain: "CameraVendorPtpSocket",
      code: 9,
      userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))
  }

  func testGalleryDownloadLocalizedPtpReadTimeoutStopsPendingQueue() {
    let error = NSError(
      domain: "CameraVendorPtpSession",
      code: 5,
      userInfo: [NSLocalizedDescriptionKey: "读取数据失败: 等待相机返回数据超时"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))
  }

  func testGalleryDownloadSelectionPolicyDisablesItemsAlreadyInDownloadList() {
    XCTAssertTrue(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .idle))
    XCTAssertTrue(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .failed("network")))
    XCTAssertFalse(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .queued))
    XCTAssertFalse(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .downloading))
    XCTAssertFalse(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .saved))
  }

  func testNativeGalleryNavigationPolicyBlocksLeavingWhileDownloading() {
    XCTAssertFalse(NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: false))
  }

  func testNativeGalleryNavigationPolicyLocksPreviewWhileDownloading() {
    XCTAssertFalse(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: false))

    XCTAssertFalse(NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: false))
  }

  func testNativeGalleryDownloadBarPolicyBlocksGalleryActionsWhileDownloading() {
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 3, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 2, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 0, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 0, isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 3, isDownloading: false))
    XCTAssertTrue(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 2, isDownloading: false))
  }

  func testNativeGalleryDownloadModePresentationPolicyEntersDownloadCenterAndBlocksOtherOperations() {
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.shouldOpenDownloadCenterAfterStartingDownload)
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.shouldBlockDownloadCenterBackWhileActive)
    XCTAssertEqual(NativeGalleryDownloadModePresentationPolicy.pauseDownloadTitle, "暂停下载")
    XCTAssertEqual(NativeGalleryDownloadModePresentationPolicy.pauseRequestedTitle, "正在暂停")
    XCTAssertFalse(NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: false))
    XCTAssertFalse(NativeGalleryDownloadModePresentationPolicy.shouldScheduleThumbnailRefresh(isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.shouldScheduleThumbnailRefresh(isDownloading: false))
    XCTAssertTrue(
      NativeGalleryDownloadModePresentationPolicy.canPauseDownload(
        isDownloading: true,
        isPauseRequested: false
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.canPauseDownload(
        isDownloading: true,
        isPauseRequested: true
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.canPauseDownload(
        isDownloading: false,
        isPauseRequested: false
      )
    )
  }

  func testNativeGalleryPostDownloadSelectionPolicyClearsSelectionLikeAndroid() {
    XCTAssertTrue(
      NativeGalleryPostDownloadSelectionPolicy.selectionAfterStartingDownload(selectedHandles: [1, 2, 3]).isEmpty
    )
  }

  func testHomeRememberedCameraPresenceDetectsOnlineCameraFromScanResults() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [rememberedID],
        status: "已发现 1 台相机",
        isBusy: false
      ),
      .online
    )
  }

  func testHomeRememberedCameraPresenceGuidesWhileScanningAndOfflineAfterMiss() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [],
        status: "搜索中",
        isBusy: true
      ),
      .scanning
    )
    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [],
        status: "未发现相机",
        isBusy: false
      ),
      .offline
    )
  }

  func testHomeRememberedCameraCopyUsesPairingAndTransferLanguage() {
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.unpairedDetailText(rssi: -54, shortID: "12345678"),
      "未配对 · 信号 -54 dB · 12345678"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .online),
      "已配对 · 在线"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .scanning),
      "已配对 · 正在搜索"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .offline),
      "已配对 · 未在线"
    )
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.pairedActionTitle, "进入相机相册")
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.unpairedActionTitle, "配对")
  }

  func testHomeCameraSearchActionUsesRefreshLanguageAfterAutoScan() {
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.symbolName, "arrow.clockwise")
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.accessibilityLabel, "刷新搜索附近相机")
  }

  func testNativeHomeAndroidParityCopyMatchesConnectScreen() {
    XCTAssertEqual(NativeHomeAndroidParityCopy.brandTitle, "CAMTRANSFER")
    XCTAssertEqual(NativeHomeAndroidParityCopy.screenTitle, "连接相机")
    XCTAssertEqual(NativeHomeAndroidParityCopy.idleModeLabel, "蓝牙配对")
    XCTAssertEqual(NativeHomeAndroidParityCopy.pairedModeLabel, "已配对")
    XCTAssertEqual(NativeHomeAndroidParityCopy.savedCameraLabel, "已保存相机")
    XCTAssertEqual(NativeHomeAndroidParityCopy.pairingPreparationTitles, ["进入配对注册界面", "取消旧的蓝牙配对"])
    XCTAssertEqual(NativeHomeAndroidParityCopy.wiredAccessLabel, "有线接入")
    XCTAssertEqual(NativeHomeAndroidParityCopy.auxiliaryActionLabels, ["诊断日志", "使用须知"])
  }

  func testFreshPairingRequiresSystemBluetoothForgetPromptLikeAndroidRegistrationGuard() {
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.shouldRequireBeforeFreshPairing())
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.title, "先删除本地蓝牙配对")
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.openBluetoothTitle, "打开本地蓝牙设置")
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.continueTitle, "我已忽略，继续配对")
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("删除本地蓝牙配对"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("设置 > 蓝牙"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("忽略此设备"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("Wi-Fi/PTP"))
  }

  func testNativeHomePairingPreparationUsesCompactRows() {
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.usesCompactRows)
    XCTAssertLessThanOrEqual(NativeHomePairingPreparationLayoutPolicy.rowMinimumHeight, 72)
    XCTAssertFalse(NativeHomePairingPreparationLayoutPolicy.showsLongInstructionBody)
    XCTAssertFalse(NativeHomePairingPreparationLayoutPolicy.showsInlineDisclaimerText)
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.hidesSystemNavigationBar)
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.usesInlineBluetoothAction)
  }

  func testNativeHomeHeaderTemporarilyHidesProEntry() {
    XCTAssertFalse(NativeHomeHeaderLayoutPolicy.showsProEntry)
  }

  func testNativeHomePairedCameraCardCentersGalleryAction() {
    XCTAssertTrue(NativeHomePairedCameraCardLayoutPolicy.centersPrimaryGalleryAction)
    XCTAssertGreaterThanOrEqual(NativeHomePairedCameraCardLayoutPolicy.primaryGalleryActionMinimumWidth, 150)
    XCTAssertLessThanOrEqual(NativeHomePairedCameraCardLayoutPolicy.cardMinimumHeight, 170)
    XCTAssertFalse(NativeHomePairedCameraCardLayoutPolicy.showsDecorativeProfileHeader)
    XCTAssertFalse(NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame)
  }

  func testNativeWiredImportEntryPolicyRequiresDetectedDevice() {
    XCTAssertFalse(NativeWiredImportEntryPolicy.canOpenImport(deviceCount: 0))
    XCTAssertTrue(NativeWiredImportEntryPolicy.canOpenImport(deviceCount: 1))
    XCTAssertEqual(NativeWiredImportEntryPolicy.noDeviceTitle, "需要有线连接")
    XCTAssertEqual(
      NativeWiredImportEntryPolicy.noDeviceMessage,
      "请先用数据线连接相机，并在相机上开启 USB 传输或读卡模式。"
    )
  }

  func testGallerySelectAllSkipsItemsAlreadyInDownloadList() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [2, 3])
    state.markDownloadStarted(handle: 3)
    state.selectAll()

    XCTAssertEqual(state.selectedHandles, [1])
  }

  func testNativeGalleryFilterPolicyFiltersByFormat() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 4, filename: "0x00000004", formatLabel: "", captureDate: "", byteSizeText: ""),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .heif),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [2])
  }

  func testNativeGalleryFilterPolicyUsesAndroidFormatHintsForExpandedHeifRawPlaceholders() {
    let items = [
      CameraVendorGalleryItem(
        handle: 9,
        filename: "0x00000009",
        formatLabel: "",
        captureDate: "20260624",
        byteSizeText: "",
        formatHints: [.heif, .raw]
      ),
    ]

    let heifFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .heif),
      now: Date(timeIntervalSince1970: 0)
    )
    let rawFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .raw),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(heifFiltered.map(\.handle), [9])
    XCTAssertEqual(rawFiltered.map(\.handle), [9])
  }

  func testNativeGalleryFilterPolicyUsesResolvedFormatLabelBeforeAmbiguousHints() {
    let items = [
      CameraVendorGalleryItem(
        handle: 11,
        filename: "DSCF0011.HEIC",
        formatLabel: "HEIF",
        captureDate: "20260624",
        byteSizeText: "8 MB",
        formatHints: [.heif, .raw]
      ),
      CameraVendorGalleryItem(
        handle: 12,
        filename: "DSCF0012.RAF",
        formatLabel: "RAW",
        captureDate: "20260624",
        byteSizeText: "42 MB",
        formatHints: [.heif, .raw]
      ),
    ]

    let rawFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .raw),
      now: Date(timeIntervalSince1970: 0)
    )
    let heifFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .heif),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(rawFiltered.map(\.handle), [12])
    XCTAssertEqual(heifFiltered.map(\.handle), [11])
  }

  func testNativeGalleryFilterPerformancePolicyCachesCaptureDatesDuringFilter() {
    XCTAssertTrue(NativeGalleryFilterPerformancePolicy.shouldBuildCaptureDateIndex)
    XCTAssertTrue(NativeGalleryFilterPerformancePolicy.shouldDisableReloadAnimation)
  }

  func testNativeGalleryFilterPolicyDoesNotTreatUnresolvedPlaceholderAsJpg() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "0x3000", captureDate: "", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 3, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .jpg),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [3])
  }

  func testNativeGalleryFormatDisplayPolicyHidesUnresolvedPlaceholderFormat() {
    let unresolvedEmpty = CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "", byteSizeText: "")
    let unresolvedHex = CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "0x3000", captureDate: "", byteSizeText: "")
    let heif = CameraVendorGalleryItem(handle: 3, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: "2 MB")

    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: unresolvedEmpty))
    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: unresolvedHex))
    XCTAssertEqual(NativeGalleryFormatDisplayPolicy.badgeText(for: heif), " HEIF ")
    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.previewSubtitle(index: 0, total: 3, item: unresolvedEmpty),
      "1 / 3"
    )
  }

  func testNativeGalleryFilterStateDefaultsToAllDatesAndFormats() {
    let state = NativeGalleryFilterState()

    XCTAssertEqual(state.date, .all)
    XCTAssertEqual(state.formats, [.all])
    XCTAssertEqual(state.sort, .newest)
  }

  func testNativeGalleryFilterPolicySortsNewestAndOldestLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let newest = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .newest),
      now: Date(timeIntervalSince1970: 0)
    )
    let oldest = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .oldest),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(newest.map(\.handle), [3, 2, 1])
    XCTAssertEqual(oldest.map(\.handle), [1, 2, 3])
  }

  func testNativeGalleryFilterPolicySortsNotDownloadedFirstLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:34:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:33:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .notDownloaded),
      downloadedHandles: [1],
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [2, 3, 1])
  }

  func testNativeGallerySectionPolicyGroupsFilesByCaptureDateLikeAndroid() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1, filename: "A.RAF", formatLabel: "RAW", captureDate: "2026:05:03 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 9, filename: "Z.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]

    let sections = NativeGallerySectionPolicy.sections(from: items, now: now, calendar: calendar)

    XCTAssertEqual(sections.map(\.title), ["今天 5月4日 2 张", "5月3日 1 张", "未知日期 1 张"])
    XCTAssertEqual(sections.map { $0.items.map(\.handle) }, [[3, 2], [1], [9]])
  }

  func testNativeGalleryThumbnailRequestWindowPrioritizesVisibleHandlesLikeAndroid() {
    let handles = Array(1...30)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [10, 11, 12],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 11, 12])
    XCTAssertEqual(request, [10, 11, 12, 7, 8, 9, 13, 14, 15, 16, 17, 18])
  }

  func testNativeGalleryThumbnailRequestWindowSortsUnorderedVisibleHandlesByGalleryOrder() {
    let handles = Array(1...30)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [12, 10, 11],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 11, 12])
    XCTAssertEqual(request, [10, 11, 12, 7, 8, 9, 13, 14, 15, 16, 17, 18])
  }

  func testNativeGalleryThumbnailRequestWindowDoesNotBridgeSparseVisibleHandles() {
    let handles = Array(1...1_600)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [10, 1_498, 1_499],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 1_498, 1_499])
    XCTAssertLessThanOrEqual(request.count, 18)
    XCTAssertFalse(request.contains(800))
  }

  func testNativeGalleryFilterPolicyAllowsMultipleFormats() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(date: .today, formats: [.jpg, .heif]),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [2, 1])
  }

  func testNativeGalleryFilterPolicyFiltersTodayByCaptureDate() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:03 10:30:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(date: .today),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [1])
  }

  func testNativeGalleryFilterPolicyCombinesDateAndFormat() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.HEIC", formatLabel: "HEIF", captureDate: "2026:04:20 10:31:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(date: .today, format: .heif),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [2])
  }

  func testStubGalleryServiceReturnsSampleItems() async throws {
    let service = CameraVendorGalleryStubService()

    let items = try await service.fetchGallery()

    XCTAssertFalse(items.isEmpty)
    XCTAssertEqual(items.first?.filename, "DSCF0001.JPG")
  }

  func testHandshakeCompletionSummaryContainsDeviceAndSerial() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "1234",
      preferredWifiNetwork: nil
    )

    XCTAssertEqual(summary.navigationTitle, "DEVICE-A")
    XCTAssertTrue(summary.subtitle.contains("1234"))
  }

  func testPairedCameraStoreRoundTripsSavedCamera() throws {
    let suiteName = "RunnerTests.PairedCameraStore.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "abc12345",
        isHidden: true
      )
    )

    store.save(record)

    XCTAssertEqual(store.load(), record)
    XCTAssertEqual(store.load()?.connectionSummary.connectedDeviceName, "iPhone-0426")
  }

  func testPairedCameraStoreKeepsMultipleSavedCameras() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Multiple.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let first = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: nil
    )
    let second = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "87654321-4321-4321-4321-BA0987654321")!,
      deviceName: "CAMERA DEVICE-B",
      serialNumber: "221019F1932011003C",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-B-003C",
        passphrase: "abc12345",
        isHidden: false
      )
    )

    store.save(first)
    store.save(second)

    XCTAssertEqual(store.loadAll(), [second, first])
  }

  func testStoredPairingPolicyRequiresOfficialWifiConfigurationBeforeGallery() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: nil
    )

    XCTAssertFalse(CameraVendorStoredPairingPolicy.canEnterGallery(record: record))
  }

  func testStoredPairingPolicyRejectsRememberedRecordWhenHandshakeIdentityMismatches() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
    let mismatchedSummary = CameraVendorConnectionSummary(
      deviceName: "CAMERA DEVICE-B",
      serialNumber: "221019F1932011003C",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-B-003C",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:00"
      )
    )

    XCTAssertFalse(
      CameraVendorStoredPairingPolicy.matchesRememberedIdentity(
        record: record,
        summary: mismatchedSummary,
        peripheralID: record.peripheralID
      )
    )
  }

  func testStoredPairingPolicyMatchesAndroidStableCameraIdentityBeforePeripheralID() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
    let sameCameraSummary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )

    XCTAssertTrue(
      CameraVendorStoredPairingPolicy.matchesRememberedIdentity(
        record: record,
        summary: sameCameraSummary,
        peripheralID: UUID(uuidString: "87654321-4321-4321-4321-BA0987654321")!
      )
    )
  }

  func testPairedCameraStoreDropsInvalidPayload() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Invalid.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.set(Data("not-json".utf8), forKey: CameraVendorPairedCameraStore.storageKey)

    let store = CameraVendorPairedCameraStore(defaults: defaults)

    XCTAssertNil(store.load())
    XCTAssertNil(defaults.data(forKey: CameraVendorPairedCameraStore.storageKey))
  }

  func testPairedCameraStoreLoadsLegacyRecordWithoutSavedConnectedDeviceName() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Legacy.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    let legacyPayload = Data("""
    {
      "peripheralID":"12345678-1234-1234-1234-1234567890AB",
      "deviceName":"CAMERA DEVICE-A",
      "serialNumber":"221019F1932011003B",
      "appVariant":"ReferenceApp",
      "preferredWifiNetwork":null
    }
    """.utf8)
    defaults.set(legacyPayload, forKey: CameraVendorPairedCameraStore.storageKey)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let record = try XCTUnwrap(store.load())

    XCTAssertNil(record.connectedDeviceName)
    XCTAssertEqual(
      record.connectionSummary.connectedDeviceName,
      CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName()
    )
  }

  func testRememberedPairingPolicySkipsManualConfirmationForSamePeripheral() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldSkipManualPairingConfirmation(
        rememberedPeripheralID: rememberedID,
        selectedPeripheralID: rememberedID
      )
    )

    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldSkipManualPairingConfirmation(
        rememberedPeripheralID: rememberedID,
        selectedPeripheralID: UUID()
      )
    )
  }

  func testRememberedPairingPolicyBypassesConfirmationForSavedCameraAfterAck() {
    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: true,
        isAlreadyPairedIdentificationNumber: false
      )
    )
    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: true,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: false,
        isAlreadyPairedIdentificationNumber: false
      )
    )
  }

  func testRememberedPairingPolicyDoesNotBypassForReferenceAppIdentificationAlone() {
    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: false,
        isAlreadyPairedIdentificationNumber: true
      )
    )
  }

  func testFreshPairingRegistrationPolicyBlocksAlreadyPairedIdentificationWithoutRememberedRecord() {
    XCTAssertTrue(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: false,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: true,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: false,
        isAlreadyPairedIdentificationNumber: false
      )
    )
  }

  func testQueuedBatchDownloadKeepsUnselectedHandlesIdle() {
    let items = [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 2,
        filename: "B.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 3,
        filename: "C.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:02:00",
        byteSizeText: "1 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1, 3])

    XCTAssertEqual(state.downloadState(for: 1), .queued)
    XCTAssertEqual(state.downloadState(for: 2), .idle)
    XCTAssertEqual(state.downloadState(for: 3), .queued)
  }

  func testGalleryDownloadProgressTextIncludesPositionAndSize() {
    let item = CameraVendorGalleryItem(
      handle: 7,
      filename: "A.RAF",
      formatLabel: "RAW",
      captureDate: "",
      byteSizeText: "52 MB"
    )
    var state = CameraVendorGalleryState(items: [item])

    state.enqueueDownloads(for: [7])
    state.markDownloadStarted(handle: 7, position: 2, total: 5)

    XCTAssertEqual(state.downloadProgressText(for: 7), "2/5")
  }

  func testPtpOperationPacketEncodingMatchesExpectedLayout() {
    let data = CameraVendorPtpPacketBuilder.buildOperationRequest(
      operationCode: 0x1002,
      transactionID: 7,
      parameters: [1]
    )

    XCTAssertEqual(data.count, 22)
    XCTAssertEqual(Array(data.prefix(8)), [22, 0, 0, 0, 6, 0, 0, 0])
    XCTAssertEqual(Array(data.suffix(14)), [1, 0, 0, 0, 0x02, 0x10, 7, 0, 0, 0, 1, 0, 0, 0])
  }

  func testCameraVendorLegacyOperationPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x1002,
      transactionID: 1,
      parameters: [1]
    )

    XCTAssertEqual(data.count, 16)
    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x02, 0x10,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorVendorGalleryPreflightPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x1015,
      transactionID: 7,
      parameters: [0xD212]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x15, 0x10,
        0x07, 0x00, 0x00, 0x00,
        0x12, 0xD2, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorLegacyDataOutPacketCanUseReferenceAppTwoByteInitSequencePayload() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: 0x1016,
      transactionID: 3,
      data: Data([0x14, 0x00])
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0E, 0x00, 0x00, 0x00,
        0x02, 0x00,
        0x16, 0x10,
        0x03, 0x00, 0x00, 0x00,
        0x14, 0x00,
      ]
    )
  }

  func testCameraVendorVendorLatestObjectInfoPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x9054,
      transactionID: 9,
      parameters: [0x10000001]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x54, 0x90,
        0x09, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x10,
      ]
    )
  }

  func testCameraVendorCurrentImageContextPolicyKeepsCurrentImagePrimeOutOfColdStartMainline() {
    XCTAssertEqual(CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle, 0x10000001)
    XCTAssertFalse(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList)
    XCTAssertFalse(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription)
  }

  func testCameraVendorCurrentImageContextPolicySkipsThumbnailPrimeAfterImagePrimeFailure() {
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailAfterImageContextPrime(
        imagePrimeSucceeded: false
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailAfterImageContextPrime(
        imagePrimeSucceeded: true
      )
    )
  }

  func testCameraVendorCurrentImageContextPolicyDoesNotPrimeDuringProductionColdStart() {
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x0992
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x0993
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: nil
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x05F4
      )
    )
  }

  func testCameraVendorLegacyGalleryPolicyMatchesOfficialColdStartListSequence() {
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectHandlesWhenSpecifiedListIsSmall)
    XCTAssertEqual(CameraVendorLegacyGalleryObjectInfoPolicy.maxStandardObjectInfoProbeCount, 300)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeDualSlotWhenSpecifiedListIsSmall)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeLatestProbe)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleViaObjectPropList)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeBeforeFormatSearch)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeDuringColdStart)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadSearchModeAllDuringColdStart)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldSetStillImageObjectFormatSearchMode)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadFormatSpecificSpecifiedObjectHandles)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldRefreshGalleryContextBeforeSpecifiedList)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetCompressionModeBeforeObjectInfoList)
  }

  func testCameraVendorOfficialColdStartMainlineReadsFormatSpecificListsForCompleteInitialGallery() {
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadSearchModeAllDuringColdStart)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeBeforeFormatSearch)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldSetStillImageObjectFormatSearchMode)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadFormatSpecificSpecifiedObjectHandles)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeDuringColdStart)
  }

  func testCameraVendorFormatSpecifiedObjectPolicyPromotesExpandedHeifAndRawListsLikeAndroid() {
    let groups = [
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260624", objectCount: 2),
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260623", objectCount: 2),
    ]

    XCTAssertTrue(
      CameraVendorFormatSpecifiedObjectPolicy.shouldPromoteToInitialHandles(
        mask: CameraVendorSearchModeAllPayload.heifObjectFormatMask,
        currentHandleCount: 3,
        candidateHandleCount: 4,
        dateGroups: groups
      )
    )
    XCTAssertTrue(
      CameraVendorFormatSpecifiedObjectPolicy.shouldPromoteToInitialHandles(
        mask: CameraVendorSearchModeAllPayload.rawObjectFormatMask,
        currentHandleCount: 3,
        candidateHandleCount: 4,
        dateGroups: groups
      )
    )
    XCTAssertFalse(
      CameraVendorFormatSpecifiedObjectPolicy.shouldPromoteToInitialHandles(
        mask: CameraVendorSearchModeAllPayload.jpegObjectFormatMask,
        currentHandleCount: 3,
        candidateHandleCount: 4,
        dateGroups: groups
      )
    )
    XCTAssertFalse(
      CameraVendorFormatSpecifiedObjectPolicy.shouldPromoteToInitialHandles(
        mask: CameraVendorSearchModeAllPayload.heifObjectFormatMask,
        currentHandleCount: 3,
        candidateHandleCount: 4,
        dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260624", objectCount: 3)]
      )
    )
  }

  func testCameraVendorPostGalleryStillFormatRecoveryIsDisabledWhenColdStartReadsFormatLists() {
    let labels = CameraVendorFormatSpecifiedObjectPolicy.galleryReadyStillRecoveryPasses.map(\.label)

    XCTAssertEqual(labels, ["ALL", "JPG", "HEIF", "RAW"])
    XCTAssertFalse(labels.contains("MOV"))
    XCTAssertFalse(labels.contains("MP4"))
    XCTAssertFalse(CameraVendorGalleryFastInitialLoadPolicy.shouldRunStillFormatRecoveryAfterGalleryReady)
    XCTAssertTrue(CameraVendorFormatSpecifiedObjectPolicy.shouldRestoreAllSearchModeAfterFormatPasses)
  }

  func testCameraVendorLegacyGalleryPolicySkipsDefaultLatestProbeWhenEmptyListHasNoCurrentHandle() {
    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeLatestObjectInfoForEmptySpecifiedList(
        currentObjectHandle: nil
      )
    )
    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeLatestObjectInfoForEmptySpecifiedList(
        currentObjectHandle: 0
      )
    )
    XCTAssertTrue(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeLatestObjectInfoForEmptySpecifiedList(
        currentObjectHandle: 0x10000002
      )
    )
  }

  func testCameraVendorLegacyGalleryPolicyFallsBackWhenSpecifiedListHasNoHeifOrRaw() {
    let jpegInfo = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0x3801,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "DSCF0001.JPG",
      captureDate: ""
    )
    let videoInfo = CameraVendorCameraObjectInfo(
      handle: 2,
      storageID: 0,
      formatCode: 0x300D,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "DSCF0002.MOV",
      captureDate: ""
    )

    XCTAssertTrue(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(
        afterSpecifiedInfos: [jpegInfo, videoInfo]
      )
    )
  }

  func testCameraVendorLegacyGalleryPolicyDoesNotFallbackWhenSpecifiedListAlreadyHasHeif() {
    let jpegInfo = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0x3801,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "DSCF0001.JPG",
      captureDate: ""
    )
    let heifInfo = CameraVendorCameraObjectInfo(
      handle: 2,
      storageID: 0,
      formatCode: 0x3812,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "DSCF0002.HEIC",
      captureDate: ""
    )

    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(
        afterSpecifiedInfos: [jpegInfo, heifInfo]
      )
    )
  }

  func testCameraVendorLegacyGalleryPolicyFallsBackWhenSpecifiedListIsRawOnly() {
    let rawInfo = CameraVendorCameraObjectInfo(
      handle: 0x073D,
      storageID: 0,
      formatCode: 0xB103,
      compressedSize: 86_968_832,
      thumbCompressedSize: 43_778,
      filename: "DSCF7842.RAF",
      captureDate: ""
    )

    XCTAssertTrue(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(
        afterSpecifiedInfos: [rawInfo]
      )
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicyProbesGapsAroundSpecifiedHandles() {
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: [1, 10, 22, 24, 26]),
      [
        2, 9, 11, 21, 23, 25, 27,
        3, 4, 5, 6, 7, 8,
      ]
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicyCoversCurrentJpegOnlySpecifiedList() {
    let handles: [UInt32] = [
      0x00000090, 0x0000008E, 0x0000008C, 0x0000008A, 0x00000088, 0x00000086,
      0x00000084, 0x00000082, 0x00000080, 0x0000007E, 0x0000007C, 0x0000007A,
      0x00000026, 0x00000025, 0x00000024, 0x00000023, 0x00000022, 0x0000000C,
      0x0000000A, 0x00000008, 0x00000006, 0x00000004, 0x00000002,
    ]

    let candidates = CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: handles)

    XCTAssertEqual(Array(candidates.prefix(4)), [
      0x0000008F,
      0x00000091,
      0x0000008D,
      0x0000008B,
    ])
    XCTAssertTrue(candidates.contains(0x00000079))
    XCTAssertTrue(candidates.contains(0x0000007B))
    XCTAssertTrue(candidates.contains(0x0000007D))
    XCTAssertTrue(candidates.contains(0x0000008F))
    XCTAssertFalse(candidates.contains(0x00000090))
  }

  func testCameraVendorHiddenObjectHandleProbePolicySkipsLargeRanges() {
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: [1, 900]),
      []
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicyReturnsRecentGapsForLargeRawOnlyList() {
    let handles: [UInt32] = [0x073D, 0x073B, 0x0739, 0x0737]

    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.recentGapCandidateHandles(from: handles),
      [0x073C, 0x073A, 0x0738]
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicyContinuesBelowLowerBoundaryAfterHiddenHit() {
    let visibleHandles = Array(UInt32(0x1A)...UInt32(0x44))

    let continuation = CameraVendorHiddenObjectHandleProbePolicy.lowerBoundaryContinuationHandles(
      from: visibleHandles,
      discoveredHiddenHandles: [0x19]
    )

    XCTAssertEqual(Array(continuation.prefix(4)), [0x18, 0x17, 0x16, 0x15])
    XCTAssertFalse(continuation.contains(0x19))
    XCTAssertFalse(continuation.contains(0x1A))
  }

  func testCameraVendorHiddenObjectHandleProbePolicyDoesNotContinueWithoutLowerBoundaryHit() {
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.lowerBoundaryContinuationHandles(
        from: [0x1A, 0x1B, 0x1C],
        discoveredHiddenHandles: []
      ),
      []
    )
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.lowerBoundaryContinuationHandles(
        from: [0x1A, 0x1B, 0x1C],
        discoveredHiddenHandles: [0x1D]
      ),
      []
    )
  }

  func testCameraVendorCurrentObjectHandleDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.currentObjectHandle, 0xD22B)
  }

  func testCameraVendorCompressionDevicePropertiesMatchReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.imageForceCompression, 0xD226)
    XCTAssertEqual(CameraVendorDevicePropCode.imageCompressionRealInfo, 0xD227)
  }

  func testCameraVendorOriginalDownloadPolicyDoesNotPairForceCompressionWithGetObject() {
    XCTAssertFalse(CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeStandardGetObject)
    XCTAssertFalse(CameraVendorOriginalDownloadPolicy.shouldAttemptStandardGetObjectDownload)
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldDownloadUsingPartialObjectFallback)
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldPreparePartialObjectFileDownload)
  }

  func testCameraVendorOriginalDownloadPolicyUsesUInt16PayloadForCorrectFileSize() {
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: true),
      Data([0x01, 0x00])
    )
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: false),
      Data([0x00, 0x00])
    )
  }

  func testCameraVendorOriginalDownloadPolicyPrefersReferenceAppFastStartPreparation() {
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldPreferReferenceAppPreparationForFileDownload)
    XCTAssertEqual(CameraVendorOriginalDownloadPolicy.referenceAppFileDownloadForceCompressionMode, 2)
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldUseReferenceAppFastStartPreparation(
        formatLabel: "RAW"
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "RAW",
        cachedExpectedSize: 87_718_912
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "RAW",
        cachedExpectedSize: 87_718_912
      )
    )
  }

  func testCameraVendorOriginalDownloadPolicySkipsRepeatedD212DuringPriorityBatch() {
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeFileDownload(
        hasReadContextDuringCurrentPriorityDownload: false
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeFileDownload(
        hasReadContextDuringCurrentPriorityDownload: true
      )
    )
  }

  func testCameraVendorPhotoDataDownloadUsesReferenceAppPreparationCommands() throws {
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeDataDownload()
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeDataDownload()
    )

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func objectData(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func objectFile(", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("EventsList before data download"))
    XCTAssertTrue(body.contains("CompressionCutOff/PartialSize"))
  }

  func testCameraVendorPhotoDataDownloadLogsInternalTimingSummary() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func objectData(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func objectFile(", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("[OBS] PTP_DOWNLOAD_DATA_TIMING"))
    XCTAssertTrue(body.contains("prepMs="))
    XCTAssertTrue(body.contains("freshInfoMs="))
    XCTAssertTrue(body.contains("readMs="))
    XCTAssertTrue(body.contains("normalizeMs="))
    XCTAssertTrue(body.contains("totalMs="))
  }

  func testCameraVendorOriginalPhotoDataDownloadDoesNotUseCachedObjectInfoForJpegAndHeif() {
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "JPG",
        cachedExpectedSize: 167_936,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 813_192,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: nil,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 813_192,
        mode: .compressed
      )
    )
  }

  func testCameraVendorThumbnailPolicyPrimesObjectContextBeforeStandardGetThumb() {
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb)
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst)
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.standardGetThumbReadTimeoutSeconds, 3)
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes, 100)
    XCTAssertFalse(CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback)
  }

  func testGalleryFastInitialLoadBuildsPlaceholderItemsFromHandles() {
    let items = CameraVendorGalleryFastInitialLoadPolicy.placeholderItems(from: [10, 12])

    XCTAssertEqual(items.map(\.handle), [10, 12])
    XCTAssertEqual(items[0].filename, "0x0000000A")
    XCTAssertEqual(items[0].formatLabel, "")
    XCTAssertEqual(items[0].captureDate, "")
    XCTAssertEqual(items[0].byteSizeText, "")
  }

  func testGalleryFastInitialLoadBuildsAndroidFormatHintsFromExpandedD621Passes() {
    let hints = CameraVendorGalleryFastInitialLoadPolicy.formatHintsByHandle(
      handlesByFormatMask: [
        CameraVendorSearchModeAllPayload.allObjectFormatMask: [1, 2],
        CameraVendorSearchModeAllPayload.heifObjectFormatMask: [1, 2, 3, 4],
        CameraVendorSearchModeAllPayload.rawObjectFormatMask: [1, 2, 3, 4],
      ]
    )

    XCTAssertNil(hints[1])
    XCTAssertEqual(hints[3], [.heif, .raw])
    XCTAssertEqual(hints[4], [.heif, .raw])
  }

  func testGalleryStateMergesThumbnailMetadataLikeAndroidGetThumbnailWithInfo() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let placeholder = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let heif = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "6 MB"
    )
    var state = CameraVendorGalleryState(items: [placeholder])

    state.updateThumbnail(handle: 7, data: thumbnail, resolvedItem: heif)

    XCTAssertEqual(state.items[0].filename, "DSCF0007.HEIC")
    XCTAssertEqual(state.items[0].formatLabel, "HEIF")
    XCTAssertEqual(state.items[0].captureDate, "2026:06:24 10:11:12")
    XCTAssertEqual(state.items[0].thumbnailData, thumbnail)
  }

  func testGalleryStateDoesNotDropInitialFormatHintsWhenThumbnailInfoIsStillUnresolved() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let placeholder = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let unresolvedThumbnailInfo = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )
    var state = CameraVendorGalleryState(items: [placeholder])

    state.updateThumbnail(handle: 7, data: thumbnail, resolvedItem: unresolvedThumbnailInfo)

    XCTAssertEqual(state.items[0].formatHints, [.heif, .raw])
    XCTAssertEqual(NativeGalleryFormatDisplayPolicy.badgeText(for: state.items[0]), " HEIF/RAW ")
  }

  func testNativeGalleryThumbnailRetryPolicyStopsWhenBatchMakesNoProgress() {
    XCTAssertFalse(
      NativeGalleryThumbnailRetryPolicy.shouldContinueLoadingAfterBatch(
        requestedCount: 6,
        loadedCount: 0
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailRetryPolicy.shouldContinueLoadingAfterBatch(
        requestedCount: 6,
        loadedCount: 1
      )
    )
  }

  func testNativeGalleryThumbnailDecodeCachePolicyUsesCacheOnlyWhenDataAndImageExist() {
    XCTAssertTrue(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: UIImage()
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: nil,
        cachedImage: UIImage()
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: nil
      )
    )
  }

  func testVisibleThumbnailPolicyRehydratesCachedDataWhenImageCacheMisses() {
    let thumbnailData = Data([0xFF, 0xD8, 0xFF])
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: thumbnailData,
        cachedImage: UIImage(),
        hasFailedThumbnailRequest: false
      ),
      .none
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: thumbnailData,
        cachedImage: nil,
        hasFailedThumbnailRequest: false
      ),
      .decodeCachedData
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil,
        hasFailedThumbnailRequest: false
      ),
      .fetchFromCamera
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil,
        hasFailedThumbnailRequest: true
      ),
      .none
    )
  }

  func testGalleryFastInitialMetadataDoesNotStarveBehindThumbnailQueuePerHandle() {
    XCTAssertEqual(CameraVendorGalleryFastInitialLoadPolicy.fullObjectInfoStartDelaySeconds, 3.0)
    XCTAssertEqual(
      CameraVendorGalleryFastInitialLoadPolicy.metadataWaitSecondsBeforeObjectInfo(resolvedCount: 0),
      CameraVendorGalleryFastInitialLoadPolicy.maxInitialThumbnailLaneWaitSeconds
    )
    XCTAssertEqual(
      CameraVendorGalleryFastInitialLoadPolicy.metadataWaitSecondsBeforeObjectInfo(resolvedCount: 1),
      CameraVendorGalleryFastInitialLoadPolicy.activeThumbnailPollIntervalSeconds
    )
    XCTAssertLessThan(
      CameraVendorGalleryFastInitialLoadPolicy.activeThumbnailPollIntervalSeconds,
      CameraVendorGalleryFastInitialLoadPolicy.maxActiveThumbnailWaitSeconds
    )
    XCTAssertEqual(
      CameraVendorGalleryFastInitialLoadPolicy.metadataWaitSecondsBeforeObjectInfo(
        resolvedCount: 1,
        hasPendingVisibleThumbnails: true
      ),
      CameraVendorGalleryFastInitialLoadPolicy.maxActiveThumbnailWaitSeconds
    )
  }

  func testGalleryFastInitialStillFormatRecoveryDoesNotWaitForFullThumbnailBacklog() {
    XCTAssertEqual(
      CameraVendorGalleryFastInitialLoadPolicy.metadataWaitSecondsBeforeObjectInfo(
        resolvedCount: 0,
        hasPendingVisibleThumbnails: true
      ),
      CameraVendorGalleryFastInitialLoadPolicy.maxInitialThumbnailLaneWaitSeconds
    )
  }

  func testGalleryBackgroundMetadataStopsWhenCommunicationIsNoLongerCurrent() {
    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 8
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: false,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: true,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
  }

  func testGalleryBackgroundMetadataStopsDuringPriorityDownload() {
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7,
        isPriorityDownloadActive: true
      )
    )
  }

  func testGalleryBackgroundMetadataUsesShortTimeoutAndInvalidatesAfterSocketFailure() {
    XCTAssertEqual(CameraVendorBackgroundMetadataRefreshPolicy.objectInfoReadTimeoutSeconds, 3.0)
    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSocket", code: 9)
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSocket", code: 9),
        isPriorityDownloadActive: true
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSession", code: 0x2005)
      )
    )
  }

  func testPriorityDownloadWaitsForInFlightBackgroundMetadata() {
    XCTAssertTrue(
      CameraVendorPriorityDownloadExclusivePtpPolicy.shouldInvalidateInFlightPtpOperation(
        activeThumbnailRequests: 0,
        activeBackgroundMetadataRequests: 1
      )
    )
    XCTAssertFalse(
      CameraVendorPriorityDownloadExclusivePtpPolicy.shouldInvalidateInFlightPtpOperation(
        activeThumbnailRequests: 0,
        activeBackgroundMetadataRequests: 0
      )
    )
  }

  func testGalleryFastInitialDoesNotPublishZeroHandlePlaceholdersAsGalleryReady() {
    let placeholder = CameraVendorGalleryItem(
      handle: 0,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )

    XCTAssertFalse(
      CameraVendorGalleryFastInitialLoadPolicy.shouldPublishInitialItems([placeholder])
    )
  }

  func testGalleryRequestSchedulerPrioritizesVisibleThumbnailBeforeBackgroundMetadata() async {
    let backgroundQueued = expectation(description: "background waiter queued")
    let thumbnailQueued = expectation(description: "thumbnail waiter queued")
    let scheduler = CameraVendorGalleryRequestScheduler { priority in
      switch priority {
      case .backgroundMetadata:
        backgroundQueued.fulfill()
      case .visibleThumbnail:
        thumbnailQueued.fulfill()
      default:
        break
      }
    }
    let activeStarted = expectation(description: "active request started")
    let releaseActive = DispatchSemaphore(value: 0)
    let orderLock = NSLock()
    var order: [String] = []

    let active = Task {
      try await scheduler.run(priority: .backgroundMetadata) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let background = Task {
      try await scheduler.run(priority: .backgroundMetadata) {
        orderLock.lock()
        order.append("background")
        orderLock.unlock()
      }
    }
    await fulfillment(of: [backgroundQueued], timeout: 1)
    let thumbnail = Task {
      try await scheduler.run(priority: .visibleThumbnail) {
        orderLock.lock()
        order.append("thumbnail")
        orderLock.unlock()
      }
    }
    await fulfillment(of: [thumbnailQueued], timeout: 1)

    releaseActive.signal()
    _ = try? await active.value
    _ = try? await thumbnail.value
    _ = try? await background.value

    XCTAssertEqual(order, ["thumbnail", "background"])
  }

  func testGalleryRequestSchedulerRemovesCancelledWaitersLikeAndroid() async {
    let scheduler = CameraVendorGalleryRequestScheduler()
    let activeStarted = expectation(description: "active request started")
    let releaseActive = DispatchSemaphore(value: 0)

    let active = Task {
      try await scheduler.run(priority: .backgroundMetadata) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let cancelled = Task { () -> String in
      do {
        try await scheduler.run(priority: .backgroundMetadata) {
          XCTFail("cancelled waiter should not run")
        }
        return "ran"
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    cancelled.cancel()

    let thumbnail = Task { () -> String in
      do {
        return try await scheduler.run(priority: .visibleThumbnail) {
          "thumbnail"
        }
      } catch {
        return "failed"
      }
    }

    releaseActive.signal()
    _ = try? await active.value

    let thumbnailResult = await thumbnail.value
    let cancelledResult = await cancelled.value

    XCTAssertEqual(thumbnailResult, "thumbnail")
    XCTAssertEqual(cancelledResult, "cancelled")
  }

  func testGalleryRequestSchedulerBlocksNonDownloadRequestsDuringPriorityDownload() async {
    let scheduler = CameraVendorGalleryRequestScheduler()
    scheduler.beginPriorityDownloadBarrier()
    var didRunThumbnail = false

    let thumbnail = Task { () -> String in
      do {
        return try await scheduler.run(priority: .visibleThumbnail) {
          didRunThumbnail = true
          return "thumbnail"
        }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(didRunThumbnail)

    scheduler.endPriorityDownloadBarrier()
    let result = await thumbnail.value

    XCTAssertEqual(result, "thumbnail")
    XCTAssertTrue(didRunThumbnail)
  }

  func testGalleryRequestSchedulerAllowsDownloadRequestsDuringPriorityDownloadBarrier() async {
    let scheduler = CameraVendorGalleryRequestScheduler()
    scheduler.beginPriorityDownloadBarrier()

    let result = try? await scheduler.run(priority: .downloadOriginal) {
      "download"
    }

    scheduler.endPriorityDownloadBarrier()
    XCTAssertEqual(result, "download")
  }

  func testCameraVendorPlaceholderObjectInfoUsesUndefinedFormatLikeAndroid() {
    let info = CameraVendorCameraObjectInfo.placeholder(handle: 10)

    XCTAssertEqual(info.formatCode, 0x3000)
    XCTAssertEqual(info.filename, "0x0000000A")
    XCTAssertFalse(info.hasResolvedFormat)
  }

  func testGalleryFastInitialLoadAssignsDateGroupsToPlaceholdersLikeAndroid() {
    let groups = [
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260624", objectCount: 2),
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260623", objectCount: 1),
    ]

    let items = CameraVendorGalleryFastInitialLoadPolicy.placeholderItems(
      from: [100, 102, 101],
      dateGroups: groups
    )
    let sections = NativeGallerySectionPolicy.sections(
      from: items,
      now: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12))!,
      calendar: Calendar(identifier: .gregorian)
    )

    XCTAssertEqual(items.map(\.handle), [100, 102, 101])
    XCTAssertEqual(items.map(\.captureDate), ["20260624", "20260624", "20260623"])
    XCTAssertEqual(sections.map(\.title), ["今天 6月24日 2 张", "6月23日 1 张"])
    XCTAssertEqual(sections.map { $0.items.map(\.handle) }, [[100, 102], [101]])
  }

  func testGalleryInitialItemsPreserveD621OrderInsteadOfSortingByHandle() {
    let infos = [
      CameraVendorCameraObjectInfo.placeholder(handle: 1267, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1268, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1265, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1266, captureDate: "20260426"),
    ]

    let items = CameraVendorGalleryItemOrderingPolicy.galleryItems(
      from: infos,
      preserveInputOrder: true
    )

    XCTAssertEqual(items.map(\.handle), [1267, 1268, 1265, 1266])
  }

  func testCameraVendorGalleryItemOrderingCarriesObjectOrientation() {
    let info = CameraVendorCameraObjectInfo(
      handle: 77,
      storageID: 0x00010001,
      formatCode: 0x3801,
      compressedSize: 4_000_000,
      thumbCompressedSize: 80_000,
      filename: "DSCF0077.JPG",
      captureDate: "2026:06:24 10:10:10",
      orientation: 2
    )

    let items = CameraVendorGalleryItemOrderingPolicy.galleryItems(from: [info])

    XCTAssertEqual(items.first?.orientation, 2)
  }

  func testNativeGalleryMetadataMergePreservesInitialDateGroupWhenResolvedDateIsMissingOrWrong() {
    let existing = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let missingDate = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: "4 MB"
    )
    let sameDayWithTime = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB"
    )
    let wrongDay = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:23 10:11:12",
      byteSizeText: "4 MB"
    )

    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: missingDate).captureDate,
      "20260624"
    )
    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: sameDayWithTime).captureDate,
      "2026:06:24 10:11:12"
    )
    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: wrongDay).captureDate,
      "20260624"
    )
  }

  func testNativeGalleryMetadataMergeReplacesUnresolvedPlaceholderWithRawAndHeifMetadata() {
    let placeholder = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      thumbnailData: Data([0xFF, 0xD8, 0xFF])
    )
    let raw = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "42 MB"
    )
    let heif = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:06:24 10:12:12",
      byteSizeText: "6 MB"
    )

    let mergedRaw = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: raw)
    let mergedHeif = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: nil, resolvedItem: heif)

    XCTAssertEqual(mergedRaw.filename, "DSCF0001.RAF")
    XCTAssertEqual(mergedRaw.formatLabel, "RAW")
    XCTAssertEqual(mergedRaw.thumbnailData, placeholder.thumbnailData)
    XCTAssertEqual(mergedHeif.filename, "DSCF0002.HEIC")
    XCTAssertEqual(mergedHeif.formatLabel, "HEIF")
  }

  func testNativeGalleryMetadataMergeClearsAmbiguousHintsWhenFormatResolves() {
    let placeholder = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let raw = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "42 MB"
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: raw)

    XCTAssertEqual(merged.formatLabel, "RAW")
    XCTAssertTrue(merged.formatHints.isEmpty)
    XCTAssertEqual(
      NativeGalleryFilterPolicy.filteredItems(
        [merged],
        state: NativeGalleryFilterState(format: .heif),
        now: Date(timeIntervalSince1970: 0)
      ),
      []
    )
  }

  func testNativeGalleryMetadataMergeUpdatesOrientationFromResolvedMetadata() {
    let placeholder = CameraVendorGalleryItem(
      handle: 8,
      filename: "0x00000008",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      orientation: nil,
      thumbnailData: Data([0xFF, 0xD8])
    )
    let resolved = CameraVendorGalleryItem(
      handle: 8,
      filename: "DSCF0008.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB",
      orientation: 4
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: resolved)

    XCTAssertEqual(merged.orientation, 4)
    XCTAssertEqual(merged.thumbnailData, Data([0xFF, 0xD8]))
  }

  func testNativeGalleryMetadataMergePreservesExistingHandleOrderForBackgroundBatches() {
    let first = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let second = CameraVendorGalleryItem(
      handle: 2,
      filename: "0x00000002",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let third = CameraVendorGalleryItem(
      handle: 3,
      filename: "0x00000003",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let resolvedSecond = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:06:24 10:12:12",
      byteSizeText: "6 MB"
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItemsPreservingExistingOrder(
      existingItems: [first, second, third],
      resolvedItems: [resolvedSecond]
    )

    XCTAssertEqual(merged.map(\.handle), [1, 2, 3])
    XCTAssertEqual(merged[1].filename, "DSCF0002.HEIC")
    XCTAssertEqual(merged[1].formatLabel, "HEIF")
  }

  func testGalleryFastInitialLoadPublishesIncrementalMetadataLikeAndroid() {
    XCTAssertEqual(CameraVendorGalleryFastInitialLoadPolicy.incrementalMetadataBatchSize, 12)
    XCTAssertTrue(
      CameraVendorGalleryFastInitialLoadPolicy.shouldPublishIncrementalMetadataBatch(
        resolvedCount: 12,
        isFinalBatch: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryFastInitialLoadPolicy.shouldPublishIncrementalMetadataBatch(
        resolvedCount: 11,
        isFinalBatch: false
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryFastInitialLoadPolicy.shouldPublishIncrementalMetadataBatch(
        resolvedCount: 1,
        isFinalBatch: true
      )
    )
  }

  func testNativeGalleryBackgroundMetadataUIRefreshPolicyUsesVisibleOnlyForDefaultAndroidGallery() {
    XCTAssertTrue(NativeGalleryBackgroundMetadataUIRefreshPolicy.shouldApplyPublishedAndroidBatchImmediately)
    XCTAssertTrue(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState()
      )
    )

    XCTAssertFalse(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState(format: .heif)
      )
    )

    XCTAssertFalse(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState(sort: .oldest)
      )
    )
  }

  func testGalleryFastInitialLoadRunsHiddenStillProbeBeforeFullObjectInfoLoop() throws {
    XCTAssertTrue(CameraVendorGalleryFastInitialLoadPolicy.shouldResolveHiddenStillFormatsBeforeFullObjectInfo)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let scheduler = try XCTUnwrap(source.range(of: "private func scheduleFullObjectInfoRefreshAfterInitialPlaceholders"))
    let schedulerSource = String(source[scheduler.lowerBound...])
    let hiddenProbe = try XCTUnwrap(schedulerSource.range(of: "GALLERY_BACKGROUND_HIDDEN_STILL_BEGIN"))
    let fullLoop = try XCTUnwrap(schedulerSource.range(of: "for handle in metadataHandles"))

    XCTAssertLessThan(hiddenProbe.lowerBound, fullLoop.lowerBound)
  }

  func testRealtimeGalleryServicePublishesFastInitialHandlesBeforeFullObjectInfoFallback() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let fastInitialStart = try XCTUnwrap(source.range(of: "let fastInitialInfos = try self.session.fastInitialGalleryObjectInfos()")?.lowerBound)
    let fallbackStart = try XCTUnwrap(source.range(of: "let infos = try self.session.galleryObjectInfos()", range: fastInitialStart..<source.endIndex)?.lowerBound)
    let fastInitialRegion = String(source[fastInitialStart..<fallbackStart])

    XCTAssertTrue(fastInitialRegion.contains(".filter { $0.handle != 0 }"))
    XCTAssertTrue(fastInitialRegion.contains("GALLERY_FAST_INITIAL_ITEMS count="))
    XCTAssertTrue(fastInitialRegion.contains("loadedItems = fastInitialItems"))
    XCTAssertTrue(fastInitialRegion.contains("GALLERY_FAST_INITIAL_ITEMS_REJECTED"))
    XCTAssertFalse(fastInitialRegion.contains("GALLERY_FAST_INITIAL_ITEMS_RECOVERED"))
  }

  func testHiddenStillBackgroundProbeSplitsGapAndForwardCandidatesLikeAndroid() {
    let gapCandidates = CameraVendorHiddenObjectHandleProbePolicy.backgroundHiddenHandleCandidates(
      from: [10, 12, 15]
    )
    let forwardCandidates = CameraVendorHiddenObjectHandleProbePolicy.forwardProbeCandidates(
      from: [10, 12, 15]
    )

    XCTAssertEqual(gapCandidates, [11, 13, 14])
    XCTAssertEqual(Array(forwardCandidates.prefix(5)), [16, 17, 18, 19, 20])
    XCTAssertEqual(forwardCandidates.count, 20)
    XCTAssertEqual(forwardCandidates.last, 35)
  }

  func testHiddenStillBackgroundGapProbeAbortsWhenGapCandidatesExceedAndroidLimit() {
    let handles = Array(stride(from: UInt32(100), through: UInt32(980), by: 9))

    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.backgroundHiddenHandleCandidates(from: handles),
      []
    )
  }

  func testHiddenStillBackgroundMetadataProbeFallsBackToRecentGapsWhenLargeRawOnlyListExceedsGapLimit() {
    let handles = Array(stride(from: UInt32(0x073D), through: UInt32(0x0601), by: -2))

    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.backgroundHiddenHandleCandidates(from: handles),
      []
    )
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.backgroundMetadataGapCandidateHandles(from: handles).prefix(6),
      [0x073C, 0x073A, 0x0738, 0x0736, 0x0734, 0x0732]
    )
  }

  func testRealtimeGalleryServiceCanPrepareForPriorityDownloads() {
    let service = CameraVendorRealtimeGalleryService()

    XCTAssertTrue(service is CameraVendorPriorityDownloadPreparing)
  }

  func testRealtimeGalleryServiceRejectsNewThumbnailsDuringPriorityDownload() async {
    let service = CameraVendorRealtimeGalleryService()
    service.prepareForPriorityDownload()

    do {
      _ = try await service.fetchThumbnail(for: 1)
      XCTFail("Expected thumbnail fetch to be suspended during priority download")
    } catch {
      let nsError = error as NSError
      XCTAssertEqual(nsError.domain, "CameraVendorRealtimeGalleryService")
      XCTAssertEqual(nsError.code, CameraVendorPriorityDownloadThumbnailGatePolicy.suspendedThumbnailErrorCode)
    }
  }

  func testRealtimeGalleryServiceUsesSchedulerBarrierForPriorityDownload() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let serviceStart = try XCTUnwrap(source.range(of: "final class CameraVendorRealtimeGalleryService")?.lowerBound)
    let prepareStart = try XCTUnwrap(source.range(of: "func prepareForPriorityDownload()", range: serviceStart..<source.endIndex)?.lowerBound)
    let finishStart = try XCTUnwrap(source.range(of: "func finishPriorityDownload()", range: prepareStart..<source.endIndex)?.lowerBound)
    let prepareBody = String(source[prepareStart..<finishStart])
    let finishEnd = try XCTUnwrap(source.range(of: "func beginVisibleThumbnailBatch", range: finishStart..<source.endIndex)?.lowerBound)
    let finishBody = String(source[finishStart..<finishEnd])

    XCTAssertTrue(prepareBody.contains("requestScheduler.beginPriorityDownloadBarrier()"))
    XCTAssertTrue(finishBody.contains("requestScheduler.endPriorityDownloadBarrier()"))
  }

  func testNativeGalleryThumbnailFailurePolicyRetriesInteractionAndDownloadPauses() {
    XCTAssertFalse(NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(CancellationError()))
    XCTAssertFalse(
      NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(
        NSError(
          domain: "CameraVendorRealtimeGalleryService",
          code: CameraVendorPriorityDownloadThumbnailGatePolicy.suspendedThumbnailErrorCode
        )
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(
        NSError(domain: "CameraVendorPtpSession", code: 0x100A)
      )
    )
  }

  func testPriorityDownloadOnlyInterruptsWhenThumbnailRequestIsInFlight() {
    XCTAssertTrue(
      NativeGalleryPriorityDownloadPolicy.shouldInterruptPtpBeforeDownload(
        isThumbnailRequestInFlight: true
      )
    )
    XCTAssertFalse(
      NativeGalleryPriorityDownloadPolicy.shouldInterruptPtpBeforeDownload(
        isThumbnailRequestInFlight: false
      )
    )
  }

  func testPreviewThumbnailPolicyPausesWhileDownloading() {
    XCTAssertFalse(NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(isDownloading: true))
    XCTAssertTrue(NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(isDownloading: false))
  }

  func testNativeGalleryStartDownloadOpensDownloadCenterBeforeTransferLoop() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private func startDownload(for handles: [Int])")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "/// One worker loop", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])
    let setDownloading = try XCTUnwrap(body.range(of: "isDownloading = true")?.lowerBound)
    let openDownloads = try XCTUnwrap(body.range(of: "showDownloadListForCurrentTasks()", range: setDownloading..<body.endIndex)?.lowerBound)
    let transferLoop = try XCTUnwrap(body.range(of: "Task { @MainActor")?.lowerBound)

    XCTAssertLessThan(setDownloading, openDownloads)
    XCTAssertLessThan(openDownloads, transferLoop)
  }

  func testNativeGalleryDownloadCompletionUnlocksGalleryAndRefreshesDownloadCenter() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private func startDownload(for handles: [Int])")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "/// One worker loop", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])
    let clearDownloading = try XCTUnwrap(body.range(of: "isDownloading = false")?.lowerBound)
    let unlockNavigation = try XCTUnwrap(
      body.range(of: "updateNavigationLock()", range: clearDownloading..<body.endIndex)?.lowerBound
    )
    let refreshStatus = try XCTUnwrap(
      body.range(of: "refreshStatusText()", range: clearDownloading..<body.endIndex)?.lowerBound
    )
    let notifyDownloads = try XCTUnwrap(
      body.range(of: "notifyDownloadStateChanged()", range: clearDownloading..<body.endIndex)?.lowerBound
    )
    let reloadThumbnails = try XCTUnwrap(
      body.range(of: "loadVisibleThumbnails()", range: clearDownloading..<body.endIndex)?.lowerBound
    )

    XCTAssertLessThan(clearDownloading, refreshStatus)
    XCTAssertLessThan(clearDownloading, unlockNavigation)
    XCTAssertLessThan(unlockNavigation, refreshStatus)
    XCTAssertLessThan(refreshStatus, notifyDownloads)
    XCTAssertLessThan(notifyDownloads, reloadThumbnails)
  }

  func testNativeGalleryDownloadPauseClearsPendingQueueWithoutPerItemLockChecks() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let pauseStart = try XCTUnwrap(source.range(of: "private func requestPauseDownload()")?.lowerBound)
    let pauseEnd = try XCTUnwrap(source.range(of: "private func startDownload(for handles: [Int])", range: pauseStart..<source.endIndex)?.lowerBound)
    let pauseBody = String(source[pauseStart..<pauseEnd])
    XCTAssertNotNil(pauseBody.range(of: "isDownloadPauseRequested = true"))
    XCTAssertNotNil(pauseBody.range(of: "galleryState.pauseQueuedDownloads()"))
    XCTAssertNotNil(pauseBody.range(of: "showDownloadListForCurrentTasks()"))

    let start = try XCTUnwrap(source.range(of: "private func startDownload(for handles: [Int])")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "/// One worker loop", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])
    let resetPause = try XCTUnwrap(body.range(of: "isDownloadPauseRequested = false")?.lowerBound)
    let setDownloading = try XCTUnwrap(body.range(of: "isDownloading = true", range: resetPause..<body.endIndex)?.lowerBound)
    let clearDownloading = try XCTUnwrap(body.range(of: "isDownloading = false", range: setDownloading..<body.endIndex)?.lowerBound)
    let clearPause = try XCTUnwrap(body.range(of: "isDownloadPauseRequested = false", range: clearDownloading..<body.endIndex)?.lowerBound)
    let conditionalPauseCleanup = try XCTUnwrap(
      body.range(of: "if isDownloadPauseRequested", range: setDownloading..<clearDownloading)?.lowerBound
    )
    let pauseCleanup = try XCTUnwrap(
      body.range(
        of: "pausedHandles = galleryState.pauseQueuedDownloads()",
        range: conditionalPauseCleanup..<clearDownloading
      )?.lowerBound
    )

    XCTAssertLessThan(resetPause, setDownloading)
    XCTAssertLessThan(setDownloading, clearDownloading)
    XCTAssertLessThan(conditionalPauseCleanup, pauseCleanup)
    XCTAssertLessThan(pauseCleanup, clearDownloading)
    XCTAssertLessThan(clearDownloading, clearPause)
    XCTAssertNil(body.range(of: "guard !isDownloadPauseRequested else { break }"))

    let workerStart = try XCTUnwrap(source.range(of: "fileprivate func runSafeDownloadLoop")?.lowerBound)
    let workerEnd = try XCTUnwrap(source.range(of: "fileprivate enum CameraVendorDownloadedFileDiagnostics", range: workerStart..<source.endIndex)?.lowerBound)
    let workerBody = String(source[workerStart..<workerEnd])
    XCTAssertNil(workerBody.range(of: "isDownloadPauseRequested"))
  }

  func testPartialObjectDownloadPolicyStopsAtExpectedSizeEvenForJpeg() {
    XCTAssertTrue(
      CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: 167_936,
        expectedBytes: 167_936,
        isJpegObject: true,
        hasJpegEndMarker: false
      )
    )
    XCTAssertFalse(
      CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: 64_000,
        expectedBytes: 167_936,
        isJpegObject: true,
        hasJpegEndMarker: false
      )
    )
  }

  func testCameraVendorCameraObjectInfoLabelsHeifFormat() {
    let info = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0x3812,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: "DSCF0001.HEIC",
      captureDate: ""
    )

    XCTAssertEqual(info.formatLabel, "HEIF")
  }

  func testCameraVendorCameraObjectInfoLabelsCameraVendorRawVariant() {
    let info = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0xB103,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: "DSCF0001.RAF",
      captureDate: ""
    )

    XCTAssertEqual(info.formatLabel, "RAW")
  }

  func testCameraVendorDualSlotStatusDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.dualSlotStatus, 0xD244)
    XCTAssertEqual(CameraVendorDevicePropCode.dualSlotStatus, CameraVendorDevicePropCode.referenceAppGalleryAccessState)
  }

  func testCameraVendorDualSlotProbePolicyUsesReferenceAppAlternateSlotStatuses() {
    XCTAssertEqual(CameraVendorDualSlotProbePolicy.alternateSlotStatuses(for: 1), [2])
    XCTAssertEqual(CameraVendorDualSlotProbePolicy.alternateSlotStatuses(for: 2), [1])
    XCTAssertEqual(CameraVendorDualSlotProbePolicy.alternateSlotStatuses(for: nil), [])
    XCTAssertTrue(CameraVendorDualSlotProbePolicy.shouldProbeAlternateSlots(currentObjectCount: 2))
    XCTAssertFalse(CameraVendorDualSlotProbePolicy.shouldProbeAlternateSlots(currentObjectCount: 3))
  }

  func testCameraVendorSpecifiedObjectCountDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.specifiedObjectCount, 0xD620)
  }

  func testCameraVendorSpecifiedObjectHandlesDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.specifiedObjectHandles, 0xD621)
  }

  func testCameraVendorSpecifiedObjectHandlesParserReadsCountPrefixedHandles() {
    let data = Data([
      0x02, 0x00, 0x00, 0x00,
      0xCA, 0x03, 0x00, 0x00,
      0xC9, 0x03, 0x00, 0x00,
    ])

    XCTAssertEqual(CameraVendorPtpDataParser.uint32Array(from: data), [0x000003CA, 0x000003C9])
  }

  func testCameraVendorSpecifiedObjectCountGroupByDateParserReadsDateGroups() {
    let data = Data([
      0x02, 0x00, 0x00, 0x00,
      0x1B, 0x00, 0x00, 0x00,
      0x09, 0x32, 0x00, 0x30, 0x00, 0x32, 0x00, 0x36, 0x00, 0x30, 0x00,
      0x35, 0x00, 0x30, 0x00, 0x34, 0x00, 0x00, 0x00,
      0x07, 0x00, 0x00, 0x00,
      0x1B, 0x00, 0x00, 0x00,
      0x09, 0x32, 0x00, 0x30, 0x00, 0x32, 0x00, 0x36, 0x00, 0x30, 0x00,
      0x35, 0x00, 0x31, 0x00, 0x30, 0x00, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x00,
    ])

    let groups = CameraVendorPtpDataParser.specifiedObjectDateGroups(from: data)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[0].dateText, "20260504")
    XCTAssertEqual(groups[0].objectCount, 7)
    XCTAssertEqual(groups[1].dateText, "20260510")
    XCTAssertEqual(groups[1].objectCount, 3)
  }

  func testCameraVendorForwardObjectHandleProbePolicyProbesAfterOldSingleDateGroup() {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 5
    components.day = 10
    let today = components.date!
    let oldGroup = CameraVendorSpecifiedObjectDateGroup(dateText: "20260504", objectCount: 7)

    XCTAssertTrue(
      CameraVendorForwardObjectHandleProbePolicy.shouldProbeAfterSpecifiedList(
        dateGroups: [oldGroup],
        now: today,
        calendar: components.calendar!
      )
    )
    XCTAssertEqual(
      Array(CameraVendorForwardObjectHandleProbePolicy.candidateHandles(after: [2, 12, 34]).prefix(3)),
      [35, 36, 37]
    )
  }

  func testCameraVendorForwardObjectHandleProbePolicyDoesNotSkipWhenSpecifiedDateIncludesToday() {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 5
    components.day = 10
    let today = components.date!
    let todayGroup = CameraVendorSpecifiedObjectDateGroup(dateText: "20260510", objectCount: 3)

    XCTAssertTrue(
      CameraVendorForwardObjectHandleProbePolicy.shouldProbeAfterSpecifiedList(
        dateGroups: [todayGroup],
        now: today,
        calendar: components.calendar!
      )
    )
  }

  func testCameraVendorForwardObjectHandleProbePolicyDoesNotDependOnDateGroupParsing() {
    XCTAssertTrue(
      CameraVendorForwardObjectHandleProbePolicy.shouldProbeAfterSpecifiedList(dateGroups: [])
    )
  }

  func testCameraVendorLegacyGalleryPolicyContinuesHiddenProbeAfterForwardProbeFindsObjects() {
    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldReturnAfterForwardProbe(forwardInfoCount: 1)
    )
    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldReturnAfterForwardProbe(forwardInfoCount: 0)
    )
  }

  func testCameraVendorForwardObjectHandleProbePolicyShortensTailAfterFirstForwardObject() {
    XCTAssertEqual(
      CameraVendorForwardObjectHandleProbePolicy.failureLimit(hasFoundForwardObject: false),
      CameraVendorForwardObjectHandleProbePolicy.maxConsecutiveFailures
    )
    XCTAssertEqual(
      CameraVendorForwardObjectHandleProbePolicy.failureLimit(hasFoundForwardObject: true),
      3
    )
  }

  func testCameraVendorLegacyThumbnailPacketsUseAlternateDataAndResponseKinds() {
    XCTAssertEqual(CameraVendorLegacyPacketMapper.packetType(forKind: 21), CameraVendorPtpPacketType.dataPacket)
    XCTAssertEqual(CameraVendorLegacyPacketMapper.packetType(forKind: 12), CameraVendorPtpPacketType.operationResponse)
  }

  func testCameraVendorLegacyThumbnailCompletionPacketSynthesizesOkResponse() {
    let payload = Data([0x00, 0x00, 0x34, 0x12, 0x00, 0x00])

    XCTAssertEqual(
      CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: 12, body: payload),
      Data([0x01, 0x20, 0x34, 0x12, 0x00, 0x00])
    )
    XCTAssertEqual(CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: 3, body: payload), payload)
  }

  func testCameraVendorCompressionResetPayloadUsesUInt32Zero() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      transactionID: 14,
      data: Data([0x00, 0x00, 0x00, 0x00])
    )

    XCTAssertEqual(Array(data.suffix(4)), [0x00, 0x00, 0x00, 0x00])
  }

  func testCameraVendorInitSequencePayloadUsesUInt16Twenty() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      transactionID: 18,
      data: Data([0x14, 0x00])
    )

    XCTAssertEqual(Array(data.suffix(2)), [0x14, 0x00])
  }

  func testMtpGetObjectPropListOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.mtpGetObjectPropList, 0x9805)
  }

  func testCameraVendorGetSearchModeDescAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll, 0x9050)
  }

  func testCameraVendorGetSearchModeDescAllPacketHasNoParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll),
      transactionID: 11
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x50, 0x90,
        0x0B, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSearchModeAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll, 0x9052)
  }

  func testCameraVendorGetSearchModeAllPacketHasNoParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll),
      transactionID: 12
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x52, 0x90,
        0x0C, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSpecifiedObjectCountGroupByDateOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate, 0x9053)
  }

  func testCameraVendorGetExtensionThumbOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb, 0x9055)
  }

  func testCameraVendorGetExtensionThumbPacketMatchesReferenceAppCurrentHandle() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb),
      transactionID: 10,
      parameters: [CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x55, 0x90,
        0x0A, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x10,
      ]
    )
  }

  func testCameraVendorGetPartialObjectOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.getPartialObject, 0x101B)
  }

  func testCameraVendorGetPartialObjectPacketMatchesReferenceAppJpegParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      transactionID: 17,
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
      )
    )

    XCTAssertEqual(
      Array(data),
      [
        0x18, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x1B, 0x10,
        0x11, 0x00, 0x00, 0x00,
        0xCA, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00,
      ]
    )
  }

  func testCameraVendorGetExtensionPartialObjectOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetExtensionPartialObject, 0x9056)
  }

  func testCameraVendorGetExtensionPartialObjectPacketMatchesReferenceAppParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionPartialObject),
      transactionID: 16,
      parameters: CameraVendorPartialObjectRequestPolicy.extensionPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
      )
    )

    XCTAssertEqual(
      Array(data),
      [
        0x1C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x56, 0x90,
        0x10, 0x00, 0x00, 0x00,
        0xCA, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSpecifiedObjectCountGroupByDatePacketMatchesReferenceAppParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate),
      transactionID: 15,
      parameters: [0, 30000]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x14, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x53, 0x90,
        0x0F, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x30, 0x75, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorSetSearchModeAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll, 0x9051)
  }

  func testCameraVendorSetSearchModeAllEmptyPayloadMatchesReferenceAppResetLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      transactionID: 13,
      data: Data([0x00, 0x00, 0x00, 0x00])
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x02, 0x00,
        0x51, 0x90,
        0x0D, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorSetSearchModeAllObjectFormatPayloadIncludesAndroidAllFormats() {
    XCTAssertEqual(
      CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
        CameraVendorSearchModeAllPayload.allObjectFormatMask
      ),
      Data([
        0x01, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x04, 0xD6,
        0x1F, 0x00,
      ])
    )
  }

  func testMtpGetObjectPropListParametersMatchNativeSDKLayout() {
    XCTAssertEqual(
      CameraVendorPtpPacketBuilder.mtpObjectPropListParameters(
        objectHandle: UInt32(bitPattern: -1),
        propertyCode: CameraVendorDevicePropCode.currentObjectHandle
      ),
      [
        UInt32(bitPattern: -1),
        0,
        CameraVendorDevicePropCode.currentObjectHandle,
        0,
        0,
      ]
    )
  }

  func testReferenceAppFunctionVersionPolicyUsesPcapObservedRemotePhotoViewExVersion() {
    XCTAssertEqual(
      CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: Data([0x01, 0x00, 0x00, 0x00])),
      3
    )
    XCTAssertEqual(CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: Data()), 3)
  }

  func testReferenceAppRemoteImageViewerPolicyMatchesFudgeAndReferenceAppClientStates() {
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.cameraStateRemoteAccess, 6)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteModeClientState, 5)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState, 20)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite, 5)
  }

  func testReferenceAppReservedReceiveProbePolicyMatchesReferenceAppModeTwentyOne() {
    XCTAssertFalse(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldProbeDuringGalleryHandshake)
    XCTAssertTrue(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldUseSeparatePtpSession)
    XCTAssertFalse(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldExposeManualDiagnosticEntry)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState, 21)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite, 3)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle, 1)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.sampleReadBytes, CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize)
  }

  func testReservedReceiveDiagnosticResultSummarizesObjectInfoAndSampleBytes() {
    let objectInfo = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0x00010001,
      formatCode: 0x3812,
      compressedSize: 12_345_678,
      thumbCompressedSize: 0,
      filename: "DSCF0001.HEIF",
      captureDate: "2026:05:03 11:42:00"
    )
    let result = CameraVendorReservedReceiveDiagnosticResult(
      objectInfo: objectInfo,
      sampleByteCount: 16_384
    )

    XCTAssertTrue(result.summary.contains("DSCF0001.HEIF"))
    XCTAssertTrue(result.summary.contains("HEIF"))
    XCTAssertTrue(result.summary.contains("12.3 MB"))
    XCTAssertTrue(result.summary.contains("sample=16,384 bytes"))
  }

  func testCameraVendorRemoteImageViewerDevicePropCodesMatchOpenImplementations() {
    XCTAssertEqual(CameraVendorDevicePropCode.imageGetVersion, 0xDF21)
    XCTAssertEqual(CameraVendorDevicePropCode.getObjectVersion, 0xDF22)
    XCTAssertEqual(CameraVendorDevicePropCode.remoteGetObjectVersion, 0xDF25)
    XCTAssertEqual(CameraVendorDevicePropCode.referenceAppReservedReceive, 0xDF29)
  }

  func testPtpResponsePolicyRejectsOperationNotSupported() {
    XCTAssertThrowsError(
      try CameraVendorPtpResponsePolicy.validateOK(responseCode: 0x2005, operationName: "GetStorageIDs")
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("0x2005"))
      XCTAssertTrue(error.localizedDescription.contains("GetStorageIDs"))
    }
  }

  func testBackgroundKeepAliveUsesReferenceAppD212InsteadOfStorageIDs() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let keepAliveStart = try XCTUnwrap(source.range(of: "func keepAlive(readTimeout: TimeInterval = 3) throws")?.lowerBound)
    let nextMethodStart = try XCTUnwrap(source.range(of: "private func sendCommand(operationCode:", range: keepAliveStart..<source.endIndex)?.lowerBound)
    let keepAliveBody = String(source[keepAliveStart..<nextMethodStart])

    XCTAssertTrue(keepAliveBody.contains("referenceAppGalleryObjectContext"))
    XCTAssertFalse(keepAliveBody.contains("getStorageIDs"))
  }

  func testPtpSessionErrorPolicyDoesNotRetryGalleryNotReadyMarker() {
    let notReadyError = NSError(
      domain: "CameraVendorPtpSession",
      code: 0xD222,
      userInfo: [NSLocalizedDescriptionKey: "相机图库状态未 ready"]
    )

    XCTAssertFalse(CameraVendorRealtimeGalleryService.CameraVendorPtpSessionErrorPolicy.shouldRetry(notReadyError))
    XCTAssertTrue(
      CameraVendorRealtimeGalleryService.CameraVendorPtpSessionErrorPolicy.shouldRetry(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
      )
    )
  }

  func testPtpInitCommandPacketMatchesCameraVendorReferenceLayout() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(friendlyName: "CamTransfer")

    XCTAssertEqual(data.count, 82)
    XCTAssertEqual(
      Array(data.prefix(28)),
      [
        0x52, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xF2, 0xE4, 0x53, 0x8F,
        0xAD, 0xA5, 0x48, 0x5D,
        0x87, 0xB2, 0x7F, 0x0B,
        0xD3, 0xD5, 0xDE, 0xD0,
        0x00, 0x00, 0x00, 0x00,
      ]
    )

    let expectedNameBytes: [UInt8] = [
      0x43, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x54, 0x00,
      0x72, 0x00, 0x61, 0x00, 0x6E, 0x00, 0x73, 0x00,
      0x66, 0x00, 0x65, 0x00, 0x72, 0x00,
      0x00, 0x00,
    ]
    XCTAssertEqual(Array(data[28..<(28 + expectedNameBytes.count)]), expectedNameBytes)
    XCTAssertEqual(Array(data[(28 + expectedNameBytes.count)..<data.count]), Array(repeating: 0, count: 30))
  }

  func testOfficialGalleryPtpInitPolicyUsesOnlyCameraVendorLegacyVariants() {
    let variants = CameraVendorOfficialGalleryPtpInitPolicy.variants()

    XCTAssertEqual(
      variants.map(\.name),
      [
        "CameraVendor legacy + client IP GUID",
        "CameraVendor legacy",
      ]
    )
    XCTAssertEqual(variants.map(\.includesClientIP), [true, false])
    XCTAssertFalse(variants.map(\.name).contains { $0.contains("PTP/IP standard") })
  }

  func testOfficialGalleryPtpInitPolicyBuildsOnlyLegacyInitPackets() {
    let attempts = CameraVendorOfficialGalleryPtpInitPolicy.initAttempts(
      clientName: "CamTransfer",
      clientIP: "192.168.0.127"
    )

    XCTAssertEqual(attempts.map(\.name), [
      "CameraVendor legacy + client IP GUID",
      "CameraVendor legacy",
    ])
    XCTAssertEqual(
      attempts[0].packet,
      CameraVendorPtpPacketBuilder.buildInitCommandRequest(
        friendlyName: "CamTransfer",
        clientIP: "192.168.0.127"
      )
    )
    XCTAssertEqual(
      attempts[1].packet,
      CameraVendorPtpPacketBuilder.buildInitCommandRequest(
        friendlyName: "CamTransfer",
        clientIP: nil
      )
    )
    XCTAssertFalse(
      attempts.contains {
        $0.packet == CameraVendorPtpPacketBuilder.buildStandardInitCommandRequest(
          friendlyName: "CamTransfer",
          clientIP: "192.168.0.127"
        )
      }
    )
  }

  func testStandardPtpIpInitCommandPacketUsesIsoFieldOrder() {
    let data = CameraVendorPtpPacketBuilder.buildStandardInitCommandRequest(friendlyName: "CamTransfer")

    XCTAssertEqual(
      Array(data.prefix(28)),
      [
        0x35, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xAD, 0xA5, 0x48, 0x5D,
        0x87, 0xB2, 0x7F, 0x0B,
        0xD3, 0xD5, 0xDE, 0xD0,
        0x00, 0x00, 0x00, 0x00,
        0x0C,
        0x43, 0x00, 0x61,
      ]
    )
    XCTAssertEqual(Array(data.suffix(4)), [0x00, 0x00, 0x01, 0x00])
  }

  func testPtpInitCommandCanIncludeClientIpInGuid() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(
      friendlyName: "CamTransfer",
      clientIP: "192.168.0.127"
    )

    XCTAssertEqual(Array(data[24..<28]), [0x7F, 0x00, 0xA8, 0xC0])
  }

  func testCameraWifiSubnetRecognizesOnlyCameraAssignedIp() {
    XCTAssertTrue(CameraVendorPtpConstants.isCameraWifiIPv4Address("192.168.0.122"))
    XCTAssertFalse(CameraVendorPtpConstants.isCameraWifiIPv4Address("192.168.3.28"))
    XCTAssertFalse(CameraVendorPtpConstants.isCameraWifiIPv4Address(nil))
  }

  func testPtpInitCommandIgnoresNonCameraSubnetClientIpInGuid() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(
      friendlyName: "CamTransfer",
      clientIP: "192.168.3.28"
    )

    XCTAssertEqual(Array(data[24..<28]), [0x00, 0x00, 0x00, 0x00])
  }

  func testPtpUInt32ArrayParserReadsCountedPayload() {
    let payload = Data([
      0x02, 0x00, 0x00, 0x00,
      0x11, 0x00, 0x00, 0x00,
      0x22, 0x00, 0x00, 0x00,
    ])

    XCTAssertEqual(CameraVendorPtpDataParser.uint32Array(from: payload), [17, 34])
  }

  func testPtpObjectInfoParserReadsFilenameAndDate() {
    var payload = Data()
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // storageId
    payload.append(contentsOf: [0x01, 0x38]) // JPEG
    payload.append(contentsOf: [0x00, 0x00]) // protection
    payload.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // size
    payload.append(contentsOf: [0x01, 0x38]) // thumb format
    payload.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // thumb size
    payload.append(contentsOf: [0x40, 0x00, 0x00, 0x00]) // thumb w
    payload.append(contentsOf: [0x30, 0x00, 0x00, 0x00]) // thumb h
    payload.append(contentsOf: [0x00, 0x04, 0x00, 0x00]) // image w
    payload.append(contentsOf: [0x00, 0x03, 0x00, 0x00]) // image h
    payload.append(contentsOf: [0x18, 0x00, 0x00, 0x00]) // depth
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // parent
    payload.append(contentsOf: [0x00, 0x00]) // assoc type
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // assoc desc
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // seq
    payload.append(ptpString("DSCF0001.JPG"))
    payload.append(ptpString("2026:04:26 17:00:00"))

    let info = CameraVendorPtpDataParser.objectInfo(handle: 99, data: payload)

    XCTAssertEqual(info.handle, 99)
    XCTAssertEqual(info.filename, "DSCF0001.JPG")
    XCTAssertEqual(info.captureDate, "2026:04:26 17:00:00")
    XCTAssertEqual(info.formatCode, 0x3801)
  }

  func testCameraVendorObjectInfoParserReadsOrientationMetadataAfterCaptureDate() {
    var payload = Data()
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x10]) // storage
    payload.append(contentsOf: [0x01, 0x38]) // JPEG
    payload.append(contentsOf: [0x00, 0x00]) // protection
    payload.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // size
    payload.append(contentsOf: [0x01, 0x38]) // thumb format
    payload.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // thumb size
    payload.append(contentsOf: [0x40, 0x00, 0x00, 0x00]) // thumb w
    payload.append(contentsOf: [0x30, 0x00, 0x00, 0x00]) // thumb h
    payload.append(contentsOf: [0x00, 0x04, 0x00, 0x00]) // image w
    payload.append(contentsOf: [0x00, 0x03, 0x00, 0x00]) // image h
    payload.append(contentsOf: [0x18, 0x00, 0x00, 0x00]) // depth
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // parent
    payload.append(contentsOf: [0x00, 0x00]) // assoc type
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // assoc desc
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // seq
    payload.append(ptpString("DSCF0001.JPG"))
    payload.append(ptpString("2026:04:26 17:00:00"))
    payload.append(ptpString("Orientation:6"))

    let info = CameraVendorPtpDataParser.objectInfo(handle: 99, data: payload)

    XCTAssertEqual(info.orientation, 2)
  }

  func testCameraVendorVendorObjectInfoParserReadsReferenceAppLayout() {
    let payload = Data([
      0x01, 0x00, 0x00, 0x10, 0x12, 0x38, 0x00, 0x00,
      0x07, 0xB1, 0x0D, 0x00, 0x01, 0xB9, 0x80, 0xCB,
      0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0xE0, 0x01,
      0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, 0x20, 0x14,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]) + ptpString("DSCF3309.HEIC") + ptpString("20260328T045849") + ptpString("Orientation:1")

    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: 0x10000001, data: payload)

    XCTAssertEqual(info.handle, 0x10000001)
    XCTAssertEqual(info.filename, "DSCF3309.HEIC")
    XCTAssertEqual(info.captureDate, "20260328T045849")
    XCTAssertEqual(info.formatCode, 0x3812)
    XCTAssertEqual(info.compressedSize, 897287)
    XCTAssertEqual(info.orientation, 1)
  }

  func testCameraVendorVendorObjectInfoParserNormalizesReferenceAppOrientation() {
    let payload = Data([
      0x01, 0x00, 0x00, 0x10, 0x12, 0x38, 0x00, 0x00,
      0x07, 0xB1, 0x0D, 0x00, 0x01, 0xB9, 0x80, 0xCB,
      0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0xE0, 0x01,
      0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, 0x20, 0x14,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]) + ptpString("DSCF3309.HEIC") + ptpString("20260328T045849") + ptpString("Orientation:8")

    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: 0x10000001, data: payload)

    XCTAssertEqual(info.orientation, 4)
  }

  func testReferenceAppGalleryContextParserReadsD222Value() {
    let referenceAppReadyContext = Data([
      0x02, 0x00, 0x00, 0xDF,
      0x14, 0x00, 0x00, 0x00,
      0x22, 0xD2, 0x92, 0x09, 0x00, 0x00,
    ])
    let notReadyContext = Data([
      0x02, 0x00, 0x00, 0xDF,
      0x14, 0x00, 0x00, 0x00,
      0x22, 0xD2, 0x02, 0x00, 0x00, 0x00,
    ])

    XCTAssertEqual(
      CameraVendorPtpDataParser.cameraVendorGalleryContextValue(for: 0xD222, in: referenceAppReadyContext),
      0x0992
    )
    XCTAssertEqual(
      CameraVendorPtpDataParser.cameraVendorGalleryContextValue(for: 0xD222, in: notReadyContext),
      0x0002
    )
  }

  func testReferenceAppGalleryReadyPolicyAllowsProbeThroughNotReadyMarker() {
    XCTAssertFalse(CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: 0x0002))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: 0x0993))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: 0x0002))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: UInt32?.none))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: 0x0992))
  }

  func testReferenceAppGalleryReadyPollingPolicyWaitsBeforeListRequests() {
    XCTAssertEqual(CameraVendorReferenceAppGalleryReadyPollingPolicy.maxAttempts, 6)
    XCTAssertEqual(CameraVendorReferenceAppGalleryReadyPollingPolicy.delaySeconds, 0.5)
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPollingPolicy.shouldPoll(marker: 0x0011, attempt: 1))
    XCTAssertFalse(CameraVendorReferenceAppGalleryReadyPollingPolicy.shouldPoll(marker: 0x0993, attempt: 1))
    XCTAssertFalse(CameraVendorReferenceAppGalleryReadyPollingPolicy.shouldPoll(marker: 0x0011, attempt: 6))
  }

  func testConnectionSummaryDoesNotGenerateCameraWifiCandidatesWithoutOfficialCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiCandidates.isEmpty)
  }

  func testConnectionSummaryDoesNotUseDeviceNameAsWifiFallbackWhenNameContainsSerialSuffix() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A-003B",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiCandidates.isEmpty)
  }

  func testReferenceAppWifiNetworkDecoderReadsVisibleSsidPassphraseAndBssid() {
    let credentials = CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(
      from: [
        CameraVendorReferenceAppNetworkConfigDecoder.ssidCharacteristicUUIDString:
          Data("CAMERA-DEVICE-A-003B".utf8),
        CameraVendorReferenceAppNetworkConfigDecoder.passphraseCharacteristicUUIDString:
          Data("uQMggJcFEEBhCDjgkww0".utf8),
        CameraVendorReferenceAppNetworkConfigDecoder.macAddressCharacteristicUUIDString:
          Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
      ]
    )

    XCTAssertEqual(
      credentials,
      CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
  }

  func testConnectionSummaryPrefersBleReportedWifiConfiguration() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true
      )
    )

    XCTAssertEqual(
      summary.wifiConfigurations,
      [
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "uQMggJcFEEBhCDjgkww0",
          isHidden: true
        )
      ]
    )
  }

  func testOfficialImportImageTransferPlanUsesLaunchRequestCharacteristic() {
    let previousPreference = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = true
    defer {
      CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = previousPreference
    }

    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .officialImportImage
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
          payload: Data([0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
          payload: Data([0x01])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
          payload: CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
          payload: Data([0x03, 0x00])
        )
      ]
    )
  }

  func testOfficialImportImageActivationIgnoresDownloadCompressionPreference() {
    let previousPreference = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
    defer {
      CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = previousPreference
    }

    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = false
    let originalModeWrites = CameraVendorReferenceAppTransferActivationPlan.writes(for: .officialImportImage)

    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = true
    let compressedModeWrites = CameraVendorReferenceAppTransferActivationPlan.writes(for: .officialImportImage)

    XCTAssertEqual(originalModeWrites, compressedModeWrites)
    XCTAssertEqual(
      compressedModeWrites.first {
        $0.characteristicUUIDString == CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString
      }?.payload,
      CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
    )
  }

  func testBleStateSamplingPlanIsDisabledForCleanImportAttempt() {
    XCTAssertEqual(CameraVendorBleStateSamplingPlan.sampleDelaysSeconds, [])
    XCTAssertEqual(CameraVendorBleStateSamplingPlan.characteristicUUIDStrings, [])
    XCTAssertFalse(CameraVendorBleStateSamplingPlan.shouldDelayGalleryUntilSamplingCompletes)
  }

  func testReservedImageReceiveStateProbePlanIsDisabledForCleanImportAttempt() {
    XCTAssertEqual(CameraVendorReservedImageReceiveStateProbePlan.writeRequests, [])
  }

  func testOfficialImportImageTransferPlanTracksApStateCharacteristic() {
    XCTAssertEqual(
      CameraVendorReferenceAppTransferActivationPlan.trackedStatusCharacteristicUUIDStrings(
        for: .officialImportImage
      ),
      [
        CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
      ]
    )
  }

  func testOfficialImportImageTreatsAnyLaunchedApStateAsGalleryWifiReady() {
    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x00, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x03, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .officialImportImage
      )
    )
  }

  func testAutoImageImportReadinessRequiresReservedApAndTransferableState() {
    XCTAssertTrue(
      CameraVendorReferenceAppAutoImageImportReadinessPolicy.isReady(
        apStateData: Data([0x03, 0x80]),
        transferStateData: Data([0x01, 0x80])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppAutoImageImportReadinessPolicy.isReady(
        apStateData: Data([0x01, 0x80]),
        transferStateData: Data([0x01, 0x80])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppAutoImageImportReadinessPolicy.isReady(
        apStateData: Data([0x03, 0x80]),
        transferStateData: Data([0x00, 0x80])
      )
    )
  }

  func testAutoImageImportSummaryKeepsGalleryAsDefaultMode() {
    let gallerySummary = CameraVendorConnectionSummary(deviceName: "DEVICE-A", serialNumber: "1234")
    let autoSummary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "1234",
      transferMode: .autoImageImport
    )

    XCTAssertEqual(gallerySummary.transferMode, .gallery)
    XCTAssertEqual(autoSummary.transferMode, .autoImageImport)
    XCTAssertTrue(autoSummary.subtitle.contains("自动接收"))
  }

  func testConnectionSummaryCapturesTransferSizeModeAtActivation() {
    let defaultSummary = CameraVendorConnectionSummary(deviceName: "DEVICE-A", serialNumber: "1234")
    let originalSummary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "1234",
      preferCompressedDownloads: false
    )

    XCTAssertTrue(defaultSummary.preferCompressedDownloads)
    XCTAssertEqual(defaultSummary.activeTransferDownloadMode, .compressed)
    XCTAssertFalse(originalSummary.preferCompressedDownloads)
    XCTAssertEqual(originalSummary.activeTransferDownloadMode, .original)
  }

  func testNativeLogTextPolicyTrimsLongLiveText() {
    let longText = String(repeating: "a", count: NativeLogTextViewPolicy.maxDisplayedCharacters + 50)
    let rendered = NativeLogTextViewPolicy.appending("next", to: longText)

    XCTAssertLessThanOrEqual(rendered.count, NativeLogTextViewPolicy.maxDisplayedCharacters + 4)
    XCTAssertTrue(rendered.hasPrefix("...\n"))
    XCTAssertTrue(rendered.hasSuffix("next"))
  }

  func testNativeLogTextPolicySkipsInvisibleLiveTextViews() {
    XCTAssertFalse(
      NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: .active,
        hasWindow: true,
        visibleHeight: 0
      )
    )
    XCTAssertTrue(
      NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: .active,
        hasWindow: true,
        visibleHeight: 12
      )
    )
  }

  func testNativeGalleryGridLayoutUsesThreeColumnsOnPhone() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.columnCount(forCollectionWidth: 390),
      3
    )
  }

  func testNativeGalleryGridLayoutUsesFourColumnsOnWideScreens() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.columnCount(forCollectionWidth: 768),
      4
    )
  }

  func testNativeGalleryGridLayoutAllowsAndroidPinchRangeTwoThroughSix() {
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(1), 2)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(2), 2)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(6), 6)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(7), 6)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.androidGridSpacing, 2)
  }

  func testNativeGalleryGridLayoutComputesSquareItemSide() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.itemSide(
        forCollectionWidth: 390,
        horizontalInset: 12,
        interItemSpacing: 8
      ),
      116,
      accuracy: 0.001
    )
  }

  func testTransferActivationStatePolicyHandlesDuplicateReadyApState() {
    XCTAssertTrue(
      CameraVendorTransferActivationStateUpdatePolicy.shouldHandleTrackedStatusUpdate(
        previousValue: Data([0x01, 0x80]),
        newValue: Data([0x01, 0x80]),
        isReadyToJoinWifi: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationStateUpdatePolicy.shouldHandleTrackedStatusUpdate(
        previousValue: Data([0x00, 0x80]),
        newValue: Data([0x00, 0x80]),
        isReadyToJoinWifi: false
      )
    )
  }

  func testPreferredImageTransferPlanUsesReferenceAppRemoteImageViewModeFallback() {
    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .preferredRemoteImageView
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
          payload: Data([0x02, 0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
          payload: Data([0x14, 0x00, 0x00, 0x00])
        )
      ]
    )
  }

  func testCompatibleImageTransferPlanUsesLegacyRemoteImageViewMode() {
    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .compatibleRemoteImageView
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
          payload: Data([0x02, 0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
          payload: Data([0x0B, 0x00, 0x00, 0x00])
        )
      ]
    )
  }

  func testTransferActivationOnlyExposesOfficialImportImage() {
    let strategies = CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
      forAvailableCharacteristicUUIDStrings: [
        CameraVendorReferenceAppTransferActivationPlan.connectedDeviceImageReceiveStateCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
      ]
    )

    XCTAssertEqual(strategies, [.officialImportImage])
  }

  func testLegacyTransferDoesNotTreatNotLaunchedApStateAsWifiReady() {
    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x00, 0x80]),
        for: .preferredRemoteImageView
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .preferredRemoteImageView
      )
    )
  }

  func testTransferActivationRecognizesActionCommandCharacteristic() {
    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.connectedDeviceImageReceiveStateCharacteristicUUIDString
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString
      )
    )
  }

  func testTransferActivationRecognizesModeCommandCharacteristic() {
    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString
      )
    )
  }

  func testMainThreadDispatcherRunsImmediatelyOnMainThread() {
    var didRun = false

    CameraVendorMainThread.run {
      XCTAssertTrue(Thread.isMainThread)
      didRun = true
    }

    XCTAssertTrue(didRun)
  }

  func testMainThreadDispatcherHopsBackToMainThreadFromBackgroundQueue() {
    let callbackOnMain = expectation(description: "callback on main")

    DispatchQueue.global(qos: .userInitiated).async {
      CameraVendorMainThread.run {
        XCTAssertTrue(Thread.isMainThread)
        callbackOnMain.fulfill()
      }
    }

    wait(for: [callbackOnMain], timeout: 2.0)
  }

  func testGalleryFailureMessageIncludesDiagnostics() {
    let message = CameraVendorGalleryDiagnostics.composeFailureMessage(
      baseMessage: "无法连接相机网络",
      diagnostics: ["尝试连接 Wi-Fi: DEVICE-A-003B", "PTP 命令端口连接失败"]
    )

    XCTAssertTrue(message.contains("无法连接相机网络"))
    XCTAssertTrue(message.contains("尝试连接 Wi-Fi: DEVICE-A-003B"))
    XCTAssertTrue(message.contains("PTP 命令端口连接失败"))
  }

  func testGalleryFailureBaseMessageDoesNotBlameWifiAfterVerifiedHandoff() {
    let message = CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
      errorDescription: "读取失败: Socket is not connected",
      didCompleteWifiHandoff: true
    )

    XCTAssertTrue(message.contains("相机 Wi-Fi 已连接"))
    XCTAssertTrue(message.contains("PTP/相册初始化失败"))
    XCTAssertFalse(message.contains("请先让 iPhone 连上相机 Wi"))
  }

  func testConnectionSummaryPrefersHiddenWifiCandidateFirst() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "CAMERA-DEVICE-A",
      serialNumber: "1234003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "secret123",
        isHidden: true
      )
    )

    XCTAssertEqual(
      summary.wifiConfigurations,
      [
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "secret123",
          isHidden: true
        )
      ]
    )
  }

  func testGalleryAssociationPreflightSkipsJoinWhenAlreadyOnCameraWifi() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: "CAMERA-DEVICE-A-003B",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: false
      )
    )
  }

  func testGalleryAssociationPreflightDoesNotSkipJoinWhenOnlyPtpIsReachableWithoutSSID() {
    XCTAssertFalse(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: nil,
        wifiConfigurations: [],
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryAssociationPreflightDoesNotSkipJoinWhenWifiAndPtpAbsent() {
    XCTAssertFalse(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: "Home WiFi",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: false
      )
    )
  }

  func testGalleryAssociationPreflightConfirmsCameraWifiFromSubnetWithoutSSID() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
        currentSSID: nil,
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryAssociationPreflightAllowsUnchangedCameraSubnetDuringManualRecovery() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: nil,
        currentIP: "192.168.0.114",
        manualPromptBaselineIP: "192.168.0.114",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ]
      )
    )
  }

  func testGalleryAssociationPreflightAllowsChangedCameraSubnetDuringManualRecovery() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: nil,
        currentIP: "192.168.0.2",
        manualPromptBaselineIP: "192.168.0.114",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ]
      )
    )
  }

  func testWifiHandoffCompletionRequiresConcreteNetworkEvidence() {
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: true,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: true,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: true,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertTrue(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: true
      )
    )
  }

  func testPtpRouteStartRequiresCompletedWifiHandoffEvidence() {
    XCTAssertTrue(
      CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
        didCompleteWifiHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
        didCompleteWifiHandoff: false
      )
    )
  }

  func testRealtimeGalleryServiceHasHardGateBeforeStartingPtpRoute() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let handoffResult = try XCTUnwrap(source.range(of: "didCompleteWifiHandoff = CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff")?.lowerBound)
    let routeLoop = try XCTUnwrap(source.range(of: "for (routeIndex, route) in diagnosticRoutes.enumerated()", range: handoffResult..<source.endIndex)?.lowerBound)
    let guardedRegion = String(source[handoffResult..<routeLoop])

    XCTAssertTrue(guardedRegion.contains("CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute"))
    XCTAssertTrue(guardedRegion.contains("didCompleteWifiHandoff: didCompleteWifiHandoff"))
  }

  func testRealtimeGalleryServiceRunsPrePtpStepsThroughOfficialCoordinator() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let fetchGallery = try XCTUnwrap(source.range(of: "func fetchGallery() async throws")?.lowerBound)
    let waitForManualWifi = try XCTUnwrap(source.range(of: "private func waitForManualCameraWifiIfNeeded", range: fetchGallery..<source.endIndex)?.lowerBound)
    let body = String(source[fetchGallery..<waitForManualWifi])

    XCTAssertTrue(body.contains("IOSCameraGalleryConnectionCoordinator"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .reconnectPairedBle"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .transferAuthorization"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .activateCameraWifi"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .waitCameraWifiReady"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .joinCameraWifi"))
    XCTAssertTrue(body.contains("confirmedConnectionSteps = prePtpCoordinator.confirmedSteps()"))
    XCTAssertTrue(body.contains("confirmedConnectionSteps: confirmedConnectionSteps"))
    XCTAssertTrue(body.contains("IOS_OFFICIAL_GALLERY_PRE_PTP_CONFIRMED"))
  }

  func testRealtimeGalleryServiceConfirmsPtpAndGalleryStepsThroughOfficialCoordinator() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let fetchGallerySync = try XCTUnwrap(source.range(of: "private func fetchGallerySync")?.lowerBound)
    let cacheObjectInfos = try XCTUnwrap(source.range(of: "private func cacheObjectInfos", range: fetchGallerySync..<source.endIndex)?.lowerBound)
    let body = String(source[fetchGallerySync..<cacheObjectInfos])

    XCTAssertTrue(body.contains("IOSCameraGalleryConnectionCoordinator"))
    XCTAssertTrue(body.contains("initialConfirmedSteps: confirmedConnectionSteps"))
    XCTAssertFalse(body.contains("initialConfirmedSteps: IOSCameraConnectionStep.officialGalleryOrderPrefix(through: .joinCameraWifi)"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .connectPtp"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .confirmGalleryMode"))
    XCTAssertTrue(body.contains("IOSCameraConnectionStepRunner(step: .loadGallery"))
    XCTAssertTrue(body.contains("confirmedSteps()"))
  }

  func testProAccessAllowsTwentyFreeJPGDownloadsPerDay() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    let items = (0..<20).map { galleryItem(handle: $0, formatLabel: "JPG") }

    XCTAssertNil(access.restriction(for: items, now: fixedDate()))
  }

  func testProAccessBlocksFreeBatchAboveDailyLimit() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    let items = (0..<21).map { galleryItem(handle: $0, formatLabel: "JPG") }

    guard case .tooManyFiles(let limit) = access.restriction(for: items, now: fixedDate()) else {
      return XCTFail("Expected tooManyFiles restriction")
    }
    XCTAssertEqual(limit, 20)
  }

  func testProAccessBlocksNonJPGForFreePlan() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    guard case .nonJPG = access.restriction(for: [galleryItem(handle: 1, formatLabel: "HEIF")], now: fixedDate()) else {
      return XCTFail("Expected nonJPG restriction")
    }
  }

  func testProAccessCountsFreeDailyUsage() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    access.registerFreeDownloads(items: (0..<20).map { galleryItem(handle: $0, formatLabel: "JPG") }, now: fixedDate())

    guard case .dailyLimitReached(let limit) = access.restriction(for: [galleryItem(handle: 21, formatLabel: "JPG")], now: fixedDate()) else {
      return XCTFail("Expected dailyLimitReached restriction")
    }
    XCTAssertEqual(limit, 20)
  }

  func testProAccessDoesNotRestrictDuringSevenDayTrial() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(fixedDate())

    let items = (0..<80).map { galleryItem(handle: $0, formatLabel: "RAW") }

    XCTAssertNil(access.restriction(for: items, now: fixedDate()))
    access.registerFreeDownloads(items: items, now: fixedDate())
    XCTAssertEqual(access.remainingFreeJPGDownloads(now: fixedDate()), 20)
  }

  func testProAccessDoesNotRestrictWhenProUnlocked() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.isProUnlocked = true

    XCTAssertNil(access.restriction(for: [galleryItem(handle: 1, formatLabel: "RAW")], now: fixedDate()))

    access.resetForTesting()
  }

  func testIOSCameraIdentityUsesStableCameraIDNotPeripheralID() {
    let identity = IOSCameraIdentity(
      cameraID: "12345678_X-T5",
      displayName: "X-T5",
      serialNumber: "12345678",
      bleEndpoint: IOSCameraBleEndpoint(identifier: "core-bluetooth-uuid", address: "AA:BB:CC:DD:EE:FF")
    )

    XCTAssertEqual(identity.cameraID, "12345678_X-T5")
    XCTAssertNotEqual(identity.cameraID, identity.bleEndpoint.identifier)
  }

  func testIOSOfficialWifiCredentialRejectsGuessedSSIDAndDefaultPassword() {
    XCTAssertNil(
      IOSCameraWifiCredential.official(
        ssid: "X-T5-003B",
        passphrase: "00000000",
        bssid: nil,
        source: .guessed
      )
    )
    XCTAssertNotNil(
      IOSCameraWifiCredential.official(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "camera-secret",
        bssid: "00:11:22:33:44:55",
        source: .bleHandshake
      )
    )
  }

  func testIOSRegistrationGuardRequiresSystemBondCleanupForStaleBond() {
    let issue = IOSCameraRegistrationGuard.evaluate(
      localRecord: nil,
      scannedEndpoint: IOSCameraBleEndpoint(identifier: "scan-id", address: "AA:BB:CC:DD:EE:FF"),
      bondedAddresses: ["AA:BB:CC:DD:EE:FF"]
    )

    XCTAssertEqual(issue, .needsSystemBondCleanup(address: "AA:BB:CC:DD:EE:FF"))
  }

  func testIOSGalleryConnectionCoordinatorRunsAndroidStepOrder() async throws {
    var executedSteps: [IOSCameraConnectionStep] = []
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: IOSCameraConnectionStep.officialGalleryOrder.map { step in
        IOSCameraConnectionStepRunner(step: step) { context in
          executedSteps.append(step)
          return context
        }
      }
    )

    let result = try await coordinator.connect(
      context: IOSCameraConnectionContext(
        cameraID: "12345678_X-T5",
        pairingRecord: nil,
        wifiCredential: nil,
        ptpSessionID: nil
      )
    )

    XCTAssertEqual(executedSteps, IOSCameraConnectionStep.officialGalleryOrder)
    XCTAssertEqual(result.cameraID, "12345678_X-T5")
  }

  func testIOSGalleryConnectionStepOrderIncludesConfirmGalleryModeBeforeLoadGallery() {
    XCTAssertEqual(
      IOSCameraConnectionStep.officialGalleryOrder,
      [
        .reconnectPairedBle,
        .transferAuthorization,
        .activateCameraWifi,
        .waitCameraWifiReady,
        .joinCameraWifi,
        .connectPtp,
        .confirmGalleryMode,
        .loadGallery,
      ]
    )
    XCTAssertEqual(IOSCameraConnectionStep.confirmGalleryMode.androidDisplayName, "ConfirmGalleryMode")
  }

  func testIOSGalleryConnectionCoordinatorStopsAtFailedStep() async {
    var executedSteps: [IOSCameraConnectionStep] = []
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: [
        IOSCameraConnectionStepRunner(step: .reconnectPairedBle) { context in
          executedSteps.append(.reconnectPairedBle)
          return context
        },
        IOSCameraConnectionStepRunner(step: .transferAuthorization) { _ in
          executedSteps.append(.transferAuthorization)
          throw IOSCameraConnectionIssue(step: .transferAuthorization, reason: "missing official Wi-Fi credential")
        },
        IOSCameraConnectionStepRunner(step: .activateCameraWifi) { context in
          executedSteps.append(.activateCameraWifi)
          return context
        },
      ]
    )

    do {
      _ = try await coordinator.connect(
        context: IOSCameraConnectionContext(
          cameraID: "12345678_X-T5",
          pairingRecord: nil,
          wifiCredential: nil,
          ptpSessionID: nil
        )
      )
      XCTFail("Expected transferAuthorization failure")
    } catch let issue as IOSCameraConnectionIssue {
      XCTAssertEqual(issue.step, .transferAuthorization)
      XCTAssertEqual(coordinator.confirmedSteps(), [.reconnectPairedBle])
      XCTAssertEqual(executedSteps, [.reconnectPairedBle, .transferAuthorization])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSGalleryConnectionCoordinatorRejectsOutOfOrderRunnersBeforeRunningThem() async {
    var didRun = false
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: [
        IOSCameraConnectionStepRunner(step: .connectPtp) { context in
          didRun = true
          return context
        }
      ]
    )

    do {
      _ = try await coordinator.connect(
        context: IOSCameraConnectionContext(
          cameraID: "12345678_X-T5",
          pairingRecord: nil,
          wifiCredential: nil,
          ptpSessionID: nil
        )
      )
      XCTFail("Expected reconnectPairedBle ordering failure")
    } catch let issue as IOSCameraConnectionIssue {
      XCTAssertEqual(issue.step, .reconnectPairedBle)
      XCTAssertTrue(issue.reason.contains("Cannot run ConnectPtp before ReconnectPairedBle"))
      XCTAssertFalse(didRun)
      XCTAssertTrue(coordinator.confirmedSteps().isEmpty)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSAppFlowRunsRegistrationGuardBeforePairingAndStopsAfterPairing() async throws {
    var guardCallCount = 0
    var pairingCallCount = 0
    var galleryCallCount = 0
    let flow = IOSCameraAppFlowCoordinator(
      registrationGuard: {
        guardCallCount += 1
        return .pass
      },
      pairingModule: IOSCameraPairingModule {
        pairingCallCount += 1
        return IOSCameraPairingResult(
          record: IOSCameraPairingRecord(
            identity: IOSCameraIdentity(
              cameraID: "12345678_X-T5",
              displayName: "X-T5",
              serialNumber: "12345678",
              bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
            ),
            wifiCredential: IOSCameraWifiCredential.official(
              ssid: "FUJIFILM-X-T5-003B",
              passphrase: "camera-secret",
              bssid: nil,
              source: .bleHandshake
            )!
          )
        )
      },
      galleryConnector: { _ in
        galleryCallCount += 1
        return IOSCameraConnectionContext(cameraID: "12345678_X-T5", pairingRecord: nil, wifiCredential: nil, ptpSessionID: "ptp")
      }
    )

    let result = try await flow.startPairing()

    XCTAssertEqual(guardCallCount, 1)
    XCTAssertEqual(pairingCallCount, 1)
    XCTAssertEqual(galleryCallCount, 0)
    XCTAssertEqual(result.record.identity.cameraID, "12345678_X-T5")
  }

  func testIOSGalleryFilterDefaultsMatchAndroidAllNewestPolicy() {
    let state = IOSCameraGalleryFilterState()

    XCTAssertEqual(state.date, .all)
    XCTAssertEqual(state.format, .all)
    XCTAssertEqual(state.sort, .newest)
  }

  func testNativeGalleryChromeCopyMatchesAndroidHeaderAndCollapsedFilter() {
    XCTAssertEqual(NativeGalleryChromeCopy.title, "CAMERA GALLERY")
    XCTAssertEqual(NativeGalleryChromeCopy.filterTitle, "筛选")
    XCTAssertEqual(NativeGalleryChromeCopy.defaultFilterSummary, "全部日期 · 全部格式 · 最新优先")
    XCTAssertEqual(NativeGalleryChromeCopy.sortOptionTitles, ["最新", "最早", "未下载"])
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 2, isLoading: true, isTransferring: false), "下载中 2")
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: false, isTransferring: true), "正在下载")
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: true, isTransferring: false), "正在读取相机照片")
    XCTAssertNil(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: false, isTransferring: false))
  }

  func testNativeGalleryTopChromeKeepsActionsInTopHeaderLikeAndroid() {
    XCTAssertTrue(NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar)
    XCTAssertEqual(NativeGalleryTopChromePolicy.horizontalInset, 18)
    XCTAssertEqual(NativeGalleryTopChromePolicy.topInset, 0)
    XCTAssertEqual(NativeGalleryTopChromePolicy.bottomInset, 0)
    XCTAssertEqual(NativeGalleryTopChromePolicy.actionRowHeight, 42)
    XCTAssertEqual(NativeGalleryTopChromePolicy.actionSpacing, 8)
    XCTAssertEqual(NativeGalleryTopChromePolicy.statusSpacing, 0)
  }

  func testNativeGalleryAndroidParityLayoutKeepsGridTightUnderFilter() {
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing, 2)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterHeaderHeight, 42)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterTopSpacing, 6)
    XCTAssertFalse(NativeGalleryAndroidParityLayoutPolicy.shouldShowPinchHintBubble)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.bottomBarHeight, 52)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.bottomBarBottomInset, 10)
  }

  func testThumbnailTimingLogPolicyMatchesAndroidDiagnosticShape() {
    XCTAssertEqual(
      CameraVendorThumbnailTimingLogPolicy.successMessage(
        handle: 0x123,
        bytes: 4096,
        ptpElapsedMs: 72,
        decodeElapsedMs: 3,
        totalElapsedMs: 81
      ),
      "[OBS] THUMBNAIL_TIMING_OK handle=0x00000123 bytes=4096 ptpMs=72 decodeMs=3 totalMs=81"
    )
    XCTAssertEqual(
      CameraVendorThumbnailTimingLogPolicy.failureMessage(handle: 0x123, elapsedMs: 91, errorDescription: "boom"),
      "[OBS] THUMBNAIL_TIMING_FAILED handle=0x00000123 totalMs=91 error=boom"
    )
  }

  func testNativeGalleryCellDoesNotDecodeThumbnailDataOnMainThreadFallback() {
    XCTAssertFalse(NativeGalleryCellThumbnailDecodePolicy.shouldDecodeDataDuringCellConfigure)
  }

  func testDownloadCenterRehydratesPersistedThumbnailsOffMainThread() {
    XCTAssertTrue(NativeDownloadCenterThumbnailPolicy.shouldRehydratePersistedThumbnailData)
    XCTAssertEqual(
      NativeDownloadCenterThumbnailPolicy.action(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: nil
      ),
      .decodeCachedData
    )
    XCTAssertEqual(
      NativeDownloadCenterThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil
      ),
      .none
    )
  }

  func testTopChromeIconButtonsDoNotDrawExtraCardFrames() {
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesFilledBackground)
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesBorder)
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesShadow)
    XCTAssertEqual(NativeTopChromeIconButtonStylePolicy.sideLength, 42)
  }

  func testThumbnailPtpVerboseDiagnosticsAreSuppressedDuringSmoothGalleryScrolling() {
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_REQUEST handle=0x00000001"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_DATA bytes=123 handle=0x00000001 elapsedMs=8"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_CONTEXT_PRIMED_STANDARD handle=0x00000001 ms=3"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_THUMB_DATA source=standardGetThumb handle=0x00000001 rawBytes=123 normalizedBytes=123 rawHead=ffd8 normalizedHead=ffd8"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] THUMBNAIL_TIMING_OK handle=0x00000001 bytes=123 ptpMs=8 decodeMs=3 totalMs=11"))
    XCTAssertTrue(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] THUMBNAIL_TIMING_FAILED handle=0x00000001 totalMs=80 error=boom"))
  }

  func testPtpPacketLevelDiagnosticsAreSuppressedDuringDownloads() {
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("等待 PTP 包头"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("等待 CameraVendor legacy PTP 包头"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到 PTP 包 type=10 length=4194312"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到 CameraVendor legacy PTP 包 kind=2 length=14"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到数据包 type=10, 当前数据大小=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("操作响应: responseCode=0x2001, 总数据大小=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("CameraVendor 操作响应: responseCode=0x2001 txnID=42"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_SOCKET_PACKET_READ transport=standard type=10 length=4194312 headerMs=0 payloadMs=500"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=standard bytesRead=1048576 totalBytes=4194304 payloadMs=120"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=download-data handle=0x000004CA offset=0 maxBytes=4194304 expectedSize=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=download-data handle=0x000004CA chunkBytes=4194304 totalBytes=4194304 chunkMs=1730 isJpeg=true"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=expected-size handle=0x000004CA totalBytes=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_PREPARE_BEGIN handle=0x000004CA mode=compressed"))
    XCTAssertTrue(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_TIMING handle=0x000004CA mode=original bytes=4194304 prepMs=20 freshInfoMs=180 readMs=1400 normalizeMs=1 totalMs=1601"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_INFO handle=0x000004CA size=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_COMPLETE handle=0x000004CA bytes=4194304 elapsedMs=1730"))
  }

  func testNativeGalleryThumbnailUISuccessLogsAreSuppressedDuringSmoothScrolling() {
    XCTAssertFalse(NativeGalleryThumbnailUILogPolicy.shouldEmitSuccess(totalElapsedMs: 42))
    XCTAssertTrue(NativeGalleryThumbnailUILogPolicy.shouldEmitFailure)
  }

  func testNativeGalleryDoesNotRebuildSectionsAfterEveryThumbnail() {
    XCTAssertFalse(NativeGalleryThumbnailSectionRefreshPolicy.shouldRebuildSectionsAfterThumbnailLoad)
  }

  func testNativeDownloadCenterChromeMatchesAndroidHeaderSummaryAndGrid() {
    XCTAssertEqual(NativeDownloadCenterChrome.title, "DOWNLOADS")
    XCTAssertEqual(NativeDownloadCenterChrome.clearRecordsTitle, "清理记录")
    XCTAssertEqual(NativeDownloadCenterChrome.pauseDownloadTitle, "暂停下载")
    XCTAssertEqual(NativeDownloadCenterChrome.pauseRequestedTitle, "正在暂停")
    XCTAssertEqual(NativeDownloadCenterChrome.emptyTitle, "下载中心为空")
    XCTAssertEqual(
      NativeDownloadCenterChrome.summary(totalCount: 8, doneCount: 5, activeCount: 2),
      "8 张 · 已保存 5 · 进行中 2"
    )
    XCTAssertEqual(NativeDownloadCenterChrome.gridColumnCount, 3)
    XCTAssertEqual(NativeDownloadCenterChrome.gridInsets, UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12))
    XCTAssertEqual(NativeDownloadCenterChrome.gridHorizontalSpacing, 8)
    XCTAssertEqual(NativeDownloadCenterChrome.gridVerticalSpacing, 12)
  }

  func testNativeDownloadCenterExposesPauseButtonAndBlocksBackUntilInactive() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private final class NativeDownloadListViewController")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "extension NativeDownloadListViewController", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertNotNil(body.range(of: "pauseDownloadButton"))
    XCTAssertNotNil(body.range(of: "onPauseDownload"))
    XCTAssertNotNil(body.range(of: "pauseDownloadButton.addTarget"))
    XCTAssertNotNil(body.range(of: "@objc private func pauseDownloadTapped()"))
    XCTAssertNotNil(body.range(of: "NativeGalleryDownloadModePresentationPolicy.canPauseDownload"))
    XCTAssertNotNil(body.range(of: "backButton.isEnabled = canLeaveDownloadCenter"))
  }

  func testIOSGalleryFilterSupportsInclusiveDateRangeAndAllFormats() {
    let calendar = Calendar(identifier: .gregorian)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let middle = calendar.date(byAdding: .day, value: 2, to: start)!
    let end = calendar.date(byAdding: .day, value: 4, to: start)!
    let before = calendar.date(byAdding: .day, value: -1, to: start)!
    let items = [
      iosGalleryItem(handle: 1, formatLabel: "JPG", captureDate: before),
      iosGalleryItem(handle: 2, formatLabel: "RAW", captureDate: middle),
      iosGalleryItem(handle: 3, formatLabel: "HEIF", captureDate: end),
    ]

    let filtered = IOSCameraGalleryPolicy.filteredItems(
      items,
      state: IOSCameraGalleryFilterState(date: .range(end, start), format: .all, sort: .newest),
      downloadedHandles: [],
      now: start,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.handle), [3, 2])
  }

  func testIOSGalleryFilterSortsNotDownloadedFirst() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let older = now.addingTimeInterval(-60)
    let items = [
      iosGalleryItem(handle: 1, formatLabel: "JPG", captureDate: now),
      iosGalleryItem(handle: 2, formatLabel: "JPG", captureDate: older),
      iosGalleryItem(handle: 3, formatLabel: "JPG", captureDate: now.addingTimeInterval(-120)),
    ]

    let filtered = IOSCameraGalleryPolicy.filteredItems(
      items,
      state: IOSCameraGalleryFilterState(date: .all, format: .jpg, sort: .notDownloaded),
      downloadedHandles: [1],
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [2, 3, 1])
  }

  func testIOSDownloadHistoryPersistsObjectInfoAndThumbnailBytes() throws {
    let record = IOSCameraDownloadHistoryRecord(
      cameraID: "12345678_X-T5",
      objectInfo: IOSCameraObjectInfo(
        handle: 42,
        filename: "DSCF0042.JPG",
        formatLabel: "JPG",
        captureDate: Date(timeIntervalSince1970: 1_800_000_000),
        byteSize: 4_200_000,
        orientation: 6
      ),
      thumbnailBytes: Data([0xFF, 0xD8, 0xFF]),
      completedAt: Date(timeIntervalSince1970: 1_800_000_100)
    )

    let payload = IOSCameraDownloadHistoryPayload(records: [record])
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(IOSCameraDownloadHistoryPayload.self, from: data)

    XCTAssertEqual(decoded.records.first?.objectInfo.filename, "DSCF0042.JPG")
    XCTAssertEqual(decoded.records.first?.objectInfo.orientation, 6)
    XCTAssertEqual(decoded.records.first?.thumbnailBytes, Data([0xFF, 0xD8, 0xFF]))
  }

  func testLegacyConnectionSummaryDoesNotGenerateGuessedWifiCandidates() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "12345678",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiConfigurations.isEmpty)
  }

  func testLegacyConnectionSummaryKeepsOnlyOfficialWifiCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "12345678",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "camera-secret",
        isHidden: true
      )
    )

    XCTAssertEqual(summary.wifiConfigurations.count, 1)
    XCTAssertEqual(summary.wifiConfigurations.first?.ssid, "FUJIFILM-X-T5-003B")
    XCTAssertEqual(summary.wifiConfigurations.first?.passphrase, "camera-secret")
  }

  func testLegacyPoliciesDisablePairingAutoGalleryAndPartialThumbnailFallback() {
    XCTAssertFalse(CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing)
    XCTAssertFalse(
      CameraVendorPostPairingTransferPolicy.canStartTransfer(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: false
      )
    )
    XCTAssertFalse(CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback)
  }

  private func ptpString(_ string: String) -> Data {
    var data = Data([UInt8(string.count + 1)])
    for scalar in string.unicodeScalars {
      let value = UInt16(scalar.value)
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
    }
    data.append(0)
    data.append(0)
    return data
  }

  private func jpegDataWithExifOrientation(_ orientation: CGImagePropertyOrientation) throws -> Data {
    let image = solidImage(size: CGSize(width: 16, height: 12), fill: .red)
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
      output,
      "public.jpeg" as CFString,
      1,
      nil
    ))
    CGImageDestinationAddImage(
      destination,
      try XCTUnwrap(image.cgImage),
      [kCGImagePropertyOrientation as String: orientation.rawValue] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func jpegData(size: CGSize, fill: UIColor) throws -> Data {
    let image = solidImage(size: size, fill: fill)
    return try XCTUnwrap(image.jpegData(compressionQuality: 1))
  }

  private func solidImage(size: CGSize, fill: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
      fill.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }

  private func dominantRedValue(in image: UIImage) throws -> Int {
    let cgImage = try XCTUnwrap(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var redTotal = 0
    var sampleCount = 0
    stride(from: 0, to: pixels.count, by: bytesPerPixel).forEach { offset in
      redTotal += Int(pixels[offset])
      sampleCount += 1
    }
    return redTotal / max(sampleCount, 1)
  }

  private func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_800_000_000)
  }

  private func expiredTrialStartDate() -> Date {
    fixedDate().addingTimeInterval(-8 * 24 * 60 * 60)
  }

  private func galleryItem(handle: Int, formatLabel: String) -> CameraVendorGalleryItem {
    CameraVendorGalleryItem(
      handle: handle,
      filename: "DSCF\(String(format: "%04d", handle)).\(formatLabel.lowercased())",
      formatLabel: formatLabel,
      captureDate: "2026:05:17 10:00:00",
      byteSizeText: "1.0 MB"
    )
  }

  private func iosGalleryItem(handle: Int, formatLabel: String, captureDate: Date) -> IOSCameraGalleryItem {
    IOSCameraGalleryItem(
      handle: handle,
      filename: "DSCF\(String(format: "%04d", handle)).\(formatLabel.lowercased())",
      formatLabel: formatLabel,
      captureDate: captureDate,
      byteSize: 1_024,
      orientation: nil,
      thumbnailBytes: nil
    )
  }
}

private struct CameraVendorPlaceholderOnlyGalleryService: CameraVendorGalleryService {
  func fetchGallery() async throws -> [CameraVendorGalleryItem] {
    [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "0x00000001",
        formatLabel: "",
        captureDate: "",
        byteSizeText: ""
      )
    ]
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    Data()
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    Data()
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    Data()
  }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData {
    CameraVendorDownloadedPhotoData(
      data: Data(),
      filename: "placeholder-\(handle).jpg"
    )
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    try await downloadOriginalFile(for: handle, mode: .compressed)
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-\(handle).jpg")
    return CameraVendorDownloadedFile(
      fileURL: url,
      filename: "placeholder-\(handle).jpg",
      mediaType: .photo
    )
  }
}
