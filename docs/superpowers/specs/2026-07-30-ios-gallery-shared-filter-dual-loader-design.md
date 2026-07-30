# iOS Gallery Shared Filter and Dual Loader Design

## Status

Approved direction: shared filter projection with independent thumbnail and high-definition content loaders.

## Goal

Make thumbnail browsing and high-definition browsing render the same filtered, ordered Gallery membership. The browse mode changes only image quality, layout, loading window, and cache behavior.

## Product Contract

1. Gallery has one filter surface and one authoritative `CameraGalleryFilterIntent`.
2. Date, format, download scope, and sort apply identically in thumbnail and high-definition modes.
3. Selecting all dates shows all dates in both modes.
4. Both modes show the same date sections in the same order.
5. Thumbnail mode requests only camera thumbnails for the grid.
6. Opening one full-screen photo from thumbnail mode requests a high-definition image for that displayed photo.
7. High-definition mode requests high-definition images directly for its current viewport.
8. High-definition loading is serial and follows visible handles, then handles below, then handles above.
9. The high-definition retention window and total high-definition cache are bounded to 30 images.
10. Loading does not stop at a date boundary. The 30-image window is calculated over the globally flattened filtered order.

## Non-Goals

- Do not merge thumbnail and high-definition PTP fetch implementations.
- Do not create a second Catalog owner, filter state, membership query, or generation counter.
- Do not change camera protocol commands or remove the ObjectInfo prime required before thumbnail requests.
- Do not make the thumbnail grid prefetch high-definition images.
- Do not make filter changes from a high-definition-only date picker.

## State Ownership

### Catalog and filter authority

`CameraGallerySession` owns the current `CameraGalleryFilterIntent` and submits it to `CameraGalleryCatalogRuntime`. `CameraGalleryCatalogRuntime` owns the generation, resolved membership, local date/download projection, sort, and repository publication.

`NativeGalleryViewController` renders the immutable `CameraGalleryPresentation` and sends filter or browse-mode intents. It does not own an alternative membership or date filter.

### Shared render projection

`NativeGalleryRenderState` remains the single UI projection of `CameraGalleryPresentation`. Its date sections define the order and membership consumed by both browse modes.

High-definition presentation transforms each shared date section independently into display cards. A RAW sidecar may be attached to its matching display photo, but every filtered handle must remain represented either as a display handle or as that card's sidecar. Pairing must never cross date sections or select an arbitrary unmatched RAW file.

### Mode-local state

Thumbnail mode owns only decoded thumbnail images, viewport identity, and thumbnail loading UI state.

High-definition mode owns only its current viewport, high-definition load state, and high-definition cache. It does not own `hdActiveDate` or another user-editable date selection.

Full-screen preview owns its currently displayed page and requests high-definition data only for that page when needed. It may reuse the shared high-definition cache.

## Data Flow

```text
Shared filter UI
    -> CameraGalleryFilterIntent
    -> CameraGallerySession
    -> CameraGalleryCatalogRuntime
    -> CameraGalleryPresentation
    -> NativeGalleryRenderState date sections
       -> ThumbnailLoader: GetThumb for thumbnail viewport
       -> HDPreviewLoader: preview/partial-object data for HD viewport
       -> Full-screen page: preview/partial-object data for selected page
```

Changing browse mode does not submit another Catalog filter and does not query membership again. It only deactivates one content loader and activates the other against the current Catalog identity and shared render projection.

## Thumbnail Mode

- The grid uses the shared date sections.
- The request window remains visible handles first, followed by a bounded nearby thumbnail prefetch window.
- Only `.thumbnail` media identities are requested.
- Thumbnail success updates affected cells without rebuilding Catalog membership.
- Entering full-screen preview suspends or yields thumbnail work through the existing PTP admission boundary and requests `.hdPreview` for the displayed page.
- Returning from full-screen preview resubmits the actual thumbnail viewport.

## High-Definition Mode

### Sections and headers

High-definition mode uses the same date section order and date header titles as thumbnail mode. The dedicated high-definition date picker, `hdActiveDate`, and single-day snapshot projection are removed.

The high-definition status may show loaded count, but it must not provide another membership-changing date control.

### Ordered loading window

The loader flattens all high-definition sections into the shared global order. For every viewport update it creates at most 30 unique candidates in this order:

1. currently visible display handles sorted by shared Gallery order;
2. handles immediately below the visible range;
3. handles immediately above the visible range.

The loader performs one high-definition PTP request at a time. A newer viewport replaces the pending order without force-killing the in-flight PTP request. After the safe completion boundary, the worker reads the latest viewport and continues from its first missing handle.

Date boundaries do not start, finish, or reset a batch.

### Cache limit

`NativeGalleryHighDefinitionPreviewCache` becomes a true 30-entry LRU cache across memory, disk files, loaded-handle state, and orientation metadata.

When entry 31 is retained, the least recently used entry is removed from memory, disk, loaded state, and orientation state. Accessing an entry refreshes its LRU position. The current visible window is touched in priority order so visible images are not evicted before off-screen images.

Cache keys remain session epoch, handle, and `.hdPreview` variant. Thumbnail and high-definition cache entries never overlap.

## Filter and Mode Transitions

### Filter change

The same filter panel remains available in both modes. A filter change submits one `CameraGalleryFilterIntent`.

When the new Catalog generation becomes ready:

1. install the shared render projection;
2. preserve only valid selection handles;
3. cancel and join content work from the previous Catalog identity;
4. settle the active collection view at the top;
5. schedule the active mode's actual viewport;
6. reject all late results from the previous Catalog identity.

### Thumbnail to high-definition

1. cancel pending thumbnail viewport refreshes;
2. suspend the thumbnail pipeline through the external-work suspension boundary;
3. activate the high-definition loader with the current Catalog identity and all shared sections;
4. request the high-definition viewport in global order.

### High-definition to thumbnail

1. cancel and join the high-definition worker;
2. retain only high-definition cache entries allowed by the 30-entry LRU;
3. resume the thumbnail pipeline;
4. clear thumbnail viewport submission identity;
5. resubmit the actual visible thumbnail viewport.

## Error and Cancellation Semantics

- A failed high-definition request marks only that handle failed for the current Catalog identity.
- Scrolling may reprioritize pending handles but does not turn cancellation into a visible failure.
- Filter, disconnect, download admission, and Catalog replacement are hard lifecycle boundaries and must cancel/join the active content worker.
- Full-screen and high-definition browsing share the same PTP admission rules; they cannot execute concurrently with download transfer.
- Late thumbnail or high-definition results are accepted only when session epoch, Catalog generation, snapshot ID, handle membership, and media variant still match.

## Required Tests

### Shared filtering

- Thumbnail and high-definition modes flatten to the same filtered handle membership and order.
- All-dates filtering produces multiple identical date sections in both modes.
- Format, download scope, and sort changes affect both modes through one runtime submission.
- High-definition mode exposes the shared filter panel and contains no `hdActiveDate` or high-definition date picker.

### High-definition projection

- High-definition projection preserves all shared date sections.
- Loading order crosses a date boundary without resetting.
- RAW pairing cannot cross sections or attach an unmatched RAW handle.

### Loading and cache

- The high-definition priority window is visible, then below, then above, and contains at most 30 handles.
- A newer viewport reprioritizes pending work without joining the current safe PTP request.
- The cache evicts entry 31 from memory, disk, loaded handles, and orientation metadata.
- Access refreshes LRU order.
- Thumbnail and high-definition variants remain isolated.

### Lifecycle

- Switching to high-definition suspends thumbnail requests once.
- Switching back resumes thumbnail work and resubmits the same visible viewport.
- Filter replacement rejects late thumbnail and high-definition publications.
- Opening a full-screen page from thumbnail mode requests high-definition data only for the displayed page.

## Physical-Device Acceptance

On the same camera session, verify:

1. all dates in thumbnail mode and high-definition mode show identical date sections and order;
2. JPG, RAW, HEIF, date, download scope, and sort filters produce identical membership in both modes;
3. thumbnail mode performs no background high-definition requests;
4. opening one full-screen photo performs a high-definition request for that photo;
5. high-definition mode loads strictly from the visible region downward across date boundaries;
6. scrolling retains no more than 30 high-definition cache entries and evicts distant entries;
7. switching modes or filters produces no duplicate handle requests, stale images, or permanent placeholders;
8. download and full-screen/high-definition preview remain mutually exclusive on the PTP lane.

Simulator tests and a generic iPhoneOS build are necessary but do not replace this camera-backed acceptance matrix.
