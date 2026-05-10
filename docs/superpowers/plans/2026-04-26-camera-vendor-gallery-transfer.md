# CameraVendor Gallery Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an iOS-native CameraVendor gallery MVP with photo listing, thumbnail preview, single download, and multi-select batch download after BLE pairing succeeds.

**Architecture:** Keep BLE pairing in the existing `CameraVendorBluetoothService`, then introduce a pure Swift gallery state layer that is unit-testable and independent from UIKit. The UIKit gallery screen will bind to that state and call a gallery service abstraction that can first be stubbed and then upgraded toward real CameraVendor Wi-Fi PTP/IP transport.

**Tech Stack:** Swift, UIKit, SwiftUI app shell, XCTest, CoreBluetooth, Foundation

---

### Task 1: Add failing tests for gallery state and download queue

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testGallerySelectionToggleAndSelectAllFlow() {
  let items = [
    CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
    CameraVendorGalleryItem(handle: 2, filename: "B.RAF", formatLabel: "RAW", captureDate: "2026", byteSizeText: "20 MB"),
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
    CameraVendorGalleryItem(handle: 11, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
    CameraVendorGalleryItem(handle: 22, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
  ]
  var state = CameraVendorGalleryState(items: items)

  state.enqueueDownloads(for: [11, 22])

  XCTAssertEqual(state.downloadState(for: 11), .queued)
  XCTAssertEqual(state.downloadState(for: 22), .queued)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL with unknown types such as `CameraVendorGalleryItem` and `CameraVendorGalleryState`

- [ ] **Step 3: Write minimal implementation**

```swift
struct CameraVendorGalleryItem: Equatable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: String
  let byteSizeText: String
}

enum CameraVendorDownloadState: Equatable {
  case idle
  case queued
  case downloading
  case saved
  case failed(String)
}

struct CameraVendorGalleryState {
  var items: [CameraVendorGalleryItem]
  var selectedHandles: Set<Int> = []
  private var downloadStates: [Int: CameraVendorDownloadState] = [:]

  mutating func toggleSelection(handle: Int) { /* ... */ }
  mutating func selectAll() { /* ... */ }
  mutating func clearSelection() { /* ... */ }
  mutating func enqueueDownloads(for handles: [Int]) { /* ... */ }
  func downloadState(for handle: Int) -> CameraVendorDownloadState { /* ... */ }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS for the new gallery state tests

### Task 2: Add failing tests for download lifecycle updates

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testGalleryDownloadLifecycleTracksProgressAndFailure() {
  let items = [CameraVendorGalleryItem(handle: 5, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "2 MB")]
  var state = CameraVendorGalleryState(items: items)

  state.enqueueDownloads(for: [5])
  state.markDownloadStarted(handle: 5)
  XCTAssertEqual(state.downloadState(for: 5), .downloading)

  state.markDownloadFinished(handle: 5)
  XCTAssertEqual(state.downloadState(for: 5), .saved)

  state.markDownloadFailed(handle: 5, message: "network")
  XCTAssertEqual(state.downloadState(for: 5), .failed("network"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL because lifecycle methods do not exist yet

- [ ] **Step 3: Write minimal implementation**

```swift
mutating func markDownloadStarted(handle: Int) {
  downloadStates[handle] = .downloading
}

mutating func markDownloadFinished(handle: Int) {
  downloadStates[handle] = .saved
}

mutating func markDownloadFailed(handle: Int, message: String) {
  downloadStates[handle] = .failed(message)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS for lifecycle tests

### Task 3: Add gallery service abstraction and a local stub implementation

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testStubGalleryServiceReturnsSampleItems() async throws {
  let service = CameraVendorGalleryStubService()
  let items = try await service.fetchGallery()

  XCTAssertFalse(items.isEmpty)
  XCTAssertEqual(items.first?.filename, "DSCF0001.JPG")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL because `CameraVendorGalleryStubService` is missing

- [ ] **Step 3: Write minimal implementation**

```swift
protocol CameraVendorGalleryService {
  func fetchGallery() async throws -> [CameraVendorGalleryItem]
  func fetchThumbnail(for handle: Int) async throws -> Data
  func downloadOriginal(for handle: Int) async throws -> Data
}

struct CameraVendorGalleryStubService: CameraVendorGalleryService {
  func fetchGallery() async throws -> [CameraVendorGalleryItem] { /* sample items */ }
  func fetchThumbnail(for handle: Int) async throws -> Data { Data() }
  func downloadOriginal(for handle: Int) async throws -> Data { Data() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS with deterministic stub output

### Task 4: Add a native gallery screen and wire navigation from handshake success

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testHandshakeCompletionSummaryContainsDeviceAndSerial() {
  let summary = CameraVendorConnectionSummary(deviceName: "DEVICE-A", serialNumber: "1234")
  XCTAssertEqual(summary.navigationTitle, "DEVICE-A")
  XCTAssertTrue(summary.subtitle.contains("1234"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL because connection summary model is missing

- [ ] **Step 3: Write minimal implementation**

```swift
struct CameraVendorConnectionSummary: Equatable {
  let deviceName: String
  let serialNumber: String
  var navigationTitle: String { deviceName }
  var subtitle: String { "序列号 \(serialNumber)" }
}
```

Then update the connect screen so successful handshake pushes a `NativeGalleryViewController(summary:service:)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS and app still builds

### Task 5: Implement single-download and multi-select download actions

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testQueuedBatchDownloadKeepsUnselectedHandlesIdle() {
  let items = [
    CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
    CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
    CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026", byteSizeText: "1 MB"),
  ]
  var state = CameraVendorGalleryState(items: items)

  state.enqueueDownloads(for: [1, 3])

  XCTAssertEqual(state.downloadState(for: 1), .queued)
  XCTAssertEqual(state.downloadState(for: 2), .idle)
  XCTAssertEqual(state.downloadState(for: 3), .queued)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL until queue behavior is fully implemented

- [ ] **Step 3: Write minimal implementation**

```swift
mutating func enqueueDownloads(for handles: [Int]) {
  for handle in handles {
    downloadStates[handle] = .queued
  }
}
```

Then connect gallery row actions and toolbar actions to sequential download tasks that update the state before and after each transfer.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS and gallery actions compile

### Task 6: Verify the app on simulator and real device

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Run the iOS unit tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: `TEST SUCCEEDED`

- [ ] **Step 2: Build for the connected iPhone**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Runner.xcodeproj -scheme Runner -destination 'id=00008150-001C7D2C2E7A401C' -allowProvisioningUpdates build`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Install to the connected iPhone**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device 00008150-001C7D2C2E7A401C /Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-hckghnglpmjgilcxkibfwjsdsfpl/Build/Products/Debug-iphoneos/Runner.app`

Expected: app install completes without signing errors

- [ ] **Step 4: Launch with console attached**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch --console --terminate-existing --device 00008150-001C7D2C2E7A401C com.camtransfer.app`

Expected: live logs show connection flow, then gallery loading flow after pairing

### Task 7: Add gallery diagnostics and minimal camera Wi-Fi assist

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testConnectionSummaryGeneratesCameraWifiCandidates() {
  let summary = CameraVendorConnectionSummary(
    deviceName: "DEVICE-A",
    serialNumber: "221019F1932011003B"
  )

  XCTAssertEqual(summary.wifiCandidates, ["DEVICE-A-003B", "DEVICE-A"])
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: FAIL because `wifiCandidates` and `CameraVendorGalleryDiagnostics` do not exist yet

- [ ] **Step 3: Write minimal implementation**

```swift
struct CameraVendorGalleryDiagnostics {
  static func composeFailureMessage(baseMessage: String, diagnostics: [String]) -> String {
    guard !diagnostics.isEmpty else { return baseMessage }
    return ([baseMessage, "诊断信息:", diagnostics.joined(separator: "\n")]).joined(separator: "\n")
  }
}

extension CameraVendorConnectionSummary {
  var wifiCandidates: [String] {
    let suffix = serialNumber.suffix(2).uppercased()
    let paddedSuffix = suffix.count == 2 ? "00\(suffix)" : String(suffix)
    return Array(NSOrderedSet(array: ["\(deviceName)-\(paddedSuffix)", deviceName])) as? [String] ?? [deviceName]
  }
}
```

Then add:
- Gallery-stage diagnostic callbacks in the realtime service
- Explicit PTP step logs for socket connect, session open, storage fetch, handle fetch, and object info fetch
- A minimal `NEHotspotConfiguration` join attempt using `wifiCandidates` and password `00000000`
- UI status text that shows diagnostics instead of silent spinning

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'`

Expected: PASS with deterministic diagnostics behavior
