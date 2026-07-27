import Foundation

struct CameraCatalogResolution: Equatable, @unchecked Sendable {
  let snapshot: CameraGalleryCatalogSnapshot
  let authoritativeObjectInfos: [Int: CameraGalleryObjectInfoResult]
}

enum CameraCatalogResolutionFailure: Error, Equatable, Sendable {
  case incompleteCatalog
  case incompleteObjectInfo(handle: Int)
  case unsupportedFormatCode(handle: Int, formatCode: UInt16)
}

actor CameraCatalogQueryEngine {
  nonisolated let sessionEpoch: UUID

  private let source: CameraCatalogQuerySource
  private let accessGate: CameraCatalogAccessGate
  private var isInvalidated = false

  init(
    source: CameraCatalogQuerySource,
    sessionEpoch: UUID = UUID(),
    accessGate: CameraCatalogAccessGate = CameraCatalogAccessGate()
  ) {
    self.source = source
    self.sessionEpoch = sessionEpoch
    self.accessGate = accessGate
  }

  func invalidate() {
    isInvalidated = true
  }

  func resolve(
    rule: CameraMediaFilterRule,
    owner: CameraCatalogAccessOwner,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    try checkActive()
    let lease = await accessGate.acquire(owner: owner)
    do {
      try checkActive()
      let resolution: CameraCatalogResolution
      switch CameraFilterEngine.plan(for: rule.formats) {
      case .allCatalog:
        resolution = try await resolveAllCatalog(
          rule: rule,
          downloadedHandles: downloadedHandles
        )
      case .exactFormats(let formats):
        resolution = try await resolveExactFormats(
          formats,
          rule: rule,
          downloadedHandles: downloadedHandles
        )
      case .objectInfoFallback(let requestedFormats):
        resolution = try await resolveObjectInfoFallback(
          requestedFormats: requestedFormats,
          rule: rule,
          downloadedHandles: downloadedHandles
        )
      }
      try checkActive()
      await lease.release()
      return resolution
    } catch {
      await lease.release()
      throw error
    }
  }

  private func resolveAllCatalog(
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    let snapshot = try await source.loadExpandedCatalog()
    try checkActive()
    let items = project(
      snapshot.items,
      rule: rule,
      downloadedHandles: downloadedHandles
    )
    return CameraCatalogResolution(
      snapshot: makeSnapshot(items: items),
      authoritativeObjectInfos: [:]
    )
  }

  private func resolveExactFormats(
    _ formats: Set<CameraMediaFormat>,
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    var orderedItems: [CameraVendorGalleryItem] = []
    var seenHandles: Set<Int> = []
    for format in [CameraMediaFormat.jpg, .raw] where formats.contains(format) {
      let snapshot = try await source.loadExactCatalog(for: format)
      try checkActive()
      for item in snapshot.items where seenHandles.insert(item.handle).inserted {
        orderedItems.append(item)
      }
    }
    let items = project(
      orderedItems,
      rule: rule,
      downloadedHandles: downloadedHandles
    )
    return CameraCatalogResolution(
      snapshot: makeSnapshot(items: items),
      authoritativeObjectInfos: [:]
    )
  }

  private func resolveObjectInfoFallback(
    requestedFormats: Set<CameraMediaFormat>,
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    let snapshot = try await source.loadExpandedCatalog()
    try checkActive()
    guard Set(snapshot.orderedHandles.map(Int.init)) == Set(snapshot.items.map(\.handle)),
          Set(snapshot.orderedHandles).count == snapshot.orderedHandles.count else {
      throw CameraCatalogResolutionFailure.incompleteCatalog
    }

    let dateOnlyRule = CameraMediaFilterRule(
      formats: .all,
      date: rule.date,
      downloadScope: .all
    )
    let dateCandidates = project(snapshot.items, rule: dateOnlyRule, downloadedHandles: [])
    var classifiedItems: [CameraVendorGalleryItem] = []
    var authoritativeObjectInfos: [Int: CameraGalleryObjectInfoResult] = [:]
    for item in dateCandidates {
      try checkActive()
      let info = try await source.loadObjectInfo(handle: item.handle)
      try checkActive()
      guard info.handle == item.handle else {
        throw CameraCatalogResolutionFailure.incompleteObjectInfo(handle: item.handle)
      }
      switch try authoritativeFormat(handle: item.handle, formatCode: info.formatCode) {
      case .still(let format) where requestedFormats.contains(format):
        classifiedItems.append(item)
        authoritativeObjectInfos[item.handle] = info
      case .still, .video:
        break
      }
    }

    let downloadRule = CameraMediaFilterRule(
      formats: .all,
      date: .all,
      downloadScope: rule.downloadScope
    )
    let items = project(
      classifiedItems,
      rule: downloadRule,
      downloadedHandles: downloadedHandles
    )
    let includedHandles = Set(items.map(\.handle))
    return CameraCatalogResolution(
      snapshot: makeSnapshot(items: items),
      authoritativeObjectInfos: authoritativeObjectInfos.filter {
        includedHandles.contains($0.key)
      }
    )
  }

  private enum AuthoritativeFormat {
    case still(CameraMediaFormat)
    case video
  }

  private func authoritativeFormat(
    handle: Int,
    formatCode: UInt16
  ) throws -> AuthoritativeFormat {
    switch formatCode {
    case 0x3801:
      return .still(.jpg)
    case 0x3812:
      return .still(.heif)
    case 0xB101, 0xB103:
      return .still(.raw)
    case 0x300B, 0x300D:
      return .video
    default:
      throw CameraCatalogResolutionFailure.unsupportedFormatCode(
        handle: handle,
        formatCode: formatCode
      )
    }
  }

  private func project(
    _ items: [CameraVendorGalleryItem],
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) -> [CameraVendorGalleryItem] {
    let candidates = items.map {
      CameraMediaFilterCandidate(
        handle: $0.handle,
        captureDate: CameraFilterEngine.parseCaptureDate($0.captureDate)
      )
    }
    let handles = Set(CameraFilterEngine.project(
      candidates,
      rule: rule,
      downloadedHandles: downloadedHandles
    ).map(\.handle))
    return items.filter { handles.contains($0.handle) }
  }

  private func makeSnapshot(items: [CameraVendorGalleryItem]) -> CameraGalleryCatalogSnapshot {
    let groupedDates = Dictionary(grouping: items) { item in
      String(item.captureDate.prefix(8))
    }
    let orderedDates = items.map { String($0.captureDate.prefix(8)) }
      .filter { !$0.isEmpty }
      .reduce(into: [String]()) { result, date in
        if !result.contains(date) { result.append(date) }
      }
    return CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: orderedDates.map {
        CameraVendorSpecifiedObjectDateGroup(
          dateText: $0,
          objectCount: UInt32(groupedDates[$0]?.count ?? 0)
        )
      },
      orderedHandles: items.map { UInt32($0.handle) },
      items: items
    )
  }

  private func checkActive() throws {
    try Task.checkCancellation()
    guard !isInvalidated else { throw CancellationError() }
  }
}
