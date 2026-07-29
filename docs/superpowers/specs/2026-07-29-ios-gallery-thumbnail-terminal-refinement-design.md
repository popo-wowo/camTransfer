# iOS Gallery Thumbnail Terminal Refinement Design

**Status:** Approved by the user on 2026-07-29.

## Goal

Close the remaining thumbnail, metadata, incremental-update, and suspension gaps without rewriting the existing Catalog, Repository, command lane, Gallery session, or HD-preview architecture.

## Architecture

`CameraGalleryRepository` remains the single Gallery item state store. The current `CameraGalleryThumbnailPipeline` is narrowed into two independently scheduled responsibilities: viewport-driven thumbnail loading and idle Details enrichment. They may remain in one source file, but they must not share cancellation progress or scheduling state.

```text
CameraGalleryCatalogRuntime
  -> CameraGalleryRepository
       <- visible thumbnail publications
       <- ObjectInfo/details publications

CameraGalleryThumbnailPipeline
  -> ThumbnailLoader state: latest viewport revision, retry/failure state
  -> DetailsEnricher state: cursor, completed handles, idle restart

Suspension
  -> catalog suspension: cleared by installing a new generation
  -> external suspension: download/HD preview; never cleared by install

UI events
  -> content delta: thumbnail/metadata/orientation for stable membership
  -> structural delta: membership/order/section-affecting metadata
```

No `EnrichmentCoordinator`, `MediaWorkGate`, or second item store is introduced.

## Required behavior

### Suspension

- Catalog submission suspends work for the retiring generation.
- Installing a new generation clears only Catalog suspension.
- Download and HD-preview suspension survive Catalog installation.
- Resuming external work replays the latest visible viewport.

### Viewport scheduling

- Every viewport request receives a monotonic revision before its first suspension point.
- An older request may never cancel or replace a newer request after actor re-entry.
- Cached handles publish immediately; uncached handles follow the latest viewport order.

### ObjectInfo reuse

- `thumbnailWithInfo` preserves the real `CameraGalleryObjectInfoResult`, including `formatCode` and completeness.
- `formatLabel` alone never promotes metadata to complete ObjectInfo.
- Details skips `fetchObjectInfo` only when a complete reusable ObjectInfo exists.

### Details enrichment

- Details maintains a persistent cursor and completed-handle set per Catalog identity.
- Visible thumbnail work may pause Details, but must not reset its progress.
- Installing a new membership preserves same-session reusable ObjectInfo and resets only membership-specific progress.

### Publications and UI

- Runtime incremental publications identify content versus structural effects.
- A late orientation change invalidates the decoded thumbnail cache before refresh.
- Date/order/membership-affecting changes rebuild sections, trim selection, and refresh status.
- Content-only thumbnail updates never call `reloadData()` on the main Gallery.

### Failure and lifecycle state

- Thumbnail requests use bounded retry/backoff and publish a failed state after exhaustion.
- UI does not immediately re-request a terminally failed handle until an explicit retry trigger or new session.
- Incremental observer IDs are retained and removed in `deinit`.
- Decoded image cache identity includes the active session epoch and orientation revision, not handle alone.

### HEIF subtraction validation

- Subtract-baseline results must validate snapshot integrity and the expected set relationship before publication.
- Invalid or ambiguous relationships fail the query instead of publishing an empty or guessed membership.
- Real-camera HEIF membership remains a separate acceptance requirement.

## Acceptance

- New regression tests demonstrate RED before each behavior change and GREEN after it.
- Targeted CatalogRuntime, ThumbnailPipeline, Repository, Gallery UI policy, and HEIF tests pass.
- The full suite introduces no unexplained new failures; stale source-scanning tests are updated when their ownership assertions moved.
- `git diff --check` and generic iPhoneOS Debug build pass.
- Simulator evidence covers deterministic concurrency and state transitions; physical-camera evidence covers PTP membership and lifecycle behavior.
