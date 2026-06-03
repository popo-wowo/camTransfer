# Android iOS UI Parity Design

## Goal

Make the Android app match the existing iOS CamTransfer operation model and visual style for connection, gallery browsing, selection, downloading, and download status.

## Scope

- Apply the iOS warm luxury theme to Android Compose screens.
- Keep the fixed Android PTP, thumbnail, and gallery save logic unchanged.
- Move download initiation back into the gallery screen so the user can continue browsing while selected items show status.
- Keep a separate download center reachable from the gallery tray action.

## Gallery Design

The gallery screen uses a warm background, compact brand/header copy, two filter chip rows, and a 3-column rounded thumbnail grid. The date row starts with `今天` and offers `选择日期`; the format row supports multiple selection for `JPG`, `HEIF`, `RAW`, and `视频`, defaulting to `JPG` and `HEIF`.

Each thumbnail shows the preview image, a format badge, a selection circle, and download state. Files in `排队`, `下载中`, `保存中`, or `已保存` are not selectable again. Failed or idle files remain selectable. Selecting one or more files reveals a floating bottom download bar with `已选 N 张` and `下载原图`.

## Download Center Design

The download center is a grid-style status page, not a plain list. It shows queued, active, saved, and failed items using the same thumbnail tile style as the gallery, with progress where available.

## Connect Design

The connection page uses the same visual language: brand label, large title, status panel, black primary action, and quiet secondary actions.

## Testing

Add unit tests for gallery filter and download selection policy. Verify with `./gradlew testDebugUnitTest assembleDebug`, then install the debug APK to the connected Android device.
