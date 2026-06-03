# iOS Camera Adapter Refactor Design

## Goal

Refactor the current iOS camera communication code into an adapter/profile
architecture so future Fujifilm models can be added without continuing to grow
the current monolithic service. The first implementation must preserve the
current X-T5 behavior.

## Non-Goals

- Do not change the current X-T5 pairing, Wi-Fi handoff, gallery listing,
  thumbnail, original download, HEIF/RAW probing, or exit behavior.
- Do not redesign the UI.
- Do not implement Canon, Sony, Nikon, or other brand adapters in this phase.
- Do not rename the product or add public brand claims.
- Do not remove existing diagnostics that are needed for current field testing.

## Architecture

The UI should depend on a small set of camera-facing interfaces instead of
depending directly on vendor-specific policy types.

```text
NativeConnectViewController
NativeGalleryViewController
  -> CameraConnectionService
  -> CameraGalleryService
  -> CameraDownloadService
      -> FujifilmCameraAdapter
          -> FujifilmXSeriesProfile
          -> FujifilmBleController
          -> FujifilmTransferActivator
          -> FujifilmPtpSession
          -> FujifilmGalleryClient
          -> FujifilmDownloadClient
```

The adapter owns vendor behavior. The profile owns model-family differences.
For phase one, there is one production profile:

```text
FujifilmXSeriesProfile.xt5Current
```

This profile represents the currently tested X-T5 path and keeps all existing
policy values.

## Interfaces

### Camera Adapter

`CameraAdapter` is the high-level vendor entry point.

Responsibilities:

- Match discovered BLE advertisements.
- Create a pairing controller for the matched camera.
- Create a gallery session from a successful connection summary.
- Expose diagnostics through the existing logging path.

Initial implementation:

```text
FujifilmCameraAdapter
```

### Camera Profile

`CameraProfile` describes model or model-family capabilities.

Initial capabilities:

- BLE services and characteristic UUIDs.
- Pairing path support.
- Transfer activation strategy.
- Wi-Fi host and ports.
- PTP init profile.
- Gallery object discovery policy.
- Object size policy.
- Thumbnail policy.
- Download chunk policy.
- Parallel download policy.

The profile must be pure data or pure policy functions where possible, so tests
can lock behavior without opening BLE or PTP connections.

### Gallery Session

`CameraGallerySession` is what the gallery UI uses.

Responsibilities:

- `fetchGallery()`
- `fetchThumbnail(for:)`
- `downloadOriginalFile(for:)`
- `terminateCameraCommunication()`
- optional configuration and diagnostics protocols currently used by the UI

The existing `CameraVendorGalleryService` behavior maps directly to this
interface in phase one.

## File Layout

Create a new iOS folder:

```text
ios/Runner/CameraAdapters/
  Core/
    CameraAdapter.swift
    CameraProfile.swift
    CameraGallerySession.swift
    CameraDiagnostics.swift
  Fujifilm/
    FujifilmCameraAdapter.swift
    FujifilmXSeriesProfile.swift
    FujifilmBleProfile.swift
    FujifilmTransferActivation.swift
    FujifilmPtpConstants.swift
    FujifilmPtpPackets.swift
    FujifilmPtpParsers.swift
    FujifilmPtpPolicies.swift
    FujifilmPtpSocket.swift
    FujifilmPtpSession.swift
    FujifilmGallerySession.swift
```

The first implementation can use compatibility typealiases so existing call
sites and tests keep compiling while files are split.

Example:

```swift
typealias CameraVendorGalleryService = CameraGallerySession
typealias CameraVendorRealtimeGalleryService = FujifilmGallerySession
```

Typealiases are transitional. They keep the first phase behavior-preserving and
can be removed after UI call sites are migrated.

## Migration Strategy

### Phase 1: Core Interfaces

Add the core camera interfaces and keep current concrete services unchanged.
Add tests that prove the UI-facing gallery contract still exposes the current
methods.

### Phase 2: Pure Fujifilm Policy Extraction

Move constants, format labels, packet builders, parsers, and pure policies out
of `CameraVendorBluetoothService.swift` into Fujifilm files.

No runtime behavior changes are allowed in this phase.

### Phase 3: PTP Boundary Extraction

Move the socket and session code behind `FujifilmPtpSession`.

Keep command serialization, legacy init, D621 object discovery, hidden handle
probing, compression reset, partial-object download, and diagnostics identical.

### Phase 4: Gallery Session Extraction

Move `CameraVendorRealtimeGalleryService` into `FujifilmGallerySession`.

The gallery UI should depend on `CameraGallerySession` plus optional capability
protocols instead of the concrete Fujifilm type.

### Phase 5: BLE Adapter Boundary

Move advertisement matching, pairing, secure handshake, and transfer activation
planning behind `FujifilmCameraAdapter`.

Keep current startup scanning, remembered pairing, phone confirmation, and
post-pairing auto transfer behavior unchanged.

## Error Handling

- Preserve existing user-facing error strings unless a string is tied to an
  obsolete concrete type name.
- Preserve current diagnostic tags such as `[OBS]`, `PTP_`, `WIFI_`, and
  pairing logs so field logs remain comparable across refactor steps.
- Keep current fallback behavior: if a secondary download worker fails, requeue
  the handle to the primary worker.

## Testing

Use the existing iOS tests as the main regression shield.

Required verification after each phase:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS' -configuration Debug
```

Add focused tests for:

- adapter/profile selection returns the current Fujifilm X-series profile;
- profile preserves current PTP startup, hidden handle, compression, thumbnail,
  and download policies;
- the gallery UI can be constructed from the generic gallery session protocol.

## Rollout

Work in small behavior-preserving patches. After each patch:

1. Compile.
2. Run targeted tests for moved policies.
3. Run the full iOS test suite before installing to device.

Only after all iOS tests pass should the build be installed to the phone for
continued HEIF/JPG/download debugging.
