# iOS Pairing Probe Disconnect Ownership Design

## Problem

After a fresh camera pairing, Home may start a silent BLE pairing probe. If the user immediately enters Gallery, the app cancels that probe and starts the remembered-camera mainline. CoreBluetooth delivers disconnect callbacks asynchronously. The cancelled probe's late `didDisconnectPeripheral` currently arrives after the probe state has already been reset to `.idle`, so the callback is misclassified as a mainline disconnect and terminates the new Gallery connection session.

The 2026-08-14 X-T5 device trace proves the ordering: the session reports `BLE_DISCONNECTED error=nil` and terminal failure before the camera is discovered, then the lower BLE service continues to `BLE_CONNECTED`, completes GATT discovery, resolves the dynamic RED plan, and activates camera Wi-Fi.

## Scope

- Preserve fact-driven compatibility resolution and all GATT, activation, Wi-Fi, PTP, and Catalog behavior.
- Preserve the startup pairing probe.
- Fix ownership transfer between a cancelled pairing probe and a user-started remembered connection.
- Prevent an orphan or stale disconnect callback from terminating the active Gallery session.
- Keep real active-mainline disconnects terminal.

## Design

Introduce a focused probe teardown gate with a token containing the peripheral UUID, `ObjectIdentifier`, probe generation, and nonce. Cancelling a probe that owns a peripheral registers the token before calling `cancelPeripheralConnection`. The caller can await teardown with a bounded timeout. A matching `didDisconnectPeripheral` consumes the token before any mainline failure routing.

The disconnect callback routing order is:

1. Consume a full-reset disconnect.
2. Consume a cancelled pairing-probe disconnect.
3. Route a callback only when it matches the active mainline peripheral identity and generation.
4. Log and ignore all orphan callbacks.

The remembered-camera UI starts its connecting state, cancels the probe, awaits teardown, and only then starts the Runtime connection worker. If teardown times out, the gate keeps a tombstone so a late probe callback is still consumed; the mainline does not start until the tombstone is resolved. This fails closed instead of allowing ambiguous BLE ownership.

## Error Handling

- Probe teardown timeout produces a bounded retryable BLE preparation failure and does not start the mainline.
- A matching probe disconnect never publishes `REMEMBERED_GALLERY_TERMINAL_FAILURE`.
- A matching active-mainline disconnect retains the existing terminal behavior.
- An orphan disconnect produces a diagnostic observation containing peripheral identity and active generation, but no UI failure.

## Verification

- Unit tests prove a cancelled probe's late disconnect is consumed.
- Unit tests prove mismatched peripheral objects are not consumed.
- Unit tests prove timeout retains a tombstone until the late callback arrives.
- Policy tests prove only the active mainline owner may terminate Gallery.
- Full `RunnerTests`, generic iPhoneOS build, signed device build, and `git diff --check` must pass.
- Real-device acceptance requires fresh pairing followed by immediate Gallery entry without a false BLE error and with a verified dynamic Plan through `GalleryReady`.
