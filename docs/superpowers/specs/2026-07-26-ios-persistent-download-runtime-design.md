# iOS Persistent Download Runtime Design

> **Superseded:** This proposal misidentified the batch scheduling barrier as a connection lifecycle and proposed an unnecessary `CameraDownloadManager`. Use `docs/superpowers/specs/2026-07-27-ios-download-stop-and-reuse-design.md` instead.

## Goal

Make downloading a reusable capability of one camera session instead of a per-batch connection/window. A completed or cancelled batch returns the download manager to idle; it does not destroy the PTP lane, disconnect the camera, or prevent navigation back to the gallery.

## Confirmed product constraints

- One physical camera session exists at a time.
- One `CameraCommandLane` exists for that camera session.
- One `CameraDownloadManager` exists for that camera session.
- Only one download batch can be active at a time.
- A second batch is not created while the current batch is active or stopping.
- Finishing or cancelling a batch returns the manager to `idle` and keeps the camera session alive.
- The PTP lane and download manager are destroyed only when the camera session disconnects or is replaced.
- After a batch finishes, the user may stay on the download page, start another batch, or navigate to the gallery.

## Architecture

```text
CameraSessionRuntime
├── CameraCommandLane          one per camera session
├── CameraGalleryCatalogRuntime
├── CameraGalleryThumbnailPipeline
├── NativeGalleryHDPreviewSession
└── CameraDownloadManager      one per camera session
    └── active Batch Task?     zero or one
```

`CameraCommandLane` serializes every physical PTP command. A download batch uses `.download` priority but does not create a new lane or a new service-level download window.

`CameraDownloadManager` owns batch state, queue, progress, cancellation, and terminal cleanup. UI controllers only submit commands and render presentation state.

## Download lifecycle

```text
idle
  └── start(batch) ──> active
                         ├── completed ──> finishing ──> idle
                         ├── cancelled ──> stopping  ──> idle
                         └── transport loss ──────────> interrupted
```

Starting a batch while the manager is not `idle` is rejected. There is no overlapping A/B batch ownership and therefore no batch owner refcount or replacement-generation protocol.

### Normal completion

1. Download queued handles sequentially through the existing PTP lane.
2. Save each completed file and publish progress.
3. Execute batch finish/reset as the final command on the same lane.
4. Clear the active task and return to `idle`.
5. Resume gallery thumbnail/details work when gallery state still exists.

### User cancellation

The page calls `await downloadManager.stopAndJoin()`.

1. Mark the batch `stopping` and cancel the active batch task.
2. Request cooperative PTP cancellation at a verified chunk boundary.
3. Await the active task's actual exit.
4. Execute required batch finish/reset on the same command lane.
5. Return to `idle`.
6. The page may then navigate away. Repeated stop calls await the same stop operation.

Cancellation is asynchronous only because the current socket/file operation must reach a safe boundary. It does not create another owner or another download session.

## Gallery and preview behavior

- Thumbnail and HD preview remain independent pipelines.
- While a batch is active, new thumbnail/details/HD commands are suspended or rejected by runtime policy; existing work is cancelled and joined before the first download command.
- When the batch returns to `idle`, the pipelines may resume using their current catalog/media identities.
- Completing a batch does not disconnect the PTP session and does not require rebuilding the gallery runtime.

## APIs

```swift
@MainActor
final class CameraDownloadManager {
  var presentation: CameraDownloadPresentation { get }

  func start(batch: CameraDownloadBatch) async throws
  func stopAndJoin(reason: String) async
  func shutdownAndJoin(reason: String) async
}
```

`shutdownAndJoin` is reserved for camera-session teardown. It stops the active batch, performs terminal cleanup, and then allows `CameraSessionRuntime` to destroy transport/session resources.

The service-level `beginExclusiveDownloadWindow` / `endExclusiveDownloadWindow` lifecycle is removed. Download PTP operations use the permanent session command lane directly.

## UI contract

- The download page never owns a PTP connection or lease.
- Stop sets the page to a stopping state, awaits `stopAndJoin`, then enables navigation.
- Natural completion returns the manager to idle; the user can navigate to the gallery immediately.
- Navigation or view lifecycle callbacks must not restart gallery connection protocols.

## Verification

- Two sequential batches reuse the same download manager, transport, PTP session, and command lane.
- Completing batch A leaves the runtime ready for gallery operations and batch B.
- Cancelling a batch joins the active task before the page exits.
- Repeated stop is idempotent.
- Download finish/reset is serialized on the command lane before later gallery commands.
- Disconnect uses `shutdownAndJoin`; normal batch completion does not disconnect.
- Thumbnail and HD pipelines resume independently after the manager returns to idle.
