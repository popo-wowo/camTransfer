import Foundation

struct CameraGalleryRepository {
  private(set) var generation: CameraGalleryGenerationID?
  private(set) var snapshotID: CameraGallerySnapshotID?
  private(set) var items: [CameraVendorGalleryItem] = []
  private(set) var entries: [CameraGalleryEntryViewState] = []

  mutating func install(
    _ snapshot: CameraGalleryCatalogSnapshot,
    generation: CameraGalleryGenerationID
  ) {
    self.generation = generation
    snapshotID = snapshot.snapshotID
    items = snapshot.items
    replaceSummaryPage(snapshot.items.map(CameraGalleryRepositoryAdapter.summary(from:)))
  }

  func contains(_ identity: CameraGalleryChildIdentity) -> Bool {
    generation == identity.generation &&
      snapshotID == identity.snapshotID &&
      entries.contains(where: { $0.summary.handle == identity.handle })
  }

  mutating func applyThumbnail(
    _ thumbnail: CameraVendorGalleryThumbnail,
    identity: CameraGalleryChildIdentity
  ) -> Bool {
    guard contains(identity),
          let itemIndex = items.firstIndex(where: { $0.handle == identity.handle }) else {
      return false
    }
    items[itemIndex] = CameraGalleryRepositoryAdapter.item(
      existingItem: items[itemIndex],
      thumbnailData: thumbnail.data,
      resolvedItem: thumbnail.item
    )
    applyThumbnailUpdate(
      handle: identity.handle,
      thumbnail: CameraGalleryEntryThumbnail(
        handle: identity.handle,
        state: .loaded,
        imageData: thumbnail.data
      )
    )
    if let resolvedItem = thumbnail.item {
      replaceSummaryForExistingHandle(resolvedItem)
    }
    return true
  }

  mutating func applyDetails(
    _ result: CameraGalleryDetailsSourceResult,
    identity: CameraGalleryChildIdentity
  ) -> Bool {
    guard contains(identity) else { return false }
    applyDetailsResult(result)
    if let resolvedItem = result.resolvedItem {
      replaceSummaryForExistingHandle(resolvedItem)
    }
    return true
  }

  private mutating func replaceSummaryForExistingHandle(_ resolvedItem: CameraVendorGalleryItem) {
    guard let itemIndex = items.firstIndex(where: { $0.handle == resolvedItem.handle }) else { return }
    items[itemIndex] = CameraGalleryRepositoryAdapter.mergedItem(
      existingItem: items[itemIndex],
      resolvedItem: resolvedItem
    )
    guard let entryIndex = entries.firstIndex(where: { $0.summary.handle == resolvedItem.handle }) else { return }
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

  mutating func applyDetailsUpdate(handle: Int, details: CameraGalleryEntryDetails) {
    guard let index = entries.firstIndex(where: { $0.summary.handle == handle }) else { return }
    entries[index].details = details
    if case .unknown = entries[index].summary.format,
       case let .confirmed(format) = details.refinedFormat {
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
