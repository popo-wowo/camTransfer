# iOS USB Gallery Selection and Background Import Design

## Scope

Improve the in-app USB camera gallery in three bounded areas:

- Show media format and file size in grid cells without showing filenames.
- Make drag selection behave exactly like the wireless gallery.
- Publish USB import progress to the existing Lock Screen and Dynamic Island Live Activity while using the finite background execution time iOS grants to the app.

Wireless gallery behavior and camera protocol handling remain unchanged.

## Grid Metadata

The USB grid cell removes its filename label. The existing format badge remains visible and the bottom information bar contains only the formatted file size. Imported, cached, unsupported, and proofing status badges remain unchanged.

## Drag Selection

The USB gallery reuses `NativeGalleryDragSelectionPolicy` directly. It does not introduce a second drag-selection policy.

- A horizontal drag starting from an unselected selectable item enters selecting mode.
- A horizontal drag starting from a selected selectable item enters deselecting mode.
- The selected range follows the same flattened visible-item ordering used by the wireless gallery, including movement across date sections.
- Unsupported items are skipped.
- Selection is disabled until the live USB catalog is ready and while import or deletion is active.
- Near the top or bottom edge, the collection view auto-scrolls using the same edge and delta policy as the wireless gallery.
- Vertical intent remains normal collection scrolling. Pinch remains grid zoom. A tap remains preview or selection-button interaction.

Visible cells and section headers are refreshed after selection changes. Thumbnail work is not restarted for every touched item.

## Live Activity

USB import creates a dedicated session ID and publishes through the existing `CameraSessionLiveActivityController` and `CameraSessionActivityAttributes` widget.

The Lock Screen and Dynamic Island display:

- USB camera name;
- completed and remaining item counts;
- aggregate byte progress when USB byte totals are available;
- foreground or background state through the existing activity state.

The activity starts only when an import starts. It updates during file transfer and after each Photos save. It ends after success, failure, cancellation, disconnect, or controller teardown.

Optional byte fields are added to the shared activity content state. Wireless downloads continue using their existing count progress when byte totals are absent.

## Background Execution

Live Activity presentation does not keep an app executing. USB import separately acquires a `CameraSessionUIKitExecutionAuthority` lease while work is active and releases it at every terminal path.

When the app moves between foreground and background, the USB activity is updated accordingly. If the finite UIKit background task expires, the USB queue stops after the active ImageCapture operation returns, the activity ends, and the UI reports that the user must return to the app to continue. The implementation does not claim indefinite background USB transfer.

No `external-accessory`, processing, or fetch background mode is added because generic ImageCaptureCore USB cameras do not qualify for those execution modes.

## Verification

- Policy tests prove USB drag selection uses the shared wireless range, intent, and auto-scroll behavior.
- State tests prove imported live items remain selectable for camera deletion and unsupported items are skipped.
- Activity-state tests prove byte progress takes precedence when available and count progress remains the fallback.
- Background lease tests prove acquisition, expiry handling, and release on terminal paths through small policy/controller boundaries.
- All `testWiredCamera...` tests and affected Live Activity tests pass.
- A signed device build is installed and launched on the paired iPhone.
- Physical USB acceptance checks drag selection, metadata display, Lock Screen/Dynamic Island updates, foreground/background transition, and truthful expiry behavior.
