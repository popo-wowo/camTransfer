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
| 3 | `82A9F452-C5CE-4EF5-8203-3FC9A47F8171` | `00` or `01` | original or camera-side resize mode |
| 4 | `600655E6-3637-42F1-8FB2-44EFC5C63B13` | `0300` | launch import image |

Status characteristics:

| Characteristic | Meaning | Ready value |
|---|---|---|
| `A68E3F66-0FCC-4395-8D4C-AA980B5877FA` | AP state | `0x8001` for gallery Wi-Fi |
| `BD17BA04-B76B-4892-A545-B73BA1F74DAE` | transfer state | `0x8001` for reserved image import readiness |

For gallery transfer, AP state `Launched(0x8001)` is enough to proceed to Wi-Fi.
`LaunchedForReservedImageTransfer(0x8003)` is reserved for the automatic image
import diagnostic path, not the normal gallery path.

Connection-time resize behavior:

- `82A9F452=00`: open gallery/import-image Wi-Fi in original-size mode.
- `82A9F452=01`: open gallery/import-image Wi-Fi in camera-side resize mode;
  the camera emits approximately 3 MB JPG transfers for still images.
- Keep this BLE value as camera global/initial state only. The actual
  original/compressed choice for a queued import is applied later on the Wi-Fi
  PTP channel immediately before reading the object.

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
9050 read SearchModeDescAll
optionally 9052 GetSearchModeAll for diagnostic snapshot
D604 search-mode format pass:
  D604=31 initial all-format attempt
  D604=HEIF or D604=RAW expanded-list attempt
D22B read current object handle
9053 read SpecifiedObjectCountGroupByDate, params [0, 30000]
D212 read context before specified list
D620 read SpecifiedObjectCount
D621 read SpecifiedObjectHandles
```

Do not wire `D222` ready polling into the normal path. It remains diagnostic
only. Previous field notes say D222 polling can disturb D212 and lead to
`0x2009`, timeouts, or connection refusal.

`9052 GetSearchModeAll` may be read as a diagnostic snapshot after `9050`.
`9051 SetSearchModeAll` is allowed only for the verified `D604` format mask
payload used to obtain specified object handles. Do not introduce unrelated
SearchMode mutations unless the payload format and restore path are proven on
real camera logs.

## Object Discovery

The main gallery list comes from `D621 SpecifiedObjectHandles`.

Flow:

1. Enter gallery mode and read the baseline specified list with `D604=31`.
2. Read `9053 GetSpecifiedObjectCountGroupByDate`, `D620 SpecifiedObjectCount`,
   and `D621 SpecifiedObjectHandles`.
3. Set `D604=HEIF` or `D604=RAW`, then read `9053/D620/D621` again.
4. If the HEIF/RAW pass returns a larger list and date-group total equals the
   handle count, promote that list to the initial gallery handle source.
5. Preserve the promoted `D621` order for placeholders and date-bucket mapping.
   Do not sort by handle before publishing placeholders.
6. Read `GetObjectInfo(0x1008)` for each returned handle in the background.
7. Hidden gap probing is now a diagnostic fallback only. It should find zero
   items when expanded `D621` succeeds.
8. If still insufficient, optionally try the standard storage/object path as a
   diagnostic fallback. On the verified Android Wi-Fi vendor session,
   `GetStorageIDs(0x1004)` returns `0x2005`.

Verified Android X-T5 evidence from 2026-06-24:

```text
D604=JPG  -> D621 count 1138
D604=MOV  -> D621 count 14
D604=MP4  -> D621 count 0
D604=31   -> D621 count 1152, formats later resolve to JPG=1138, Video=14
D604=HEIF -> D621 count 1268
D604=RAW  -> D621 count 1268

promoted initial list:
full-object-info-final total=1268 formats={HEIF=37, RAW=79, JPG=1138, Video=14}
hidden metadata selected=0
```

Known format labels:

| Format code | Label |
|---|---|
| `0x3801` | JPG |
| `0x3812` | HEIF |
| `0xB101` | RAW |
| `0xB103` | RAW |
| `0x300B`, `0x300D` | Video |

Risk to keep in mind: `D604=HEIF` and `D604=RAW` currently behave as an
expanded-list trigger on the verified X-T5, not as literal single-format
filters. Treat this as a camera behavior proven by logs, not as a generic PTP
rule. If another model returns only one format for these masks, fall back to
merging multiple format-specific `D621` lists and keep hidden probing as a
diagnostic fallback.

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

Photo download path:

1. Treat download as an exclusive PTP operation. Pause thumbnail and background
   metadata requests before starting it.
2. Resolve the selected handle to fresh `ObjectInfo` before saving, because a
   large-gallery UI item may still carry placeholder metadata.
3. Do not use standard `GetObject` by default.
4. Carry the UI-selected download mode with the queued item. Do not re-read a
   mutable global preference after the item is queued.
5. Original mode: immediately before the download, set
   `D226 ImageForceCompression` to `2`, re-read `ObjectInfo`, read chunks with
   `GetPartialObject(0x101B)`, then reset `D226` to `0`.
6. Compressed mode: immediately before the download, set
   `D22E ObjectCompressionSetting` to `1` (`ImageResizeRateValue.RateS`), then
   set `D226 ImageForceCompression` to `1`, re-read `ObjectInfo`, read chunks
   with `GetPartialObject(0x101B)`, then reset `D226` to `0`.
7. `D227 ImageCompressionRealInfo` is reset during gallery initialization, but
   it is not the official app's import-time original/compressed switch. The
   download decision must come from the queued item's mode immediately before
   the transfer, not from the BLE/AP activation preference.
8. Never save grid thumbnail data as either compressed or original download.
   A compressed download is still an import-image transfer object selected by
   `D22E/D226`, not `GetThumb(0x100A)` and not the existing thumbnail cache.
9. Stop at expected size or JPEG EOI marker. JPEG EOI is only a bounded stop
   condition for JPEG-like data; do not use unbounded reads as a generic HEIF,
   RAW, or video strategy.
10. If a socket/connection-lost error occurs, stop the remaining queue and mark
   pending items as failed with a reconnect-required message. Do not continue
   issuing PTP commands after the command socket is invalid.

2026-06-26 Android XApp reverse engineering: `ReceiveImageModel.startImportImage`
sets `D22E=resizeRate` before compressed import, then sets `D226=1` for
compressed or `D226=2` for original. `ReceiveImageModel.finishImportImage`
resets `D226=0`. Native `libFFIR.so` confirms the mapping:
`SetImageForceCompression -> D226`, `SetImageCompressionRealInfo -> D227`, and
`SetObjectCompressionSetting -> D22E`.

Property payload width is important: `D226`, `D227`, and `D22E` must be written
as PTP `UINT16` values. Native `FTL_PTP_DATA_TYPE=0x0004` maps to the PTP
`UINT16` datatype here, and device reads for `D226/D227` return two bytes
(`0000` after reset on the verified X-T5). Writing these properties as
four-byte integers can make the camera accept the command response while the
following `ObjectInfo.compressedSize` remains at thumbnail/preview-object size.

Required download diagnostics:

- Log each mode write with handle, queued mode, format, property code, value,
  width, and PTP response.
- Log the fresh `ObjectInfo.compressedSize` after mode write and before the
  first `GetPartialObject`.
- A failed original/pressed mode is visible as `D226/D22E response=0x2001` but
  `freshSize/readSize` staying at small thumbnail-like values such as a few
  hundred KB. Do not paper over that by saving cached thumbnails.

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
