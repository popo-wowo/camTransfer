# iOS Camera Adapter Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce an iOS camera adapter/profile architecture while preserving the current Fujifilm X-T5 behavior.

**Architecture:** Add generic camera-facing protocols first, then introduce a Fujifilm X-series profile that mirrors current policy values. Migrate UI dependencies to generic protocols before moving runtime implementation files, so each step is behavior-preserving and testable.

**Tech Stack:** Swift 5, UIKit, CoreBluetooth, NetworkExtension, PTP/IP socket code, XCTest, Xcode iOS project.

---

## File Structure

- Create `ios/Runner/CameraAdapters/Core/CameraAdapter.swift`: generic adapter and gallery session protocols used by UI.
- Create `ios/Runner/CameraAdapters/Fujifilm/FujifilmXSeriesProfile.swift`: current X-T5 profile and pure capability values.
- Modify `ios/Runner.xcodeproj/project.pbxproj`: add new Swift files to the Runner target.
- Modify `ios/Runner/NativeConnectViewController.swift`: depend on `CameraGallerySession` where possible.
- Modify `ios/RunnerTests/RunnerTests.swift`: add regression tests for the generic contract and current Fujifilm profile.
- Later phases will split `CameraVendorBluetoothService.swift`; the first implementation batch intentionally avoids moving live BLE/PTP code.

## Task 1: Add Core Camera Interfaces

**Files:**
- Create: `ios/Runner/CameraAdapters/Core/CameraAdapter.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these tests to `RunnerTests`:

```swift
func testCameraGallerySessionProtocolMatchesCurrentGalleryServiceContract() {
  XCTAssertTrue((CameraVendorRealtimeGalleryService.self as Any.Type) is CameraGallerySession.Type)
}

func testCameraAdapterDescriptorCanDescribeFujifilmWithoutUiBrandClaims() {
  let descriptor = CameraAdapterDescriptor(
    id: "fujifilm-x-series",
    displayName: "FUJIFILM X Series",
    legalDisclaimer: "FUJIFILM is a trademark of FUJIFILM Corporation. This app is not affiliated with or endorsed by FUJIFILM Corporation."
  )

  XCTAssertEqual(descriptor.id, "fujifilm-x-series")
  XCTAssertTrue(descriptor.displayName.contains("FUJIFILM"))
  XCTAssertTrue(descriptor.legalDisclaimer.contains("not affiliated"))
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testCameraGallerySessionProtocolMatchesCurrentGalleryServiceContract -only-testing:RunnerTests/RunnerTests/testCameraAdapterDescriptorCanDescribeFujifilmWithoutUiBrandClaims
```

Expected: compile failure because `CameraGallerySession` and `CameraAdapterDescriptor` do not exist.

- [ ] **Step 3: Add minimal core interfaces**

Create `CameraAdapter.swift`:

```swift
import Foundation

struct CameraAdapterDescriptor: Equatable {
  let id: String
  let displayName: String
  let legalDisclaimer: String?
}

protocol CameraGallerySession: CameraVendorGalleryService,
  CameraVendorGalleryConnectionTerminating,
  CameraVendorGalleryDiagnosticReporting,
  CameraVendorGalleryConfigurable,
  CameraVendorReservedReceiveDiagnosticService,
  CameraVendorParallelDownloadFactory {}

protocol CameraAdapter {
  var descriptor: CameraAdapterDescriptor { get }
  func makeGallerySession() -> CameraGallerySession
}
```

Update `CameraVendorRealtimeGalleryService` conformance:

```swift
final class CameraVendorRealtimeGalleryService: CameraGallerySession {
```

- [ ] **Step 4: Run tests and verify pass**

Run the same targeted command.

Expected: both tests pass.

## Task 2: Add Fujifilm X-Series Profile

**Files:**
- Create: `ios/Runner/CameraAdapters/Fujifilm/FujifilmXSeriesProfile.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add:

```swift
func testFujifilmXSeriesProfilePreservesCurrentXt5GalleryPolicies() {
  let profile = FujifilmXSeriesProfile.xt5Current

  XCTAssertEqual(profile.id, "fujifilm-x-series-xt5-current")
  XCTAssertEqual(profile.ptpStartupDelaySeconds, CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true))
  XCTAssertEqual(profile.fileDownloadReadSize, CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize)
  XCTAssertEqual(profile.fileDownloadFallbackReadSize, CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize)
  XCTAssertEqual(profile.parallelDownloadMaxWorkers, CameraVendorParallelDownloadPolicy.maxWorkers)
  XCTAssertEqual(profile.hiddenHandleMaxOverallRange, CameraVendorHiddenObjectHandleProbePolicy.maxOverallRange)
  XCTAssertEqual(profile.hiddenHandleMaxContiguousGapRange, CameraVendorHiddenObjectHandleProbePolicy.maxContiguousGapRange)
  XCTAssertEqual(profile.shouldResetCompressionModeBeforeObjectInfoList, CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetCompressionModeBeforeObjectInfoList)
}

func testFujifilmXSeriesProfilePreservesCurrentObjectSizePolicy() {
  let profile = FujifilmXSeriesProfile.xt5Current

  XCTAssertTrue(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: 100))
  XCTAssertTrue(profile.shouldSkipFreshFileInfoProbe(formatLabel: "RAW", cachedExpectedSize: 100))
  XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "JPG", cachedExpectedSize: 100))
  XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: nil))
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testFujifilmXSeriesProfilePreservesCurrentXt5GalleryPolicies -only-testing:RunnerTests/RunnerTests/testFujifilmXSeriesProfilePreservesCurrentObjectSizePolicy
```

Expected: compile failure because `FujifilmXSeriesProfile` does not exist.

- [ ] **Step 3: Add profile implementation**

Create `FujifilmXSeriesProfile.swift`:

```swift
import Foundation

struct FujifilmXSeriesProfile: Equatable {
  let id: String
  let ptpStartupDelaySeconds: TimeInterval
  let fileDownloadReadSize: UInt32
  let fileDownloadFallbackReadSize: UInt32
  let parallelDownloadMaxWorkers: Int
  let hiddenHandleMaxOverallRange: UInt32
  let hiddenHandleMaxContiguousGapRange: UInt32
  let shouldResetCompressionModeBeforeObjectInfoList: Bool

  static let xt5Current = FujifilmXSeriesProfile(
    id: "fujifilm-x-series-xt5-current",
    ptpStartupDelaySeconds: CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true),
    fileDownloadReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
    fileDownloadFallbackReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
    parallelDownloadMaxWorkers: CameraVendorParallelDownloadPolicy.maxWorkers,
    hiddenHandleMaxOverallRange: CameraVendorHiddenObjectHandleProbePolicy.maxOverallRange,
    hiddenHandleMaxContiguousGapRange: CameraVendorHiddenObjectHandleProbePolicy.maxContiguousGapRange,
    shouldResetCompressionModeBeforeObjectInfoList: CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetCompressionModeBeforeObjectInfoList
  )

  func shouldSkipFreshFileInfoProbe(formatLabel: String, cachedExpectedSize: UInt32?) -> Bool {
    CameraVendorOriginalDownloadPolicy.shouldSkipFreshFileInfoProbe(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    )
  }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run the same targeted command.

Expected: both tests pass.

## Task 3: Add Fujifilm Adapter Shell

**Files:**
- Create: `ios/Runner/CameraAdapters/Fujifilm/FujifilmCameraAdapter.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add:

```swift
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
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testFujifilmCameraAdapterCreatesCurrentGallerySession -only-testing:RunnerTests/RunnerTests/testFujifilmCameraAdapterExposesCurrentProfileForDiagnostics
```

Expected: compile failure because `FujifilmCameraAdapter` does not exist.

- [ ] **Step 3: Add adapter shell**

Create `FujifilmCameraAdapter.swift`:

```swift
import Foundation

struct FujifilmCameraAdapter: CameraAdapter {
  let profile: FujifilmXSeriesProfile

  let descriptor = CameraAdapterDescriptor(
    id: "fujifilm-x-series",
    displayName: "FUJIFILM X Series",
    legalDisclaimer: "FUJIFILM is a trademark of FUJIFILM Corporation. This app is not affiliated with or endorsed by FUJIFILM Corporation."
  )

  func makeGallerySession() -> CameraGallerySession {
    CameraVendorRealtimeGalleryService()
  }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run the same targeted command.

Expected: both tests pass.

## Task 4: Route Connect UI Through Adapter-Owned Gallery Session

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testNativeConnectUsesDefaultFujifilmAdapterDescriptor() {
  let descriptor = NativeCameraAdapterRegistry.defaultAdapterDescriptor

  XCTAssertEqual(descriptor.id, "fujifilm-x-series")
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testNativeConnectUsesDefaultFujifilmAdapterDescriptor
```

Expected: compile failure because `NativeCameraAdapterRegistry` does not exist.

- [ ] **Step 3: Add registry and use it for gallery service creation**

Add near the connect UI policies:

```swift
enum NativeCameraAdapterRegistry {
  static let defaultAdapter = FujifilmCameraAdapter(profile: .xt5Current)
  static var defaultAdapterDescriptor: CameraAdapterDescriptor {
    defaultAdapter.descriptor
  }
}
```

Change the connect controller gallery service property from concrete creation:

```swift
private let galleryService: CameraVendorGalleryService = CameraVendorRealtimeGalleryService()
```

to adapter creation:

```swift
private let galleryService: CameraGallerySession = NativeCameraAdapterRegistry.defaultAdapter.makeGallerySession()
```

- [ ] **Step 4: Run test and verify pass**

Run the same targeted command.

Expected: test passes.

## Task 5: Full Verification And Device Build

**Files:**
- No source changes.

- [ ] **Step 1: Run full iOS tests**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
```

Expected: `TEST SUCCEEDED`, all tests pass.

- [ ] **Step 2: Build for real device**

Run:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install to iPhone if available**

Run:

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device 952611F0-557B-5C5F-BF1F-265474E9BC4B /Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-fgsgtrspheaswdbhlcgnkxfynojt/Build/Products/Debug-iphoneos/Runner.app
```

Expected: app installed for bundle id `com.camtransfer.app`.
