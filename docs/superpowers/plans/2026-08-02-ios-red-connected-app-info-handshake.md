# iOS RED Connected Application Information Handshake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS BLE pairing/reconnect flow write `8B5ECF55 = 80 01 01` when the camera exposes that capability, and block Wi-Fi/PTP activation until its write response succeeds.

**Architecture:** Add a small pure capability policy beside the existing secure-handshake policies, then integrate it into the single identity-write completion path in `CameraVendorBluetoothService`. The service remains the CoreBluetooth executor; the policy owns UUID, payload, timeout, and callback-generation acceptance. Cameras without the characteristic keep the existing path.

**Tech Stack:** Swift 5, CoreBluetooth, XCTest, Xcode iOS simulator and iPhoneOS builds.

---

## File map

- Modify `ios/Runner/CameraVendorSecureHandshake.swift`: define the capability policy and the additional pending phase.
- Modify `ios/Runner/CameraVendorBluetoothService.swift`: discover the characteristic, execute/fence the write, handle success/error/timeout, and reset state between attempts.
- Modify `ios/RunnerTests/RunnerTests.swift`: add pure-policy regression tests and source-boundary tests proving identity completion cannot bypass the capability write.

### Task 1: Lock the capability contract with failing tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add failing policy tests**

Add tests near the existing secure handshake codec tests:

```swift
func testConnectedApplicationHandshakeRequiresXAppIdentityWhenCharacteristicExists() {
  let action = CameraVendorConnectedApplicationHandshakePolicy.action(
    availableCharacteristicUUIDStrings: [
      CameraVendorConnectedApplicationHandshakePolicy.characteristicUUIDString
    ]
  )

  XCTAssertEqual(action, .writeApplicationInfo(Data([0x80, 0x01, 0x01])))
}

func testConnectedApplicationHandshakeCompletesDirectlyWhenCharacteristicIsAbsent() {
  XCTAssertEqual(
    CameraVendorConnectedApplicationHandshakePolicy.action(
      availableCharacteristicUUIDStrings: []
    ),
    .completeIdentityHandshake
  )
}

func testConnectedApplicationHandshakeRejectsStaleOrForeignWriteCallbacks() {
  XCTAssertTrue(
    CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
      pendingGeneration: 4,
      currentGeneration: 4,
      isCurrentCharacteristic: true
    )
  )
  XCTAssertFalse(
    CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
      pendingGeneration: 3,
      currentGeneration: 4,
      isCurrentCharacteristic: true
    )
  )
  XCTAssertFalse(
    CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
      pendingGeneration: 4,
      currentGeneration: 4,
      isCurrentCharacteristic: false
    )
  )
}
```

- [ ] **Step 2: Add failing service-boundary tests**

Add a source inspection test that verifies the service has one post-identity owner and no direct bypass:

```swift
func testBluetoothIdentityWriteCompletionIsGatedByConnectedApplicationInfo() throws {
  let source = try runnerSource("CameraVendorBluetoothService.swift")
  let start = try XCTUnwrap(
    source.range(of: "func peripheral(\n    _ peripheral: CBPeripheral,\n    didWriteValueFor characteristic: CBCharacteristic")?.lowerBound
  )
  let end = try XCTUnwrap(
    source.range(of: "func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor", range: start..<source.endIndex)?.lowerBound
  )
  let body = String(source[start..<end])

  XCTAssertTrue(body.contains("continueAfterIdentityWrite(on: peripheral)"))
  XCTAssertTrue(body.contains("completeConnectedApplicationInfoWrite"))
  XCTAssertFalse(body.contains("secureHandshakePhase = .completed\n      handleIdentifierWriteCompletion(on: peripheral)"))
}
```

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```bash
xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testConnectedApplicationHandshakeRequiresXAppIdentityWhenCharacteristicExists \
  -only-testing:RunnerTests/RunnerTests/testConnectedApplicationHandshakeCompletesDirectlyWhenCharacteristicIsAbsent \
  -only-testing:RunnerTests/RunnerTests/testConnectedApplicationHandshakeRejectsStaleOrForeignWriteCallbacks \
  -only-testing:RunnerTests/RunnerTests/testBluetoothIdentityWriteCompletionIsGatedByConnectedApplicationInfo
```

Expected: compile/test failure because `CameraVendorConnectedApplicationHandshakePolicy` and the service gate do not exist.

- [ ] **Step 4: Commit the RED tests**

```bash
git add ios/RunnerTests/RunnerTests.swift
git commit -m "test: require connected application handshake gate"
```

### Task 2: Add the pure capability policy

**Files:**
- Modify: `ios/Runner/CameraVendorSecureHandshake.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add the action and policy**

Add after `CameraVendorSecureHandshakeCodec`:

```swift
enum CameraVendorConnectedApplicationHandshakeAction: Equatable {
  case completeIdentityHandshake
  case writeApplicationInfo(Data)
}

enum CameraVendorConnectedApplicationHandshakePolicy {
  static let characteristicUUIDString = "8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7"
  static let applicationInfoPayload = Data([0x80, 0x01, 0x01])
  static let writeTimeoutSeconds: TimeInterval = 5

  static func action(
    availableCharacteristicUUIDStrings: Set<String>
  ) -> CameraVendorConnectedApplicationHandshakeAction {
    let normalized = Set(availableCharacteristicUUIDStrings.map { $0.uppercased() })
    guard normalized.contains(characteristicUUIDString) else {
      return .completeIdentityHandshake
    }
    return .writeApplicationInfo(applicationInfoPayload)
  }

  static func acceptsWriteCallback(
    pendingGeneration: UInt64?,
    currentGeneration: UInt64,
    isCurrentCharacteristic: Bool
  ) -> Bool {
    pendingGeneration == currentGeneration && isCurrentCharacteristic
  }
}
```

- [ ] **Step 2: Add the pending secure phase**

Change `CameraVendorSecureHandshakePhase` to include:

```swift
case awaitingConnectedApplicationInfoWrite
```

Update the recovery-policy switch so this phase does not masquerade as an identification-number retry:

```swift
case .idle, .awaitingDeviceNameWrite, .awaitingIdentificationNumberRead,
     .awaitingConnectedApplicationInfoWrite, .completed:
  return false
```

- [ ] **Step 3: Run the three pure-policy tests**

Run the first three `-only-testing` selectors from Task 1.

Expected: all three pass.

- [ ] **Step 4: Commit the policy**

```bash
git add ios/Runner/CameraVendorSecureHandshake.swift
git commit -m "feat: define connected application handshake policy"
```

### Task 3: Integrate the capability gate into the BLE executor

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add characteristic and attempt state**

Add service fields:

```swift
private let connectedApplicationInfoCharacteristicUUID = CBUUID(
  string: CameraVendorConnectedApplicationHandshakePolicy.characteristicUUIDString
)
private var connectedApplicationInfoCharacteristic: CBCharacteristic?
private var connectedApplicationInfoTimeoutWorkItem: DispatchWorkItem?
private var secureHandshakeGeneration: UInt64 = 0
private var pendingConnectedApplicationInfoGeneration: UInt64?
```

Add one reset helper and invoke it from `resetForNewConnectionAttempt`, `startScan`, `prepareConnectionAttempt`, and `resetHandshakeStateForReconnect`:

```swift
private func resetConnectedApplicationHandshakeState() {
  connectedApplicationInfoTimeoutWorkItem?.cancel()
  connectedApplicationInfoTimeoutWorkItem = nil
  connectedApplicationInfoCharacteristic = nil
  pendingConnectedApplicationInfoGeneration = nil
  secureHandshakeGeneration &+= 1
}
```

- [ ] **Step 2: Capture the characteristic during discovery**

Extend the existing characteristic routing:

```swift
} else if characteristic.uuid == connectedApplicationInfoCharacteristicUUID {
  connectedApplicationInfoCharacteristic = characteristic
```

Do not put it in metadata reads or post-handshake probes.

- [ ] **Step 3: Add the single post-identity gate**

Add helpers:

```swift
private func continueAfterIdentityWrite(on peripheral: CBPeripheral) {
  hasWrittenPairingIdentifier = true
  let availableUUIDs = Set(discoveredCharacteristicsByUUID.keys.map { $0.uuidString })
  switch CameraVendorConnectedApplicationHandshakePolicy.action(
    availableCharacteristicUUIDStrings: availableUUIDs
  ) {
  case .completeIdentityHandshake:
    completeIdentityHandshake(on: peripheral)
  case .writeApplicationInfo(let payload):
    guard let characteristic = connectedApplicationInfoCharacteristic else {
      failConnectedApplicationHandshake("缺少 Connected Application Information 特征")
      return
    }
    secureHandshakePhase = .awaitingConnectedApplicationInfoWrite
    pendingConnectedApplicationInfoGeneration = secureHandshakeGeneration
    appendObservation("BLE_APP_INFO_REQUIRED uuid=\(characteristic.uuid.uuidString)")
    appendObservation(
      "BLE_APP_INFO_WRITE_REQUEST payload=\(hexString(payload)) generation=\(secureHandshakeGeneration)"
    )
    scheduleConnectedApplicationInfoTimeout(
      peripheral: peripheral,
      characteristic: characteristic,
      generation: secureHandshakeGeneration
    )
    peripheral.writeValue(payload, for: characteristic, type: .withResponse)
  }
}

private func completeIdentityHandshake(on peripheral: CBPeripheral) {
  secureHandshakePhase = .completed
  handleIdentifierWriteCompletion(on: peripheral)
}
```

Replace every direct post-identity `secureHandshakePhase = .completed` plus `handleIdentifierWriteCompletion` pair in `didWriteValueFor` with `continueAfterIdentityWrite(on: peripheral)`.

- [ ] **Step 4: Handle write success, failure, duplicate callback, and timeout**

Before generic write handling, add an app-info branch. Accept only the current characteristic instance and generation:

```swift
if characteristic.uuid == connectedApplicationInfoCharacteristicUUID {
  let isCurrentCharacteristic = characteristic === connectedApplicationInfoCharacteristic
  guard CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
    pendingGeneration: pendingConnectedApplicationInfoGeneration,
    currentGeneration: secureHandshakeGeneration,
    isCurrentCharacteristic: isCurrentCharacteristic
  ) else {
    appendObservation("BLE_APP_INFO_WRITE_ACK result=ignored-stale generation=\(secureHandshakeGeneration)")
    return
  }

  if let error {
    failConnectedApplicationHandshake(error.localizedDescription)
    return
  }

  completeConnectedApplicationInfoWrite(on: peripheral)
  return
}
```

`completeConnectedApplicationInfoWrite` cancels the timeout, clears pending state, logs success, and calls `completeIdentityHandshake` exactly once. The timeout closure captures peripheral ID, characteristic identity, and generation; it only fails the current pending write.

Failure status:

```swift
updateStatus("相机应用握手失败，请重新连接", isBusy: false)
```

No error path may call transfer activation or PTP.

- [ ] **Step 5: Run all four focused tests**

Run the complete Task 1 command.

Expected: four tests pass.

- [ ] **Step 6: Run existing adjacent handshake tests**

Run:

```bash
xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testSecureHandshakeStatusAckReplacesFourthByteWith20 \
  -only-testing:RunnerTests/RunnerTests/testSecureHandshakeWaitsForAllServicesBeforeWritingConnectedDeviceName \
  -only-testing:RunnerTests/RunnerTests/testSecureHandshakeWaitsForNotificationSubscriptionsBeforeWritingConnectedDeviceName \
  -only-testing:RunnerTests/RunnerTests/testPairingConfirmationFlowDriverRoutesRememberedGalleryIdentifierWriteToMainline \
  -only-testing:RunnerTests/RunnerTests/testTransferFlowDriverBuildsActivationActionFromAvailableCharacteristics
```

Expected: five tests pass.

- [ ] **Step 7: Commit the BLE integration**

```bash
git add ios/Runner/CameraVendorBluetoothService.swift ios/RunnerTests/RunnerTests.swift
git commit -m "fix: gate transfer on connected application handshake"
```

### Task 4: Verify regression boundary and device build

**Files:**
- Verify: `ios/Runner/CameraVendorSecureHandshake.swift`
- Verify: `ios/Runner/CameraVendorBluetoothService.swift`
- Verify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Run formatting and diff checks**

```bash
git diff --check HEAD~3..HEAD
rg -n "GFX100RF|X-T5|X-S20" ios/Runner/CameraVendorSecureHandshake.swift ios/Runner/CameraVendorBluetoothService.swift
```

Expected: no whitespace errors and no model-specific branch introduced by this change.

- [ ] **Step 2: Run the complete RunnerTests suite**

```bash
xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests
```

Expected regression boundary: no failures beyond the three baseline `Info.plist` assertions recorded before implementation.

- [ ] **Step 3: Build the iPhoneOS target**

```bash
xcodebuild build \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Review the final diff**

Confirm every production-code change is limited to capability policy, characteristic discovery, identity completion gating, lifecycle fencing, and diagnostics. Do not repair the unrelated `Info.plist` baseline failures in this branch.

- [ ] **Step 5: Record physical-camera proof boundary**

Code completion requires the automated checks above. Product-incident closure additionally requires a fresh GFX100RF run showing `BLE_APP_INFO_WRITE_ACK result=success`, then a 68-byte PTP INIT ACK and successful OpenSession. Until that run exists, report physical verification as pending.
