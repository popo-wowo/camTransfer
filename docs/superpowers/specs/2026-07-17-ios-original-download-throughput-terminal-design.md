# iOS Original Download Throughput Terminal Design

## Scope

This design is limited to wireless original-file download throughput. HEIF
catalog behavior, connection/bootstrap behavior, BLE, Wi-Fi handover, pairing,
Home routing, thumbnails, and catalog ownership are frozen and out of scope.

The authoritative protocol contract remains
`docs/superpowers/specs/2026-07-13-ios-camera-filter-download-final-solution.md`.
This document narrows the next evidence and implementation boundary for its
download-performance phase.

## Evidence already established

- FUJIFILM XApp uses one long-lived PTP command session and one serialized
  transfer lane.
- For original transfer it prepares `D226=2` once per serialized batch, then
  performs `ObjectInfo -> D235 -> contiguous 0x101B GetPartialObject` for each
  file.
- The current iOS high-level preparation order and exclusive download lease are
  already aligned with that contract.
- Historical CamTransfer runs reached approximately 11–12 MiB/s with the
  generic file path, while recent runs through the current original executor
  are receive-dominated at approximately 3–4 MiB/s.
- Changing request size and changing the receive loop with `MSG_WAITALL` or
  `SO_RCVTIMEO` are not accepted fixes. No further chunk-size or socket-option
  change is authorized without a current iOS PTP/TCP capture.

The remaining question is therefore whether the throughput loss belongs to the
executor-level cadence or to shared session/socket state. It is not yet proven
which one is responsible.

## Terminal architecture

`CameraVendorOriginalReadImageExecutor` remains the sole production owner of
original-file transfer. It owns the complete file transaction under the
existing exclusive PTP lease and is the only code allowed to issue the
contiguous original-read requests.

The generic file-command loop is not a second production owner. It may be
selected only by an explicit Debug experiment argument and only for one
original `download-file` run. Release builds and Debug builds without an
explicit argument always use the dedicated executor.

The experiment is evidence infrastructure, not a fallback policy. Once the
causal low-level difference is identified, the proven behavior is implemented
under the dedicated executor and the Debug branch is deleted.

## Controlled experiment

Each branch must use a newly opened and closed physical PTP session. A generated
run UUID is not a session identity. The branch log must contain the physical
PTP session identifier and must reject a borrowed active Gallery session.

The dedicated and generic branches must use the same:

- camera and Wi-Fi association;
- object handle and file;
- `D226=2` batch preparation;
- fresh `ObjectInfo` and `D235` preparation;
- request size and contiguous offsets;
- PTP transaction serialization and socket options;
- thumbnail/metadata suspension and exclusive download lease.

Each file must emit one begin record, one record per partial-object chunk, and
one completion summary containing:

- branch, physical session ID, run ID, and transaction ID;
- handle, offset, requested size, and received bytes;
- request-to-first-byte, socket receive, file-write, chunk elapsed, and
  inter-chunk gap timings;
- total elapsed time and calculated MiB/s;
- fallback count and response validation result.

No per-recv logging, extra retries, socket options, or request-size changes may
be introduced by the experiment.

## Decision tree

1. If generic is materially faster than dedicated under fresh-session,
   same-file conditions, identify the exact executor-level difference from the
   chunk transcript, move only that behavior beneath
   `CameraVendorOriginalReadImageExecutor`, remove the Debug branch, and repeat
   the full verification ladder.
2. If both branches are similarly slow, do not change the executor. Capture the
   current iOS PTP/TCP traffic and compare it packet-by-packet with
   `/private/tmp/xapp-heif-from-connect-20260716-2217.pcap`, focusing on camera
   response delay, TCP ACK/window behavior, retransmission, reassembly gaps,
   and session state.
3. If the experiment cannot prove a physical fresh session, same-file
   conditions, or complete timing, it is an invalid experiment and produces no
   production decision.

## Required implementation boundary

The first implementation change is limited to Debug branch selection and
diagnostic evidence. It must not modify:

- connection/bootstrap functions;
- BLE or Wi-Fi handover;
- GalleryReady or catalog transactions;
- thumbnail, preview, or metadata scheduling semantics;
- request size, socket options, retry policy, or PTP packet framing.

Only after a valid experiment identifies a causal executor difference may the
dedicated executor receive a narrowly scoped production change. The final
production tree must contain one executor owner and no experiment selector.

## Verification and delivery standard

Before a device run:

1. targeted RunnerTests must report the real executed count and pass;
2. complete RunnerTests must report the real executed count and pass;
3. `git diff --check` must pass;
4. a Debug physical-device build must succeed;
5. the installed package must log a build/source fingerprint matching the
   source under test.

Device acceptance requires a fresh install, fresh PTP session evidence, and a
newly pulled per-file timing log. Historical logs, compile-only output, or a
borrowed-session experiment cannot establish a speed improvement. A throughput
claim is made only after a same-camera, same-file comparison against the
matching XApp conditions.

## Non-goals

This design does not enable HEIF, change connection sequencing, alter the
catalog owner, add a second PTP session to production, or change background
download/recovery behavior.
