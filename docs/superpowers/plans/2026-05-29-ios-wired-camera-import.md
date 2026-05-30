# iOS Wired Camera Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a separate iOS wired-camera import beta that discovers USB/PTP cameras through ImageCaptureCore, lists media, and saves selected originals to Photos.

**Architecture:** Keep the feature isolated from the existing BLE/Wi-Fi/PTP flow. Add a small ImageCaptureCore service, a testable state/policy model, and a dedicated UIKit import screen presented from the native connect screen.

**Tech Stack:** Swift 5, UIKit, ImageCaptureCore, Photos, XCTest, existing Xcode project.

---

### Task 1: Testable Wired Import State

**Files:**
- Create: `ios/Runner/WiredCameraImportModels.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Write failing tests for state transitions and file filtering**
- [x] **Step 2: Run tests to verify the symbols are missing**
- [x] **Step 3: Implement minimal models and policies**
- [x] **Step 4: Run tests again**

### Task 2: ImageCaptureCore Service

**Files:**
- Create: `ios/Runner/WiredCameraImportService.swift`

- [x] **Step 1: Define service delegate and item mapping boundary**
- [x] **Step 2: Implement device browsing, authorization, session open, item refresh, thumbnail, and file download**
- [x] **Step 3: Keep the service UI-agnostic and main-thread delegate safe**

### Task 3: Import Screen and Entry Point

**Files:**
- Create: `ios/Runner/WiredCameraImportViewController.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/Runner/Info.plist`

- [x] **Step 1: Add a visible "有线导入 Beta" entry point to the connect screen**
- [x] **Step 2: Build the wired import screen for disconnected, unauthorized, loading, ready, saving, and error states**
- [x] **Step 3: Save downloaded files through the existing Photos saver**

### Task 4: Project Integration and Verification

**Files:**
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `ios/project.yml`

- [x] **Step 1: Add new Swift files to the Runner target**
- [x] **Step 2: Run focused tests/builds**
- [x] **Step 3: Report hardware-test limitation clearly**
