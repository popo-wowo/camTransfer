# Cross Platform Refactor Audit

> Scope: review the current CameraVendor adaptation logic before refactoring iOS and
> Android. This document separates confirmed behavior, risks, and the proposed
> staged refactor so the protocol does not regress while files are split.

## Current Shape

### iOS

The iOS app contains the field-verified CameraVendor path:

- BLE advertisement matching, pairing, secure/ReferenceApp handshake.
- ReferenceApp transfer activation through the official import image sequence.
- Manual/automatic Wi-Fi readiness policies.
- CameraVendor legacy PTP INIT and operation transport.
- CameraVendor/ReferenceApp gallery handshake.
- D621 specified handle discovery plus hidden handle gap probing.
- Sequential thumbnails and sequential original downloads through partial
  object reads.

Most protocol policies are currently colocated in
`ios/Runner/CameraVendorBluetoothService.swift`, which is too large and mixes policy,
packet codecs, sockets, BLE orchestration, PTP session state, gallery service,
and diagnostic logging.

### Android

Android has a cleaner file split, but it does not yet match the verified CameraVendor
protocol:

- `protocol/PtpConnection.kt` uses standard PTP/IP INIT and opens command plus
  event sockets.
- `protocol/PtpCommands.kt` uses standard storage/object enumeration.
- `ble/CameraVendorBleHandshake.kt` has a basic CameraVendor BLE pairing/token/secure flow.
- Android does not currently implement the iOS ReferenceApp activation sequence,
  CameraVendor legacy operation packet format, CameraVendor/ReferenceApp gallery handshake, D621 list
  path, hidden handle gap probing, or partial-object original download policy.

Conclusion: iOS has the proven behavior but poor module boundaries. Android has
better boundaries but is protocol-incomplete for the current CameraVendor path.

## Logic Review

### Finding 1: Android Protocol Is Not Equivalent To iOS

Severity: high for cross-platform support.

Android currently uses standard PTP/IP command packets and `GetStorageIDs ->
GetObjectHandles -> GetObjectInfo`. Field notes and iOS code show the working
CameraVendor path is CameraVendor legacy INIT/operation transport plus ReferenceApp gallery handshake
and D621 specified handles.

Impact:

- Android may connect to some standard PTP cameras, but it should not be
  considered equivalent to the working iOS CameraVendor implementation.
- HEIF/RAW discovery will likely fail on the verified DEVICE-A-like path.

Refactor requirement:

- Port the iOS protocol facts to Android as policy/codecs first.
- Do not present Android as feature-complete until it passes equivalent packet
  and policy tests.

### Finding 2: Hidden Gap Probe Can Miss A Format Class

Severity: medium.

The current iOS policy only probes hidden standard object handles when the
specified list contains no HEIF and no RAW. That protects performance and avoids
unnecessary camera pressure, but it assumes D621 either hides all extended still
formats or exposes all relevant extended still formats.

Counterexample:

```text
D621 returns JPG + HEIF
RAW exists in handle gaps
Current policy sees HEIF and skips hidden probe
RAW is never discovered
```

Refactor requirement:

- Keep the current policy unchanged until we have logs proving the counterexample.
- Extract it behind a named `CameraVendorHiddenObjectDiscoveryPolicy`.
- Add tests that document both current behavior and the proposed optional
  behavior: "probe when any requested format class is missing".

### Finding 3: `standardPtpIp` Path Exists But Is Not Reachable From INIT

Severity: medium.

The iOS session has standard PTP/IP packet builders and a standard gallery
handshake path, but `performInitHandshake` currently attempts only CameraVendor legacy
INIT. That makes the standard path reference code, not an active fallback.

Impact:

- New maintainers may assume standard fallback is active when it is not.
- Refactors could accidentally wire in the standard path and regress CameraVendor
  gallery loading.

Refactor requirement:

- Introduce an explicit `CameraVendorPtpInitProfile` with current value
  `.cameraVendorLegacyOnly`.
- Keep standard PTP/IP as a future profile, not an implicit fallback.

### Finding 4: Diagnostic D222 Polling Is Easy To Reintroduce

Severity: medium.

The code still contains ready marker validation/polling helpers, while field
notes say they must not be used in the formal gallery path. This is acceptable
as diagnostic code, but risky while everything lives in one file.

Refactor requirement:

- Move diagnostic-only helpers into a diagnostic module/file.
- Name the production route so it is obvious D222 polling is excluded.
- Keep tests that assert production policy skips `GetSearchModeAll`,
  `SetSearchModeAll`, and D222 polling.

### Finding 5: `D244` Has Two Meanings In Code

Severity: low to medium.

`D244` is named as both gallery access state and dual slot status. Dual slot
probing is currently disabled, so this is not breaking the active path. If
enabled, slot probing may mutate the same property used as gallery access state.

Refactor requirement:

- Keep dual slot probing disabled by default.
- Encapsulate D244 reads/writes behind route-specific helpers so a slot probe
  cannot be accidentally inserted into the cold-start gallery handshake.

### Finding 6: The Protocol Test Suite Is Strong But File Boundaries Are Weak

Severity: medium.

`RunnerTests.swift` already locks down many important packet layouts and
policies. The risk is not lack of tests; it is that the code under test is
mostly nested inside one app file.

Refactor requirement:

- Split pure policies/codecs first, with no behavior changes.
- Keep all existing tests green before extracting live BLE/PTP orchestration.

## Refactor Design

### Goal

Create a shared architecture where iOS and Android use the same CameraVendor adaptation
concepts and test fixtures, while preserving the current working iOS behavior.

### Non-Goals

- Do not redesign the UI during protocol refactor.
- Do not introduce parallel PTP downloads for DEVICE-A.
- Do not turn D222 polling or SearchMode reset back on.
- Do not claim Android feature parity until equivalent tests and device logs
  exist.

### iOS Target Structure

Proposed split under `ios/Runner/CameraVendorProtocol/`:

| File | Responsibility |
|---|---|
| `CameraVendorProtocolConstants.swift` | op codes, prop codes, packet types, format codes |
| `CameraVendorPtpPacketBuilder.swift` | standard and CameraVendor legacy packet encoding |
| `CameraVendorPtpDataParser.swift` | arrays, object info, ReferenceApp context parsing |
| `CameraVendorPtpPolicies.swift` | gallery, hidden handles, thumbnail, download, retry policies |
| `CameraVendorPtpSocket.swift` | socket connect/read/write only |
| `CameraVendorPtpSession.swift` | PTP session state and command execution |
| `CameraVendorBleProfiles.swift` | UUIDs and advertisement matching data |
| `CameraVendorBleActivationPlan.swift` | ReferenceApp transfer activation writes/status handling |
| `CameraVendorGalleryService.swift` | high-level fetch/download API |
| `CameraVendorDiagnostics.swift` | logging and diagnostic-only helpers |

Keep `CameraVendorBluetoothService.swift` as orchestration during the first split, then
thin it down after pure code has moved.

### Android Target Structure

Proposed split under `app/src/main/java/com/camtransfer/cameraVendor/`:

| Package | Responsibility |
|---|---|
| `cameraVendor.protocol` | packet codecs, constants, data parsers, transport profile |
| `cameraVendor.ptp` | socket/session/command execution |
| `cameraVendor.ble` | profile UUIDs, scanner, handshake, activation plan |
| `cameraVendor.gallery` | object discovery, thumbnails, original download |
| `cameraVendor.policy` | retry, Wi-Fi, hidden handle, download policies |

The first Android refactor should add the missing CameraVendor legacy codecs and policy
tests before replacing runtime behavior.

## Staged Execution Plan

### Phase 1: Documentation And Test Freeze

- Add this audit and `docs/cameraVendor-adaptation-protocol.md`.
- Run existing iOS and Android build/test commands to establish baseline.
- Add any missing pure tests for current policies before moving code.

### Phase 2: iOS Pure Extraction

- Move constants, packet builders, parsers, and pure policies out of
  `CameraVendorBluetoothService.swift`.
- Do not change public behavior.
- Keep all existing `RunnerTests` passing after each small extraction.

### Phase 3: iOS Session Boundary

- Move `CameraVendorPtpSocket` and `CameraVendorPtpSession` into separate files.
- Keep `CameraVendorBluetoothService` as the BLE orchestrator.
- Keep gallery fetch/download call sites unchanged.

### Phase 4: Android Protocol Parity

- Add CameraVendor legacy packet builders matching iOS tests.
- Add CameraVendor data parser tests for `D621`, object info, hidden handles, and RAW
  format variants.
- Add ReferenceApp activation plan tests for the four BLE writes.
- Only after tests exist, wire Android runtime from standard PTP into the CameraVendor
  legacy ReferenceApp route.

### Phase 5: Device Matrix

- Create a machine-readable model matrix for tested bodies/firmware.
- Track per-model support for activation, D621 completeness, hidden gaps,
  thumbnail path, original download, and parallelism.

## Verification Commands

Use these before and after behavior-preserving refactors:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'
./gradlew test
./gradlew assembleDebug
```

If the local simulator name differs, list destinations with:

```bash
xcodebuild -showdestinations -project ios/Runner.xcodeproj -scheme Runner
```

## Approval Gate

The next code step should be Phase 2 iOS pure extraction. It is intentionally
behavior-preserving and lower risk than changing Android runtime behavior first.
After Phase 2 passes, Android parity can use the extracted iOS concepts as the
reference instead of copying from the current monolithic file.
