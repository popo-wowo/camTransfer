# iOS Runtime Reconnect Convergence Design

## Goal

Prevent priority-download PTP reconnect from sending INIT on an unverified network, prevent Home lifecycle work from racing an active connection worker, and distinguish unsupported BLE probe validation from an offline camera.

## Boundaries

- `CameraVendorRealtimeGalleryService` owns the asynchronous Wi-Fi/IP/PTP preflight because it already owns the session connection configuration.
- `CameraVendorPtpSession` consumes a verified reconnect client IPv4 and never starts Wi-Fi UI or duplicates the connection state machine.
- `CameraSessionRuntimeConnectionWorker` remains active until its cancelled task actually exits, so Home cannot observe a false idle window.
- `NativeConnectViewController` skips passive reset and startup probe while the Runtime connection worker is active.
- A missing BLE validation service or characteristic produces `validationUnavailable`, not `offline` or `pairingInvalid`.

## Reconnect Admission

Before a disconnected priority download enters the PTP command lane, the Gallery service collects:

- current SSID;
- current `en0` IPv4;
- current PTP command-port reachability.

PTP INIT is admitted only when the SSID matches the remembered camera configuration, the IPv4 is in the verified camera subnet, and the command port is reachable. Failure is reported as `WIFI_RECONNECT_PREFLIGHT_FAILED` and no PTP INIT packet is sent.

## Home Convergence

Cancelling a connection worker requests cancellation but does not clear the worker token synchronously. The worker becomes idle only when the task reaches its `defer` cleanup. Home passive reset and pairing probe both remain blocked during that interval.

## Filter Failure Boundary

The existing Catalog behavior remains: a failed filter retains the last good Catalog, publishes `GALLERY_FILTER_FAILED`, and invalidates a physically corrupted PTP session. Mixed-format query protocol repair remains separate from BLE and Home lifecycle changes.

## Verification

- RED/GREEN unit tests for reconnect admission, Home worker gating, and probe classification.
- Existing cancellation, probe teardown, Catalog retention, and recovery tests.
- Full `RunnerTests`, iPhoneOS build, `git diff --check`, signed install, and fresh real-camera logs.
