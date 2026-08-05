# iOS Gallery Format Membership Repair Design

Date: 2026-08-04

## Goal

Repair the post-`GalleryReady` format-filter regression without changing the
connection path, first Catalog transaction, runtime ownership, command lane,
thumbnail, preview, or download behavior.

## Evidence

- The fresh X-T5 run installs the base Catalog with 1813 handles and reaches
  `GalleryReady` before format enrichment.
- `D604=2` returns a broad 2435-handle directory in the current iOS session;
  subtracting the 1813-handle base isolates 622 HEIF handles.
- `D604=4` returns an exact 15-handle MOV directory. Treating it as a broad
  response makes `baseline.isSubset(of: format)` fail and prevents the MP4
  query from running.
- A filtered transaction failure currently publishes `items=[]`, replacing a
  valid Ready presentation with an empty failed presentation.
- The factory XApp uses direct format directories: JPG, HEIF, RAW, and MOV are
  returned as exact D621 memberships; MP4 is empty on the captured card.

## Approved Behavior

1. HEIF remains the only compatibility format that uses the current
   subtract-initial-base membership strategy.
2. JPG, RAW, MOV, and MP4 use structurally validated direct Catalog snapshots.
3. Product `.video` executes separate MOV and MP4 queries and deduplicates their
   union. A successful MOV result cannot be rejected by HEIF's superset rule.
4. MP4 must execute after MOV. Its current X-T5 physical result must be recorded
   before device support is declared complete.
5. A non-terminal filtered-query failure preserves the last installed Ready
   Catalog and does not publish an empty catalog. A terminal transport failure
   continues through the existing runtime transport-loss path.
6. Post-ready ALL enrichment remains generation fenced and atomically installs
   only a validated current-generation result.
7. ALL membership enrichment starts whenever the restored intent has the same
   camera membership as ALL; local sort/date/download projections must not
   suppress enrichment.

## Architecture

- `CameraSessionRuntime` remains the session/lifecycle owner.
- `CameraGalleryCatalogRuntime` remains the sole Catalog generation,
  transaction, repository-install, and publication owner.
- `CameraCatalogQueryEngine` continues to compose product membership.
- `CameraSessionGalleryCatalogRuntimeSource` maps product formats to physical
  queries: HEIF compatibility subtraction, JPG/RAW direct, MOV/MP4 direct.
- `CameraCommandLane`, actor isolation, generation fences, and snapshot identity
  checks remain unchanged.

## Failure Semantics

- Structural snapshot mismatch: reject the current transaction.
- Non-terminal format-query failure: keep the previous Ready presentation and
  leave the failed membership uncached.
- Terminal socket/session failure: report transport evidence and let the
  existing runtime terminate the session.
- Cancelled or stale generation: never publish.

## Verification

- Wire-contract tests prove HEIF broad subtraction and MOV/MP4 direct queries.
- Source tests prove MOV and MP4 execute independently and merge without
  duplicates.
- Runtime tests prove a filter failure cannot publish `items=0` over a Ready
  Catalog and that stale generations cannot install.
- Session tests prove ALL enrichment starts for ALL-equivalent camera membership
  even when local projections differ.
- Fresh X-T5 logs must show base Ready first, HEIF isolated 622, MOV direct 15,
  an executed MP4 query, video membership, and an ALL union without empty
  publication.

## Non-Goals

- No D212, D227, D244, BLE, Wi-Fi, PTP INIT/retry, first Catalog, 9050,
  thumbnail, HD preview, download, Quick Download, or background changes.
- No complete XApp count-sweep production cutover in this repair.
- No commit or push.
