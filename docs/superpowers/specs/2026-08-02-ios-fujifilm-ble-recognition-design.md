# iOS Fujifilm BLE protocol-based recognition design

Date: 2026-08-02

Status: proposed for user review

## 1. Problem statement

The current iOS discovery path scans all BLE advertisements and then applies a generic matcher before it checks whether the peripheral is the remembered reconnect target. The matcher accepts a limited list of service UUIDs or a hard-coded Fujifilm model-name prefix list.

The 2026-08-02 X-M5 incident exposed two gaps at the same time:

- `X-M5` is not included in the `X-T`, `X-H`, `X-S`, `X-E`, `X-PRO`, and `GFX` name-prefix list.
- The camera advertised `SERVICE_FF_CONNECTED_DEVICE_INFORMATION_RED` (`123D8F06-62A1-4935-9322-833C531EE225`), which the current generic advertisement service map does not accept.

The App therefore observed the correct remembered peripheral but discarded it before the remembered-target check. It timed out in `ReconnectPairedBle` and never entered Wi-Fi or PTP.

This design replaces model-name admission with protocol evidence and verified camera identity. It must not create a second BLE connection owner or a second connection state machine.

## 2. Goals

- Recognize supported Fujifilm cameras by confirmed BLE protocol evidence instead of enumerating model families.
- Preserve the single connection owner and the existing ordered flow:
  `ReconnectPairedBle -> TransferAuthorization -> ActivateCameraWifi -> WaitCameraWifiReady -> JoinCameraWifi -> ConnectPtp -> ConfirmGalleryMode -> LoadGallery`.
- Reuse a valid post-pairing or preconnected GATT session instead of disconnecting it and immediately scanning again.
- Treat an advertisement as a connection candidate, not as verified camera identity.
- Verify the camera through GATT before any Wi-Fi activation or PTP work.
- Support remembered reconnect when the CoreBluetooth peripheral identifier is stable and provide a safe recovery route when it changes.
- Produce stage-specific diagnostics that distinguish no advertisement, rejected candidate, GATT failure, and identity mismatch.

## 3. Non-goals

- No changes to Wi-Fi joining, PTP/IP, Gallery, thumbnail, preview, or download protocols.
- No claim that every Fujifilm model is compatible merely because BLE discovery succeeds.
- No cross-brand abstraction in this change.
- No parallel legacy and new reconnect implementations.
- No name-only fallback that can connect to an arbitrary nearby camera.

## 4. Design principles

1. Service UUIDs and manufacturer formats are protocol constants and may be explicit. Camera model names are presentation data and must not control connection admission.
2. Discovery, candidate selection, GATT connection, identity verification, and transfer authorization are separate states.
3. `peripheral.identifier` is an endpoint hint, not durable camera identity.
4. The durable identity remains the stored camera identity, preferably `serialNumber + deviceName`, verified after GATT connection.
5. The existing Runtime/Connection Worker remains the workflow owner. New types are pure profiles, parsers, policies, or evidence values only.
6. A stale callback from a cancelled scan, probe, or connection attempt must not advance a newer attempt.

## 5. Components

### 5.1 Fujifilm BLE protocol profile

Introduce a pure `FujifilmBleProtocolProfile` that centralizes confirmed advertisement services by intent:

- Fresh pairing: camera-information/standby, file-transfer, and confirmed pairing-capable services.
- Remembered reconnect: connected-device-information (`123D...`), file-transfer (`AF85...`), and confirmed startup-information services.
- Home pairing validation: only services required to connect and read the validation characteristic.
- Pairing-ready rediscovery: secure-pair/file-transfer services and confirmed manufacturer pairing-key format.

The profile returns protocol roles, not product-family labels. `X-M5`, `X-T5`, and future names follow the same rules.

### 5.2 Advertisement parser

Replace the current mixed name/service matcher with a parser that returns structured evidence:

- advertised service UUID roles;
- Fujifilm manufacturer identifier (`0x04D8`, represented as `D8 04` in the observed bytes);
- manufacturer payload type, including short serial (`type=0x01`) and pairing key (`type=0x02`) when present;
- local name for display and later comparison only;
- peripheral identifier and RSSI.

An unknown model name does not reject otherwise valid Fujifilm protocol evidence.

### 5.3 Intent-aware candidate evaluator

Introduce a pure evaluator that accepts `connectionIntent`, parsed advertisement evidence, and an optional remembered record. It returns one of:

- rejected with a concrete reason;
- protocol candidate;
- preferred remembered candidate.

Remembered reconnect priority is:

1. Exact current `peripheral.identifier` match.
2. Manufacturer short-serial evidence compatible with the stored serial identity.
3. A single unambiguous Fujifilm protocol candidate, which may be connected only for GATT identity verification.

If multiple protocol candidates are present without stable identity evidence, the flow fails as ambiguous instead of guessing by model name or RSSI.

### 5.4 GATT identity verifier

After a candidate connects, the existing handshake owner reads the full device name and serial number and computes the same stored identity used by `CameraVendorStoredPairingPolicy.matchesRememberedIdentity`.

Only a successful match may publish `ReconnectPairedBle` evidence. An identity mismatch disconnects the candidate, records the expected and observed identity in redacted form, and does not activate camera Wi-Fi.

### 5.5 Reusable BLE session handoff

The existing Bluetooth service retains ownership of the live peripheral, discovered characteristics, handshake summary, and connection generation.

When pairing has just completed or a home preconnection remains valid, entering Gallery evaluates a pure reuse policy:

- peripheral is still connected;
- pairing confirmation ACK completed;
- required transfer-activation characteristics are still present;
- verified identity matches the remembered record;
- connection generation is current;
- the session is within a bounded TTL.

If valid, `ReconnectPairedBle` reuses the session. The flow must not call the destructive reset that cancels the selected peripheral. If invalid, the owner tears it down once and runs direct retrieval followed by constrained reconnect scanning.

### 5.6 Generation and operation admission

All pairing probe, scan, connect, and handshake callbacks carry or validate the active BLE connection generation. Starting a user connection:

1. closes probe admission;
2. cancels and joins probe cleanup;
3. either adopts a verified reusable GATT session or starts one reconnect attempt;
4. ignores callbacks from previous generations.

This preserves one executor and prevents probe teardown from racing the formal connection.

## 6. Connection flow

### 6.1 Remembered Gallery connection

1. Runtime receives the remembered camera intent.
2. Validate that the record contains stable camera identity and official Wi-Fi credentials.
3. Cancel and join any home pairing probe.
4. Attempt reusable-session adoption.
5. If not reusable, try `retrievePeripherals(withIdentifiers:)` and connect the saved endpoint within a bounded direct window.
6. If direct connection fails, scan only the profile services allowed for remembered reconnect.
7. Evaluate candidates using endpoint and manufacturer identity evidence.
8. Connect one safe candidate and perform GATT identity verification.
9. Publish `ReconnectPairedBle` only after identity verification.
10. Continue the existing transfer-authorization, Wi-Fi, PTP, and Gallery sequence unchanged.

### 6.2 Fresh pairing

Fresh pairing uses the pairing intent's profile services and manufacturer evidence. Product names are displayed but are not admission rules. Pairing success produces the durable identity record and hands the valid GATT session to the same owner for optional Gallery reuse.

## 7. Error model and diagnostics

Replace the generic `未找到上次配对的相机` surface with stage-specific evidence:

- `no-protocol-advertisement`: no matching protocol service observed.
- `remembered-endpoint-not-observed`: saved endpoint was not observed before fallback.
- `candidate-rejected`: include service roles and rejection reason.
- `ambiguous-candidates`: more than one safe candidate and no stable identity evidence.
- `gatt-connect-failed`: CoreBluetooth connection error.
- `identity-read-failed`: required identity characteristics could not be read.
- `identity-mismatch`: connected camera differs from the remembered camera.
- `probe-teardown-timeout`: formal connection could not safely take ownership from the probe.
- `reusable-session-invalid`: include the failed reuse condition, then continue through normal reconnect.

Logs must state the connection intent, generation, selected route (`reuse`, `direct`, or `scan`), candidate evidence, and the last confirmed connection step. Secrets and full identifiers remain redacted in exported diagnostics.

## 8. Compatibility and migration

- Existing pairing records remain readable; no destructive migration is required.
- Records with a stable serial identity can use manufacturer short-serial fallback when the CoreBluetooth identifier changes.
- Records without stable identity may use the exact saved peripheral identifier. If that identifier is stale, the user must perform fresh pairing rather than accepting an ambiguous name-only match.
- The old model-prefix matcher may remain only as UI classification/display support. It must not be used by remembered reconnect, fresh pairing admission, or identity verification.
- The current single-owner Runtime and ordered connection steps remain intact.

## 9. Test strategy

### 9.1 Pure policy tests

- X-M5 + `123D` is accepted for remembered reconnect.
- X-M5 + `A9D2` is accepted for fresh pairing.
- X-T5 and GFX advertisements remain accepted through protocol evidence.
- An unknown future model name with valid Fujifilm protocol evidence is accepted as a candidate.
- A Fujifilm-looking name without protocol/manufacturer evidence is rejected.
- Exact remembered endpoint is evaluated before generic display classification.
- Manufacturer short serial can select the remembered candidate.
- Multiple ambiguous cameras do not fall back to RSSI or name.

### 9.2 State-machine and ownership tests

- Pairing-to-Gallery handoff does not cancel a valid connected peripheral.
- Invalid reusable sessions tear down once and enter reconnect.
- User connection cancels and joins the pairing probe before scanning or connecting.
- Stale probe/scan/GATT callbacks cannot advance a newer generation.
- Identity mismatch never confirms `ReconnectPairedBle` and never writes Wi-Fi activation commands.
- Repeated connection requests do not create parallel scans or connects.
- Timeout and cancellation close pending continuations exactly once.

### 9.3 Regression tests

- Existing X-T5 pairing and remembered reconnect behavior remains green.
- Full `RunnerTests` passes, not only focused tests.
- `git diff --check` passes.
- Generic iPhoneOS build passes.

## 10. Physical-device acceptance

Code and simulator tests are not final proof. The change is complete only after fresh device evidence shows:

1. X-M5 fresh pairing succeeds.
2. Entering Gallery immediately after pairing reuses or safely adopts the BLE session and reaches GalleryReady.
3. App relaunch followed by remembered Gallery connection succeeds when the camera advertises `123D`.
4. Repeated `Gallery -> Home -> Gallery` and Quick Download loops succeed without a new pairing probe race.
5. Camera power-off/power-on produces a bounded reconnect failure and later recovery.
6. Background/foreground during reconnect does not create duplicate workers.
7. A second nearby Fujifilm camera is not mistaken for the remembered camera.
8. X-T5 regression is run when the camera is available; otherwise the result must explicitly remain unverified for X-T5 physical compatibility.

Acceptance logs must prove the actual route, generation, candidate evidence, GATT identity result, ordered connection steps, and first Catalog success.

## 11. Expected implementation size and risk

This is a medium connection-layer change, not a full product rewrite:

- approximately four to six production files;
- one new pure profile/parser file or equivalent focused extraction;
- focused policy/state-machine tests plus full RunnerTests;
- no intended changes below BLE handoff in Wi-Fi/PTP/Gallery/download code.

Risk is medium because BLE lifecycle and cancellation are timing-sensitive. The design controls that risk through one owner, explicit generations, no name-only identity, no parallel implementation, focused regression tests, and physical X-M5 acceptance.
