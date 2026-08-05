import Foundation

struct CameraCatalogResolution: Equatable, @unchecked Sendable {
  let membershipSnapshot: CameraGalleryCatalogSnapshot
  let snapshot: CameraGalleryCatalogSnapshot
  let authoritativeObjectInfos: [Int: CameraGalleryObjectInfoResult]
}

enum CameraCatalogQueryProgress: Equatable, Sendable {
  case queryingCatalog
}

actor CameraCatalogQueryEngine {
  private enum MembershipCacheKey: Hashable {
    case all
    case selected(Set<CameraMediaFormat>)

    init(_ selection: CameraMediaFormatSelection) {
      switch selection {
      case .all:
        self = .all
      case .selected(let formats):
        self = .selected(formats)
      }
    }
  }

  nonisolated let sessionEpoch: UUID

  private let source: CameraCatalogQuerySource
  private let accessGate: CameraCatalogAccessGate
  private var isInvalidated = false
  private var initialMembershipItems: [CameraGalleryCatalogItem]?
  private var membershipItemsByCacheKey: [MembershipCacheKey: [CameraGalleryCatalogItem]] = [:]

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
    initialMembershipItems = nil
    membershipItemsByCacheKey.removeAll(keepingCapacity: false)
  }

  func clearMembershipCache() {
    initialMembershipItems = nil
    membershipItemsByCacheKey.removeAll(keepingCapacity: false)
  }

  func resolveInitial(
    rule: CameraMediaFilterRule,
    owner: CameraCatalogAccessOwner,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    try checkActive()
    if let initialMembershipItems {
      return makeResolution(
        membershipItems: initialMembershipItems,
        rule: rule,
        downloadedHandles: downloadedHandles
      )
    }
    let lease = try await accessGate.acquire(owner: owner)
    do {
      try checkActive()
      let items = try await loadInitialMembershipItems()
      try checkActive()
      await lease.release()
      return makeResolution(
        membershipItems: items,
        rule: rule,
        downloadedHandles: downloadedHandles
      )
    } catch {
      await lease.release()
      throw error
    }
  }

  func resolve(
    rule: CameraMediaFilterRule,
    owner: CameraCatalogAccessOwner,
    downloadedHandles: Set<Int>,
    onProgress: (@MainActor @Sendable (CameraCatalogQueryProgress) -> Void)? = nil
  ) async throws -> CameraCatalogResolution {
    try checkActive()
    let cacheKey = MembershipCacheKey(rule.formats)
    if let membershipItems = membershipItemsByCacheKey[cacheKey] {
      return makeResolution(
        membershipItems: membershipItems,
        rule: rule,
        downloadedHandles: downloadedHandles
      )
    }
    let lease = try await accessGate.acquire(owner: owner)
    do {
      try checkActive()
      if let membershipItems = membershipItemsByCacheKey[cacheKey] {
        await lease.release()
        return makeResolution(
          membershipItems: membershipItems,
          rule: rule,
          downloadedHandles: downloadedHandles
        )
      }
      await onProgress?(.queryingCatalog)
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
      case .subtractBaseline(let requestedFormats):
        resolution = try await resolveSubtractBaseline(
          requestedFormats: requestedFormats,
          rule: rule,
          downloadedHandles: downloadedHandles
        )
      }
      try checkActive()
      membershipItemsByCacheKey[cacheKey] = resolution.membershipSnapshot.items
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
    var orderedItems = try await loadInitialMembershipItems()
    var seenHandles = Set(orderedItems.map(\.handle))
    let heifSnapshot = try await source.loadSubtractBaselineCatalog(for: .heif)
    try checkActive()
    for item in heifSnapshot.items where seenHandles.insert(item.handle).inserted {
      orderedItems.append(item)
    }
    let videoSnapshot = try await source.loadExactCatalog(for: .video)
    try checkActive()
    for item in videoSnapshot.items where seenHandles.insert(item.handle).inserted {
      orderedItems.append(item)
    }
    try checkActive()
    return makeResolution(
      membershipItems: globallyNewestFirst(orderedItems),
      rule: rule,
      downloadedHandles: downloadedHandles
    )
  }

  private func loadInitialMembershipItems() async throws -> [CameraGalleryCatalogItem] {
    if let initialMembershipItems {
      return initialMembershipItems
    }
    let snapshot = try await source.loadInitialCatalog()
    try checkActive()
    initialMembershipItems = snapshot.items
    return snapshot.items
  }

  private func resolveExactFormats(
    _ formats: Set<CameraMediaFormat>,
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    var orderedItems: [CameraGalleryCatalogItem] = []
    var seenHandles: Set<Int> = []
    for format in [CameraMediaFormat.jpg, .raw, .video] where formats.contains(format) {
      let snapshot = try await source.loadExactCatalog(for: format)
      try checkActive()
      for item in snapshot.items where seenHandles.insert(item.handle).inserted {
        orderedItems.append(item)
      }
    }
    return makeResolution(
      membershipItems: globallyNewestFirst(orderedItems),
      rule: rule,
      downloadedHandles: downloadedHandles
    )
  }

  private func resolveSubtractBaseline(
    requestedFormats: Set<CameraMediaFormat>,
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) async throws -> CameraCatalogResolution {
    // HEIF uses a compatibility set-difference query:
    // (D604=format result) minus (ALL baseline) = format-only handles.
    // This avoids per-handle ObjectInfo and completes in one PTP round-trip.
    var orderedItems: [CameraGalleryCatalogItem] = []
    var seenHandles: Set<Int> = []

    // Collect direct-format handles for JPG/RAW/Video if also requested.
    for format in [CameraMediaFormat.jpg, .raw, .video] where requestedFormats.contains(format) {
      let snapshot = try await source.loadExactCatalog(for: format)
      try checkActive()
      for item in snapshot.items where seenHandles.insert(item.handle).inserted {
        orderedItems.append(item)
      }
    }

    // Collect HEIF handles via subtractBaseline
    if requestedFormats.contains(.heif) {
      let snapshot = try await source.loadSubtractBaselineCatalog(for: .heif)
      try checkActive()
      for item in snapshot.items where seenHandles.insert(item.handle).inserted {
        orderedItems.append(item)
      }
    }

    return makeResolution(
      membershipItems: globallyNewestFirst(orderedItems),
      rule: rule,
      downloadedHandles: downloadedHandles
    )
  }

  private func globallyNewestFirst(
    _ items: [CameraGalleryCatalogItem]
  ) -> [CameraGalleryCatalogItem] {
    let datedItems = items.compactMap { item -> (item: CameraGalleryCatalogItem, date: Date)? in
      guard let date = CameraFilterEngine.parseCaptureDate(item.captureDate) else { return nil }
      return (item, date)
    }
    guard datedItems.count == items.count else {
      return items.sorted { $0.handle > $1.handle }
    }
    return datedItems.sorted { lhs, rhs in
      if lhs.date != rhs.date {
        return lhs.date > rhs.date
      }
      return lhs.item.handle > rhs.item.handle
    }.map(\.item)
  }

  private func makeResolution(
    membershipItems: [CameraGalleryCatalogItem],
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) -> CameraCatalogResolution {
    let membershipSnapshot = makeSnapshot(items: membershipItems)
    let projectedItems = project(
      membershipItems,
      rule: rule,
      downloadedHandles: downloadedHandles
    )
    let snapshot = projectedItems.map(\.handle) == membershipItems.map(\.handle)
      ? membershipSnapshot
      : makeSnapshot(items: projectedItems)
    return CameraCatalogResolution(
      membershipSnapshot: membershipSnapshot,
      snapshot: snapshot,
      authoritativeObjectInfos: [:]
    )
  }

  private func project(
    _ items: [CameraGalleryCatalogItem],
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>
  ) -> [CameraGalleryCatalogItem] {
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

  private func makeSnapshot(items: [CameraGalleryCatalogItem]) -> CameraGalleryCatalogSnapshot {
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
        CameraGalleryDateGroup(
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
