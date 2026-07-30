import Foundation

struct CameraGalleryRepository {
  private(set) var generation: CameraGalleryGenerationID?
  private(set) var snapshotID: CameraGallerySnapshotID?
  private(set) var items: [CameraGalleryCatalogItem] = []
  private(set) var entries: [CameraGalleryEntryViewState] = []

  mutating func install(
    _ snapshot: CameraGalleryCatalogSnapshot,
    generation: CameraGalleryGenerationID
  ) {
    let existingItemsByHandle = Dictionary(uniqueKeysWithValues: items.map { ($0.handle, $0) })
    self.generation = generation
    snapshotID = snapshot.snapshotID
    items = snapshot.items.map { incomingItem in
      guard let existingItem = existingItemsByHandle[incomingItem.handle] else {
        return incomingItem
      }
      let mergedItem = CameraGalleryRepositoryAdapter.mergedItem(
        existingItem: incomingItem,
        resolvedMetadata: CameraGalleryRepositoryAdapter.resolvedMetadata(from: existingItem)
      )
      guard let thumbnailData = incomingItem.thumbnailData ?? existingItem.thumbnailData else {
        return mergedItem
      }
      return CameraGalleryRepositoryAdapter.item(
        existingItem: mergedItem,
        thumbnailData: thumbnailData,
        resolvedMetadata: nil
      )
    }
    replaceSummaryPage(items.map(CameraGalleryRepositoryAdapter.summary(from:)))
  }

  func contains(_ identity: CameraGalleryChildIdentity) -> Bool {
    generation == identity.generation &&
      snapshotID == identity.snapshotID &&
      entries.contains(where: { $0.summary.handle == identity.handle })
  }

  mutating func applyThumbnail(
    _ thumbnail: CameraGalleryThumbnailResult,
    identity: CameraGalleryChildIdentity
  ) -> Bool {
    guard contains(identity),
          let itemIndex = items.firstIndex(where: { $0.handle == identity.handle }) else {
      return false
    }
    items[itemIndex] = CameraGalleryRepositoryAdapter.item(
      existingItem: items[itemIndex],
      thumbnailData: thumbnail.data,
      resolvedMetadata: thumbnail.resolvedMetadata
    )
    applyThumbnailUpdate(
      handle: identity.handle,
      thumbnail: CameraGalleryEntryThumbnail(
        handle: identity.handle,
        state: .loaded,
        imageData: thumbnail.data
      )
    )
    if let resolvedMetadata = thumbnail.resolvedMetadata {
      replaceSummaryForExistingHandle(resolvedMetadata)
    }
    return true
  }

  @discardableResult
  mutating func applyDetails(
    _ result: CameraGalleryDetailsSourceResult,
    identity: CameraGalleryChildIdentity
  ) -> Bool {
    guard contains(identity) else { return false }
    applyDetailsResult(result)
    if let resolvedMetadata = result.resolvedMetadata {
      replaceSummaryForExistingHandle(resolvedMetadata)
    }
    return true
  }

  private mutating func replaceSummaryForExistingHandle(_ resolvedMetadata: CameraGalleryResolvedItemMetadata) {
    guard let itemIndex = items.firstIndex(where: { $0.handle == resolvedMetadata.handle }) else { return }
    items[itemIndex] = CameraGalleryRepositoryAdapter.mergedItem(
      existingItem: items[itemIndex],
      resolvedMetadata: resolvedMetadata
    )
    guard let entryIndex = entries.firstIndex(where: { $0.summary.handle == resolvedMetadata.handle }) else { return }
    entries[entryIndex].summary = CameraGalleryRepositoryAdapter.summary(from: items[itemIndex])
  }

  mutating func replaceSummaryPage(_ summaries: [CameraGalleryEntrySummary]) {
    let existingEntriesByHandle = Dictionary(uniqueKeysWithValues: entries.map { ($0.summary.handle, $0) })
    entries = summaries.map { summary in
      if let existing = existingEntriesByHandle[summary.handle] {
        return CameraGalleryEntryViewState(
          summary: summary,
          thumbnail: existing.thumbnail,
          details: existing.details
        )
      }
      return CameraGalleryEntryViewState(
        summary: summary,
        thumbnail: CameraGalleryEntryThumbnail(handle: summary.handle, state: .idle, imageData: nil),
        details: CameraGalleryEntryDetails(
          handle: summary.handle,
          orientation: .unknown,
          refinedFormat: .unknown,
          notes: []
        )
      )
    }
  }

  mutating func applyThumbnailUpdate(handle: Int, thumbnail: CameraGalleryEntryThumbnail) {
    guard let index = entries.firstIndex(where: { $0.summary.handle == handle }) else { return }
    entries[index].thumbnail = thumbnail
  }

  @discardableResult
  mutating func applyThumbnailState(
    _ state: CameraGalleryThumbnailState,
    identity: CameraGalleryChildIdentity
  ) -> Bool {
    guard contains(identity),
          let index = entries.firstIndex(where: { $0.summary.handle == identity.handle }) else {
      return false
    }
    entries[index].thumbnail.state = state
    if state == .failed {
      entries[index].thumbnail.imageData = nil
    }
    return true
  }

  mutating func applyDetailsUpdate(handle: Int, details: CameraGalleryEntryDetails) {
    guard let index = entries.firstIndex(where: { $0.summary.handle == handle }) else { return }
    let existing = entries[index].details
    entries[index].details = CameraGalleryEntryDetails(
      handle: handle,
      orientation: existing.orientation.confirmedOr(details.orientation),
      refinedFormat: existing.refinedFormat.confirmedOr(details.refinedFormat),
      notes: existing.notes.isEmpty ? details.notes : existing.notes
    )
    if case .unknown = entries[index].summary.format,
       case let .confirmed(format) = entries[index].details.refinedFormat {
      entries[index].summary.format = .confirmed(format)
    }
  }

  mutating func applyDetailsResult(_ result: CameraGalleryDetailsSourceResult) {
    applyDetailsUpdate(
      handle: result.handle,
      details: CameraGalleryRepositoryAdapter.entryDetails(from: result)
    )
  }

}

private extension CameraGalleryConfirmedValue {
  func confirmedOr(_ fallback: Self) -> Self {
    switch self {
    case .confirmed:
      return self
    case .unknown:
      return fallback
    }
  }
}
