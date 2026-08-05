# CameraVendor Adaptation Protocol

> Android warning: this is historical cross-platform material and is not the
> Android source of truth. Android camera connection changes must use
> `docs/android-current-execution-logic.md` and
> `docs/android-official-xapp-connection-analysis.md`, which are based on the
> official Android XApp analysis. Do not use iOS implementation behavior to
> decide Android BLE, Wi-Fi, or PTP behavior.

## Current Source Of Truth

- Android source of truth:
  - `docs/android-current-execution-logic.md`
  - `docs/android-official-xapp-connection-analysis.md`
- Historical iOS implementation references below are not authoritative for
  Android behavior.
- Product and field notes:
  - `docs/cameraVendor-camera-flow-and-product-notes.md`
  - `docs/camtransfer-product-implementation-v2.md`
- Android implementation status: Android now has a strict official-XApp-style
  protocol adaptation path for paired-camera reconnect, Wi-Fi handoff, and
  gallery entry. Current Android execution rules are maintained in
  `docs/android-current-execution-logic.md`.

## Protocol Layers

The working CameraVendor gallery transfer path is not a single standard PTP flow. It is
four layers that must be verified separately for every new model:

1. BLE discovery and pairing
2. BLE ReferenceApp transfer activation
3. Wi-Fi handoff / camera subnet readiness
4. CameraVendor legacy PTP gallery and object transfer

Treating this as plain `GetStorageIDs -> GetObjectHandles -> GetObjectInfo`
will miss HEIF/RAW on the verified DEVICE-A path and may fail with `0x2005`.

## BLE Discovery And Pairing

### Advertisement Signals

The iOS matcher accepts CameraVendor cameras through service UUIDs, CameraVendor-like device
names, and manufacturer payloads. The important service UUIDs are:

| Purpose | UUID |
|---|---|
| Legacy Remote | `AF854C2E-B214-458E-97E2-912C4ECF2CB8` |
| ReferenceApp | `117C4142-EDD4-4C77-8696-DD18EEBB770A` |
| Secure / Standby | `A9D2B304-E8D6-4902-8336-352B772D7597` |
| Modern pair service | `123D8F06-62A1-4935-9322-833C531EE225` |
| Legacy pair service | `91F1DE68-DFF6-466E-8B65-FF13B0F16FB8` |

Manufacturer data can contain a four-byte pairing token. iOS tests currently
lock down both the company-prefixed and five-byte payload variants.

### Pairing Rules

- The connected device name is written before reading the ReferenceApp identification
  number.
- Secure status ACK keeps the first three bytes from the camera and replaces
  the fourth byte with `0x20`.
- ReferenceApp identification number ACK sets the application identifier bit in the
  fourth byte.
- Metadata reads and required notification subscriptions must complete before
  starting the secure handshake.
- A single encryption recovery retry is allowed; after that the user should be
  guided back to camera pairing mode.

## BLE ReferenceApp Transfer Activation

The verified gallery entry strategy is `officialImportImage`.

Write sequence:

| Step | Characteristic | Payload | Meaning |
|---|---|---|---|
| 1 | `CAEDB497-83BF-482C-91EF-91CF6F1216FF` | `00` | `ImageTransferSetting` |
| 2 | `98934B2C-756C-4632-AA2F-DCBA1BFEC824` | `01` | `ImageTransferSettingEx` |
| 3 | `82A9F452-C5CE-4EF5-8203-3FC9A47F8171` | `00` or `01` | resize off/on |
| 4 | `600655E6-3637-42F1-8FB2-44EFC5C63B13` | `0300` | launch import image |

Status characteristics:

| Characteristic | Meaning | Ready value |
|---|---|---|
| `A68E3F66-0FCC-4395-8D4C-AA980B5877FA` | AP state | `0x8001` for gallery Wi-Fi |
| `BD17BA04-B76B-4892-A545-B73BA1F74DAE` | transfer state | `0x8001` for reserved image import readiness |

For gallery transfer, AP state `Launched(0x8001)` is enough to proceed to Wi-Fi.
`LaunchedForReservedImageTransfer(0x8003)` is reserved for the automatic image
import diagnostic path, not the normal gallery path.

Compression behavior:

- `82A9F452=00`: original transfer path.
- `82A9F452=01`: camera-side downsize to a small JPG on verified DEVICE-A/DEVICE-B-like
  behavior. This is model/firmware-specific and must be re-verified per model.

## Wi-Fi Handoff

Default CameraVendor AP assumptions:

- Camera host: `192.168.0.1`
- Command port: `55740`
- Event port: `55741` is not used before gallery OpenSession in the CameraVendor legacy
  path.
- A local `en0` IP starting with `192.168.0.` is accepted as camera Wi-Fi
  evidence even when iOS cannot read the SSID.

Important rule: do not require the current IP to differ from a baseline IP. A
CameraVendor camera network can be correctly connected while the baseline and current
camera-subnet IP are the same.

## PTP INIT

Android follows the official Android XApp connection chain. `libFTLPTPIP.so`
contains the CameraVendor legacy plain INIT template:

```text
[4 length]
[4 packetType = 0x00000001]
[4 CameraVendor protocolVersion = 0x8F53E4F2]
[16 GUID words, fourth word = 0x00000000 in the plain template]
[54 raw UTF-16LE friendly name, zero padded]
```

The native plain template is not enough by itself on the current verified X-T5
path. Keep the Kotlin gallery-open order aligned with the stable implementation:
send the CameraVendor legacy INIT variant with local `192.168.0.x` in the fourth
GUID word first, then send the plain template only if the first variant does not
ACK. Standard PTP/IP INIT exists in code for reference, but Android gallery open
does not select it.

After INIT ACK:

```text
OpenSession(0x1002, session=1)
```

CameraVendor legacy does not open the event socket before the gallery session. The code
comments note that the event port becomes useful only after other camera modes
such as open capture.

## Operation Packet Formats

### Standard PTP/IP

```text
[4 length][4 type=6][4 dataPhase][2 op][4 transactionID][4*N params]
```

### CameraVendor Legacy Operation Request

```text
[4 length][2 dataPhase][2 op][4 transactionID][4*N params]
```

Data-out in CameraVendor legacy uses:

```text
[4 length][2 dataPhase=2][2 op][4 transactionID][payload]
```

CameraVendor legacy packet reading maps packet kind `2` and `21` to data packets, and
kind `3` and `12` to operation responses. Kind `12` is normalized into an OK
response because some thumbnail/object streams finish with a non-standard first
word.

All command socket use is serialized. Keep this invariant; the DEVICE-A can become
unstable when commands or downloads overlap on multiple PTP sessions.

## Gallery Handshake

The verified CameraVendor legacy ReferenceApp gallery handshake is:

```text
D212 read ReferenceApp gallery context
DF01 read current ClientState
DF01 write 20
DF28 read ImageHost
DF28 write version 3
D244 read gallery access state #1
D212 read gallery context #2
D244 read gallery access state #2
9054 read current image info, handle 0x10000001
9055 read current image thumbnail, handle 0x10000001
skip 9050 GetSearchModeDescAll (descriptor is unused by current Catalog construction)
D22B read current object handle
9053 read SpecifiedObjectCountGroupByDate, params [0, 30000]
D212 read context before specified list
D620 read SpecifiedObjectCount
D621 read SpecifiedObjectHandles
```

Do not wire `D222` ready polling into the normal path. It remains diagnostic
only. Previous field notes say D222 polling can disturb D212 and lead to
`0x2009`, timeouts, or connection refusal.

`9050 GetSearchModeDescAll` is intentionally not a `GalleryReady` gate. Its
descriptor response is not consumed by the current Catalog or filter query
construction, and field logs show that some camera/firmware combinations can
return `0x2019 Device Busy`. The opcode, request helper, and retry policy remain
implemented for a future capability-driven probe. If that probe is introduced,
run it outside the blocking gallery startup path, parse the descriptor before
using it, and treat busy/unsupported responses as non-fatal when the normal
Catalog path is usable.

The same boundary applies to empty-Catalog recovery. A zero-count/empty-handle
snapshot may perform its bounded delay, optional `D22B` refresh, and Catalog
retry, but it must not insert `9050` into that recovery loop.

The initial unfiltered Catalog does not need `9052/9051`. User-initiated
camera-side filtering is a separate, already-supported transaction:

```text
9052 backup current SearchModeAll
9051 write the requested SearchModeAll conditions
9053 read SpecifiedObjectCountGroupByDate
D620 read SpecifiedObjectCount
D621 read SpecifiedObjectHandles
9051 restore the backed-up SearchModeAll
```

Removing `9050` from Gallery bootstrap must not remove, bypass, or weaken this
filter transaction.

## Object Discovery

The main gallery list comes from `D621 SpecifiedObjectHandles`.

Flow:

1. Parse `D621` as a count-prefixed UInt32 array.
2. Read `GetObjectInfo(0x1008)` for each returned handle.
3. If the specified list lacks extended still formats, compute gaps between
   min/max handles when the range is at most `120`.
4. Probe missing handles with `GetObjectInfo`.
5. If hidden probe finds HEIF or RAW, merge specified and hidden infos by
   handle.
6. If still insufficient, optionally try the standard storage/object path as a
   diagnostic fallback.

Known format labels:

| Format code | Label |
|---|---|
| `0x3801` | JPG |
| `0x3812` | HEIF |
| `0xB101` | RAW |
| `0xB103` | RAW |
| `0x300B`, `0x300D` | Video |

Risk to keep in mind: the current hidden probe is skipped once the specified
list already contains any HEIF or RAW. A model that returns HEIF in `D621` but
hides RAW in handle gaps could still miss RAW. See the audit document before
changing this behavior.

## Thumbnail And Original Transfer

Thumbnail path:

1. Optionally read `ObjectInfo`.
2. Try standard `GetThumb(0x100A)`.
3. Normalize CameraVendor-prefixed JPEG/HEIF payloads before rendering.
4. If the standard thumbnail is unavailable, report thumbnail failure. Do not
   fall back to `GetPartialObject(0x101B)` for grid thumbnails.

Screen preview path:

1. Treat screen preview as separate from grid thumbnails and original download.
2. Set `D226 ImageForceCompression` to `1`.
3. Re-read `ObjectInfo`.
4. Read `GetPartialObject(0x101B)` from offset `0` using the fresh
   `ObjectInfo.compressedSize`.
5. Validate that returned image data is complete before caching or rendering.
6. Reset `D226` to `0`.

Original photo download path:

1. Treat original download as an exclusive PTP operation. Pause thumbnail and
   background metadata requests before starting it.
2. Resolve the selected handle to fresh `ObjectInfo` before saving, because a
   large-gallery UI item may still carry placeholder metadata.
3. Do not use standard `GetObject` by default.
4. Set `D227 ImageCompressionRealInfo` to `1` before getting a fresh object
   size.
5. Re-read `ObjectInfo`.
6. Read chunks with `GetPartialObject(0x101B)`.
7. Stop at expected size or JPEG EOI marker.
8. Reset `D227` to `0`.

Video original download remains intentionally blocked until the file path is
tested separately.

## Adaptation Checklist For A New CameraVendor Model

Create one row per tested camera/firmware:

| Field | What to record |
|---|---|
| Model / firmware | Exact model and firmware version |
| BLE advertisement | UUIDs, name, manufacturer payload shape |
| Pairing path | legacy, modern token, secure, or already paired |
| Activation writes | exact write sequence and ACKs |
| AP state | values observed before and after activation |
| Wi-Fi evidence | SSID readability, local IP, PTP reachability |
| PTP INIT | CameraVendor legacy ACK or standard ACK |
| Gallery handshake | first failing step, if any |
| D621 behavior | complete list, partial list, hidden gaps |
| RAW/HEIF codes | exact format codes |
| Thumbnail path | GetThumb success or explicit thumbnail failure |
| Original path | partial chunk size, size accuracy, reset behavior |
| Parallelism | whether multiple PTP sessions disconnect camera |

Only promote a model to supported when BLE activation, D621 listing, hidden gap
handling, thumbnail loading, and one original photo download have all been
verified from fresh logs.
