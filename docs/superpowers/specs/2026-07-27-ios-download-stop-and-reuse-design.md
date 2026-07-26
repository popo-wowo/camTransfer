# iOS Download Stop and Session Reuse Design

## Goal

Keep the existing single camera/PTP session and single sequential download queue, but make download-page exit wait until an active cancellation has actually drained. Normal completion and cancellation both return `CameraSessionRuntime` to `galleryReady`; neither recreates nor disconnects the healthy camera session.

## Confirmed architecture

```text
CameraSessionRuntime (one app/session owner)
├── CameraGalleryCatalogRuntime        catalog, thumbnails, details
├── NativeGalleryHDPreviewCoordinator  independent HD task/cache
└── queuedDownloads + presentation     one sequential batch
        ↓
CameraVendorGallerySessionRuntimeTransport   zero or one active transfer Task
        ↓
CameraVendorRealtimeGalleryService
        ↓
CameraCommandLane + CameraVendorPtpSession   one physical PTP command path
```

The batch download lease remains a scheduling barrier. It blocks new thumbnail, HD-preview, details, and keep-alive commands while original download commands own the physical PTP lane. It does not own Wi-Fi, create a PTP connection, or terminate the camera session.

## Module responsibilities and reuse

- `CameraSessionRuntime` remains the only download-state owner. It owns the queue, progress, recovery state, current phase, and lease acquisition/release.
- `NativeDownloadListViewController` is presentation only. Every manual, quick, or recovered entry uses the same controller and the same Runtime.
- `QuickDownloadCoordinator` only selects handles from the Runtime catalog and submits them to the same Runtime queue.
- Thumbnail and HD preview keep independent tasks and caches. They share only Runtime admission and the physical PTP command lane.
- `CameraVendorGallerySessionRuntimeTransport` keeps the single active file-transfer Task and reports completion/cancellation back to Runtime.

No new `CameraDownloadManager`, owner refcount, batch generation, or overlapping-batch protocol is introduced.

## Download lifecycle

### Natural completion

1. Runtime accepts a batch only from `galleryReady`.
2. Runtime acquires one scheduling lease for the whole queue.
3. Runtime starts only `queuedDownloads.first`.
4. Transport downloads and saves one file, then sends `transferFinished` or `fileSaveFailed`.
5. Runtime removes the first item and starts the next item.
6. When the queue is empty, Runtime releases the lease and returns to `galleryReady`.
7. The same camera service, PTP session, command lane, catalog, and Runtime remain available for gallery work or a later batch.

### User stop and page exit

1. The download page enters a local `stoppingForExit` presentation state and disables repeated back actions.
2. It calls `await runtime.stopDownloadAndWait()`.
3. Runtime sends the existing `cancelDownloadByUser` command.
4. If cancellation is synchronous because no file is in flight, the method returns immediately.
5. If a file is in flight, Runtime remains in `cancelling` while Transport cancels its Task, invalidates the Photo Library commit gate, and requests cooperative PTP cancellation at a verified chunk boundary.
6. `transferCancelled` completes Runtime cleanup, releases the scheduling lease, and returns the phase to `galleryReady`.
7. Runtime resumes all stop waiters; only then may the download page pop.

This wait is asynchronous because physical I/O and Photo Library commit work must reach a safe terminal point. It does not imply two downloads or two connections.

## Preview behavior

HD preview already pauses before a download starts. Because the download page now pops only after Runtime leaves `cancelling`, the gallery controller's `viewWillAppear` sees an idle Runtime and can call `resumeAfterDownload()` against the existing HD session/cache. Thumbnail mode similarly resumes through the existing Runtime catalog presentation and request gate.

## Error and teardown boundaries

- User stop never calls `terminateCameraCommunication()`.
- Explicit camera disconnect and proven transport loss keep their existing teardown paths.
- A stop waiter completes whenever Runtime leaves `.cancelling`, including cancellation cleanup that ends in a non-downloading terminal phase.
- The page does not add a timeout that could pop while the PTP operation is still active.

## Verification

- A Runtime test proves `stopDownloadAndWait()` remains suspended until `transferCancelled` is received.
- A Runtime test proves it returns immediately when no active cancellation join is required.
- A controller contract proves `popViewController` occurs after awaiting Runtime stop.
- Existing tests continue to prove one lease spans the whole queue, cancellation keeps the healthy camera connected, and batch B is rejected until batch A has drained.
- Focused tests, full RunnerTests comparison, `git diff --check`, and an iPhoneOS Debug build are required before completion.
- Real-camera stop/resume remains a separate physical verification layer.
