# Local Proofing Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a no-server on-site proofing mode where the photographer's iPhone serves a browser gallery over the local network and clients favorite photos from Safari.

**Architecture:** Keep proofing state, HTML generation, QR generation, and the Network.framework HTTP listener in a new focused Swift file. The wired import controller only starts/stops a session, presents the QR/link, serves cached thumbnails, and mirrors client favorites into the existing selected item set.

**Tech Stack:** Swift, UIKit, Network.framework, CoreImage QR generation, XCTest.

---

### Task 1: Proofing Model And Web Renderer

**Files:**
- Create: `ios/Runner/LocalProofingSession.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [x] Write tests for session token format, photo JSON, favorite request decoding, and HTML containing the API endpoints.
- [x] Implement `LocalProofingPhoto`, `LocalProofingFavoriteUpdate`, and `LocalProofingWebRenderer`.
- [x] Run focused tests for local proofing models.

### Task 2: Local HTTP Server

**Files:**
- Modify: `ios/Runner/LocalProofingSession.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [x] Implement request parsing and response building as testable pure helpers.
- [x] Implement `LocalProofingServer` with `NWListener` and `NWConnection`.
- [x] Serve `/s/<token>`, `/api/photos`, `/preview/<id>.jpg`, and `/api/favorite`.
- [x] Run focused tests for routing helpers.

### Task 3: Wired Import UI Integration

**Files:**
- Modify: `ios/Runner/WiredCameraImportViewController.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `ios/project.yml`

- [x] Add a "现场选片" navigation action when there are visible items.
- [x] Present a QR/link sheet with session status and selected count.
- [x] Build proofing photos from visible wired items, using cached thumbnails as JPEG previews.
- [x] On favorite updates, update `state.selectedItemIDs` and refresh the grid.

### Task 4: Verification

**Files:**
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] Run focused proofing tests.
- [x] Run full simulator tests.
- [x] Run a true device build.
- [x] Install and launch the app on the iPhone.
