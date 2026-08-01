# iOS Linked HD Preview Design

## Status

Approved in principle by the user on 2026-08-01. This document defines the
target design only; implementation and physical-device acceptance remain
pending.

This design supersedes the following parts of
`2026-07-30-ios-gallery-shared-filter-dual-loader-design.md`:

- treating the 30-handle loading window as the total HD cache;
- deleting loaded state whenever an in-memory entry is evicted;
- allowing full-screen preview to act as a separate HD request owner;
- limiting full-screen camera priority to one page instead of current, next,
  and previous after the current page becomes available.

## Problem Statement

iOS currently presents the same camera-provided screen preview through two UI
surfaces:

1. a vertically scrolling high-definition Gallery list;
2. a horizontally paging full-screen viewer.

The current implementation does not yet model these as two presentations of
one shared HD-preview session. It also decodes the camera JPEG/HEIF data at its
full pixel dimensions for the vertical list.

Physical-device logs from 2026-08-01 show the consequences:

- a compressed HD JPEG of about `1.9 MB` decodes to `1824 x 2736`, about
  `19 MiB` of RGBA pixels;
- other camera previews decode to `2560 x 3840` or `3888 x 2592`, about
  `37.5-38.4 MiB` each;
- the vertical list schedules up to eight decoded images while its decoded
  cache budget is `96 MiB`;
- the same handle is decoded repeatedly after `NSCache` eviction, producing
  blank/loading cells and scroll hitching;
- preview and original-download code both write CameraVendor property `D226`, but
  the logical download-mode state can disagree with the physical camera mode;
- after HD preview resets `D226` to `0`, an original download can read fresh
  ObjectInfo as `167936` bytes and save that compressed screen object instead
  of the original file.

The target design must fix the display architecture and the transfer-mode
ownership together. Improving only the bitmap cache would leave incorrect
downloads possible, while fixing only `D226` would leave the Gallery janky.

## Goals

1. Treat vertical HD browsing and full-screen paging as two presentations of
   one HD-preview session.
2. Keep one authoritative ordered photo sequence, request state, compressed-data
   availability, selection state, and download state.
3. Decode the vertical list only to the pixels required by the rendered card.
4. Decode only the current full-screen page at the camera preview's native
   dimensions; keep adjacent pages at screen-fit resolution.
5. Return from full-screen to the same handle and make that handle the center
   of the vertical loading priority.
6. Preserve successful load state independently of compressed-memory and
   decoded-image eviction.
7. Prevent any preview operation from leaving the download mode state out of
   sync with the physical `D226` value.
8. Keep camera requests serial and mutually exclusive with every download
   transfer mode.

## Non-Goals

- Do not download the original photo merely to render full-screen preview.
- Do not create separate filters or Catalog membership for the two HD surfaces.
- Do not allow full-screen paging across photos outside the current filtered
  Gallery sequence.
- Do not add infinite server-style Catalog paging in this change.
- Do not persist HD previews across camera sessions.
- Do not change RAW/JPEG pairing or Gallery filter semantics.
- Do not introduce a second PTP command lane or a second download manager.

## Product Contract

### Vertical HD list

- Shows the current shared Gallery filter and ordering.
- Scrolls vertically and supports batch selection.
- Loads current visible handles first, then nearby handles below, then nearby
  handles above.
- Uses screen-sized decoded images rather than native-sized preview bitmaps.
- A compressed preview that has already been fetched is considered loaded even
  when its decoded bitmap is no longer resident.
- Local disk restoration must not display the camera-loading spinner.

### Full-screen viewer

- Opens at the handle tapped in the vertical list or thumbnail grid.
- Pages horizontally through the same filtered display-photo sequence.
- Supports double-tap and pinch zoom.
- Keeps the current page at native HD-preview resolution so zoom remains useful.
- Keeps the previous and next pages at screen-fit resolution only.
- Updates selection and download state through the same Runtime state used by
  the Gallery.
- Returns its current handle when closed.

### Return positioning

- If the Catalog identity and handle are still valid, closing full-screen
  scrolls the active collection view to that handle.
- In HD mode the item is positioned near the vertical center and becomes the
  center of the HD loading priority.
- In thumbnail mode the item is positioned visibly and the thumbnail viewport
  is resubmitted.
- If the Catalog was replaced or the handle no longer belongs to the filter,
  the Gallery keeps its existing scroll position and does not guess another
  item.

### Download cancellation return

- User cancellation is a normal download outcome, not a Gallery disconnect.
- After the active transfer reaches a safe cancellation boundary and transfer
  mode is reset, the app dismisses download UI back to the originating Gallery
  browse mode.
- The current filter, selection, browse mode, and return handle are preserved.
- Only an independently proven terminal camera/session failure may route to
  Home. A plain user cancellation must never reuse that route.

## Architecture Summary

```text
CameraGallerySession
  |
  +-- CameraGalleryPresentation
  |     authoritative filtered order and sections
  |
  +-- CameraGalleryHDPreviewPipeline
  |     one serial HD fetch owner
  |     one active focus: vertical list or full-screen
  |
  +-- CameraGalleryHDPreviewStore
  |     authoritative asset records
  |     compressed memory LRU
  |     session-scoped disk files
  |
  +-- NativeGalleryHDPreviewImageRepository
        target-aware decode tasks and decoded-image caches
        |
        +-- vertical HD list
        +-- full-screen pager

CameraSessionRuntime
  +-- selection/download state
  +-- Gallery/download admission

CameraVendorPtpSession command lane
  +-- CameraVendorTransferModeCoordinator
        only owner allowed to write D226 and companion compression properties
```

The two UI surfaces never fetch directly from the camera and never own loaded
history. They submit focus changes and render publications from the shared
session.

## State Ownership

| State | Owner | Consumers |
|---|---|---|
| Filtered sections and ordering | `CameraGallerySession` | thumbnail, vertical HD, full-screen |
| HD request priority, in-flight state, and failure | `CameraGalleryHDPreviewPipeline` | both HD surfaces |
| Successful asset availability, compressed bytes, and disk location | `CameraGalleryHDPreviewStore` | pipeline, decoder, full-screen |
| Decoded image variants | `NativeGalleryHDPreviewImageRepository` | visible cells/pages |
| Current full-screen handle | `NativePhotoPreviewViewController` while open | Gallery close callback |
| Vertical scroll position | `NativeGalleryViewController` | vertical Gallery only |
| Selection and download state | `CameraSessionRuntime` | both HD surfaces, download center |
| Physical CameraVendor transfer mode | `CameraVendorTransferModeCoordinator` | preview and download executors |

No controller infers fetch success from `NSCache` residency. No controller
writes `D226` directly.

## Shared HD Preview Session

### Focus model

The pipeline receives one focus value:

```swift
enum CameraGalleryHDPreviewFocus: Equatable {
  case inactive
  case verticalList(visibleHandles: [Int])
  case fullScreen(currentHandle: Int, orderedHandles: [Int])
}
```

The ordered handles are validated against the current Catalog identity and the
shared display-photo projection before use. Full-screen opened from thumbnail
mode must not depend on an already-active vertical-HD snapshot; the session can
derive the same display sequence directly from the current presentation.

Vertical-list priority remains:

1. visible handles in Gallery order;
2. handles below the visible range;
3. handles above the visible range;
4. at most 30 pending priority candidates.

The number `30` is a scheduling window, not a loaded-history limit and not a
disk-cache limit.

Full-screen priority is:

1. current handle;
2. next display handle;
3. previous display handle.

Only the current handle is mandatory. Adjacent camera prefetch starts only
after the current page is available and the command lane is not needed by a
download.

### Request state and asset availability

The pipeline owns transient request state. The store owns successful local
availability. These are separate:

```swift
enum CameraGalleryHDPreviewRequestState: Equatable {
  case idle
  case loading(requestID: UUID)
  case failed(CameraGalleryHDPreviewFailure)
}

enum CameraGalleryHDPreviewAvailability: Equatable {
  case absent
  case compressedMemory
  case compressedDisk
}
```

`compressedDisk` remains a loaded item even if its in-memory compressed bytes
and all decoded images were evicted. Reading and decoding the disk file is local
rehydration, not a new camera load. A successful camera fetch becomes available
only after the store has atomically written and published its asset record.

The UI derives display state as follows:

- decoded variant available: show image;
- compressed bytes exist locally: keep the last lower-quality image
  or thumbnail while local decode runs; do not show a camera spinner;
- camera request active: show the loading indicator;
- request failed: show retry state;
- not yet requested: show the normal waiting placeholder.

## Compressed Data Store

`NativeGalleryHighDefinitionPreviewCache` is replaced by a focused
`CameraGalleryHDPreviewStore` in `CameraCore/Gallery`.

The store maintains one record per `(sessionEpoch, handle, hdPreview)`:

- byte count;
- object orientation;
- encoded format;
- optional in-memory `Data`;
- session disk-file URL;
- last-access sequence.

### Memory layer

- Byte-budgeted LRU, initially `64 MiB`.
- Eviction removes only the in-memory `Data`.
- It never removes the asset record, orientation, or the disk file.

### Disk layer

- One directory per camera session epoch.
- Successful bytes are written atomically before the asset is published as
  available.
- Initial session disk budget is `512 MiB`, enforced by encoded byte cost rather
  than item count. The exact production budget may be lowered by a measured
  free-space guard, but it must not silently fall back to a 30-item limit.
- Current full-screen, adjacent pages, and the active vertical viewport are
  pinned while enforcing the disk budget; older unpinned assets are evicted in
  LRU order with an explicit diagnostic marker.
- Remaining files are cleared on session replacement, disconnect, or explicit
  Gallery teardown.
- There is no 30-file app-level eviction.
- A missing OS-purged cache file changes availability to `absent`; it does not
  masquerade as an active request.

This separation ensures that scrolling through more than 30 photos does not
erase loaded history merely because the request window moved.

## Target-Aware Image Decoding

The current `UIImage(data:)` first path is not suitable for the vertical HD
list because it decodes the full source dimensions. All HD display decoding
must use ImageIO with an explicit target.

```swift
enum NativeGalleryHDPreviewDecodeTier: Hashable {
  case verticalList(maxPixelSize: Int)
  case fullScreenFit(maxPixelSize: Int)
  case fullScreenNative
}
```

The decoded cache key includes:

- session epoch;
- handle;
- object orientation;
- decode tier and target pixel size.

### Vertical-list tier

- Target width is the rendered card width multiplied by display scale.
- Add at most 20 percent headroom to avoid decode churn during small layout
  changes.
- Never exceed the source dimensions.
- Initial decoded-cache budget: `64 MiB`.
- The repository coalesces duplicate requests for the same key.

For a typical iPhone-width card, this turns a `1824 x 2736` source into a
roughly screen-width bitmap rather than a `19 MiB` native bitmap.

### Full-screen fit tier

- Target is the full-screen viewport multiplied by display scale.
- Used for the previous and next pages and as the first image shown on the
  current page.
- Initial adjacent-page decoded budget: `32 MiB`.

### Full-screen native tier

- Only the settled current page may retain a native decode of the compressed HD
  preview source. This is never an original-file decode.
- The previous native page is released when paging completes.
- The page first displays `fullScreenFit`, then promotes to native off the main
  thread.
- Native decode failure leaves the fit image visible and exposes retry without
  blanking the page.

### Memory pressure

On memory warning:

1. release the current native image after preserving the fit image;
2. clear adjacent full-screen variants;
3. clear off-screen vertical-list variants;
4. keep compressed disk assets and their availability records.

Memory pressure must not trigger a camera request by itself.

## Vertical and Full-Screen Linkage

### Opening

The Gallery builds an immutable navigation context from the current render
projection:

```swift
struct NativeGalleryHDPreviewNavigationContext {
  let catalogIdentity: CameraGalleryCatalogIdentity
  let orderedDisplayHandles: [Int]
  let initialHandle: Int
  let sourceMode: NativeGalleryBrowseMode
}
```

For HD mode, `orderedDisplayHandles` comes from the HD snapshot's display
cards. RAW sidecars remain selectable from their card but do not become blank
image pages. For thumbnail mode, the sequence uses previewable display photos
from the current filtered presentation.

Opening full-screen changes pipeline focus from `.verticalList` or `.inactive`
to `.fullScreen`; it does not create a second preview requester. Thumbnail mode
does not activate vertical-list loading merely because full-screen is open.
Entering full-screen also releases off-screen vertical-list decoded variants;
the compressed store remains shared.

### Paging

- `UIPageViewController` remains the paging container.
- A page controller reads the shared store and requests decoded variants from
  the shared image repository.
- When paging settles, full-screen publishes the new `currentHandle` and the
  pipeline reprioritizes that handle.
- Cancelled interactive paging restores the actual visible page as current.
- Zoom and manual rotation are page-local presentation state and are discarded
  when that page controller is released.

### Closing and return positioning

The close contract changes from:

```swift
onPreviewClosed: () -> Void
```

to:

```swift
onPreviewClosed: (_ currentHandle: Int, _ catalogIdentity: CameraGalleryCatalogIdentity) -> Void
```

After the full-screen controller has been dismissed:

1. validate that the Catalog identity still matches;
2. map `currentHandle` to the active snapshot's index path;
3. scroll it into the active collection view without rebuilding sections;
4. if `sourceMode == .highDefinition`, place it near the vertical center,
   restore `.verticalList`, and submit the post-scroll visible handles;
5. if `sourceMode == .thumbnail`, keep the HD pipeline `.inactive`, position
   the thumbnail visibly, resume the thumbnail pipeline, and resubmit its
   post-scroll viewport.

The scroll occurs after layout has the current snapshot. It must not use a
stale index captured when full-screen opened.

## Download and D226 Mode Ownership

### Root rule

There is one physical transfer-mode owner on the serialized camera command
lane. Preview code, full-screen code, download code, and debug experiments are
not allowed to write `D226` or its companion compression properties
independently.

Introduce `CameraVendorTransferModeCoordinator`, owned by
`CameraVendorPtpSession`, with these logical modes:

```swift
enum CameraVendorPhysicalTransferMode: Equatable {
  case reset
  case screenPreview
  case compressedDownload
  case originalDownload
  case unknown
}
```

Every successful preparation records the last confirmed physical mode. Any
failed preparation or reset sets the mode to `.unknown`; the next camera
operation must prepare from the physical property boundary instead of trusting
an older logical flag.

### Screen preview operation

For each camera fetch:

1. acquire normal Gallery command admission;
2. ensure physical mode is `screenPreview` by writing `D226=1`;
3. read fresh ObjectInfo;
4. read exactly the reported screen-preview bytes;
5. validate and store the image;
6. reset to `D226=0` at the serialized operation boundary;
7. update physical state to `reset` or `unknown` if reset failed.

### Compressed download operation

For a queued compressed download:

1. pause and join the shared HD camera-fetch pump;
2. acquire the exclusive download lease;
3. prepare the required resize/compression companion property;
4. explicitly write `D226=1` before fresh ObjectInfo;
5. read ObjectInfo only after all preparation responses succeed;
6. transfer exactly the fresh compressed size;
7. retain this mode only while consecutive serialized queue items request the
   same compressed mode.

The coordinator distinguishes `screenPreview` from `compressedDownload` even
though both use `D226=1`, because their admission, companion properties, result
validation, and lifecycle are different.

### Original download operation

For a queued original download:

1. pause and join the shared HD camera-fetch pump;
2. acquire the exclusive download lease;
3. explicitly write `D226=2` before the first fresh ObjectInfo, regardless of
   a remembered logical download mode;
4. read fresh ObjectInfo only after the property response succeeds;
5. use that fresh size for ReadImage transfer;
6. retain this mode only while consecutive serialized queue items request
   original mode.

When the queue switches between compressed and original modes, the coordinator
performs the required reset and fresh preparation before ObjectInfo. When the
queue completes or is cancelled, it writes `D226=0`. A reset failure marks the
mode unknown and blocks Gallery camera requests until a fresh preparation or
session recovery succeeds.

No session-lifetime optimization may skip step 3 after a preview operation.
The debug `session` lifetime experiment must not alter correctness in an app
installed for user testing.

### Download safety evidence

Before every file transfer, log one unsuppressed summary containing:

- purpose;
- requested logical mode;
- physical mode before and after preparation;
- whether a property write occurred;
- handle;
- fresh ObjectInfo size;
- cached size, if any;
- selected transfer size.

This makes `mode=original` with `freshSize=167936` immediately attributable and
prevents diagnostic policies from hiding the state transition that matters.

## Lifecycle and Concurrency

- HD camera requests remain serial.
- Vertical-list-to-full-screen changes focus; it does not disconnect or recreate
  PTP.
- Full-screen-to-list or full-screen-to-thumbnail preserves compressed session
  files and asset availability.
- Download admission pauses and joins the active HD camera-fetch pump, then
  owns the command lane exclusively.
- Local disk reads and image decodes may run concurrently because they do not
  use PTP; they are cancelled only for UI lifecycle, stale identity, or memory
  pressure.
- Filter or Catalog replacement cancels old-generation work and rejects late
  publications by Catalog identity.
- Disconnect clears compressed session files, decoded caches, focus, and mode
  coordinator state.

## Error Semantics

### Camera fetch failure

- Marks only that handle failed for the current Catalog identity.
- Existing lower-quality thumbnail remains visible.
- Explicit retry removes the failure and submits the handle to the shared
  pipeline.

### Local disk/decode failure

- Does not mark the camera fetch failed.
- Removes only the invalid local asset or decoded variant.
- If compressed bytes remain valid, retry local decode.
- If the disk asset is missing, show the thumbnail and request camera data only
  when the item becomes current/visible or the user explicitly retries.

### Catalog replacement while full-screen is open

- The current full-screen snapshot remains immutable until close or terminal
  transport loss.
- Late data from the replaced identity is rejected.
- Close does not attempt return positioning into the new Catalog.

### Download interruption

- Cancellation drains at a verified chunk boundary.
- The exclusive finalizer resets transfer mode before Gallery work resumes.
- Gallery focus is restored only after Runtime returns to `galleryReady`.
- Runtime publishes a distinct user-cancelled result carrying the originating
  browse mode and return handle. The controller dismisses back to Gallery and
  must not translate this result into Gallery exit or Home navigation.
- A transport failure discovered during cancellation is reported separately;
  only that terminal failure may start the existing disconnect route.

## Diagnostics

Add concise, unsuppressed markers at component boundaries:

```text
HD_ASSET_FETCH_BEGIN handle=... focus=vertical-list|fullscreen
HD_ASSET_FETCH_END handle=... encodedBytes=... disk=true
HD_ASSET_RESTORE handle=... source=memory|disk
HD_ASSET_DISK_EVICT handle=... encodedBytes=... reason=budget|os-purge
HD_DECODE_BEGIN handle=... tier=vertical-list|fit|native targetPixels=...
HD_DECODE_END handle=... tier=... decodedPixels=... costBytes=...
HD_DECODE_CACHE_HIT handle=... tier=...
HD_FOCUS_CHANGE from=vertical-list|inactive to=fullscreen handle=...
HD_FULLSCREEN_PAGE_SETTLED handle=...
HD_FULLSCREEN_CLOSE_RETURN handle=... catalogMatch=true|false
PTP_TRANSFER_MODE_PREPARE purpose=... before=... requested=... wrote=true|false
PTP_TRANSFER_MODE_READY purpose=... actual=... freshSize=...
```

The logs must distinguish camera fetch, disk restoration, compressed cache hit,
fit decode, and native decode. Repeated native decode for one settled handle is
a defect unless preceded by memory pressure or target-key change.

## File Boundaries

### Create

- `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewStore.swift`
  - authoritative asset records, compressed memory LRU, session disk files.
- `ios/Runner/NativeGalleryHDPreviewImageRepository.swift`
  - target-aware ImageIO decode, task coalescing, decoded variant caches.
- `ios/Runner/CameraVendorTransferModeCoordinator.swift`
  - physical CameraVendor transfer-mode state and legal transitions.

### Modify

- `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
  - one vertical-list/full-screen focus and one fetch priority pump.
- `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
  - expose focus changes and shared asset access.
- `ios/Runner/CameraSessionRuntime.swift`
  - forward HD focus and shared image/data access without becoming another owner.
- `ios/Runner/NativeGalleryViewController.swift`
  - remove full-size HD decode cache, request vertical-list variants, open navigation
    context, and restore current handle on close.
- `ios/Runner/NativePhotoPreviewViewController.swift`
  - page through the provided filtered sequence, use fit/native tiers, and
    return current handle.
- `ios/Runner/CameraVendorPtpSession.swift`
  - route all `D226` writes through the transfer-mode coordinator.
- `ios/Runner/CameraVendorTransferPolicy.swift`
  - remove correctness dependence on session-lifetime remembered mode.
- `ios/RunnerTests/RunnerTests.swift`
  - add state, cache, paging, return-position, and transfer-mode regressions.
- `ios/project.yml`
  - include newly created Swift files if project generation requires explicit
    source declarations.

The existing large view-controller files are not broadly refactored beyond
moving the new cache/decode responsibilities into focused files.

## Test Strategy

### Store tests

- Memory eviction keeps the asset record and disk availability.
- Disk eviction uses encoded-byte LRU, protects pinned handles, and has no
  30-item stop condition.
- Disk restoration does not create a camera request.
- Session replacement rejects and removes previous-epoch assets.
- Atomic write failure never publishes an available asset.

### Decode tests

- Vertical-list decode output does not exceed the requested pixel target.
- Cache keys distinguish vertical-list, fit, and native variants.
- Duplicate requests for the same key share one decode task.
- Evicting a decoded image does not change asset availability.
- Memory warning keeps compressed disk assets while removing decoded variants.

### Focus and paging tests

- Vertical list and full-screen use the same filtered display-handle order.
- RAW sidecars are not emitted as blank full-screen pages.
- Full-screen priority is current, next, previous.
- Settled page changes current handle; cancelled paging restores the visible
  handle.
- Closing returns the current handle and Catalog identity.
- Matching Catalog scrolls to the returned handle; replaced Catalog does not.

### Transfer-mode tests

- HD preview writes `D226=1` before ObjectInfo and resets after the request.
- Compressed download prepares its companion property and writes `D226=1`
  before fresh ObjectInfo.
- Original download writes `D226=2` before fresh ObjectInfo after any preview.
- Switching compressed/original queue items performs reset and fresh mode
  preparation before ObjectInfo.
- A remembered original mode cannot suppress the write after `D226=0`.
- User cancellation resets mode before Gallery requests resume.
- User cancellation returns the originating Gallery context and never emits a
  Gallery-exit/Home-navigation outcome by itself.
- Failed property/reset writes mark physical mode unknown.
- No source outside `CameraVendorTransferModeCoordinator` performs a direct
  `D226` write.

### Regression and build verification

- Run focused new tests first.
- Run the complete `RunnerTests` suite and compare executed-test count with the
  current baseline.
- Run `git diff --check`.
- Generate the Xcode project if required by `project.yml` changes.
- Build Debug for the connected iPhone target.

## Physical-Device Acceptance

Use the same iPhone and real camera for the complete flow:

1. Enter HD mode and scroll rapidly through at least 30 cards.
2. Confirm encoded preview logs remain compressed-preview sized (typically
   `1-6 MB` for the observed camera and within the protocol safety cap) while
   vertical-list decoded dimensions remain near the card target. Do not compare
   encoded bytes with RGBA decoded cost.
3. Confirm a loaded card never returns to a camera spinner after decoded-cache
   eviction.
4. Open one card full-screen and verify current page native promotion.
5. Swipe at least ten pages in both directions; confirm only the settled current
   page retains a native decode.
6. Close on a different photo and confirm the vertical list returns to that
   handle and resumes priority around it.
7. Reopen previously visited pages and confirm `source=disk` or cache-hit logs,
   not repeated camera reads.
8. Select photos from both vertical and full-screen surfaces and confirm both
   reflect the same queue state.
9. Start original download immediately after HD/full-screen browsing.
10. Confirm an unsuppressed `D226=2` preparation precedes fresh ObjectInfo.
11. Confirm downloaded byte counts match original ObjectInfo, not `167936` and
    not the `1-6 MB` screen preview.
12. Cancel a download, return to Gallery, and repeat HD plus original download
    without reconnecting.
13. Confirm cancellation preserves the originating filter, browse mode,
    selection, and return handle, with no Home navigation unless a separate
    terminal disconnect is logged.

Compile-only, simulator-only, install-only, and old logs do not satisfy this
acceptance matrix.

## Acceptance Criteria

The design is complete when all of the following are true:

- vertical HD and full-screen use one ordered sequence and one fetch/store
  state;
- vertical cards are decoded to a bounded target rather than native preview
  dimensions;
- only one full-screen page retains a native HD bitmap;
- full-screen closes back to the current handle;
- decoded eviction never changes a successful item to camera-loading state;
- disk restoration never re-enters PTP;
- disk retention is byte-budgeted and never stops loading at an arbitrary
  30-item count;
- original download always prepares physical original mode before fresh
  ObjectInfo;
- user cancellation returns to the originating Gallery context after mode
  reset and does not route Home by itself;
- the real-camera flow proves correct original byte counts after HD browsing;
- full `RunnerTests`, build, install, launch, and physical-device evidence are
  reported separately.
