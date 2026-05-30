import CoreLocation
import Network
import NetworkExtension
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

  func testHandshakeIdentityPolicyPrefersDeviceName() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "Gold 的 iPhone",
        fallbackAppName: "CamTransfer"
      ),
      "Gold 的 iPhone"
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

  func testHandshakeIdentityPolicyFallsBackToAppNameThenDefault() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "   ",
        fallbackAppName: "CamTransfer Native"
      ),
      "CamTransfer Native"
    )
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: nil,
        fallbackAppName: nil
      ),
      "CamTransfer"
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
      "请先在 iPhone 和相机里删除旧配对，再重新配对"
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

  func testGalleryPreparationSkipsAutomaticWifiJoinAfterManualRecoveryWasSuggested() {
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
        hasWifiConfigurations: true,
        prefersManualWifiRecovery: true
      )
    )
  }

  func testGalleryPreparationDoesNotAttemptAutomaticWifiJoinBeforeManualRecoveryIsNeeded() {
    XCTAssertFalse(
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

  func testPtpStartupPolicyKeepsReferenceAppSettleDelayAfterWifiHandoff() {
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true),
      3
    )
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: false),
      3
    )
  }

  func testPtpConnectionStartupPolicyUsesShortSocketTimeoutsDuringReferenceAppWindow() {
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds, 1.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 1), 0.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 4), 0.5)
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
  }

  func testCameraVendorPartialObjectRequestPolicyUsesReferenceAppInitialReadSize() {
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize, 4 * 1_024 * 1_024)
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

  func testGalleryPreparationPausesBeforePtpWhileWaitingForManualWifiJoin() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false
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
        currentSSIDMatchesCamera: true,
        isCameraPtpReachable: false
      )
    )
  }

  func testGalleryPreparationAllowsManualRecoveryWhenPtpIsReachable() {
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

  func testTransferFlowAutomaticallyPreparesAfterPairingLikeReferenceApp() {
    XCTAssertTrue(CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing)
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

  func testTransferFlowCanStartAfterPairingWhenAutoPrepareIsEnabled() {
    XCTAssertFalse(
      CameraVendorPostPairingTransferPolicy.canStartTransfer(
        hasCompletedPairing: false,
        hasUserInitiatedTransfer: true
      )
    )
    XCTAssertTrue(
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

  func testGalleryReloadPolicyRetriesOnlyWhenCameraWifiIsReadyAfterFailure() {
    XCTAssertTrue(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28"
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

  func testGalleryLoadPolicyAllowsReloadOnlyOnCameraWifiIp() {
    XCTAssertTrue(CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: "192.168.0.122"))
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: "192.168.3.28"))
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: nil))
  }

  func testGalleryLoadPolicyRetriesAutomaticallyWhenReturningFromWifiSettings() {
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldLoadAutomaticallyOnEntry)
    XCTAssertTrue(CameraVendorGalleryLoadPolicy.shouldRetryAutomaticallyWhenAppBecomesActive)
  }

  func testGalleryLoadPolicyAutoLoadsWhenCameraWifiBecomesReady() {
    XCTAssertTrue(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.3.28",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 2,
        isLoading: false
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.114",
        baselineWifiIP: "192.168.0.114",
        itemCount: 0,
        isLoading: false
      )
    )
  }

  func testTransferActivationCompletionPolicyProceedsAfterObservedChange() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: true,
        hasMoreStrategies: false
      )
    )
  }

  func testOfficialImportImageActivelyDisconnectsBluetoothBeforeGallery() {
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
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldWaitForBluetoothDisconnect(
        afterObservedChangeFor: .compatibleRemoteImageView
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

  func testTransferActivationCompletionPolicyAllowsHandshakeAfterWifiLaunch() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: true,
        hadActivationFeature: true
      )
    )
  }

  func testTransferActivationCompletionPolicyAllowsHandshakeWithoutActivationFeature() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: false,
        hadActivationFeature: false
      )
    )
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

    XCTAssertFalse(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(video))
    XCTAssertTrue(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(jpeg))
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: video), .video)
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: jpeg), .photo)
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

  func testConnectionSummaryAddsVisibleFallbackForHiddenPreferredWifi() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true
      )
    )

    let configurations = Array(summary.wifiConfigurations.prefix(2))
    XCTAssertEqual(configurations.count, 2)
    XCTAssertEqual(configurations[0].ssid, "CAMERA-DEVICE-A-003B")
    XCTAssertTrue(configurations[0].isHidden)
    XCTAssertEqual(configurations[1].ssid, "CAMERA-DEVICE-A-003B")
    XCTAssertFalse(configurations[1].isHidden)
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
      "CamTransfer 需要定位权限来确认 iPhone 是否已切换到相机 Wi-Fi"
    )
    XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
    let appTransportSecurity = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertEqual(appTransportSecurity["NSAllowsLocalNetworking"] as? Bool, true)
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

  func testNativeGalleryNavigationPolicyBlocksPreviewDismissWhileDownloading() {
    XCTAssertFalse(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: false))
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

  func testHomeCameraSearchActionUsesRefreshLanguageAfterAutoScan() {
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.symbolName, "arrow.clockwise")
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.accessibilityLabel, "刷新搜索附近相机")
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
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(format: .heif),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [2])
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

  func testCameraVendorCurrentImageContextPolicyMatchesReferenceAppImportInitialization() {
    XCTAssertEqual(CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle, 0x10000001)
    XCTAssertTrue(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList)
    XCTAssertTrue(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription)
  }

  func testCameraVendorLegacyGalleryPolicyMatchesOfficialColdStartListSequence() {
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectHandlesWhenSpecifiedListIsSmall)
    XCTAssertEqual(CameraVendorLegacyGalleryObjectInfoPolicy.maxStandardObjectInfoProbeCount, 300)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeDualSlotWhenSpecifiedListIsSmall)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeLatestProbe)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleViaObjectPropList)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeBeforeFormatSearch)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeDuringColdStart)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadSearchModeAllDuringColdStart)
    XCTAssertFalse(CameraVendorLegacyGalleryObjectInfoPolicy.shouldSetStillImageObjectFormatSearchMode)
    XCTAssertTrue(CameraVendorLegacyGalleryObjectInfoPolicy.shouldRefreshGalleryContextBeforeSpecifiedList)
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
    let heifInfo = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0x3812,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "DSCF0001.HEIC",
      captureDate: ""
    )

    XCTAssertFalse(
      CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(
        afterSpecifiedInfos: [heifInfo]
      )
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicyProbesGapsAroundSpecifiedHandles() {
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: [1, 10, 22, 24, 26]),
      [
        2, 3, 4, 5, 6, 7, 8, 9,
        11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
        23, 25,
      ]
    )
  }

  func testCameraVendorHiddenObjectHandleProbePolicySkipsLargeRanges() {
    XCTAssertEqual(
      CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: [1, 900]),
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

  func testCameraVendorThumbnailPolicyPrefersStandardGetThumbWithObjectInfoPreflight() {
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb)
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst)
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes, 100)
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
        0x00, 0x00, 0x40, 0x00,
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
        0x00, 0x00, 0x40, 0x00,
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

  func testCameraVendorSetSearchModeAllObjectFormatPayloadIncludesJpegHeifRaw() {
    XCTAssertEqual(
      CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
        CameraVendorSearchModeAllPayload.jpegObjectFormatMask |
        CameraVendorSearchModeAllPayload.heifObjectFormatMask |
        CameraVendorSearchModeAllPayload.rawObjectFormatMask
      ),
      Data([
        0x01, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x04, 0xD6,
        0x13, 0x00,
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

  func testConnectionSummaryGeneratesCameraWifiCandidates() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertEqual(summary.wifiCandidates, ["DEVICE-A-003B", "DEVICE-A"])
  }

  func testConnectionSummaryDoesNotDuplicateSerialSuffixWhenNameAlreadyContainsIt() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A-003B",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertEqual(summary.wifiCandidates, ["DEVICE-A-003B"])
  }

  func testReferenceAppWifiNetworkDecoderReadsHiddenSsidAndPassphrase() {
    let credentials = CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(
      from: [
        CameraVendorReferenceAppNetworkConfigDecoder.ssidCharacteristicUUIDString:
          Data("CAMERA-DEVICE-A-003B".utf8),
        CameraVendorReferenceAppNetworkConfigDecoder.passphraseCharacteristicUUIDString:
          Data("uQMggJcFEEBhCDjgkww0".utf8),
      ]
    )

    XCTAssertEqual(
      credentials,
      CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true
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
        ),
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "uQMggJcFEEBhCDjgkww0",
          isHidden: false
        ),
        CameraVendorWifiNetworkConfiguration(ssid: "DEVICE-A-003B", passphrase: "00000000", isHidden: false),
        CameraVendorWifiNetworkConfiguration(ssid: "DEVICE-A", passphrase: "00000000", isHidden: false),
      ]
    )
  }

  func testOfficialImportImageTransferPlanUsesLaunchRequestCharacteristic() {
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
          payload: Data([0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
          payload: Data([0x03, 0x00])
        )
      ]
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

  func testOfficialImportImageTreatsOnlyLaunchedApStateAsGalleryWifiReady() {
    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x00, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertFalse(
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

  func testNativeLogTextPolicyTrimsLongLiveText() {
    let longText = String(repeating: "a", count: NativeLogTextViewPolicy.maxDisplayedCharacters + 50)
    let rendered = NativeLogTextViewPolicy.appending("next", to: longText)

    XCTAssertLessThanOrEqual(rendered.count, NativeLogTextViewPolicy.maxDisplayedCharacters + 4)
    XCTAssertTrue(rendered.hasPrefix("...\n"))
    XCTAssertTrue(rendered.hasSuffix("next"))
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
        ),
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "secret123",
          isHidden: false
        ),
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A",
          passphrase: "00000000",
          isHidden: false
        ),
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

  func testGalleryAssociationPreflightSkipsJoinWhenPtpIsReachableWithoutSSID() {
    XCTAssertTrue(
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

  func testGalleryAssociationPreflightConfirmsCameraWifiFromSubnetWhenSSIDIsUnavailable() {
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
}
