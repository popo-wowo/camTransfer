# iOS HD Preview and Full-Screen Design

## Status

Revised after user correction on 2026-08-01. This document defines the target
design only. Swift implementation and physical-device acceptance are pending.

The earlier revision in commit `154f6651` is superseded by this document. In
particular, this revision rejects these earlier assumptions:

- thumbnail full-screen and HD full-screen are not one loading state machine;
- the number `30` is not merely a scheduling window; it is the HD cache entry
  limit;
- the existing `NativeGalleryHighDefinitionPreviewCache` is not replaced by an
  unbounded or `512 MiB` session asset store;
- the current thumbnail full-screen architecture is preserved.

## Hard Product Constraints

1. Thumbnail browsing and HD browsing use two distinct full-screen loading
   flows.
2. Thumbnail full-screen shows the thumbnail immediately, then loads only the
   currently displayed photo's HD preview. It never preloads adjacent photos.
3. Vertical HD browsing and HD full-screen paging are linked. They reuse the
   HD list's ordered snapshot, loader, and 30-entry cache.
4. The HD cache contains at most 30 photo entries. Loading may continue as the
   viewport moves, but entry 31 evicts the least-recently-used entry.
5. The current Catalog, Runtime, Gallery session, PTP command lane, and download
   ownership boundaries remain intact. This feature must not introduce a second
   Catalog owner, camera session, command lane, or download manager.

## Current Architecture Anchors

The implementation plan must extend these existing owners instead of replacing
them:

- `NativeGalleryViewController`
  - owns thumbnail/HD browse mode and Gallery navigation;
  - currently opens `NativePhotoPreviewViewController`;
  - owns the vertical HD decoded-image presentation cache.
- `NativePhotoPreviewViewController`
  - is the existing thumbnail-origin full-screen flow;
  - creates page controllers for horizontal navigation;
  - only the page marked by `setDisplayedPage(true)` calls `loadImage()`;
  - shows `item.thumbnailData` or the cached thumbnail first;
  - requests the HD preview only for that currently displayed page.
- `CameraGalleryHDPreviewPipeline`
  - is the existing serial HD-list camera-request owner;
  - loads visible handles, then handles below, then handles above;
  - publishes `NativeGalleryHDPreviewState` through `CameraGallerySession`.
- `NativeGalleryHighDefinitionPreviewCache`
  - is the existing HD encoded-data cache;
  - owns loaded handles, orientation, memory data, disk files, and LRU order;
  - keeps at most 30 entries.
- `CameraGallerySession` and `CameraSessionRuntime`
  - remain the Gallery lifecycle and public intent boundaries.
- `CameraVendorPtpSession`
  - remains the single physical PTP command executor.

No new component may restart BLE, Wi-Fi, PTP, Catalog, or Gallery state merely
because the user opens or closes either full-screen viewer.

## Product Behavior Matrix

| Entry surface | Full-screen flow | First display | Camera loading | Prefetch | Return target |
|---|---|---|---|---|---|
| Thumbnail grid | Thumbnail full-screen | Thumbnail | Current page only | None | Current thumbnail |
| Vertical HD list | Linked HD full-screen | Existing HD cache entry, otherwise thumbnail | Shared HD pipeline | Current, then next/previous within the 30-entry cache | Current HD card |

The two rows are separate feature-level state machines. They may share immutable
Catalog identity, selection/download state, the physical PTP command lane, and
a read-only hit for already-fetched encoded bytes of the current handle. They do
not share loading focus, cache insertion, prefetch policy, or controller
lifecycle.

## Architecture Summary

```text
CameraGalleryPresentation
  +-- one filtered Catalog membership and order
  |
  +-- Thumbnail grid
  |     +-- existing NativePhotoPreviewViewController
  |           thumbnail first
  |           current displayed page only
  |           no adjacent camera prefetch
  |
  +-- Vertical HD list
        +-- existing CameraGalleryHDPreviewPipeline
        +-- existing 30-entry NativeGalleryHighDefinitionPreviewCache
        +-- dedicated linked HD full-screen controller
              horizontal paging
              current/next/previous priority
              no second camera loader

CameraSessionRuntime
  +-- shared selection and download state
  +-- Gallery/download admission

CameraVendorPtpSession
  +-- one serialized command lane
  +-- one transfer-mode coordinator for D226
```

## Flow A: Thumbnail Full-Screen

### Entry

When a photo is opened from thumbnail mode:

1. `NativeGalleryViewController` captures the current filtered thumbnail item
   order and initial index.
2. It opens the existing `NativePhotoPreviewViewController`.
3. The displayed page renders `item.thumbnailData` or the current decoded
   thumbnail immediately.
4. Only after the page is visible does it request that handle's HD preview.

This flow does not activate or reprioritize
`CameraGalleryHDPreviewPipeline`.

### Paging

`UIPageViewController` may construct previous and next page controllers for
gesture handling, but construction is not loading.

- Only `setDisplayedPage(true)` may start an HD request.
- When the gesture completes, the previous page cancels its request and the new
  displayed page starts its own request.
- A cancelled interactive transition must keep the actually visible page as
  current.
- No request is started for an adjacent page merely because the page controller
  exists.

### Cache behavior

Thumbnail full-screen is demand-only:

- it may read an already-existing HD encoded entry for the current handle;
- a successful current-page request remains page-local and does not insert into
  or refresh the HD list's 30-entry LRU;
- it never inserts next/previous handles through prefetch;
- it never submits a 30-handle loading window;
- it never reports HD-list loading progress.

The read-only hit avoids a needless camera round trip without allowing
thumbnail full-screen to evict or reprioritize HD-list entries. Thumbnail
full-screen owns its current-page bytes, task, and cancellation state.

### Closing

The close callback returns the current handle and Catalog identity.

- If the Catalog identity still matches, the thumbnail grid scrolls that handle
  into view and resubmits its real thumbnail viewport.
- The HD pipeline remains inactive when the originating browse mode is
  thumbnail.
- Closing thumbnail full-screen must not switch the Gallery into HD mode.

## Flow B: Vertical HD List

### Loading order

The existing `CameraGalleryHDPreviewPipeline` remains the sole HD-list camera
request owner. For every viewport update it calculates up to 30 unique handles:

1. visible display handles in Gallery order;
2. handles immediately below the visible range;
3. handles immediately above the visible range.

Camera requests remain serial. A new viewport replaces pending priority without
force-killing the in-flight PTP request; the worker changes direction after the
safe completion boundary.

The 30-handle priority list and 30-entry cache have the same upper bound, but
they have different meanings:

- priority list: which missing handles should be requested next;
- cache: which completed photo entries are retained now.

Loading does not stop forever after 30 photos. When the viewport moves, new
handles may load and old LRU entries may be evicted so retained count remains
30.

### Cache contract

`NativeGalleryHighDefinitionPreviewCache` remains the cache owner and retains
at most 30 photo entries.

One entry is keyed by `(sessionEpoch, handle, hdPreview)` and contains:

- encoded preview bytes in memory when resident;
- session disk file;
- loaded-handle membership;
- object orientation;
- LRU position;
- the identity used to invalidate decoded vertical/full-screen variants stored
  by the existing presentation-layer caches.

When entry 31 is stored:

1. choose the least-recently-used unpinned entry;
2. remove its encoded memory data;
3. remove its disk file;
4. remove loaded-handle and orientation state;
5. notify the existing presentation caches to remove decoded variants for that
   handle;
6. emit one explicit eviction log.

Visible HD cards and the settled full-screen current page are touched before
eviction. Current, next, and previous full-screen handles are pinned while a
page transition is active.

An evicted handle is no longer considered loaded. If it becomes visible again,
it may be requested again through the HD pipeline. This is expected LRU
behavior, not an unbounded loaded-history design.

## Flow C: Linked HD Full-Screen

### Separate controller, shared HD owner

Opening a card from the vertical HD list uses a dedicated linked-HD full-screen
controller. It does not repurpose the thumbnail full-screen request state
machine.

The recommended boundary is:

```swift
struct NativeGalleryHDFullScreenContext {
  let catalogIdentity: CameraGalleryCatalogIdentity
  let orderedDisplayHandles: [Int]
  let initialHandle: Int
}
```

The context is derived from the current `NativeGalleryHDPreviewSnapshot`.
RAW sidecars remain attached to their display card and do not become blank
full-screen pages.

The new controller is only a presentation and navigation owner. It does not
fetch from the camera directly. It submits the current full-screen focus to the
existing `CameraGalleryHDPreviewPipeline`.

### Paging and priority

When a full-screen page settles, HD priority becomes:

1. current handle;
2. next display handle;
3. previous display handle.

Rules:

- current is mandatory;
- next/previous are eligible only after current is available;
- all fetched results enter the same 30-entry HD cache;
- full-screen prefetch never creates a 31st retained entry without LRU eviction;
- a download request preempts all HD camera loading through existing admission;
- cancelled paging restores the actually visible page as current.

### Decode tiers

The encoded HD object is normally only a few megabytes, while a full native
RGBA decode may consume roughly `19-38 MiB`. Display decoding therefore uses
ImageIO target sizes instead of unconditional `UIImage(data:)` decoding.

```swift
enum NativeGalleryHDDecodeTarget: Hashable {
  case verticalCard(maxPixelSize: Int)
  case fullScreenFit(maxPixelSize: Int)
  case fullScreenNative
}
```

- Vertical card: decode near the rendered card width multiplied by display
  scale, with at most 20 percent headroom.
- Full-screen fit: decode near the full-screen viewport size; use for adjacent
  pages and the first presentation of current.
- Full-screen native: only the settled current page may retain the native HD
  preview decode. This is still the compressed camera preview, not the original
  photo file.

Decoded variants remain owned by the existing presentation layer and the
focused decoder helper; they are not moved into a new cache owner. Every variant
is keyed to one of the 30 retained handle identities. Evicting the encoded entry
invalidates every decoded variant for that handle. When paging settles, the
previous native variant is released or downgraded to fit.

### Closing and linkage

The HD full-screen close callback returns current handle and Catalog identity.

After dismissal:

1. verify Catalog identity still matches;
2. map current handle using the current HD snapshot, not a stale opening index;
3. scroll the vertical HD collection so the card is near the center;
4. restore HD-pipeline priority around the post-scroll visible handles;
5. keep the 30-entry cache and existing loaded state intact.

If the Catalog was replaced or the handle no longer exists, keep the current
Gallery position and do not guess a replacement.

## Transfer Mode and Download Correctness

### Single physical owner

Preview and download flows share the physical command lane but must not write
`D226` independently.

Add `CameraVendorTransferModeCoordinator` under
`CameraVendorPtpSession`. It is the only component allowed to prepare/reset
`D226` and companion compression properties.

Logical purposes remain distinct:

```swift
enum CameraVendorPhysicalTransferPurpose: Equatable {
  case reset
  case screenPreview
  case compressedDownload
  case originalDownload
  case unknown
}
```

Thumbnail current-page preview and HD-pipeline preview both use the same safe
physical screen-preview operation, even though their UI state machines are
separate:

1. acquire Gallery command admission;
2. write `D226=1`;
3. read fresh ObjectInfo;
4. read exactly the reported preview bytes;
5. validate the encoded image;
6. reset `D226=0` at the serialized operation boundary.

Compressed download prepares its companion resize property and writes
`D226=1` before fresh ObjectInfo. Original download writes `D226=2` before
fresh ObjectInfo. Switching queue modes requires reset and fresh preparation.

No remembered session-lifetime flag may suppress the original `D226=2` write
after a preview reset. A failed property write or reset marks physical state
unknown.

## Download Cancellation Return

User cancellation is not a Gallery exit.

The required sequence is:

1. request soft cancellation;
2. drain at a verified chunk boundary;
3. finalize the active download item;
4. reset physical transfer mode;
5. release exclusive download admission;
6. resume the originating Gallery content flow;
7. dismiss download UI back to the same Gallery mode and handle.

Thumbnail origin returns to the thumbnail grid. HD origin returns to the
vertical HD list. Only a separately proven terminal connection/session failure
may route Home.

## State Ownership

| State | Owner |
|---|---|
| Catalog generation, membership, filter, order | Existing `CameraGalleryCatalogRuntime` / `CameraGallerySession` |
| Thumbnail viewport and thumbnail fetches | Existing thumbnail pipeline |
| Thumbnail full-screen current-page task | Existing `NativePhotoPreviewViewController` page |
| Vertical HD/full-screen camera priority | Existing `CameraGalleryHDPreviewPipeline` |
| Thirty retained HD entries | Existing `NativeGalleryHighDefinitionPreviewCache` |
| HD full-screen current handle and zoom | Dedicated linked-HD full-screen controller |
| Selection/download state | Existing `CameraSessionRuntime` |
| Physical D226 mode | `CameraVendorTransferModeCoordinator` inside existing PTP session |
| Gallery/Home navigation | Existing Gallery/session navigation owner |

The change must not move these states into a new parallel Runtime or controller
singleton.

## Error and Lifecycle Semantics

### Thumbnail full-screen failure

- Keep the thumbnail visible.
- Mark only the current page request failed.
- Retry only when that page is still displayed or the user explicitly retries.
- Never start adjacent requests as recovery.

### HD failure

- Mark only that handle failed for the current Catalog identity.
- Keep a thumbnail or existing lower-quality decoded image visible.
- Explicit retry re-enters the HD pipeline for that handle.
- Cache eviction is not reported as camera failure.

### Catalog replacement

- Cancel old-identity camera tasks at the safe boundary.
- Reject late results by session epoch, generation, snapshot identity, handle,
  and media variant.
- Full-screen close does not scroll into a different Catalog.

### Memory warning

- Release full-screen native decode first.
- Release adjacent fit decodes next.
- Release off-screen vertical-card decodes next.
- Do not change the 30-entry encoded cache contract merely because decoded
  images were released.
- Memory pressure alone does not start a camera request.

### Disconnect

- Cancel and join both full-screen current-page work and HD-pipeline work.
- Clear the 30-entry cache for the ended session.
- Clear transfer-mode coordinator state.
- Route according to the existing terminal disconnect owner.

## Diagnostics

Required unsuppressed boundary logs:

```text
THUMB_FULLSCREEN_PAGE_DISPLAYED handle=...
THUMB_FULLSCREEN_PREVIEW_BEGIN handle=... source=thumbnail
THUMB_FULLSCREEN_PREVIEW_END handle=... encodedBytes=...
THUMB_FULLSCREEN_PREVIEW_CANCEL handle=... reason=page-changed|closed|download
THUMB_FULLSCREEN_HD_CACHE_UNCHANGED handle=... retained=...
HD_PRIORITY_PLAN focus=list|fullscreen candidates=... retained=...
HD_CACHE_STORE handle=... retained=... limit=30
HD_CACHE_EVICT handle=... retained=30 reason=lru
HD_DECODE_BEGIN handle=... tier=vertical|fit|native targetPixels=...
HD_DECODE_END handle=... tier=... decodedPixels=... costBytes=...
HD_FULLSCREEN_PAGE_SETTLED handle=...
HD_FULLSCREEN_CLOSE_RETURN handle=... catalogMatch=true|false
PTP_TRANSFER_MODE_PREPARE purpose=... before=... requested=... wrote=...
PTP_TRANSFER_MODE_READY purpose=... actual=... freshSize=...
DOWNLOAD_CANCEL_RETURN mode=thumbnail|highDefinition handle=... terminal=false
```

The logs must prove that thumbnail full-screen never requests an undisplayed
page and that the HD retained count never exceeds 30.

## File Boundaries

### Preserve

- `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
  - remains the single vertical-HD and HD-full-screen fetch owner.
- `ios/Runner/NativePhotoPreviewViewController.swift`
  - remains the thumbnail-origin full-screen flow;
  - keep thumbnail-first and current-page-only behavior.
- `ios/Runner/NativeGalleryViewController.swift`
  - remains browse-mode and navigation owner.
- `ios/Runner/NativePhotoPreviewViewController.swift`:
  `NativeGalleryHighDefinitionPreviewCache`
  - remains the 30-entry encoded HD cache in the first implementation;
  - do not replace or relocate it as unrelated refactoring.

### Create

- `ios/Runner/NativeGalleryHDFullScreenViewController.swift`
  - linked HD paging UI and current-handle return contract;
  - submits focus to the existing HD pipeline, never fetches PTP directly.
- `ios/Runner/NativeGalleryHDTargetDecoder.swift`
  - ImageIO target-aware vertical/fit/native decoding;
  - contains no Gallery membership or camera-request state.
- `ios/Runner/CameraVendorTransferModeCoordinator.swift`
  - physical transfer-mode transitions under the existing PTP session.

### Modify narrowly

- `ios/Runner/NativeGalleryViewController.swift`
  - branch preview entry by browse mode;
  - thumbnail opens existing controller;
  - HD opens linked-HD controller;
  - restore the returned handle to the correct collection mode.
- `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
  - add explicit list/full-screen focus priority without adding another worker.
- `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
  - forward HD focus intents through the existing session boundary.
- `ios/Runner/CameraSessionRuntime.swift`
  - expose those existing-session intents; do not own another cache or loader.
- `ios/Runner/CameraVendorPtpSession.swift`
  - route transfer-mode writes through the coordinator.
- `ios/Runner/CameraVendorTransferPolicy.swift`
  - remove correctness dependence on Debug session-lifetime D226 suppression.
- `ios/RunnerTests/RunnerTests.swift`
  - add behavior, cache, mode, navigation, and ownership regressions.
- `ios/project.yml`
  - include new focused Swift files only if source generation requires it.

No broad `NativeGalleryViewController` split, Catalog refactor, Runtime
replacement, or new PTP lane belongs in this change.

## Test Strategy

### Thumbnail full-screen tests

- Initial page displays thumbnail before HD data arrives.
- Creating previous/next page controllers causes zero camera requests.
- Only the page marked displayed requests its handle.
- Completed swipe cancels the previous task and requests the new current page.
- Cancelled swipe keeps the original current handle.
- Thumbnail full-screen never submits HD-list focus or adjacent prefetch.
- A thumbnail current-page fetch does not insert, touch, or evict an HD-list
  cache entry.
- Closing returns current handle to the thumbnail grid.

### HD cache tests

- Cache retains at most 30 photo entries.
- Storing entry 31 evicts exactly the LRU unpinned entry.
- Eviction removes memory data, disk file, loaded state, orientation, and
  decoded variants for that handle.
- HD-list or linked-HD access refreshes LRU position; the thumbnail
  full-screen read-only hit does not.
- Loading continues beyond 30 total visited photos while retained count remains
  30.
- Current HD full-screen handle cannot be evicted during an active transition.

### Linked HD full-screen tests

- It uses the HD snapshot order, not thumbnail full-screen request state.
- Priority is current, then next, then previous.
- Only current retains native decode; adjacent pages use fit decode.
- RAW sidecars do not create blank pages.
- Closing returns current handle and centers the HD list on it.
- Replaced Catalog rejects return positioning and late results.

### Transfer and cancellation tests

- Both preview flows write `D226=1` before fresh ObjectInfo and reset afterward.
- Compressed download prepares companion property and `D226=1` before ObjectInfo.
- Original download always writes `D226=2` before fresh ObjectInfo after preview.
- Failed preparation/reset marks physical mode unknown.
- User cancellation resets mode before Gallery requests resume.
- User cancellation returns to the originating Gallery mode and never emits
  Home navigation by itself.

### Architecture guard tests

- There remains one `CameraGalleryCatalogRuntime` owner.
- There remains one `CameraGalleryHDPreviewPipeline` camera worker.
- Thumbnail full-screen performs current-only requests without activating that
  worker.
- There remains one PTP command lane and one download manager.
- No UI controller writes `D226` directly.

### Verification

- Run focused tests first.
- Run the complete `RunnerTests` suite and report executed-test count.
- Run `git diff --check`.
- Build Debug for the connected iPhone target.
- Install and launch on the physical iPhone.
- Treat simulator/build/install proof separately from real-camera behavior.

## Physical-Device Acceptance

Use one continuous iPhone and camera session:

1. In thumbnail mode, open full-screen and confirm thumbnail appears first.
2. Stay on one page and confirm only that handle gets an HD camera request.
3. Confirm that request does not change the HD list's retained count or LRU.
4. Begin but cancel a horizontal swipe and confirm no undisplayed handle fetch.
5. Complete a swipe and confirm the new current page alone begins loading.
6. Close on a different page and confirm the thumbnail grid returns to it.
7. Enter vertical HD mode and scroll through more than 30 photos.
8. Confirm loading continues while `retained <= 30` at every cache log.
9. Confirm entry 31 produces one LRU eviction rather than stopping the loader.
10. Open HD full-screen and swipe both directions.
11. Confirm HD priority is current/next/previous and uses the same 30-entry
    cache as the vertical HD list.
12. Confirm only the settled current page retains a native decode.
13. Close on a different page and confirm the vertical HD list centers it and
    resumes loading around it.
14. Start original download immediately after both preview flows.
15. Confirm an unsuppressed `D226=2` preparation precedes fresh ObjectInfo and
    the saved byte count is the original size, not the HD preview size.
16. Cancel download and confirm the app returns to the originating Gallery mode,
    with no Home navigation unless an independent terminal disconnect is logged.

## Acceptance Criteria

The design is correctly implemented only when:

- thumbnail full-screen remains thumbnail-first, current-page-only, and has no
  adjacent prefetch;
- vertical HD and HD full-screen share the existing HD pipeline and the same
  30-entry LRU cache;
- the cache never retains more than 30 photo entries and loading can continue
  beyond 30 visited photos by eviction;
- vertical cards use bounded target decode instead of native-sized RGBA images;
- only the settled HD full-screen page retains a native HD-preview decode;
- each full-screen flow returns to the correct originating Gallery mode and
  current handle;
- D226 preparation is physically correct for preview, compressed download, and
  original download;
- user cancellation returns to Gallery rather than Home;
- no duplicate Catalog owner, HD camera worker, PTP lane, Runtime, or download
  manager is introduced.
