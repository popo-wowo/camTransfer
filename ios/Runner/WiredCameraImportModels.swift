import Foundation
import UIKit

struct WiredCameraImportDevice: Codable, Equatable {
  let id: String
  let name: String
  let transportName: String
}

struct WiredCameraImportItem: Codable, Equatable {
  let id: String
  let ptpObjectHandle: UInt32
  let name: String
  let uti: String?
  let fileSize: Int64
  let createdAt: Date?
  var thumbnail: UIImage?
  let isImportable: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case ptpObjectHandle
    case name
    case uti
    case fileSize
    case createdAt
    case isImportable
  }

  init(
    id: String,
    ptpObjectHandle: UInt32 = 0,
    name: String,
    uti: String?,
    fileSize: Int64,
    createdAt: Date?,
    thumbnail: UIImage?,
    isImportable: Bool
  ) {
    self.id = id
    self.ptpObjectHandle = ptpObjectHandle
    self.name = name
    self.uti = uti
    self.fileSize = fileSize
    self.createdAt = createdAt
    self.thumbnail = thumbnail
    self.isImportable = isImportable
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    ptpObjectHandle = try container.decodeIfPresent(UInt32.self, forKey: .ptpObjectHandle) ?? 0
    name = try container.decode(String.self, forKey: .name)
    uti = try container.decodeIfPresent(String.self, forKey: .uti)
    fileSize = try container.decode(Int64.self, forKey: .fileSize)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    thumbnail = nil
    isImportable = try container.decode(Bool.self, forKey: .isImportable)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(ptpObjectHandle, forKey: .ptpObjectHandle)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(uti, forKey: .uti)
    try container.encode(fileSize, forKey: .fileSize)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encode(isImportable, forKey: .isImportable)
  }

  var fileSizeText: String {
    guard fileSize > 0 else { return "大小未知" }
    return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
  }

  var dateText: String {
    guard let createdAt else { return "日期未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: createdAt)
  }

  var formatFilter: WiredCameraImportFormatFilter {
    WiredCameraImportPolicy.formatFilter(filename: name, uti: uti)
  }

  var formatLabel: String {
    switch formatFilter {
    case .all:
      return "FILE"
    case .jpg:
      return "JPG"
    case .heif:
      return "HEIF"
    case .raw:
      return "RAW"
    case .video:
      return "视频"
    }
  }
}

struct WiredCameraDownloadedFile {
  let fileURL: URL
  let filename: String
  let mediaType: CameraVendorDownloadedMediaType
}

enum WiredCameraImportItemIdentity {
  static func make(
    ptpObjectHandle: UInt32,
    filename: String,
    fileSize: Int64,
    createdAt: Date?
  ) -> String {
    let dateValue = Int((createdAt?.timeIntervalSince1970 ?? 0).rounded())
    let base = "\(filename)-\(fileSize)-\(dateValue)"
    let handlePart = ptpObjectHandle == 0 ? "nohandle" : "ptp\(ptpObjectHandle)"
    return "\(handlePart)-\(cacheKey(for: base))"
  }

  private static func cacheKey(for value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let key = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return key.isEmpty ? "camera-file" : key
  }
}

struct WiredCameraImportState {
  var devices: [WiredCameraImportDevice] = []
  var selectedDeviceID: String?
  var items: [WiredCameraImportItem] = []
  var selectedItemIDs: Set<String> = []
  var importedItemIDs: Set<String> = []
  var proofingFavoriteItemIDs: Set<String> = []
  var filterState = WiredCameraImportFilterState()
  var isLiveCatalogReady = false
  var isBrowsing = false
  var isLoadingItems = false
  var isImporting = false
  var importedCount = 0
  var errorMessage: String?

  var selectedDevice: WiredCameraImportDevice? {
    guard let selectedDeviceID else { return nil }
    return devices.first { $0.id == selectedDeviceID }
  }

  var importableItems: [WiredCameraImportItem] {
    guard isLiveCatalogReady else { return [] }
    return items.filter { $0.isImportable && !importedItemIDs.contains($0.id) }
  }

  var selectedImportableItems: [WiredCameraImportItem] {
    guard isLiveCatalogReady else { return [] }
    return items.filter { selectedItemIDs.contains($0.id) && $0.isImportable && !importedItemIDs.contains($0.id) }
  }

  func filteredItems(
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [WiredCameraImportItem] {
    WiredCameraImportFilterPolicy.filteredItems(
      items,
      state: filterState,
      importedItemIDs: importedItemIDs,
      proofingFavoriteItemIDs: proofingFavoriteItemIDs,
      now: now,
      calendar: calendar
    )
  }

  func filteredImportableItems(
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [WiredCameraImportItem] {
    guard isLiveCatalogReady else { return [] }
    return filteredItems(now: now, calendar: calendar).filter { $0.isImportable && !importedItemIDs.contains($0.id) }
  }

  func selectedFilteredImportableItems(
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [WiredCameraImportItem] {
    filteredImportableItems(now: now, calendar: calendar).filter { selectedItemIDs.contains($0.id) }
  }

  mutating func replaceDevices(_ nextDevices: [WiredCameraImportDevice]) {
    devices = nextDevices
    if let selectedDeviceID, nextDevices.contains(where: { $0.id == selectedDeviceID }) {
      return
    }
    selectedDeviceID = nextDevices.first?.id
    replaceItems([], isLiveCatalog: false)
  }

  mutating func selectDevice(id: String) {
    selectedDeviceID = id
    replaceItems([], isLiveCatalog: false)
  }

  mutating func replaceItems(_ nextItems: [WiredCameraImportItem], isLiveCatalog: Bool = true) {
    isLiveCatalogReady = isLiveCatalog
    let thumbnailsByID = Dictionary(uniqueKeysWithValues: items.compactMap { item in
      item.thumbnail.map { (item.id, $0) }
    })
    items = nextItems
    for index in items.indices {
      if items[index].thumbnail == nil {
        items[index].thumbnail = thumbnailsByID[items[index].id]
      }
    }
    let validIDs = Set(nextItems.map(\.id))
    selectedItemIDs = selectedItemIDs.intersection(validIDs)
    proofingFavoriteItemIDs = proofingFavoriteItemIDs.intersection(validIDs)
    importedItemIDs = importedItemIDs.intersection(validIDs)
  }

  mutating func toggleSelection(for item: WiredCameraImportItem) {
    guard isLiveCatalogReady, item.isImportable, !importedItemIDs.contains(item.id) else { return }
    if selectedItemIDs.contains(item.id) {
      selectedItemIDs.remove(item.id)
    } else {
      selectedItemIDs.insert(item.id)
    }
  }

  mutating func setSelection(_ shouldSelect: Bool, for item: WiredCameraImportItem) {
    guard isLiveCatalogReady, item.isImportable, !importedItemIDs.contains(item.id) else { return }
    if shouldSelect {
      selectedItemIDs.insert(item.id)
    } else {
      selectedItemIDs.remove(item.id)
    }
  }

  mutating func setProofingFavorite(_ shouldFavorite: Bool, itemID: String) {
    guard items.contains(where: { $0.id == itemID }) else { return }
    if shouldFavorite {
      proofingFavoriteItemIDs.insert(itemID)
    } else {
      proofingFavoriteItemIDs.remove(itemID)
    }
  }

  mutating func selectAllImportable() {
    guard isLiveCatalogReady else {
      selectedItemIDs.removeAll()
      return
    }
    selectedItemIDs = Set(importableItems.map(\.id))
  }

  mutating func selectAllFilteredImportable(
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) {
    selectedItemIDs = Set(filteredImportableItems(now: now, calendar: calendar).map(\.id))
  }

  mutating func toggleAllFilteredImportable(
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) {
    let filteredIDs = Set(filteredImportableItems(now: now, calendar: calendar).map(\.id))
    guard !filteredIDs.isEmpty else {
      selectedItemIDs.removeAll()
      return
    }
    if filteredIDs.isSubset(of: selectedItemIDs) {
      selectedItemIDs.subtract(filteredIDs)
    } else {
      selectedItemIDs.formUnion(filteredIDs)
    }
  }

  mutating func markImported(itemID: String) {
    importedItemIDs.insert(itemID)
    selectedItemIDs.remove(itemID)
  }

  mutating func applyCache(_ snapshot: WiredCameraImportCacheSnapshot) {
    if selectedDeviceID == nil {
      selectedDeviceID = snapshot.device.id
    }
    replaceItems(snapshot.items, isLiveCatalog: false)
    importedItemIDs = snapshot.importedItemIDs
  }

  mutating func clearSelection() {
    selectedItemIDs.removeAll()
  }
}

enum WiredCameraDeletePolicy {
  static func selectedItem(
    from state: WiredCameraImportState,
    isDeleting: Bool
  ) -> WiredCameraImportItem? {
    guard state.isLiveCatalogReady, !state.isImporting, !isDeleting else { return nil }
    let selectedItems = state.items.filter {
      state.selectedItemIDs.contains($0.id) &&
        $0.isImportable &&
        !state.importedItemIDs.contains($0.id)
    }
    guard selectedItems.count == 1 else { return nil }
    return selectedItems[0]
  }
}

enum WiredCameraThumbnailQueuePolicy {
  static func shouldStartRequest(
    isDeleteInFlight: Bool,
    isForegroundOperationInFlight: Bool = false,
    hasActiveThumbnailRequest: Bool
  ) -> Bool {
    !isDeleteInFlight && !isForegroundOperationInFlight && !hasActiveThumbnailRequest
  }
}

enum WiredCameraPreviewPolicy {
  static let gridMaximumPixelSize = 320
  static let maximumPixelSize = 1_536
}

enum WiredCameraImportSortPolicy {
  static func newestFirst(_ items: [WiredCameraImportItem]) -> [WiredCameraImportItem] {
    items.sorted(by: shouldPlaceBefore)
  }

  private static func shouldPlaceBefore(
    _ left: WiredCameraImportItem,
    _ right: WiredCameraImportItem
  ) -> Bool {
    switch (left.createdAt, right.createdAt) {
    case let (lhs?, rhs?) where lhs != rhs:
      return lhs > rhs
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      if left.ptpObjectHandle != right.ptpObjectHandle {
        return left.ptpObjectHandle > right.ptpObjectHandle
      }
      if left.name != right.name {
        return left.name > right.name
      }
      return left.id > right.id
    }
  }
}

struct WiredCameraImportDaySection: Equatable {
  let day: Date?
  let title: String
  let items: [WiredCameraImportItem]
}

enum WiredCameraImportSectionPolicy {
  static func sections(
    from items: [WiredCameraImportItem],
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [WiredCameraImportDaySection] {
    guard !items.isEmpty else { return [] }

    var orderedDays: [Date] = []
    var itemsByDay: [Date: [WiredCameraImportItem]] = [:]
    var unknownDateItems: [WiredCameraImportItem] = []
    for item in items {
      guard let createdAt = item.createdAt else {
        unknownDateItems.append(item)
        continue
      }
      let day = calendar.startOfDay(for: createdAt)
      if itemsByDay[day] == nil {
        orderedDays.append(day)
        itemsByDay[day] = []
      }
      itemsByDay[day]?.append(item)
    }

    var sections = orderedDays.compactMap { day -> WiredCameraImportDaySection? in
      guard let dayItems = itemsByDay[day], !dayItems.isEmpty else { return nil }
      return WiredCameraImportDaySection(
        day: day,
        title: "\(dayLabel(for: day, now: now, calendar: calendar)) · \(dayItems.count) 张",
        items: dayItems
      )
    }
    if !unknownDateItems.isEmpty {
      sections.append(
        WiredCameraImportDaySection(
          day: nil,
          title: "未知日期 · \(unknownDateItems.count) 张",
          items: unknownDateItems
        )
      )
    }
    return sections
  }

  private static func dayLabel(for day: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(day, inSameDayAs: now) {
      return "今天"
    }
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
      return formattedDay(day)
    }
    if calendar.isDate(day, inSameDayAs: yesterday) {
      return "昨天"
    }
    return formattedDay(day)
  }

  private static func formattedDay(_ day: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日"
    return formatter.string(from: day)
  }
}

enum WiredCameraThumbnailRequestWindowPolicy {
  private static let prefetchRowsBefore = 1
  private static let prefetchRowsAfter = 2

  static func itemIDsToRequest(
    orderedItemIDs: [String],
    visibleItemIDs: [String],
    columnCount: Int
  ) -> [String] {
    guard !orderedItemIDs.isEmpty, !visibleItemIDs.isEmpty else { return [] }
    let indexByID = Dictionary(uniqueKeysWithValues: orderedItemIDs.enumerated().map { ($0.element, $0.offset) })
    let visibleOrdered = visibleItemIDs
      .filter { indexByID[$0] != nil }
      .reduce(into: [String]()) { result, itemID in
        if !result.contains(itemID) { result.append(itemID) }
      }
      .sorted { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    guard let firstVisibleIndex = visibleOrdered.compactMap({ indexByID[$0] }).min(),
          let lastVisibleIndex = visibleOrdered.compactMap({ indexByID[$0] }).max() else {
      return []
    }

    let safeColumnCount = max(columnCount, 1)
    let start = max(0, firstVisibleIndex - safeColumnCount * prefetchRowsBefore)
    let end = min(orderedItemIDs.count - 1, lastVisibleIndex + safeColumnCount * prefetchRowsAfter)
    let visibleSet = Set(visibleOrdered)
    let nearby = orderedItemIDs[start...end].filter { !visibleSet.contains($0) }
    return visibleOrdered + nearby
  }
}

enum WiredCameraImportDateFilter: Codable, Equatable {
  case all
  case today
  case specificDay(Date)
  case range(Date, Date)
}

enum WiredCameraImportFormatFilter: Codable, Equatable {
  case all
  case jpg
  case heif
  case raw
  case video
}

enum WiredCameraImportStatusFilter: Codable, Equatable {
  case all
  case notImported
  case imported
  case proofingFavorite
}

struct WiredCameraImportFilterState: Codable, Equatable {
  var date: WiredCameraImportDateFilter = .all
  var format: WiredCameraImportFormatFilter = .all
  var importedStatus: WiredCameraImportStatusFilter = .all
}

enum WiredCameraImportFilterPolicy {
  static func filteredItems(
    _ items: [WiredCameraImportItem],
    state: WiredCameraImportFilterState,
    importedItemIDs: Set<String>,
    proofingFavoriteItemIDs: Set<String> = [],
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [WiredCameraImportItem] {
    items.filter { item in
      matchesDate(item, date: state.date, now: now, calendar: calendar) &&
      matchesFormat(item, format: state.format) &&
      matchesImportedStatus(
        item,
        status: state.importedStatus,
        importedItemIDs: importedItemIDs,
        proofingFavoriteItemIDs: proofingFavoriteItemIDs
      )
    }
  }

  private static func matchesDate(
    _ item: WiredCameraImportItem,
    date: WiredCameraImportDateFilter,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    switch date {
    case .all:
      return true
    case .today:
      guard let createdAt = item.createdAt else { return false }
      return calendar.isDate(createdAt, inSameDayAs: now)
    case .specificDay(let day):
      guard let createdAt = item.createdAt else { return false }
      return calendar.isDate(createdAt, inSameDayAs: day)
    case .range(let firstDay, let secondDay):
      guard let createdAt = item.createdAt else { return false }
      let start = calendar.startOfDay(for: min(firstDay, secondDay))
      guard let end = calendar.date(
        byAdding: .day,
        value: 1,
        to: calendar.startOfDay(for: max(firstDay, secondDay))
      ) else {
        return false
      }
      return createdAt >= start && createdAt < end
    }
  }

  private static func matchesFormat(
    _ item: WiredCameraImportItem,
    format: WiredCameraImportFormatFilter
  ) -> Bool {
    format == .all || item.formatFilter == format
  }

  private static func matchesImportedStatus(
    _ item: WiredCameraImportItem,
    status: WiredCameraImportStatusFilter,
    importedItemIDs: Set<String>,
    proofingFavoriteItemIDs: Set<String>
  ) -> Bool {
    switch status {
    case .all:
      return true
    case .notImported:
      return !importedItemIDs.contains(item.id)
    case .imported:
      return importedItemIDs.contains(item.id)
    case .proofingFavorite:
      return proofingFavoriteItemIDs.contains(item.id)
    }
  }
}

struct WiredCameraImportCacheSnapshot: Codable, Equatable {
  let device: WiredCameraImportDevice
  let items: [WiredCameraImportItem]
  let importedItemIDs: Set<String>
  let cachedAt: Date
}

enum WiredCameraDownloadResolutionPolicy {
  static func resolvedURL(
    savedFilename: String?,
    requestedFilename: String,
    directory: URL
  ) -> URL {
    guard let savedFilename, !savedFilename.isEmpty else {
      return directory.appendingPathComponent(requestedFilename)
    }

    if let url = URL(string: savedFilename), url.isFileURL {
      return url
    }

    if savedFilename.hasPrefix("/") {
      return URL(fileURLWithPath: savedFilename)
    }

    return directory.appendingPathComponent(savedFilename)
  }
}

struct WiredCameraImportCacheStore {
  let rootDirectory: URL
  private let fileManager: FileManager

  init(
    rootDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CamTransferWiredImportCacheV3", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory
    self.fileManager = fileManager
  }

  func save(_ snapshot: WiredCameraImportCacheSnapshot) throws {
    try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    try data.write(to: url(forDeviceID: snapshot.device.id), options: [.atomic])
  }

  func load(deviceID: String) throws -> WiredCameraImportCacheSnapshot? {
    let url = url(forDeviceID: deviceID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WiredCameraImportCacheSnapshot.self, from: data)
  }

  private func url(forDeviceID deviceID: String) -> URL {
    rootDirectory.appendingPathComponent("\(cacheKey(for: deviceID)).json", isDirectory: false)
  }

  private func cacheKey(for value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let key = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return key.isEmpty ? "camera" : key
  }
}

enum WiredCameraImportHistoryStore {
  private static let storageKey = "camtransfer.wiredImportHistory.v3"

  static func importedItemIDs(for deviceID: String) -> Set<String> {
    let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
    return Set(dict[deviceID] ?? [])
  }

  static func markImported(itemID: String, for deviceID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
    var existing = Set(dict[deviceID] ?? [])
    existing.insert(itemID)
    dict[deviceID] = Array(existing).sorted()
    UserDefaults.standard.set(dict, forKey: storageKey)
  }
}

struct WiredCameraThumbnailCacheStore {
  let rootDirectory: URL
  private let fileManager: FileManager

  init(
    rootDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CamTransferWiredThumbnailCacheV3", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory
    self.fileManager = fileManager
  }

  func loadThumbnail(deviceID: String, itemID: String) -> UIImage? {
    let url = url(deviceID: deviceID, itemID: itemID)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
  }

  func saveThumbnail(_ image: UIImage, deviceID: String, itemID: String) {
    guard let data = image.jpegData(compressionQuality: 0.78) else { return }
    let url = url(deviceID: deviceID, itemID: itemID)
    try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: [.atomic])
  }

  private func url(deviceID: String, itemID: String) -> URL {
    rootDirectory
      .appendingPathComponent(cacheKey(for: deviceID), isDirectory: true)
      .appendingPathComponent("\(cacheKey(for: itemID)).jpg", isDirectory: false)
  }

  private func cacheKey(for value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let key = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return key.isEmpty ? "item" : key
  }
}

enum WiredCameraImportPolicy {
  private static let supportedExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
    "raf", "raw", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf",
    "mov", "mp4", "avi",
  ]

  static func isSupportedMedia(filename: String, uti: String?) -> Bool {
    if let uti = uti?.lowercased() {
      if uti.contains("image") || uti.contains("movie") || uti.contains("video") || uti.contains("heic") {
        return true
      }
      if uti.contains("raw-image") {
        return true
      }
    }

    let ext = (filename as NSString).pathExtension.lowercased()
    return supportedExtensions.contains(ext)
  }

  static func mediaType(filename: String, uti: String?) -> CameraVendorDownloadedMediaType {
    if let uti = uti?.lowercased(), uti.contains("movie") || uti.contains("video") {
      return .video
    }
    let ext = (filename as NSString).pathExtension.lowercased()
    return ["mov", "mp4", "avi"].contains(ext) ? .video : .photo
  }

  static func formatFilter(filename: String, uti: String?) -> WiredCameraImportFormatFilter {
    let lowerUTI = uti?.lowercased()
    let ext = (filename as NSString).pathExtension.lowercased()
    if lowerUTI?.contains("movie") == true || lowerUTI?.contains("video") == true || ["mov", "mp4", "avi"].contains(ext) {
      return .video
    }
    if lowerUTI?.contains("heic") == true || lowerUTI?.contains("heif") == true || ["heic", "heif"].contains(ext) {
      return .heif
    }
    if lowerUTI?.contains("raw-image") == true || ["raf", "raw", "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf"].contains(ext) {
      return .raw
    }
    if lowerUTI?.contains("jpeg") == true || ["jpg", "jpeg"].contains(ext) {
      return .jpg
    }
    return .all
  }
}

enum WiredCameraAutoImportPolicy {
  static func itemsToImport(from state: WiredCameraImportState, isEnabled: Bool = false) -> [WiredCameraImportItem] {
    guard isEnabled, state.isLiveCatalogReady else { return [] }
    return state.items.filter { item in
      item.isImportable && !state.importedItemIDs.contains(item.id)
    }
  }
}

enum WiredCameraImportNavigationPolicy {
  static func canLeaveImportScreen(isImporting: Bool) -> Bool {
    !isImporting
  }

  static func canOpenPreview(isImporting: Bool) -> Bool {
    !isImporting
  }
}
