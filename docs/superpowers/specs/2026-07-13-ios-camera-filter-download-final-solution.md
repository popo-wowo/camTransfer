# iOS Camera Gallery Catalog Runtime and Original Download: Terminal Solution

## Status and authority

This document is the sole implementation contract for the iOS camera Gallery
filter repair and the later original-download throughput investigation.  It
supersedes every earlier Gallery filter design and invalidates the current
dual-generation implementation plan in
`docs/superpowers/plans/2026-07-14-ios-camera-filter-download-final-implementation.md`.
A replacement implementation plan must be written from this document after
review.

The required end state is not a local filter patch.  It is a terminal ownership
cut for the single-camera, single-PTP-lane wireless Gallery:

- `CameraSessionRuntime` is the only active camera-session authority.
- A runtime-owned `CameraGalleryCatalogRuntime` is the only Gallery catalog
  lifecycle authority.
- `CameraGalleryRepository` is the catalog runtime's data store, not a second
  lifecycle owner.
- the vendor PTP layer executes commands and reports results; it does not
  publish Gallery state or decide session lifetime.
- UIKit submits typed intents and renders immutable presentation snapshots; it
  does not own catalog tasks, generations, membership, loading, or errors.

The earlier rule _"wait for a complete ObjectInfo index and keep the previous
Grid"_ is invalid and must not be reintroduced.

## Why the current implementation is not terminal

The present code contains three independent lifecycle clocks:

1. `NativeGalleryViewController.completeGalleryCatalogGeneration` owns a UI
   task, clears and installs the Grid, and decides loading/error presentation.
2. `CameraSessionRuntime.cameraCatalogRequestGeneration` rejects a stale
   transport return value, but does not own the catalog state or its child work.
3. `CameraVendorRealtimeGalleryService.communicationTerminationGeneration`
   scopes background ObjectInfo work to the connection, not to the currently
   installed catalog.

It also retains parallel mutable representations in `galleryState.items`,
`allGalleryItems`, `CameraGalleryRepository`, and runtime handle maps.  The
background metadata producer publishes through untyped `NotificationCenter`
messages and may call `session.disconnect()` itself.

This is an ownership defect, not three unrelated UI bugs.  The existing plan
made it explicit by requiring both a controller generation and a runtime
generation.  The terminal implementation must move authority and delete the
superseded paths in the same cut; it must not add another guard around them.

## Original XApp behavior used as the reference

The checked-in XApp reverse-engineering archive is the behavioral reference,
not source to copy verbatim.

### Filter transition

The observed XApp flow is:

1. remove queued thumbnail/image requests;
2. stop the old image coroutines and wait for them to finish;
3. stop and join temporary filter-count work;
4. build one complete `SearchModeAllInfo` for the selected conditions;
5. write SearchMode;
6. reload date groups and ordered handles;
7. replace the repository directory;
8. start thumbnail/ObjectInfo work for that new directory.

Evidence:

- `ImportImageViewModel` removes request queues, calls `stopCoroutine()`, and
  joins `stopAllCoroutineJob` before `applyFilterConditions()`.
- `FilteringConditionsViewModel` waits for image work, cancels and joins the
  count job, then applies conditions.
- `ImportImageModel.applyFilterConditions()` is mutex-protected.
- `getFiltersLoadThumbImg()` writes SearchMode and calls repository
  `createImageHandlesByDate()` before image details.
- `createDateFilterData()` builds
  `SearchModeStr(dataType=4, propertyCode=0xD601, value=...)`.
- `matchFilterForObjectFormat()` projects using `ImageInformation.realFileFormat`,
  never a thumbnail.
- XApp USB `XSDK.getSpecifiedObjectInfo()` assigns
  `ImageInformation.realFileFormat` directly from native
  `SpecifiedObjectInfo.lObjectFormat`; the converted display category is a
  separate field and is not catalog truth.
- The July 14 X-T5 WLAN device log repeatedly resolves `DSCF....HEIC` objects
  as HEIF through `GetObjectInfo`.  In the live iOS parser, that label can only
  be produced by the `0x3812` object-format branch.  This proves `0x3812` as the
  active X-T5 wireless HEIF `realFileFormat`; XApp USB's separate `0x3808`
  conversion path is not used for this wireless catalog capability.

The July 15 official iPhone XApp packet capture supersedes the earlier HEIF
candidate interpretation.  The frozen capture is
`/private/tmp/xapp-heif-filter-20260715-pcapd-stable.pcap`; its TCP stream has no
reassembly gaps.  XApp sends these complete `0x9051` data payloads and the X-T5
returns the following exact `D620`/`D621` directories:

| Format | `0x9051` data payload | unique handles |
| --- | --- | ---: |
| JPG | `01 00 00 00 08 00 00 00 04 d6 01 00` | 1136 |
| HEIF | `01 00 00 00 08 00 00 00 04 d6 02 00` | 616 |
| RAW | `01 00 00 00 08 00 00 00 04 d6 10 00` | 656 |
| MOV | `01 00 00 00 08 00 00 00 04 d6 04 00` | 15 |
| ALL | `00 00 00 00` | 2423 |

The returned sets close exactly: `1136 + 616 + 656 + 15 = 2423`.  For every
format, the reassembled D621 packet's declared count, decoded count, and unique
count are equal.  In particular, `D604=2` is a camera-confirmed exact HEIF
directory on this X-T5, not a broad all-images candidate.  ObjectInfo remains
useful enrichment evidence, but it is not required to determine HEIF catalog
membership and must not refine, subtract from, or delay the D621 directory.

XApp does not need to expose the same numeric generation token as Swift.  Its
stop-and-join transition supplies the same ownership invariant.  iOS keeps one
explicit generation because Swift tasks can complete out of order, but that
generation belongs to one catalog runtime only.

### July 15 startup wire sequence and the initial-directory boundary

The frozen iPhone XApp capture also establishes a required startup boundary
that is distinct from a later filter transaction.  After the Gallery-mode
handshake and the `9054 -> 9055 -> 9050 -> D22B` current-image sequence, XApp
performs one unfiltered directory acquisition before it accepts any user
SearchMode change:

```text
D212 (ready event) -> 9053 -> D212 (empty drain) -> D620 -> D621
```

That first `D620/D621` result is the camera's baseline directory activation;
it is not a second catalog owner and it is not a local ObjectInfo index.  The
catalog runtime must own this acquisition as generation 1 and install its
validated snapshot before a later `.all`, JPG, HEIF, RAW, or date/format intent
can write `9051`.

The earlier iOS live log skipped this baseline acquisition.  It went from
`D22B` directly to `9052 backup -> 9051 -> 9053`, and returned `ALL=1807` while
the same camera/XApp baseline is `ALL=2423`.  The current iOS ready `D212` is
associated with the 1807 baseline before the first `9051`, whereas the XApp
startup context is associated with the 2423 baseline.  D212 itself does not
encode the directory count; the count comes from the subsequent D620/D621
reads.  These are observed protocol-state differences.  The initial-directory
acquisition is therefore a mandatory parity correction, but its causal effect
on the HEIF result must be proven by one variable-at-a-time device evidence;
neither this discrepancy nor the wrong HEIF count is evidence that ObjectInfo
must refine membership.

The production implementation must therefore expose two explicit operations
behind the single catalog runtime:

1. `loadInitialCatalog`: after the bootstrap has completed the captured
   post-`D22B` seven-byte `D212` read, execute the remaining unfiltered
   `9053/D212/D620/D621` acquisition and validate/install generation 1 without
   writing SearchMode.  The combined session sequence is therefore
   `D212/#3 -> 9053 -> D212/#4 -> D620 -> D621`; `loadInitialCatalog` must not
   add a second copy of `D212/#3`;
2. `loadFilteredCatalog`: execute the SearchMode transaction below for every
   subsequent date/format membership change.

The initial-directory run still produced `D620/D621=1807`.  The A/B/C/D
post-write matrix also logged HEIF=2423, but its Debug entry point borrowed the
already-connected Gallery session rather than opening a fresh PTP session for
each branch (`CameraVendorCatalogExperimentPtpSessionAdapter(borrowing:)`,
`connectDuration=0.000`).  Its generated `experimentSession` UUID is therefore
only a trace label, not physical-session evidence.  Those runs are useful as a
diagnostic observation of one already-mutated session, but they do not satisfy
the independent-session requirement and cannot falsify startup-state causes.
The July 16 full-lifecycle capture still moves the first deterministic wire
divergence to the earlier D212 event order.

The vendor layer may execute these operations, but it may not install the
snapshot, create a generation, or publish Gallery state.

The same capture shows that a post-write `9052` readback is not part of the
XApp format-filter sequence.  The approved transaction contract requires a
backup `9052` and a restore after validation; production must not add a second
post-write `9052` round trip unless a new wire capture proves that the target
camera requires it.  Diagnostic logging may record the written payload and
returned directory, but an unproven readback must not become protocol truth.

The connection regression evidence supersedes the earlier assumption that
`9054`, `9055`, `9050`, and `D22B` must complete inside the blocking
`ConfirmGalleryMode` step.  The same X-T5 completed the PTP/session-readiness
publication in 0.5-0.7 s when that step was limited to ClientState, ImageHost,
and one CardSlotStatus read.  Adding the extra D212/9050/D22B bootstrap raised
the post-handshake path to approximately 4.3 s; adding blocking `9054` and
`9055` primes raised it again to approximately 25.8 s (`9054` 14.3 s,
`9055` 7.2 s, `D22B` 3.7 s) without changing the incorrect HEIF result.  The
0.5-0.7 s value is therefore a readiness milestone, not a claim that the
complete Gallery catalog is already ready.

The July 16 full-lifecycle capture below corrects one detail in the earlier
fast-path rule: one early `D212` read immediately after `OpenSession` is part of
the factory session initialization and must not be omitted or moved into the
later catalog bootstrap.  This read is a bounded event drain, not a catalog
load and not an invitation to restore the slow bootstrap commands to the
blocking connection path.

Therefore the terminal connection rule has two explicit milestones on the same
session and the same serialized command lane:

```text
OpenSession
-> Read D212 #1 (38-byte factory session event drain)
-> Set ClientState
-> Read/write ImageHost
-> Read CardSlotStatus #1
-> publish PTP/session readiness (no GalleryReady yet)

same session/lane, with no UI command interleaving:
-> Read D212 #2 (14-byte context)
-> Read CardSlotStatus #2
-> 9054 -> 9055 -> 9050 -> D22B
-> Read D212 #3 (7-byte ready event)
-> 9053 -> Read D212 #4 (empty drain) -> D620 -> D621
-> publish GalleryReady after generation 1 is installed
```

The vendor connection implementation must perform exactly one first factory
D212 read at its captured position between `OpenSession` and ClientState, then
publish the transport/session milestone only after ClientState, ImageHost, and
the first CardSlotStatus read complete.  The current `connect()` method owns
`OpenSession` and the ClientState/ImageHost/CardSlotStatus sequence while the
current `ConfirmGalleryMode` step is evidence-only; implementation may either
split that method or expose one narrow vendor operation, but it must not place
the early D212 in both locations or create a second session owner.  Neither
location may perform the later ready D212 read, prime `9054` or `9055`, request
`9050`, or read `D22B` before the readiness milestone.  The later bootstrap and
generation-1 catalog acquisition must remain on the same session/lane and must
complete before `GalleryReady`; they may not be replaced by a second session or
allowed to race with UI catalog/download commands.  HEIF research cannot
broaden this rule without a new single-variable experiment proving both the
expected HEIF directory and no readiness regression.

### July 16 full-lifecycle XApp capture: first deterministic HEIF divergence

The full iPhone XApp network capture is frozen at
`/private/tmp/xapp-heif-from-connect-20260716-2217.pcap` (approximately 358 MB,
capture interval `2026-07-16 22:17:14.644` through `22:22:29.032`).  Its PTP
connection is `192.168.0.120:64629 -> 192.168.0.1:55740`; TCP reassembly has no
missing application payload.  The camera sent approximately 330.9 MB of PTP
payload and the phone sent approximately 21.6 KB.

The companion Bluetooth capture is
`/private/tmp/xapp-full-lifecycle-bluetooth-20260716.pcap`.  It is only a
24-byte pcap header and contains no HCI packets.  It is therefore not evidence
for BLE deletion, pairing, activation, or write order and must not be cited as
such.  BLE conclusions remain limited to the already collected application
logs and the withdrawn experiment below.

The factory PTP initialization is:

```text
OpenSession
-> D212 #1 (38 bytes)
-> write DF01=0x14
-> read/write DF28
-> read D244
-> D212 #2 (14 bytes)
-> read D244
-> 9054
-> 9055
-> 9050
-> D22B
-> D212 #3 (7 bytes: 01 00 2f d2 01 00 00)
-> 9053
-> D212 #4 (empty 00 00)
-> D620=2423
-> D621=2423
```

The current iOS implementation enters the same region in a different order:

```text
OpenSession
-> write DF01=0x14 (missing D212 #1)
-> read/write DF28
-> read D244
-> D212 (14 bytes)
-> D212 (7 bytes, read before 9054/9055/9050/D22B)
-> 9054/9055/9050/D22B
-> 9053
-> D212=00 00
-> D620=1807
-> D621=1807
```

The command-level comparison is therefore narrower than “iOS uses a different
Gallery protocol”:

| Boundary | XApp capture | Current iOS | Evidence status |
| --- | --- | --- | --- |
| OpenSession → first context | D212 #1, 38 bytes | no D212 read | deterministic difference; first experiment |
| ClientState/ImageHost/card slot | DF01 → DF28 read/write → D244 | same values and relative order | aligned at command semantics |
| Ready context | D212 #2 (14 bytes) → D244 #2 | D212 #2 → D244 #2 | relative order aligned |
| Current-image bootstrap | 9054 → 9055 → 9050 → D22B | same commands, but 9054/9055/D22B take ~25.8 s on current iOS run | command set aligned, state/timing not aligned |
| Ready event before first directory | D212 #3 (7 bytes) → 9053 | D212 #3 occurs before 9054/9055/9050/D22B | deterministic ordering difference; first experiment |
| Initial directory | D212 #4 → D620/D621 = 2423 | D212 #4 → D620/D621 = 1807 | confirmed result mismatch |

The table deliberately separates command identity from camera-state outcome:
matching opcodes does not prove matching state, and the 1807/2423 difference
does not prove that D212 is the sole causal variable.

The borrowed-session A/B/C/D observations all sent the correct HEIF payload and
still received 2423, but they cannot be promoted to independent-session
causality evidence.  One conclusion is nevertheless temporal and does not need
that matrix: restoration occurs after `D620/D621` have already been read, so it
cannot change the count that was just observed; production must still restore
atomically because that is the catalog transaction contract.  The deterministic
wire differences before that read are earlier and include both a missing D212
read and a moved seven-byte D212 read.  The complete capture does not prove
which of those initialization differences is causal; it proves only that the
current iOS session enters the first directory transaction in a different camera
state and returns 1807 instead of XApp's 2423.  A later correct `D604=2` write
then returns the broad 2423-object directory instead of the factory 616-object
HEIF directory.

This establishes the next repair boundary without changing the ownership
architecture:

- reproduce the factory D212 positions exactly: the 38-byte read immediately
  after `OpenSession`, the 14-byte read after the first card-slot read, and the
  seven-byte read after `D22B` and before `9053`;
- add exactly the missing early read so the startup sequence has the four
  captured reads, and do not add any polling-to-empty loop;
- preserve the fast connection publication boundary;
- do not change BLE, Wi-Fi handoff, pairing, Home routing, `9051` payloads,
  generation ownership, repository membership, thumbnail, or ObjectInfo rules;
- do not add new bootstrap commands or restore any candidate/refinement path.

This is the first approved HEIF implementation experiment, but it is not yet a
claim that D212 alone is the root cause.  A fresh iOS run must first reproduce
the complete factory order, which means inserting the missing 38-byte read and
moving the existing seven-byte read to its captured post-`D22B` position while
retaining the 14-byte read after the first card-slot read.  If HEIF remains
broad, the next isolated branch must test the other deterministic XApp
difference: the still-image baseline (`D604=31`) before the formal HEIF
transaction.  Only if that isolated baseline fails may a later branch reproduce
the complete count sweep.  No branch may combine these changes or alter the
connection owner.

### Complete HEIF transaction comparison

The full capture shows two different XApp operations that must not be collapsed
into one abstract "write HEIF" call.

First, opening or refreshing the filter UI performs a count sweep.  XApp reads
the current SearchMode, clears it, queries the unfiltered count, then writes
each supported condition and reads date groups plus `D620` without fetching
`D621`.  The format portion includes:

```text
D604=1  -> D620=1136  (JPG)
D604=2  -> D620=616   (HEIF)
D604=8  -> D620=0     (MP4 on this card)
D604=4  -> D620=15    (MOV)
D604=16 -> D620=656   (RAW)
```

XApp then activates `D604=31`, reads the full 2423-handle directory, drains
empty D212 events, and only later applies the user's HEIF choice:

```text
precondition: active D604=31, D620/D621=2423
9051 D604=2
-> 9053 (9 date groups)
-> D212=00 00
-> D620=616
-> D621=616 unique ordered handles
-> 9052 confirms D604=2 remains active
```

Current iOS executes:

```text
9052 backup (default five-condition SearchMode)
-> 9051 D604=2
-> 9053
-> D212=00 00
-> D620=2423
-> D621=2423
-> restore the backed-up SearchMode
```

The Debug matrix did not run with a fresh PTP session per branch: the active
Gallery session was borrowed, each branch's `connectDuration` was `0.000`, and
the validator also reported `missingRawReference` in addition to the invalid
616-count.  Earlier owned-session attempts failed with `Connection refused`
before `sessionOpened`, so there is no successful fresh-session A/B/C/D result.
The logs therefore establish only that, on one already-connected session, all
four branches emitted the exact HEIF payload and observed `D620/D621=2423`;
they do not establish independent-session rejection of the post-`9053` D212 or
restore variants.  Restoration after `D620/D621` remains temporally unable to
explain that already-read count.  A compliant matrix must open and close one
owned PTP session per branch, record the physical PTP session identifier (not a
generated UUID), and provide a same-session RAW reference set before any branch
can be used for causality claims.

The payload, `9053/D212/D620/D621` read order, count validation, uniqueness
validation, and ordered publication boundary are already aligned.  The
remaining differences are:

| Difference | XApp | Current iOS | Status |
| --- | --- | --- | --- |
| Session startup | four D212 reads at captured positions | three reads; missing early read and seven-byte read placed before current-image bootstrap | first experiment |
| Initial catalog | 2423 | 1807 | confirmed mismatch |
| Filter count sweep | executes complete count sweep | absent | untested HEIF variable |
| Pre-apply format state | `D604=31`, full 2423 directory | default five-condition SearchMode | untested HEIF variable |
| Successful apply state | selected `D604=2` remains active | unconditional restore | restore is after the measured directory and cannot cause its count; preserve-vs-restore remains untested on an independent fresh session |
| Membership | direct D621 publication | direct D621 publication | aligned; ObjectInfo must stay enrichment-only |

The count sweep cannot be added speculatively to production because it writes
many SearchModes and can increase latency.  If the factory startup-order
experiment still returns 2423 for HEIF, test one isolated `D604=31` baseline
branch first.  Only if that fails should a separate branch reproduce the full
count sweep.  A successful branch must prove the exact 616-handle directory;
"HEIF objects became visible" is not acceptance.

### July 16 BLE activation experiment — withdrawn and rolled back

The July 15 device experiment falsified the hypothesis that adding the initial
directory acquisition would by itself restore HEIF.  The
new iOS run executed that acquisition but still returned `ALL=1807`; the first
`D604=2` transaction still returned `2423`.  Therefore the initial catalog is
required for XApp parity but is not the causal HEIF repair.

An attempted BLE lifecycle cut then changed the Gallery mainline by separating
`9893`, removing `CAED/82A9` from launch, and adding an APState read barrier.
The first real X-T5 run exposed an unverified capability assumption: this
camera does not expose optional `2A125640`, and the new gate blocked activation
before any BLE launch write.  The run also introduced an unverified mainline
change without proving a HEIF result.  That entire BLE cut is withdrawn and
has been rolled back to the prior connection baseline.

No BLE write ordering, capability gate, APState barrier, or connection timing
change may be reintroduced from this section.  Any future HEIF experiment must
change one variable only, preserve the known connection path, and be accepted
only after fresh same-camera logs prove both connection health and the
`D604=2` result.  HEIF remains unresolved until that evidence exists.

### July 17 fresh iOS evidence: D212 parity and D604=31 are falsified as standalone fixes

The fresh physical-device pull is frozen at
`/private/tmp/camtransfer-terminal-pull-20260717-131649/`.  It is the first
run after the factory D212 ordering change was exercised on the normal Gallery
session, and it records the complete startup order:

```text
D212 #1 (38 bytes)
-> DF01=0x14 -> DF28 read/write -> D244 #1
-> D212 #2 (14 bytes) -> D244 #2
-> 9054 -> 9055 -> 9050 -> D22B
-> D212 #3 (7 bytes)
-> 9053 -> D212 #4 (empty) -> D620 -> D621
```

The result is still `D620/D621=1807`.  The same run then executed an isolated
`D604=31` baseline inside the HEIF transaction; that baseline also returned
`1807`, and the subsequent exact `D604=2` write returned the broad `2423`
directory.  SearchMode restoration completed with `0x2001`.  This falsifies
both of these standalone hypotheses for this camera/session state:

- inserting or moving the captured D212 reads does not by itself restore the
  `2423` initial directory or the `616` HEIF directory;
- writing `D604=31` and reading its directory before `D604=2` does not by
  itself restore the `616` HEIF directory.

The evidence does not justify changing the BLE/Wi-Fi path, adding another
SearchMode restore variant, or reviving ObjectInfo membership logic.  The
current production source must keep the proven D212 order and the normal
catalog transaction, while the `D604=31` baseline experiment is removed from
the mainline because it produced no causal improvement and added latency.

The next HEIF variable is therefore the complete XApp filter count sweep (the
sequence of supported `D604` values before the user's formal HEIF apply), and
it must run as a diagnostic-only experiment on a fresh owned PTP session.  It
must not be combined with connection, BLE, restore, ObjectInfo, or download
changes.  Until that experiment proves `D620=616`, `D621=616`, order, and no
RAW overlap, HEIF remains unsupported in production.

The same pull also falsifies the claim that the D212 change fixed connection
latency.  PTP readiness is `GALLERY_TIMING_CONNECT=0.593s`, but the blocking
Gallery bootstrap still measures approximately `9054=14.213s`,
`9055=7.222s`, and `D22B=3.633s`.  These are request-to-first-byte delays,
not file-write or Swift catalog publication time.  A current iOS packet
capture is required to distinguish a camera-side delayed response from a
transport-reader/TCP-window issue; no socket, timeout, chunk, or reconnect
change is authorized before that capture.

### Historical HEIF implementations, false positives, and current repair gate

HEIF support has been implemented several times in the sense that HEIF objects
became visible in the Gallery.  None of those earlier implementations proved an
exact camera-side HEIF directory, and they must not be treated as a previously
working `D604=2` transaction.

The historical sequence is:

1. On June 21, the application recovered HEIF/RAW objects by probing gaps in a
   JPEG-dominated D621 directory and calling ObjectInfo for candidate handles.
   This made HEIF/RAW appear after approximately ten seconds, but date groups,
   totals, and initial membership remained incomplete.  It was a discovery
   fallback, not a format-filter implementation.
2. On June 24, the Android X-T5 path used `D604=31` as a baseline and then read
   `D604=HEIF` and `D604=RAW` expansion directories.  Both expansion requests
   returned the same 1268-handle set; ObjectInfo later classified that set as
   HEIF, RAW, JPG, and video.  Promoting the larger directory fixed initial
   visibility, but did not prove either expansion result as an exact HEIF or RAW
   catalog.
3. The July 5 iOS baseline inherited the expansion/promotion approach.  It kept
   per-mask handle sets, promoted a larger HEIF/RAW result into the initial
   directory, and used `formatHints`.  The same expanded handles could receive
   both HEIF and RAW hints.  The UI could therefore look correct while the
   catalog membership remained ambiguous.
4. The July 12 filter audit recorded that the interactive HEIF and RAW masks
   could return the whole catalog.  That audit correctly rejected publishing a
   broad D621 result or allowing incremental ObjectInfo/thumbnail completion to
   shrink the visible result.
5. The July 15 official XApp capture was the first evidence that established an
   exact X-T5 WLAN HEIF result: `D604=2`, `D620=616`, and `D621=616` from an
   ALL=2423 card.  Current iOS sends the same payload but receives 2423, proving
   payload parity without camera-state parity.

These incidents establish the following permanent lessons:

- "HEIF objects are visible" is not evidence that the HEIF filter is correct.
- A larger D621 directory is a candidate/discovery result unless the camera
  proves it as the exact selected format.
- ObjectInfo, filename extensions, thumbnails, and `formatHints` may enrich a
  known member, but may never create, remove, relabel, or reorder catalog
  membership.
- A successful `0x2001` response to `9051` proves transport acceptance only; it
  does not prove that the camera activated the requested SearchMode semantics.
- Matching the `9051` payload is insufficient when the factory application and
  iOS enter the transaction with different camera/SearchMode state.
- Connection, BLE activation, startup timing, and Gallery readiness must not be
  changed to investigate a format-only discrepancy without a single-variable
  experiment and fresh device evidence.

The July 16 full-lifecycle capture narrows the next HEIF experiment, but the
borrowed-session A/B/C/D run must not be treated as a complete causal matrix.
Exactly one bounded repair experiment is now authorized: reproduce the four
captured D212 positions (one inserted read and one moved read, without
polling-to-empty) on a fresh owned session.  Until that experiment passes
device acceptance:

- HEIF must not be reported as verified or accepted support;
- no local subtraction, candidate refinement, hidden-handle promotion, or old
  ObjectInfo-owned membership path may be restored;
- the unresolved 2423-handle iOS result is retained only as diagnostic evidence,
  not as a publishable HEIF contract;
- the download investigation may continue only as a separately measured phase
  and may not be used to hide or compensate for the catalog-state mismatch.

The minimum acceptance evidence remains a fresh same-camera run showing the
captured startup D212 order, exact `D604=2` payload, `D620=616`, `D621=616`,
preserved D621 order, successful SearchMode restoration, no RAW contamination,
and no regression from the proven approximately 0.6-second PTP/session
readiness milestone.  Complete Gallery readiness must also be measured
separately; the milestone is not a catalog-latency guarantee.

## Architecture boundaries

The word _owner_ means the sole authority allowed to make a state transition,
not necessarily the only type involved in the operation.

| Capability | Session Runtime | Catalog Runtime | Repository | PTP transport | UIKit |
| --- | --- | --- | --- | --- | --- |
| Create/end camera session | yes | no | no | execute/report only | no |
| Admit catalog work | yes | no | no | no | no |
| Create catalog generation | no | yes | no | no | no |
| Install/reject catalog snapshot | no | yes | store when instructed | no | no |
| Start thumbnail/ObjectInfo work | no | yes | no | execute one request | no |
| Decide transport lost/disconnect | yes | report evidence only | no | report evidence only | no |
| Render immutable presentation | publish aggregate | publish catalog snapshot | no | no | yes |

`CameraSessionRuntime` and `CameraGalleryCatalogRuntime` therefore do not share
one authority.  The former owns the session boundary; the latter owns the
catalog state machine inside that already-valid session.

### `CameraSessionRuntime`: session authority

`CameraSessionRuntime` owns:

- the active camera identity and session lifetime;
- whether catalog commands are currently admissible;
- the one serialized PTP lease shared by catalog and download work;
- the decision to enter `transportLost`, terminate communication, or recover;
- creation and destruction of the session's `CameraGalleryCatalogRuntime`;
- download, lifecycle, background, and recovery authority already assigned to
  it by the wireless terminal architecture.

It accepts UI commands and exposes immutable presentation.  UIKit must not
receive a transport object or a method that returns a publishable catalog for
the page to install itself.

### `CameraGalleryCatalogRuntime`: sole catalog lifecycle authority

This is a runtime-owned component, not an independent application/session
owner.  It owns:

- the current complete `CameraGalleryFilterIntent`;
- the only `CameraGalleryCatalogGeneration` counter/token;
- the catalog state machine;
- the active catalog transaction task;
- visible-thumbnail work for the active generation;
- background ObjectInfo/details work for the active generation;
- the current `CameraGalleryRepository` instance/state;
- publication of `CameraGalleryPresentation` snapshots back through the
  session runtime.

No other production type may create a catalog generation, atomically install
catalog membership, or decide that a stale catalog event is current.

### `CameraGalleryRepository`: data authority inside one generation

The repository owns stored catalog entries and enrichment fields for the
catalog runtime.  It does not start tasks, increment generations, call the
camera, or decide session failure.

Rules:

- only an installed, validated catalog snapshot may add, remove, or order
  handles;
- thumbnail/details results may enrich an existing handle only when their
  generation and snapshot identity are current;
- results for unknown handles are discarded;
- details may not downgrade confirmed catalog fields;
- sorting and download-status projection may reorder/present current members,
  but may not create membership.

### Vendor PTP transport: execution only

The vendor layer owns packet encoding, socket reads/writes, and the serialized
PTP scheduler.  It reports typed success/failure to the runtime.  It may not:

- post Gallery membership/details through global `NotificationCenter`;
- start an unscoped background metadata loop;
- publish UI loading/error state;
- call session termination because a background enrichment task failed;
- retain a catalog generation that competes with the catalog runtime.

Only the session runtime decides whether a reported transport error proves the
active session unusable.

### UIKit: intent and rendering only

`NativeGalleryViewController` may own transient presentation interaction such
as scroll position, selection gesture state, and decoded image cache.  It may
not own:

- a catalog request `Task`;
- a catalog generation;
- authoritative catalog membership;
- catalog loading/error state;
- `allGalleryItems` as a second directory source;
- direct vendor catalog/ObjectInfo commands;
- metadata notifications that lack generation/snapshot identity.

The page submits `CameraGalleryFilterIntent` and renders the latest immutable
`CameraGalleryPresentation` supplied by the runtime.  A local cached reference
to that immutable presentation for cell rendering is not ownership and must be
replaced only by the presentation observer.

### Architecture audit after the July 16 wire capture

The current ownership split is consistent with the supported single-camera,
single-PTP-lane topology, and the collected evidence does not identify it as the
cause of the HEIF mismatch:

- `CameraSessionRuntime` is the session owner and the admission point for the
  one serialized PTP lane;
- `CameraGalleryCatalogRuntime` is an actor and the sole catalog generation,
  transaction, publication, thumbnail, and ObjectInfo child-work owner;
- `CameraGalleryRepository` stores the installed snapshot and rejects stale
  generation/snapshot/unknown-handle enrichment;
- the vendor layer executes commands and returns typed evidence;
- UIKit submits intents and renders immutable presentation.

The wire failure occurs inside the vendor PTP bootstrap before the catalog
runtime can receive a correct camera directory.  Adding another runtime,
controller generation, ObjectInfo index, or format-refinement owner would make
the architecture less safe and would not repair the missing/misordered D212
state transition.

There are still bounded structural improvements, but they are not part of the
HEIF repair patch:

1. `CameraVendorBluetoothService.swift` currently contains PTP handshake,
   gallery catalog queries, download orchestration, socket framing, and
   diagnostics.  Split these behind narrow internal protocols only after the
   factory startup-order experiment is proven; the split must preserve one
   transport lease and one session owner.
2. Keep `CameraVendorOriginalReadImageExecutor` as the exclusive continuous
   original-transfer policy, and make the low-level receive loop an explicit
   dependency of that executor.  Do not let a generic command helper regain
   ownership of a file transfer.
3. Keep the repository's membership boundary immutable: ObjectInfo and
   thumbnails may enrich known handles but cannot add, remove, or reorder
   handles.  This is the permanent guard against the historical HEIF/RAW
   candidate path returning as a second owner.
4. Keep connection readiness, catalog generation, and download admission as
   separate states under the same session owner.  Moving work between these
   states is a sequencing change, not a reason to create another lifecycle
   authority.

This ownership shape is the retained target for future filters, metadata,
caching, and presentation features.  That is a design judgment backed by the
current source boundaries, not a claim that every current lifecycle path is
already device-proven.  New capabilities extend the typed intent and capability
profile; they do not add a new generation counter, repository, or UI task owner.

### Download and connection audit from the July 16 capture

The XApp PTP transfer primitives are aligned with the current iOS command
model, but the preparation order is not fully aligned:

```text
D226=2 once per serialized batch
ObjectInfo -> D235 -> 0x101B GetPartialObject
each data payload ~= 0xBFFFE0 bytes (12 MiB - 32)
next request uses the contiguous offset
```

The exact preparation order in the capture is:

```text
D226=2 once
for each file:
  ObjectInfo
  -> D235
  -> 0x101B offset=0, then contiguous offsets
```

The production iOS source order in `objectFile` has now been corrected to:

```text
D226=2 once per serialized priority-download batch
for each file:
  ObjectInfo
  -> D235
  -> 0x101B offset=0, then contiguous offsets
```

That preparation-order experiment is complete in source: D235 is no longer
read before fresh ObjectInfo or before the batch D226 mode, and its failure is
not silently ignored.  The July 17 device runs below still remain slow after
this order correction, so preparation order is no longer the active throughput
hypothesis.

The observed same-camera XApp RAW transfers in
`/private/tmp/xapp-heif-from-connect-20260716-2217.pcap` were:

| Handle | Bytes | Elapsed | Measured speed |
| --- | ---: | ---: | ---: |
| `0x583` | 86,456,320 | 8.397 s | 9.82 MiB/s |
| `0x978` | 86,824,960 | 7.040 s | 11.76 MiB/s |
| `0x97A` | 87,389,696 | 7.310 s | 11.40 MiB/s |

The latest available CamTransfer per-file timing evidence is in
`/private/tmp/camtransfer-live-pull-20260716-115655/Documents/camtransfer_debug.log`
and the preceding same-camera run in
`/private/tmp/camtransfer-live-20260715-035331/camtransfer_debug.log`:

| Handle | Bytes | Elapsed | Measured speed |
| --- | ---: | ---: | ---: |
| `0x93A` | 86,758,400 | 19.580 s | 4.23 MiB/s |
| `0x92A` | 87,396,352 | 20.450 s | 4.08 MiB/s |

CamTransfer's July 15-16 per-file timing split was approximately 292–297 ms
accumulated across all request-to-first-byte intervals, 19–20 s in
`socketReceiveMs`, and 123–211 ms in `fileWriteMs`; command gaps were
approximately 59–164 ms.  The preparation order was then aligned.  A July 17
RAW run using the dedicated executor and 12,582,880-byte requests still measured
87,608,832 bytes in 29.055 s (`2.88 MiB/s`), including 28.237 s in
`socketReceiveMs` and only 59 ms in file writes.  This confirms that disk writes
are not the bottleneck and that order parity alone did not recover throughput.

One isolated receive-loop experiment replaced `poll()` plus normal `recv()`
with `MSG_WAITALL` and a temporary `SO_RCVTIMEO` only under the original
executor.  The same July 17 run became slower, not faster.  That experiment is
falsified and must be removed; no additional socket option may be layered on
top of it.

The earlier inference that a 12 MiB request-size problem was ruled out is also
superseded by same-application evidence.  On July 10, CamTransfer itself used
the standard file-streaming path with fixed 4,194,304-byte requests and
completed comparable RAW files at `10.97`, `12.58`, and `12.50 MiB/s`.  Typical
4 MiB transactions after the first chunk completed in approximately 0.2-0.6 s.
This proves that iOS, the app process, the same camera family, and the same file
writer can sustain factory-class throughput.  It does not by itself prove that
4 MiB is universally optimal because the historical run also preceded the
dedicated-executor cut.

The fresh July 17 pull at
`/private/tmp/camtransfer-live-pull-20260717-latest-xB6DIs/` completed the
authorized dedicated-executor 4 MiB experiment and falsified request size as a
sufficient repair.  The relevant executor summaries are:

| Handle | Format | Bytes | request-to-first-byte | socket receive | file write | executor elapsed | speed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `0x948` | RAW | 87,302,656 | 300 ms | 22,754 ms | 59 ms | 23,794 ms | 3.50 MiB/s |
| `0x920` | RAW | 87,286,784 | 325 ms | 19,008 ms | 68 ms | 20,056 ms | 4.15 MiB/s |
| `0x922` | RAW | 87,504,896 | 382 ms | 19,760 ms | 72 ms | 20,848 ms | 4.00 MiB/s |
| `0x4C5` | JPG | 25,033,041 | 232 ms | 5,000 ms | 17 ms | 5,423 ms | 4.40 MiB/s |

Every request used contiguous 4,194,304-byte offsets with zero fallback.  The
transfer remains receive-dominated, and the same request size that reached
10.97-12.58 MiB/s on the historical generic file path remains limited to
approximately 3.5-4.5 MiB/s inside the current dedicated executor/session.
Therefore neither 4 MiB nor 12 MiB may be promoted as the terminal speed fix.

The XApp capture also shows approximately 0.1–0.4 ms from each `0x101B`
request to the first reassembled data payload (about 0.2–0.4 ms per chunk, or
roughly 1–3 ms accumulated over seven chunks), while CamTransfer accumulates
approximately 292–297 ms over the same file.  This is a wire-observed
difference, not yet proof of a single cause: it can reflect camera transfer
state, TCP receive/ack behavior, or the native executor's request path.  A new
CamTransfer pcap is required after preparation-order alignment.

This is a staged boundary finding, not yet a micro-optimization prescription.
The current iOS design already routes original files through the dedicated
`CameraVendorOriginalReadImageExecutor` under one exclusive download lease, so
the next step is not to invent another high-level download owner or return file
ownership to `sendCommandForFileData`.  XApp's native
`CCameraCommandReadImage` / `StartGetPartialObjectThread` remains the structural
reference, but the attempted Swift continuous socket reader did not reproduce
its performance.  Production must remove that failed reader and retain the
known-safe generic socket receive primitive as the low-level dependency of the
dedicated executor.

The next authorized experiment is a Debug-only controlled comparison between
the current dedicated executor and the already-existing generic file-command
execution path.  It is diagnostic, not a production ownership change:

- production and an experiment-disabled Debug build continue to use
  `CameraVendorOriginalReadImageExecutor`;
- one explicit Debug launch argument may select `dedicated` or `generic` for
  original-file transfer only;
- every branch run must start from a freshly opened physical PTP session, use
  the same camera/file/Wi-Fi conditions, and log the physical session ID,
  branch, run ID, transaction ID, offset, request size, request-to-first-byte,
  socket receive, file write, chunk elapsed, inter-chunk gap, and per-file
  summary;
- the comparison must not change request size, D226/ObjectInfo/D235 order,
  socket options, connection bootstrap, catalog ownership, preview, thumbnail,
  or scheduling admission;
- the generic branch is temporary evidence infrastructure.  It may not become
  a second production owner.  Once the causal difference is identified, the
  proven low-level behavior must be incorporated beneath the dedicated
  executor and the experiment branch removed.

The July 17 controlled device run completed this executor comparison on the
same X-T5 and Wi-Fi with near-identical RAW sizes:

| Branch | File | Bytes | request-to-first-byte | socket receive | file write | executor elapsed | speed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dedicated | `DSCF8050.RAF` | 86,609,408 | 293 ms | 24,030 ms | 77 ms | 25,096 ms | 3.29 MiB/s |
| generic | `DSCF8105.RAF` | 86,758,400 | 389 ms | 25,937 ms | 62 ms | 26,946 ms | 3.07 MiB/s |

The generic route was proven active by
`capabilitySource=experiment-matched-4mb` and the
`PTP_STANDARD_PARTIAL_OBJECT_FILE_*` completion transcript. It did not recover
factory-class throughput and was slightly slower than the dedicated route.
This falsifies executor ownership/serialized-lease cadence as the sufficient
cause of the current RAW slowdown. The remaining boundary is shared camera
transfer state or PTP/TCP behavior, and a current iOS packet capture is now the
required next evidence.

### July 18 D235 profile evidence and bounded production change

The frozen XApp capture contains a direct `D235` read before each original
partial-object transfer. The returned little-endian value is
`e0 ff bf 00`, or `0x00BFFFE0` (`12,582,880` bytes), and XApp uses that exact
value for `0x101B GetPartialObject`. For handle `0x978`, XApp therefore uses
six `12,582,880`-byte requests followed by one `11,327,680`-byte request for
the `86,824,960`-byte file. The current iOS logs show the dedicated executor
using fixed `4,194,304`-byte requests for the same-size class of file, which
requires about 21 requests. This is a protocol-level difference, not a claim
that a larger request alone fixes receive cadence.

The authorized production correction is consequently bounded to the existing
dedicated executor:

1. read `D235` immediately after fresh `ObjectInfo` in `objectFile`;
2. decode only the evidence-backed little-endian values `0x00BFFFE0`,
   `0x00400000`, and `0x00100000`;
3. let a valid D235 value take precedence over any cached capability record;
4. use the existing safe `4 MiB` profile when D235 is missing or invalid;
5. log the raw D235 value, selected read size, and source per file;
6. keep the existing bounded receiver, serialized lease, D226/ObjectInfo/D235
   order, session lifecycle, connection bootstrap, catalog, thumbnails, and
   generic experiment path unchanged.

This change does not promote `12 MiB` as a universal speed fix. A fresh same-
camera device run must still prove request count, contiguous offsets, zero
fallback, and per-file receive timing before any throughput conclusion.

The final fingerprinted device run is now available in
`/tmp/camtransfer-device-pull-20260718-final-test/`.  It proves the bounded
D235 correction itself: 21 files completed after the final build marker, every
file used `initialReadSize=12582880`, `capabilitySource=d235`, and
`fallbackCount=0`, and the requests used contiguous offsets.  Connection to
the existing PTP session remained normal at `GALLERY_TIMING_CONNECT=0.673s`.

That run also falsifies the remaining assumption that transfer volume alone
warms a cold session.  Four foreground RAW downloads stayed at `4.63-4.72
MiB/s` for more than 70 seconds, with `17.0-17.4s` in socket receive per file.
After the app entered background, the existing runtime BLE keep-alive issued
its read-only characteristic sampling batch.  The in-flight RAW improved to
`6.47 MiB/s`, then subsequent RAW files rose through `12.37`, `13.28`, and
`14.15-14.36 MiB/s`; later JPG, RAW, and HEIF batches remained at approximately
`14.4-16.4 MiB/s` without reopening PTP.  The earlier July 18 run shows the
same sequence: foreground transfers remained slow, background BLE sampling
started, then RAW/HEIF rose to approximately `14.4-17.1 MiB/s`.

The same-handle comparison removes file layout and format as sufficient
causes: RAW `0x978` measured `4.72 MiB/s` before background activity and
`14.63 MiB/s` after it in the preceding run; RAW `0x97A` measured `4.65` and
`15.12 MiB/s` respectively.  D235, executor, request size, fallback count, and
file bytes were unchanged.  Disk writes remained tens of milliseconds, so the
change is still in camera/socket receive cadence.

This is strong correlation, not yet authorization to alter BLE or connection
bootstrap.  The next single-variable experiment must start a fresh physical
PTP session and invoke exactly one read-only copy of the existing BLE sampling
batch at priority-download admission while leaving app lifecycle, D226,
ObjectInfo, D235, request size, socket receiver, and connection flow unchanged.
If cold RAW immediately reaches the sustained range, the foreground transfer
state trigger is proven; if it does not, BLE sampling is falsified and the
remaining variable is iOS foreground/background network scheduling.  No new
BLE writes, reconnect, Wi-Fi handoff, or session-owner changes are authorized
by the current evidence.

The first Debug comparison build also exposed two diagnostic defects that are
not production transfer changes: launch-only branch selection was lost when
the app relaunched during the connection flow, and the broad
`[OBS] PTP_DOWNLOAD` suppression prefix hid experiment markers. The Debug
selector now persists only an explicitly selected branch until explicit `off`,
Release remains permanently off, and the diagnostic policy allows only
`PTP_DOWNLOAD_EXECUTOR_EXPERIMENT_*` through the broad suppression rule.

If both branches remain slow in fresh sessions, the next evidence is a current
iOS PTP/TCP capture compared with the frozen XApp capture; no additional socket
or receiver tuning is authorized. The D235 profile injection above is the only
request-profile change authorized by the direct wire evidence.

Connection timing and stability from the same evidence are similarly bounded:

- XApp keeps one TCP/PTP session open for 314.388 s, with 1038 serialized
  requests, 29 partial-object transfers, monotonically increasing transaction
  IDs, and zero TCP reassembly gaps;
- XApp reaches the initial directory flow in about 2.0 s after `OpenSession`
  in this complete capture (DF01 takes about 0.99 s and the initial 9053 takes
  about 1.0 s);
- in the same XApp capture, `9054` completes in about 1 ms, `9055` in about
  4 ms, and `D22B` in less than 1 ms; current iOS uses the same opcodes but
  observes approximately 14.3 s, 7.2 s, and 3.7 s respectively, so the
  regression is session-state/timing parity, not missing command names;
- the iOS PTP/session-readiness portion is approximately 0.5–0.7 s, but the
  current `loadGallery` step still synchronously calls
  `prepareCameraVendorLegacyGalleryLoadIfNeeded`, which blocks on 9054/9055/
  9050/D22B before publishing Gallery-ready evidence; on the current wrong
  startup state those commands consume approximately 25.8 s;
- the prior iOS experiment that blocked on `9054` (~14.3 s), `9055` (~7.2 s),
  and `D22B` (~3.7 s) stretched bootstrap to about 25.8 s without fixing HEIF.

The connection stability invariant is therefore:

```text
one physical Wi-Fi association
-> one TCP/PTP session
-> one serialized command lane and transaction-ID sequence
-> one session owner decides recovery/termination
-> catalog/download work admitted only through that lane
```

The first connection optimization hypothesis is sequencing and admission
control: reproduce the four factory D212 positions, publish PTP/session
readiness after the first bounded handshake, then run the remaining
current-image/bootstrap and generation-1 catalog steps on the same lane without
UI interleaving or a second session.  This sequence is required for XApp wire
parity, but its effect on the 25.8-second iOS bootstrap remains unproven until a
fresh same-camera timing run.  Reconnect retries remain a recovery path after a
proven transport failure; they are not part of normal Gallery startup and must
not mask a sequencing error.

### Initial Gallery activation

The initial directory is not a special owner path.  After the connection flow
has proved PTP session readiness, the session-owned activation flow completes
the captured post-handshake bootstrap on the one admitted lane.  The session
runtime then creates exactly one catalog runtime and asks it to execute
`loadInitialCatalog`, the unfiltered
`D212 -> 9053 -> D212 -> D620 -> D621` acquisition.  This first validated
directory is generation 1.  `GalleryReady` presentation is published only
after that catalog runtime has installed the resulting validated first
generation.

The catalog runtime then starts its own thumbnail and ObjectInfo children.  The
connection service supplies session/transport evidence only; it does not load a
parallel mutable item list, start a metadata loop, or hand catalog ownership to
the page.  Re-entering the same active Gallery observes the existing catalog
runtime; it does not create a second one.

## Typed model and state machine

### Filter intent

One intent contains the entire selected state:

```text
CameraGalleryFilterIntent
  date
  format mask/selection
  sort
  download-status projection
```

Date/format changes require a new camera catalog generation.  Sort and local
download-status changes may project the installed snapshot without starting a
camera transaction because they cannot create membership.

### Catalog state

The catalog runtime exposes one state machine:

```text
unavailable
  -> loading(generation, intent)
  -> ready(generation, snapshot, entries)
  -> unsupported(generation, reason)
  -> failed(generation, error)
  -> transportLost(error)
```

Rules:

- only `loading` may install `ready`, `unsupported`, or `failed` for the same
  current generation;
- an older generation may finish cleanup but cannot mutate presentation,
  repository, or session state;
- `failed` and `unsupported` are persistent presentation states, never a normal
  empty result;
- `transportLost` rejects new catalog intents until the session runtime creates
  a new valid session; this work must not add page-level reconnect or Home
  routing;
- a genuine, validated empty camera directory is represented as
  `ready(... entries=[])`, distinct from failure.

### Per-generation work domain

Every generation owns one structured work domain:

```text
CatalogGeneration
  catalog transaction
  visible thumbnail children
  ObjectInfo/details children
```

Starting a new date/format generation performs this sequence:

1. allocate the next generation and make it current;
2. stop accepting new work for the previous generation;
3. cancel queued thumbnail/details children;
4. wait for any admitted non-transaction PTP command to finish or reach its
   documented safe cancellation boundary;
5. run the new catalog transaction;
6. publish only if the generation is still current;
7. start thumbnail/details children from the installed snapshot.

Rapid taps use latest-intent semantics.  Superseded intents may finish mandatory
transport cleanup but never publish.  The implementation must not accumulate
an unbounded FIFO of obsolete catalog transactions.  There may be at most one
active catalog transaction and one replaceable pending intent.  A newer pending
intent replaces the older pending intent before transport admission.

## PTP catalog transaction contract

The SearchMode transaction is an indivisible critical section:

```text
backup SearchMode
  -> write complete requested SearchMode
  -> read and validate date groups + ordered handles
  -> restore SearchMode
  -> return typed snapshot
```

This transaction applies only after generation 1 has been acquired.  Its
backup `9052` is not a substitute for the initial unfiltered directory read.
The implementation must not insert a post-write `9052` readback between
`9051` and `9053` without target-camera wire evidence.

Cancellation may mark the result obsolete, but may not interrupt the critical
section between backup and restoration.  A publishable snapshot is returned
only after successful restoration.

If the primary operation fails, restoration is still attempted.  The typed
failure must preserve both the primary and restoration outcome so the session
runtime can decide whether transport health is still proven.  A background
details task cannot make this decision.

Validation requires:

- declared count matches handle count;
- date-group counts match handle count;
- handles are unique;
- ordering is preserved exactly as returned by the camera;
- the transaction used the complete current filter intent.

## Supported and unsupported filter behavior

### JPG and RAW

For the currently verified X-T5 behavior:

- JPG uses `D604=1`;
- RAW uses `D604=16`.

The validated returned directory is published immediately.  There is no
ObjectInfo or thumbnail completion gate.

### HEIF — terminal target, currently deferred

For the verified X-T5 behavior, HEIF uses `D604=2`.  The camera-confirmed date
groups, declared count, and ordered D621 handles are validated and published
directly after successful SearchMode restoration, exactly like JPG and RAW.
The July 15 official XApp golden result is 616 unique HEIF handles from a
2423-object card.

This is the terminal protocol target, not the current iOS delivery status.
Current iOS receives 2423 handles for the same condition, so HEIF remains
deferred and must not be claimed as supported until the acceptance evidence in
the historical/deferral section is satisfied.

There is no HEIF candidate-refinement phase.  The catalog runtime must not wait
for ObjectInfo, fetch all candidate ObjectInfo before publication, rebuild date
groups from metadata, or subtract non-HEIF handles from the D621 directory.
Generation-scoped ObjectInfo work begins only after publication and may enrich
known HEIF members.  An ObjectInfo failure cannot invalidate or change the
already camera-confirmed catalog membership.

Filename extension, `formatHints`, thumbnail content, and the old shared
metadata completion flag remain forbidden membership truth sources.

### Date

Date remains `unsupported` until captured/proven native bytes establish the
XApp `SearchModeStr(dataType=4, D601, value)` wire encoding.  No guessed golden
vector, local filtering, or zero-result fallback is allowed.

### Video and later filter types

Unverified formats remain `unsupported`.  A later rating/folder/subject/date or
format feature extends the typed intent, camera capability profile, and query
builder.  It does not add a task owner, generation, repository, or UI command
path.

## Required production-code changes

### New or terminalized catalog runtime layer

Expected scope:

- add/complete a dedicated Swift `actor CameraGalleryCatalogRuntime` under the
  iOS Gallery runtime/Core area;
- add typed filter intent, generation, state, presentation, transaction result,
  and failure models;
- make the catalog runtime own `CameraGalleryRepository` and structured child
  work;
- expose a narrow session-runtime command/presentation boundary.

The actor accepts Sendable value intents and returns/publishes immutable value
snapshots.  It owns any non-Sendable repository/transport adapter behind actor
isolation and never stores UIKit objects.  Presentation delivery crosses back
through the `@MainActor` session runtime.  This prevents catalog state and
blocking PTP work from becoming page-owned or Main-Actor mutable state.

### `CameraSessionRuntime`

- create/bind/destroy the catalog runtime with the camera session;
- accept complete filter intents and forward them through the sole catalog
  owner;
- include catalog presentation in its immutable UI presentation surface;
- own catalog admission and transport-lost decisions;
- remove the transport-return-only catalog generation API exposed to UIKit.

### `NativeGalleryViewController`

- replace direct request/task/generation handling with intent submission and
  presentation rendering;
- remove authoritative `allGalleryItems` and catalog loading/error ownership;
- retain only UI-local selection, scrolling, gesture, decoded-image-cache, and
  rendering concerns;
- remove untyped background metadata observers;
- start no direct catalog/ObjectInfo transport work.

### `CameraVendorRealtimeGalleryService` and PTP runtime

- retain packet encoding and the exclusive PTP scheduler;
- expose typed catalog transaction, thumbnail, preview, and ObjectInfo
  operations to the runtime-owned catalog source;
- remove autonomous background metadata scheduling/publication;
- remove background-metadata authority to disconnect the session;
- preserve download serialization and existing proven command behavior.

### Repository and adapters

- make catalog installation generation/snapshot-aware;
- make thumbnail/details merges generation/snapshot-aware;
- remove any adapter path that can reconstruct membership from legacy
  `allGalleryItems`, ObjectInfo, thumbnails, filenames, or format hints;
- keep saved-download history as presentation enrichment, not catalog truth.

### Project and tests

- add new runtime files to the Xcode target if needed;
- update spies/fakes to observe typed intents, generations, child cancellation,
  and transport-health reports;
- replace source-string tests where a behavioral or compile-time boundary can
  prove the invariant;
- retain narrow forbidden-dependency scans only as an additional architecture
  fitness check.

## Explicit removals

The terminal cut is incomplete while any production path retains:

- `NativeGalleryViewController.completeGalleryCatalogGeneration`;
- a controller-owned catalog request `Task`;
- `CameraSessionRuntime.cameraCatalogRequestGeneration` as a second generation;
- `allGalleryItems` as authoritative membership;
- `isCurrentCatalogObjectInfoIndexComplete` or equivalent membership gate;
- a local `applyCurrentFilters` membership path;
- autonomous service-owned background metadata loops not bound to the current
  catalog generation;
- untyped global metadata notifications;
- background metadata code that calls `session.disconnect()`;
- HEIF membership changed by ObjectInfo, filename, hints, or thumbnail content;
- `refineHEIFCandidate` or an equivalent pre-publication HEIF metadata scan.

No dual compatibility owner is permitted after cutover.

## Implementation phases

### Phase 0: freeze and prove the current failure

- preserve the dirty worktree and record the exact relevant diff;
- retain the current failing persistent-error test;
- add failing architecture/behavior tests for dual generation, stale metadata
  continuation, stale failure disconnect authority, and dead-session admission;
- do not modify download performance code.

### Phase 1: establish typed boundaries

- add the catalog runtime models/state machine and fake transport tests;
- add the session-runtime command and immutable presentation boundary;
- make old UIKit/service mutation paths fail tests before moving behavior.

### Phase 2: move ownership

- move initial catalog, filter transaction, thumbnail, and ObjectInfo child work
  behind the catalog runtime;
- bind all work to one generation and snapshot identity;
- move repository installation/merge into the catalog runtime;
- route transport-health decisions to the session runtime.

### Phase 3: delete superseded owners

- remove controller generation/task/catalog state;
- remove runtime's second generation;
- remove autonomous service metadata task/publication/disconnect authority;
- remove legacy membership state and adapters;
- run forbidden-path scans plus behavioral tests.

### Phase 4: device acceptance and stabilization

- build, install, launch, exercise the exact filter sequence, pull new logs,
  and compare them with the state-machine contract;
- fix only defects that violate this contract; do not add parallel guards or a
  compatibility owner.

### Phase 5: separate download-performance investigation

Begin only after the catalog architecture passes device acceptance.  This
phase gathers new per-file timing and XApp comparison evidence before any
executor change.

## Required tests

### Architecture and state-machine tests

- UIKit submits a complete intent and cannot install a catalog itself.
- Production has one catalog generation authority.
- Starting generation N+1 cancels/invalidates every queued child of N.
- An admitted PTP command reaches a safe boundary before the next transaction.
- A stale catalog success cannot publish.
- A stale thumbnail/details success cannot mutate repository or presentation.
- A stale details failure cannot disconnect or move the current session.
- `failed`, `unsupported`, a valid empty catalog, and `transportLost` render as
  distinct states.
- `transportLost` rejects new filter intents without page-level reconnect.
- rapid JPG/RAW/HEIF/date taps use latest-intent semantics without an obsolete
  FIFO backlog.

### Transaction and repository tests

The HEIF-specific requirements below remain the mandatory resumption gate, but
they are not an assertion that the current iOS build has passed HEIF device
acceptance.

- a complete format intent emits the selected `D604` condition;
- startup reads exactly one early D212 after `OpenSession` and before the first
  `DF01` write;
- startup has exactly the four captured D212 reads and places the seven-byte
  ready event after `D22B` and before the initial `9053`;
- backup/write/read/validate/restore occurs in order;
- cancellation cannot skip restore;
- restore failure is surfaced to the session authority;
- declared counts, date groups, uniqueness, and order are validated;
- JPG/RAW/HEIF publish before thumbnail/ObjectInfo completion;
- unknown or stale ObjectInfo handles cannot alter membership;
- the official HEIF golden payload is exactly
  `01 00 00 00 08 00 00 00 04 d6 02 00`;
- validated `D604=2` D620/D621 results publish directly without ObjectInfo;
- generation 1 performs the captured post-handshake bootstrap, then the
  unfiltered `9053/D212/D620/D621` acquisition (with the seven-byte D212
  already read at the post-D22B bootstrap boundary) before any `9051` filter
  write;
- no production filter transaction inserts an unproven post-write `9052`
  readback;
- production contains no HEIF candidate-refinement path;
- SearchMode restoration failure cannot publish a HEIF catalog;
- no date golden test exists until proven XApp bytes are available.

The Debug experiment matrix has additional mandatory guards:

- every branch must obtain an owned fresh PTP session; a borrowed active
  Gallery session is a test failure;
- the log must contain the physical PTP session identifier and a non-zero
  connection duration, not only a generated experiment UUID;
- every branch must carry a same-session RAW handle reference and reject any
  HEIF/RAW overlap; `rawHandles=nil` is an invalid experiment input;
- the branch must close its owned session before the next branch starts.

### Regression tests

- selection, sectioning, newest/oldest sorting, download-status projection,
  visible-window thumbnails, preview, download admission, and saved-history
  enrichment remain correct;
- catalog work cannot enter the PTP lane while download owns the exclusive
  lease;
- connection readiness is published only after D212 #1/ClientState/ImageHost/
  D244 #1, and no catalog/download command can interleave before the
  post-readiness factory bootstrap and generation-1 catalog finish;
- the same PTP session keeps one monotonically increasing transaction-ID lane
  across bootstrap, catalog, thumbnails, and download; a normal Gallery flow
  does not create a second session.  The isolated Debug matrix is the explicit
  exception and must use one owned session per branch;
- the download preparation transcript orders `D226=2` once before the first
  file, then `ObjectInfo -> D235 -> 0x101B` for every file;
- a D235 read failure is surfaced or reaches an explicitly tested fallback; it
  cannot be swallowed with `try?` and followed by a normal original transfer;
- leaving/re-entering Gallery follows existing session-runtime behavior and
  does not create a second catalog runtime.

## Device acceptance sequence

Until the factory startup-order experiment passes device acceptance, the active catalog
acceptance sequence covers the connection baseline, initial catalog evidence,
JPG, RAW, rapid JPG/RAW changes, date unsupported behavior, transport loss, and
fresh logs.  Step 6 below is the HEIF delivery gate and is not required to
begin the separately scoped download-performance measurement.  It must not be
marked passed from the current 2423-handle result.

On the paired physical iPhone and the same camera:

1. enter Gallery from a fresh session and verify
   `OpenSession -> early D212 -> DF01`, with no blocking 9054/9055/9050/D22B
   bootstrap added to the connection confirmation step;
2. verify the initial generation performs the post-handshake
   `D212#2 -> D244#2 -> 9054 -> 9055 -> 9050 -> D22B -> D212#3`, then
   `9053 -> D212#4 -> D620 -> D621` before any `9051`, and publishes ALL=2423;
3. select JPG and verify exactly one catalog transaction, successful restore,
   stable handle count while thumbnails/details continue, and no old-generation
   metadata requests;
4. select RAW and verify the same properties;
5. rapidly alternate JPG/RAW and verify only the latest intent publishes;
6. select HEIF and verify one `D604=2` transaction, successful SearchMode
   restoration, direct publication of the camera-returned 616 unique handles,
   preserved D621 order, and no ObjectInfo gate or membership mutation;
7. select date and verify a persistent `unsupported` state with no camera
   transaction for the unproven payload and no continued old-generation
   ObjectInfo traffic;
8. return to JPG/RAW and verify the existing healthy session remains usable;
9. induce or observe a real transport loss and verify one `transportLost`
   transition, no repeated `socket 未建立` command loop, and no page-level
   reconnect;
10. pull fresh `camtransfer_debug.log` and `cameraVendor-fast-debug.log` and map
   every transition to the current generation/session identity.

No compile-only run, simulator-only run, stale log, or successful installation
without the sequence above is acceptance evidence.

## Delivery standard for the catalog phase

The phase is complete only when all of the following are true:

1. the approved replacement implementation plan has been executed without a
   dual compatibility owner;
2. targeted RunnerTests report the real executed count with zero failures;
3. the complete `RunnerTests` suite reports the real executed count with zero
   failures;
4. architecture fitness checks find none of the explicitly removed ownership
   paths;
5. `git diff --check` passes;
6. a Debug physical-device build succeeds;
7. the app installs and launches on the paired iPhone;
8. the full device acceptance sequence passes using newly pulled logs;
9. the final report lists changed files, removed owner paths, executed test
   counts, device identifiers, log timestamps, observed JPG/HEIF/RAW counts, and any
   deliberately unsupported capabilities;
10. no claim is made about download-speed improvement.

## Download-performance contract

The catalog architecture phase does not claim a downloader speed improvement.
Existing approximately 12 MiB chunk evidence and reduced logging are not
accepted speed claims.

The later download phase must:

1. retain serialized ownership of the PTP transport;
2. emit one summary per file with prepare, request-to-first-byte, socket
   receive, file-write, total, bytes, and MiB/s;
3. after the D212 session-order repair, collect a new CamTransfer RAW run and
   compare it with the same-camera/same-Wi-Fi XApp capture listed below;
4. use timings to locate command-gap, receive, disk-write, or camera/network
   bottlenecks;
5. compare a native-style dedicated continuous receive reader beneath the
   existing original-download executor only after the evidence identifies that
   boundary;
6. keep `D226=2` force-original mode scoped to one serialized continuous
   original-download batch, matching the factory trace's batch preparation;
7. use the factory native `ReadImage` continuous-transfer design as the
   reference, not a speculative chunk-size change.

Download changes require their own failing tests, full RunnerTests, diff check,
physical-device build/install/launch, fresh logs, and measured comparison.

### July 18 current-iOS TCP capture and download D212 falsification

The required current CamTransfer PTP/TCP capture has now been collected from
the paired iPhone and compared with the frozen XApp capture.  The artifacts are:

- baseline Debug branch `off`:
  `/private/tmp/camtransfer-d212-off-20260718.pcap` and
  `/tmp/camtransfer-d212-off-logs-20260718-1217/`;
- isolated Debug branch `d212-once`:
  `/private/tmp/camtransfer-d212-once-20260718.pcap`,
  `/tmp/camtransfer-d212-once-logs-20260718-1225/`, and
  `/tmp/camtransfer-d212-once-cache-20260718-1225/`;
- XApp reference:
  `/private/tmp/xapp-heif-from-connect-20260716-2217.pcap`.

Both CamTransfer captures include the TCP SYN, OpenSession, the complete
download, and zero PTP/TCP reassembly gaps.  The controlled results are:

| Branch | Handle | Bytes | Download-time order | Average chunk wire time | Wire speed |
| --- | ---: | ---: | --- | ---: | ---: |
| `off` | `0x960` | 86,697,984 | `D226=2 -> ObjectInfo -> D235 -> 0x101B` | 2388.3 ms | 4.67 MiB/s |
| `d212-once` | `0x92E` | 87,302,144 | `D212(7 bytes) -> D226=2 -> ObjectInfo -> D235 -> 0x101B` | 2533.8 ms | 4.64 MiB/s |

The D212 experiment emitted the captured payload
`01 00 2f d2 01 00 00` exactly once in the priority batch and preserved seven
contiguous `0x101B` requests with D235 `e0 ff bf 00` and no fallback.  It did
not reduce the camera-on-wire transfer time.  Therefore a download-admission or
pre-D226 D212 read is falsified as a throughput fix and must not remain in the
production end state.

The complete handshakes expose one new transport-level difference that was not
available in the earlier partial CamTransfer capture:

| App | Phone SYN window scale | Camera SYN-ACK window scale | Phone MSS |
| --- | ---: | ---: | ---: |
| CamTransfer `off` | 5 | 5 | 1460 |
| CamTransfer `d212-once` | 5 | 5 | 1460 |
| XApp | 6 | 5 | 1460 |

Current CamTransfer source sets `SO_RCVBUF=2 MiB` and `SO_SNDBUF=2 MiB` before
`connect()`.  The phone-side Window Scale `5` is consistent with the configured
receive-buffer range, while XApp's `6` is a concrete packet-level difference,
not a proven throughput cause.

The 4 MiB branch was exercised in a fresh physical session.  The socket log
proves `SO_RCVBUF=4,194,304` was accepted and the SYN advertised Window Scale
`6`, exactly matching XApp.  The corresponding RAW `0x92A` still took
`28.679 s` on the wire at `2.91 MiB/s`, with average chunk wire time
`3960.4 ms`; App timing was `2.97 MiB/s` with `27,373 ms` in socket receive.
This is slower than the 2 MiB baseline (`4.67 MiB/s`), so the
receive-buffer/Window-Scale hypothesis is falsified as a sufficient fix.  The
capture and logs are `/private/tmp/camtransfer-rcvbuf-4m-20260718.pcap`,
`/tmp/camtransfer-rcvbuf-4m-logs-20260718-1255/`, and
`/tmp/camtransfer-rcvbuf-4m-cache-20260718-1255/`.  The Debug branch must be
removed; no socket-buffer value is promoted to production from this result.

### July 18 unified packet-level comparison: the remaining boundary is transfer admission/state

The three CamTransfer captures and the frozen XApp capture were reprocessed by
the same offline parser
`/private/tmp/analyze_ptp_tcp_compare.py`.  This comparison is deliberately
packet-level and does not infer speed from application logs alone.

All four captures have zero PTP reassembly gaps and zero observed TCP
retransmissions.  For a full 12,582,880-byte `0x101B` response, the camera emits
the same 8,690 TCP payload packets in XApp and CamTransfer.  The difference is
the camera's send cadence between those packets:

| Capture | Phone SYN scale | Effective advertised window during transfer | Phone ACK/data ratio | Average 12 MiB wire time | Wire speed |
| --- | ---: | ---: | ---: | ---: | ---: |
| XApp `0x978` | 6 | about 283–370 KiB | about 0.039 | 888.7 ms | 11.76 MiB/s |
| CamTransfer `off` `0x960` | 5 | about 2.10 MiB | about 0.098 | 2388.3 ms | 4.67 MiB/s |
| CamTransfer `d212-once` `0x92E` | 5 | about 2.10 MiB | about 0.119 | 2533.8 ms | 4.64 MiB/s |
| CamTransfer `4m` `0x92A` | 6 | about 4.19 MiB | about 0.181 | 3960.4 ms | 2.91 MiB/s |

The camera packet burst size is approximately 74–76 packets in all branches,
so the capture does not show a different MTU or request framing.  The decisive
metric is the sum of long camera-to-phone gaps inside each 12 MiB response:
XApp is roughly 0.1–0.7 seconds per chunk, CamTransfer `off` is roughly
0.8–4.0 seconds, and the 4 MiB window is roughly 2.5–4.4 seconds.  The larger
receive window therefore does not remove the camera-side stalls; it makes the
measured result worse.  File writes remain tens of milliseconds in the device
logs and cannot account for this difference.

The pre-transfer PTP state is also not equivalent.  Immediately before the
first XApp `D226=2`, the capture contains several consecutive empty
`D212=00 00` reads and approximately one second of quiet before `D226`.  The
CamTransfer baseline has no such pre-`D226` empty-read sequence and enters
`D226` within milliseconds of the preceding thumbnail/ObjectInfo activity.  The
earlier `d212-once` branch sent a non-empty seven-byte context once and also
entered `D226` immediately; it therefore falsifies only “one arbitrary D212
read is enough,” not the factory pre-download admission state.

The XApp source confirms that original transfer is a single synchronous native
`ControlFFIR.ReadImage(...)` call.  The native library routes that call through
`CCameraCommandReadImage::ExecReadImage` and
`CCameraHandleData::StartGetPartialObjectThread`; the Java/Kotlin layer does
not implement the per-chunk receive loop.  CamTransfer has the same visible
PTP request sizes and offsets, but its admission and receive loop are owned by
Swift.  This is the remaining architectural boundary to compare; it is not
evidence that a new high-level owner or another socket option is needed.

Current conclusion: packet loss, TCP reassembly, receive-window size, request
size, disk write time, D212 single-read placement, and executor-owner choice are
not sufficient explanations.  The unresolved single boundary is the complete
pre-`ReadImage` transfer-state/quiescence context plus the native continuous
transfer executor semantics.  No production code change is authorized until
those two observations are represented as one end-to-end admission profile and
tested in one fresh physical session.  A future experiment must not combine
multiple unrelated toggles or leave a branch in the production tree.

## July 18 failure review and alternate investigation routes

The July 18 download-state matrix is a completed diagnostic exercise, not a
throughput repair.  It must be recorded as a failed repair attempt so that the
same external-variable loop is not repeated or promoted into production.

### What was attempted and what it proved

Each branch used a fresh physical PTP session and the same dedicated original
transfer executor.  D235, request size, contiguous offsets, and the socket
receive path were held constant unless the branch explicitly tested the
documented variable:

| Branch | Variable | RAW result | Verdict |
| --- | --- | ---: | --- |
| `baseline` | no additional BLE/lifecycle action | 4.59 MiB/s | baseline only |
| `bleOnce` | one read-only BLE sampling batch | 3.05 MiB/s | not a stable trigger |
| `blePeriodic` | repeated read-only BLE sampling batches | 3.91 MiB/s | not a stable trigger |
| `lifecycleOnly` | foreground-to-background transition with BLE sampling suppressed | 4.26 MiB/s | lifecycle alone is not a trigger |

The authoritative logs are:

- `/private/tmp/camtransfer_download_baseline_completed-20260718-1850.log`
- `/private/tmp/camtransfer_download_bleOnce_second-20260718-1910.log`
- `/private/tmp/camtransfer_download_blePeriodic_completed-20260718-1912.log`
- `/private/tmp/camtransfer_download_lifecycleOnly_completed-20260718-1922.log`

All four runs have the same important shape: `ReadImage` uses the dedicated
worker, D235 is `0x00BFFFE0`, the initial and final read sizes are
`12,582,880`, fallback is zero, file writes are below one second, and almost
all elapsed time is `socketReceiveMs`.  None reached the factory-class
`12-15 MiB/s` range.

The matrix therefore falsifies these claims as sufficient fixes:

- one BLE read before transfer;
- periodic BLE reads during transfer;
- an iOS foreground/background transition by itself;
- D235/request-size selection, dedicated-worker ownership, or file writing as
  the complete explanation for the current slowdown.

It does **not** prove that BLE, lifecycle, or native transfer state can never
affect the camera.  It proves only that these isolated variants, in the tested
session state, did not produce the factory behavior.

### Why the previous investigation did not reach a fix

The failed work followed a valid falsification method but stopped one boundary
too high and repeatedly treated an excluded hypothesis as if it were a repair
candidate:

1. The application logs measured aggregate `socketReceiveMs`, but not the
   causal packet/state transition inside that interval.
2. The experiments changed phone-side admission or lifecycle variables while
   the packet comparison already showed the dominant difference in camera
   send cadence: identical packet counts, but long inter-burst gaps in
   CamTransfer and short gaps in XApp.
3. Matching `D226`, `ObjectInfo`, `D235`, `0x101B` offsets, and request sizes was
   incorrectly treated as equivalent to the native XApp `ReadImage` call.
   Those values prove protocol-shape parity, not native executor/admission
   parity.
4. The historical `12.58 MiB/s` run was not controlled against the current
   dedicated-session path, so it was evidence that the device can be fast, not
   evidence that any one current code path was the cause.
5. Some earlier diagnostic matrices used borrowed sessions or incomplete
   reference sets.  Those results were later corrected in the evidence audit,
   but they should never have been used for causal claims.

The honest status is therefore: the exact throughput trigger is still
unresolved.  The evidence has narrowed the boundary to the complete
pre-`ReadImage` transfer-state/quiescence context and the native continuous
executor semantics, but no production fix has been proven.

### Alternate routes, ranked and gated

The next investigation must select one route and state its falsifiable
prediction before any device run.  No route may alter the Gallery connection,
catalog ownership, BLE/Wi-Fi handoff, socket options, chunk profile, or generic
PTP command path as a side effect.

1. **Admission/quiescence route (primary).**  Reconstruct the exact XApp
   pre-`D226` and
   pre-`ReadImage` state from the frozen pcap: empty D212 drain, quiet interval,
   no competing thumbnail/ObjectInfo command, and one synchronous transfer
   admission.  Test this as one Debug-only end-to-end profile in a fresh
   physical session.  A single D212 read, a lifecycle toggle, or a new BLE
   poll is not an acceptable substitute for the complete profile.
2. **Native executor route.**  Inspect the XApp native
   `ControlFFIR.ReadImage -> CCameraCommandReadImage::ExecReadImage ->
   CCameraHandleData::StartGetPartialObjectThread` path and map its admission,
   thread, receive, ACK, and completion behavior to the Swift executor.  The
   required output is a concrete sequence/timing difference that predicts a
   shorter camera inter-burst gap.  Only that difference may be implemented
   beneath the existing dedicated executor.
3. **Packet-level transport route.**  If native inspection cannot resolve the
   difference, instrument one controlled CamTransfer run at TCP/PTP packet
   boundaries and compare per-burst ACK cadence, receive-window evolution,
   command interleave, and camera response gaps with the existing XApp pcap.
   This route is for locating the exact boundary, not for trying more
   `SO_RCVBUF`, `MSG_WAITALL`, timeout, or chunk values.
4. **Native bridge route.**  If the native library is callable on iOS and its
   license/distribution constraints permit it, build a Debug-only adapter that
   invokes the same native `ReadImage` entry point for one file while retaining
   the existing session/lease owner.  A factory-class result would isolate the
   Swift executor as the cause; a slow result would move the boundary back to
   admission/session state.  This adapter must not become a second production
   transfer owner without a separate architecture review.

The routes are alternatives, not a checklist to run in parallel.  The first
route that produces a falsifiable prediction wins; failed branches are deleted
after their evidence is recorded.  Until one route explains the camera
inter-burst stalls and then passes a same-file, same-camera, same-Wi-Fi device
comparison, there is no authorized throughput implementation.

### Parallel research synthesis

Three independent read-only investigations were completed after the matrix:
native FFIR reconstruction, packet-level gap analysis, and historical
fast-path regression analysis.  Their combined result changes the evidence
priority without claiming a fix.

The native path is now reconstructed to the socket primitive:

- `ControlFFIR.ReadImage` calls native `SDK_CommonReadImage` synchronously;
- `CCameraCommandReadImage::ExecCommonReadImage` reads D235, clamps it to
  `0x00BFFFE0`, and starts `StartGetPartialObjectThread`;
- the worker continuously advances contiguous `0x101B` offsets and keeps the
  ImageObj critical section across the transfer;
- `libFTLPTPIP` receives one complete PTP data packet before copying its
  payload to the destination;
- its low-level receiver sets `SO_RCVTIMEO` and loops directly on blocking
  `recvfrom(..., MSG_NOSIGNAL)`; it does not call `poll()` and does not use
  `MSG_WAITALL`;
- the Java event-5 callback gates progress only after a complete partial-object
  chunk, so it cannot by itself explain the long gaps observed inside a chunk.

The current Swift executor already matches the high-level properties: one
worker, one serialized lease, D235, contiguous offsets, and one payload/file
write.  Its direct low-level difference is `poll() -> recv()` on each partial
read.  That is a valid secondary experiment, but the packet evidence prevents
promoting it to the primary cause: during the long camera gaps, ACKs are usually
already delivered and the receive window still has substantial headroom.

The packet-level analysis establishes a more specific pattern:

- every full `12,582,880`-byte response has the same 8,690 TCP payload packets
  in XApp and CamTransfer;
- there are no retransmissions, reassembly gaps, PTP command interleaves, or
  chunk-boundary pauses that explain the slowdown;
- long gaps recur inside one PTP data container at approximately
  `0.9-1.05 MiB` intervals, consistent with a camera-side producer/pacing
  quantum;
- before most long gaps, the phone ACK has already covered the last camera
  packet and the camera then goes silent while the receive window remains open;
- XApp's first download admission follows consecutive empty D212 reads, no
  thumbnail/ObjectInfo competition, and approximately one second of quiet
  before D226; CamTransfer enters D226 within milliseconds of preceding Gallery
  work or uses only a non-empty single D212 read.

The Debug `SO_RCVBUF=4 MiB` capture also changed ECN/TOS session behavior, so
its slower result cannot be attributed to the receive window alone.  The XApp,
CamTransfer baseline, and D212-once captures retain equivalent ECN signaling
and still differ materially in speed, so ECN/TOS is not a sufficient cause.

The historical regression investigation removes a tempting rollback path.  On
July 10, the old generic 4 MiB implementation reached `10.97`, `12.58`, and
`12.50 MiB/s`, but the same code family and day also produced approximately
`2.48-4.85 MiB/s`.  There is no committed production change between that run
and the current dedicated executor; the relevant implementation changes are
in the current dirty tree.  The historical run proves that the app/device can
enter a fast camera state, not that restoring the old generic executor will
make it stable.

The resulting order is therefore:

1. test the complete XApp admission/quiescence profile while keeping the Swift
   receiver, socket configuration, D235, chunk size, and owner unchanged;
2. only if that fails, test the native blocking-receive primitive as a separate
   Debug branch, using `SO_RCVTIMEO` plus blocking `recv`/`recvfrom` and no
   `poll()` or `MSG_WAITALL`;
3. if both fail, collect syscall/framing evidence before considering a native
   bridge; do not add another socket/chunk/lifecycle experiment.

The admission experiment has an explicit success threshold for the first six
full-size chunks: average wire time at or below `1.3 s`, total gaps above
`50 ms` at or below `0.8 s` per chunk, no gap above `500 ms`, and file speed at
or above `8.5 MiB/s`.  Anything below that boundary is evidence, not a fix.

### July 19 XApp-quiescent admission result: falsified as a sufficient trigger

The isolated Debug run is preserved at
`tmp/device-logs/live-pull-20260719-122239/`.  It used a fresh physical PTP
session (`192.168.0.1-0-1`, generation `1`) and the explicit
`xapp-quiescent` branch.  Connection remained healthy at
`GALLERY_TIMING_CONNECT=0.710s`.

The branch executed exactly as designed before the first HEIF transfer:

- active thumbnail count `0`, active metadata count `0`, pending thumbnail
  count `0`;
- D212 attempt 1 returned 14 bytes, attempt 2 returned 7 bytes, and attempts
  3-11 returned nine consecutive exact `00 00` payloads;
- the lane then remained quiet for 1000 ms; total admission time was 1122 ms;
- after admission, the observed command sequence was fresh `ObjectInfo`,
  D235=`12,582,880`, then contiguous `ReadImage`; no thumbnail, catalog, or
  other PTP command was inserted;
- all six files validated and downloaded as HEIF, `fallbackCount=0`, with no
  RAW contamination.

This clean admission state did not improve throughput.  The same six-file
baseline produced transfer speeds `7.44, 8.42, 8.88, 9.28, 9.29, 9.06 MiB/s`
(median `8.97 MiB/s`) and end-to-end median `7.43 MiB/s`.  The
`xapp-quiescent` branch produced `7.18, 8.30, 8.23, 8.32, 8.27, 8.19 MiB/s`
(median `8.25 MiB/s`) and end-to-end median `6.89 MiB/s`.  Median socket receive
time increased from `1398 ms` to `1550.5 ms`; median request-to-first-byte time
was effectively unchanged (`221 ms` versus `221.5 ms`).

Therefore empty-D212 drain plus a one-second quiet interval is falsified as a
sufficient cause of XApp throughput.  It must not enter the production path or
be combined with another experiment.  The next authorized independent route
is the native receive primitive already reconstructed above: Debug-only
`SO_RCVTIMEO` plus direct blocking `recv`/`recvfrom`, with no `poll()` and no
`MSG_WAITALL`, applied only to the dedicated original `ReadImage` payload path.

### Fast-state commonality audit

The historical fast samples and the July 18 cold-to-hot run were re-aligned by
handle, batch, and lifecycle event.  The commonality is not simply “HEIF plus
RAW” and is not a per-file property:

- July 10's fast sequence is a continuous queue in one session.  It begins at
  `8.04 MiB/s`, rises through `9.86` and `10.97`, and reaches `12.58` and
  `12.50 MiB/s` only after several preceding transfers.  The queue alternates
  adjacent RAF/HEIC pairs, which is correlated with the fast sequence but is
  not sufficient evidence of a format trigger.
- In the July 18 pull, the same RAW handle `0x00000978` measures about
  `4.72 MiB/s` in the cold phase and `14.63 MiB/s` later in the same overall
  session.  The same RAW handle `0x0000097A` measures about `4.65 MiB/s` and
  later `15.12 MiB/s`.  D235, request sizes, executor, file bytes, and write
  times remain equivalent.
- The July 18 transition occurs after a preceding batch of slow full-size RAW
  transfers, a new priority batch, an app background transition, and a
  CoreBluetooth background activity callback.  The in-flight file improves
  only to `6.47 MiB/s`; the following RAW files rise to `12.37`, `13.28`,
  `14.15`, and `14.36 MiB/s`.
- The earlier `lifecycleOnly` run backgrounded during the first cold file and
  remained at `4.26 MiB/s`.  BLE-once and BLE-periodic runs also remained slow.
  These results do not contradict the interaction hypothesis: they lacked
  the preceding warm-up/batch state.
- Conversely, four or more foreground RAW files alone can remain at
  `4.6-4.7 MiB/s`, so transfer volume alone is not sufficient either.

The best-supported current hypothesis is therefore an interaction, not one
isolated switch:

```text
same PTP session
-> several complete original transfers / camera producer warm-up
-> batch boundary or quiet interval
-> background/state callback at the warm boundary
-> camera enters a sustained fast producer state
```

This explains why the earlier experiments failed: they tested BLE, lifecycle,
and warm-up independently, while the observed fast state requires their
ordering/context combination.  It remains a hypothesis until a single Debug
matrix proves it with fresh owned sessions.

The next experiment must therefore be one package with four independent fresh
sessions, not four sequential guesses:

| Branch | Warm-up transfers | Batch boundary/quiet | Background/state callback |
| --- | --- | --- | --- |
| `cold-background` | none | no | yes |
| `warm-foreground` | four same-size originals | no | no |
| `warm-boundary` | four same-size originals | yes | no |
| `warm-boundary-background` | four same-size originals | yes | yes |

Every branch uses the same target RAW, D235, request size, receiver, queue
admission, and physical camera/Wi-Fi conditions.  `cold-background` is already
represented by the slow `lifecycleOnly` result; it remains in the matrix as a
control.  The key prediction is that only `warm-boundary-background` should
cross the `8.5 MiB/s` acceptance threshold.  If `warm-boundary` is already
fast, the decisive trigger is the camera batch/quiescence boundary; if only
the background branch is fast after warm-up, lifecycle/state scheduling is
part of the trigger; if all remain slow, return to the native receive
primitive.  No branch may be promoted to production without this result.

Reproducible packet-level outputs are frozen at:

- `/private/tmp/pcap_gap_summary_20260718.txt`
- `/private/tmp/pcap_long_gap_events_20260718.csv`
- `/private/tmp/pcap_long_gap_chunks_20260718.csv`

### Required cleanup after this matrix

The Debug branch selector and BLE/lifecycle experiment harness are temporary
diagnostic infrastructure.  After this document update, they must be removed
from the production end state, with the default download path restored to one
dedicated executor and no experiment branch.  The cleanup itself must be
verified with targeted RunnerTests, full RunnerTests, `git diff --check`, and a
Debug device build/install/launch.  Cleanup is not a speed fix and must not be
reported as one.

## Reverse-validation audit of the current conclusions

The conclusions were re-checked by attempting to falsify each causal step rather
than treating a matching opcode or a green validator as proof:

| Conclusion | Direct evidence | What would falsify or weaken it | Current verdict |
| --- | --- | --- | --- |
| X-T5 HEIF is an exact camera-side directory, not a local refinement | Reassembled XApp capture has no TCP gaps; `D604=2` payload is exact; `D620=616`, `D621=616`, declared/decoded/unique/order all agree | A same-session capture with the same payload returning a different exact 616-set, or duplicate/mismatched D621 validation | Proven for this X-T5 capture; not generalized to every camera/firmware |
| Current iOS reaches the first directory transaction with a different command history and result | Source order has no D212 immediately after `OpenSession` and reads the seven-byte D212 before `9054`; device logs show initial `D620/D621=1807` | A fresh iOS wire capture showing the four factory reads at the captured positions and still yielding 1807 | Source-order and result differences proven; inferred camera-state cause not yet proven |
| Restore timing is not the cause of the observed 2423 count | Restore command is issued only after D620/D621 have been read in the transaction | A protocol trace proving the camera asynchronously applies a post-read restore retroactively to the already-returned count | Proven by command causality for that count; atomic restore remains required contract |
| A/B/C/D independently falsify post-9053 D212/restore variants | Would require one owned PTP session and a same-session RAW reference for every branch | Current implementation borrows the active session, logs `connectDuration=0.000`, and passes `rawHandles=nil` | Not proven; prior matrix is diagnostic-only |
| Preparation order is a real iOS/XApp difference | XApp all-mode trace shows `D226=2 -> ObjectInfo -> D235 -> 0x101B`; iOS `objectFile` source shows D235 before D226/ObjectInfo | A new iOS pcap showing the same order, or an order-aligned run with unchanged timings | Wire difference proven; speed causality unproven |
| D212 immediately before download may prepare the camera for fast transfer | XApp has nearby D212 reads in the complete lifecycle | Current isolated branch emitted the seven-byte D212 immediately before D226 and remained at 4.64 MiB/s | Falsified as a sufficient fix; remove the experiment |
| Phone receive-window configuration may affect camera wire rate | Current CamTransfer captures advertise Window Scale 5; XApp advertises 6; CamTransfer explicitly sets `SO_RCVBUF=2 MiB` | The Debug-only 4 MiB receive buffer advertised Window Scale 6 but slowed to 2.91 MiB/s with 3960.4 ms average chunk wire time | Falsified as a sufficient fix; remove the branch |
| Swift/native transfer admission is the remaining boundary | XApp uses one native `ReadImage` call and shows short camera send gaps; CamTransfer shows the same packet count but much larger camera send gaps and a different pre-`D226` state | A fresh end-to-end admission-profile run matching the XApp pre-`ReadImage` state but retaining the same Swift receiver remains slow | Boundary identified; exact causal sub-step still requires one controlled end-to-end validation |
| The owner split is not currently implicated as the HEIF cause | Catalog runtime/repository enforce generation and known-handle boundaries; the wrong directory is returned before snapshot publication | A reproducible stale-owner, lane-admission, or cross-session mutation that changes the camera-side D620/D621 result | No evidence implicates the owner split; target retained, lifecycle still needs device proof |

The failed reasoning found during this audit is explicit: a generated
`experimentSession` UUID is not a physical PTP session identifier, a
`missingRawReference` rejection means “no RAW contamination” was not tested,
and the fact that a branch returned 2423 on a borrowed session cannot be used to
falsify a clean-session startup hypothesis.  Any implementation report must
carry these evidence limitations forward.

## Evidence confidence and unresolved boundaries

| Area | Proven from current evidence | Not yet proven |
| --- | --- | --- |
| HEIF payload/result | XApp sends exact `D604=2` and returns 616; current iOS sends the same payload and the observed runs return 2423 | independent-session effect of post-`9053` D212 variants; which startup-state difference is causal |
| HEIF startup | iOS misses D212 #1 and places D212 #3 before the current-image bootstrap; initial catalog is 1807 vs XApp 2423 | whether exact four-D212 parity alone restores 2423 baseline and 616 HEIF |
| HEIF filter preparation | XApp performs a count sweep and establishes `D604=31` before formal HEIF apply; iOS does neither | whether `D604=31` alone, or only the full count sweep, is required after startup parity |
| Download command model | both use `D226=2`, fresh ObjectInfo, D235, contiguous `0x101B`, and ~12 MiB payloads | whether command-order parity alone materially improves sustained receive |
| Download performance | Fresh CamTransfer captures are 4.67 MiB/s (`off`), 4.64 MiB/s (`d212-once`), and 2.91 MiB/s (`SO_RCVBUF=4 MiB`); XApp RAW is 9.82-11.76 MiB/s; no retransmissions or reassembly gaps; the same 8,690 TCP payload packets per 12 MiB chunk | which exact part of the complete pre-`ReadImage` admission/native-executor context removes the camera's long inter-burst stalls |
| Connection stability | XApp holds one session/lane for 314.388 s; current owner/scheduler architecture also enforces one lane, but `loadGallery` blocks on a ~25.8 s bootstrap in the current state | whether exact startup-state parity also removes the 9054/9055/D22B latency |

No implementation report may promote a “not yet proven” cell to root cause or
completion without a new same-camera run and the required command/timing logs.

## Evidence inventory and current decision

Authoritative artifacts for the next implementation and verification cycle:

| Evidence | Location | What it proves |
| --- | --- | --- |
| July 16 full XApp network lifecycle | `/private/tmp/xapp-heif-from-connect-20260716-2217.pcap` | Startup D212 ordering, exact HEIF transaction, initial counts, and XApp original-download timing |
| July 16 Bluetooth capture | `/private/tmp/xapp-full-lifecycle-bluetooth-20260716.pcap` | Nothing beyond capture setup; 24-byte header only, no HCI packets |
| July 15 stable HEIF golden capture | `/private/tmp/xapp-heif-filter-20260715-pcapd-stable.pcap` | Exact JPG/HEIF/RAW/MOV/ALL payloads and counts |
| July 16 HEIF matrix logs | `/private/tmp/camtransfer-device-20260716-archives/` and `/private/tmp/camtransfer-device-20260716-2123/` | Borrowed-session A/B/C/D diagnostic results (all 2423, `connectDuration=0.000`, `missingRawReference`), startup/connection timing, and 1807 initial catalog |
| July 16 CamTransfer RAW timing | `/private/tmp/camtransfer-live-pull-20260716-115655/Documents/camtransfer_debug.log` | Handle `0x93A`, 86,758,400 bytes, 19.580 s, 4.23 MiB/s, receive-dominated timing |
| July 15 CamTransfer RAW timing | `/private/tmp/camtransfer-live-20260715-035331/camtransfer_debug.log` | Handle `0x92A`, 87,396,352 bytes, 20.450 s, 4.08 MiB/s, receive-dominated timing |
| July 18 CamTransfer baseline TCP/PTP capture | `/private/tmp/camtransfer-d212-off-20260718.pcap` | Complete SYN/OpenSession/download; Window Scale 5; handle `0x960`; 4.67 MiB/s; 2388.3 ms average chunk wire time |
| July 18 CamTransfer D212 TCP/PTP capture | `/private/tmp/camtransfer-d212-once-20260718.pcap` | Seven-byte D212 immediately before D226; Window Scale 5; handle `0x92E`; 4.64 MiB/s; D212 throughput hypothesis falsified |
| July 18 CamTransfer 4 MiB receive-buffer capture | `/private/tmp/camtransfer-rcvbuf-4m-20260718.pcap` | Window Scale 6; handle `0x92A`; 2.91 MiB/s; 3960.4 ms average chunk wire time; receive-window hypothesis falsified |
| July 18 4 MiB receive-buffer device logs | `/tmp/camtransfer-rcvbuf-4m-logs-20260718-1255/` and `/tmp/camtransfer-rcvbuf-4m-cache-20260718-1255/` | `SO_RCVBUF=4 MiB`, accepted setsockopt, unchanged D235/chunk profile, and slower receive-dominated transfer |
| July 18 D212 device logs | `/tmp/camtransfer-d212-once-logs-20260718-1225/` and `/tmp/camtransfer-d212-once-cache-20260718-1225/` | Debug branch persistence, exact D212 payload/order, D235 profile, no fallback, and receive-dominated timing |
| Pcap parsers used for reproducibility | `/private/tmp/analyze_xapp_full_ptp.py` and `/private/tmp/analyze_ptp_tcp_compare.py` | TCP/PTP reassembly, SYN options, ACK cadence, effective receive window, camera inter-packet gaps, pre-`0x101B` PTP state, filter payload/count, and per-chunk download measurements |
| Production vendor implementation | `ios/Runner/CameraVendorBluetoothService.swift` | Current PTP bootstrap, filter request, download executor, and socket receive path |
| Catalog owner | `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift` | Single generation/task/publication owner |
| Catalog repository | `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift` | Generation/snapshot/known-handle enrichment boundary |

Current delivery decision:

1. Keep the session/catalog/repository/UI ownership architecture.
2. Keep the factory D212 ordering already proven by the July 17 run; do not
   re-run or reintroduce it as a proposed fix.  Remove the standalone `D604=31`
   baseline from production and test it only in an isolated diagnostic branch.
3. The required current iOS PTP capture and packet-by-packet comparison are
   complete.  Do not collect another capture or change a socket option until
   the single admission-profile hypothesis below has been specified and
   tested.
4. Run the complete XApp filter count-sweep experiment from a fresh owned PTP
   session, diagnostic-only, and accept HEIF only from fresh device evidence showing 616 exact handles and no
   RAW contamination.
5. Re-measure download throughput only after the complete pre-`ReadImage`
   admission state is reproduced in one fresh physical session.
6. Treat the download-preparation-order, dedicated 4 MiB, BLE admission, and
   pre-D226 D212 experiments as complete and falsified as sufficient fixes.
   Delete their Debug harnesses from the end state.
7. Do not promote any socket-buffer or Window-Scale change. The complete
   nine-consecutive-empty D212/quiet admission profile has now been exercised
   and falsified as a sufficient throughput trigger; do not reintroduce or
   stack it. Current-build JPG and HEIF measurements are complete. The next
   authorized work is one isolated Debug-only native blocking-receive branch
   on the dedicated original `ReadImage` payload path. Default, Release,
   generic command/file reads, connection, catalog, D235, and chunk sizing must
   remain unchanged.

### July 19 JPG/HEIF original-download measurement contract

The current JPG and HEIF speed numbers were re-measured on the current Debug
build instead of reusing the older fast-session logs. The measurement is
Debug-only and does not change the HEIF catalog transaction or production
download path. JPG and HEIF are run in separate fresh physical PTP sessions,
with six to eight same-format files per run. Every file is validated by the
existing ObjectInfo path before transfer; a suffix/format mismatch aborts the
run and never falls back to RAW or another catalog result.

The report must separate camera-to-file transfer speed from end-to-end speed:

- `PTP_DOWNLOAD_FILE_TIMING.speedMBps`, `socketReceiveMs`, `transferMs`,
  `fileWriteMs`;
- `ORIGINAL_DOWNLOAD_TIMING.speedMBps`, `photoSaveMs`, and `totalMs`.

The temporary probe uses the existing single PTP owner, scheduler,
exclusive download lease, communication generation, and original-read
executor. It must not add a session owner, change BLE/Wi-Fi/connection,
change catalog filtering, or run hidden warm-up downloads. The probe is removed
after the native blocking-receive comparison is complete; neither the admission
branch nor the receive branch may remain in the terminal production path.

## Non-goals

This terminal Gallery catalog cut does not change:

- pairing;
- pairing or the general Wi-Fi handoff topology; it does correct the internal
  Gallery activation lifecycle described above;
- Home routing;
- remembered-camera recovery policy;
- background-download authority or lock-screen behavior;
- original-file chunk size or executor;
- wired USB ownership;
- general Gallery visual design.

The current wireless Gallery does not implement camera-file deletion or local
proofing.  Its local-proofing button is a placeholder.  Camera-file deletion
and the working local HTTP/QR proofing flow belong to the wired USB module and
must remain untouched by this wireless catalog cut.

It may change the internal Gallery activation handoff only as required to bind
the already-established session and initial catalog to the single catalog
runtime.  It must not create a new connection or recovery path.

Future simultaneous multi-camera sessions, multiple PTP lanes, concurrent live
view plus Gallery, or unified USB/Wi-Fi operation are topology changes and need
a separate approved architecture.  Ordinary new filter types, camera
capabilities, metadata fields, caching, and presentation features must extend
the typed intent/capability/repository boundaries without changing ownership.
