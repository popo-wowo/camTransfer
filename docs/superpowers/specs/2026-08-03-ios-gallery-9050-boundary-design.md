# iOS Gallery 9050 Startup Boundary Design

## Problem

`GetSearchModeDescAll (0x9050)` currently runs inside the blocking legacy Gallery bootstrap and again during empty-Catalog recovery. Its returned descriptor payload is only logged; it does not participate in the current Catalog query, retry decision, or filter construction. Several camera logs show `0x9050` returning `0x2019 Device Busy`: X-T5 and X-S20 sometimes recover, while X-M5 and X-T30 III exhaust the fixed retry window and fail `loadGallery`.

The current filter implementation still interacts with the camera, but it does so through the SearchMode transaction and directory commands:

```text
9052 backup SearchMode
-> 9051 set query conditions
-> 9053 read date groups
-> D620 read count
-> D621 read handles
-> 9051 restore SearchMode
```

Removing the unused descriptor read from startup must not remove or weaken this transaction.

## Decision

Remove `0x9050` from every current blocking Gallery/Catalog path: both the legacy Gallery bootstrap and empty-Catalog recovery. Bootstrap continues directly from the optional current-image primes to `D22B`, the following `D212` drain, and the real Catalog acquisition. Empty-Catalog recovery keeps its bounded delay, optional `D22B` refresh, and Catalog retry, but does not fetch the unused descriptor.

```text
D212 #2 -> D244 -> 9054 -> 9055 -> D22B -> D212 #3
-> 9053 -> D212 #4 -> D620 -> D621
```

The `0x9050` opcode and request implementation remain available. A future capability-driven filter implementation may call it outside the GalleryReady critical path, parse its descriptor payload, and use the result to decide which SearchMode conditions a camera supports. That future probe must be optional: `Device Busy` or an unsupported descriptor query must not invalidate an otherwise usable Catalog.

## Evidence Boundary

- Official XApp capture proves that XApp sent `0x9050` in one successful X-T5 startup sequence; it does not prove the command caused Gallery readiness.
- Current iOS does not consume the returned descriptor data.
- Existing X-T5 logs also contain successful initial Catalog acquisition without entering the `0x9050` recovery bootstrap.
- Physical-camera proof for X-M5 after this change still requires a tester-provided diagnostic log. Build, unit tests, and device installation cannot prove the camera protocol result by themselves.

## Acceptance

- The blocking `prepareCameraVendorLegacyGalleryLoad()` body does not request `SearchModeDescAll`.
- Empty-Catalog recovery does not request `SearchModeDescAll`.
- SearchMode filtering continues to use `9052/9051/9053/D620/D621`.
- The full iOS `RunnerTests` suite passes.
- A subsequent X-M5 diagnostic log reaches `D22B` and the real Catalog commands without a fatal `0x9050` error.
