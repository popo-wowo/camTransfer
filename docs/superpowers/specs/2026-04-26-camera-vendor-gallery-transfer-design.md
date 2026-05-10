# CameraVendor Gallery Transfer Design

**Date:** 2026-04-26

## Goal

在现有原生 iOS 蓝牙配对成功的基础上，补齐 CameraVendor DEVICE-A 的图库浏览与照片传输 MVP：
- 展示相机照片列表
- 支持缩略图预览
- 支持单张下载
- 支持多选批量下载

## Confirmed Constraints

- BLE secure pairing 已经在真机上完成并有日志证据。
- 富士图库与文件下载不走 BLE 主通道，核心链路是 Wi-Fi + PTP/IP。
- 当前 iOS 页面只有搜索、连接、日志，没有图库页。
- 当前仓库不是 git repo，因此本次只在工作区内保存设计和计划文档，不执行 commit。

## Recommended Approach

推荐采用三层 MVP 架构：

1. `CameraVendorBluetoothService`
负责 BLE 搜索、连接和 secure handshake，提供“握手已完成”的入口。

2. `CameraVendorGallerySession` / `CameraVendorGalleryState`
负责图库会话、照片列表状态、选择状态、下载状态。先把这些做成可单元测试的纯 Swift 逻辑，避免调试时把 UI、网络、协议混在一起。

3. `NativeGalleryViewController`
负责列表展示、缩略图请求、单张下载、多选下载与进度反馈。

## Scope for This MVP

- 先打通从连接页进入图库页的主流程。
- 图库页先用列表实现，不追求复杂视觉。
- 单张下载与多选下载先支持顺序队列，保证稳定性。
- 缩略图与文件下载统一通过图库服务接口调用，底层后续逐步替换为完整 CameraVendor Wi-Fi PTP 实现。

## Out of Scope

- RAW 在线解码大图预览
- 后台断点续传
- 并行多文件下载优化
- 相机远程控制

## Data Model

- `CameraVendorGalleryItem`
  包含 handle、文件名、格式、拍摄时间、尺寸、缩略图状态、下载状态。

- `CameraVendorGalleryState`
  包含 items、selectedHandles、isLoading、activeDownloads、errorMessage。

- `CameraVendorDownloadTask`
  表示单个下载项的状态：idle / queued / downloading / saved / failed。

## User Flow

1. 用户在连接页完成 CameraVendor BLE 握手。
2. App 进入图库页。
3. 图库页尝试建立 Wi-Fi 图库会话。
4. 拉取对象列表并展示。
5. 列表项逐个触发缩略图加载。
6. 用户可点击单张下载，也可进入多选后批量下载。

## Error Handling

- Wi-Fi/PTP 未连通时，图库页显示明确错误，而不是无限转圈。
- 缩略图失败不阻塞列表展示。
- 单个文件下载失败不应中断整个批量队列，失败项单独标记。
- 保存到系统相册失败时，保留错误信息并停止将该项标记为成功。

## Testing Strategy

- 先为纯 Swift 状态层写测试：
  - 选择/取消选择
  - 全选/清空
  - 下载排队和完成状态
  - 单个失败不污染其他项
- 再把控制器接到这些状态对象上，尽量让 UI 层只做绑定和事件转发。

## Implementation Notes

- 参考现有 Android 代码中的 `ObjectInfo`、选择逻辑和下载队列，但不机械照搬。
- 参考 `fudge` 的图库顺序：对象列表、缩略图、文件下载。
- 本轮先把 iOS 架构和交互打通；底层 Wi-Fi PTP 若仍未完全可用，也要把接口与 UI 先准备好，方便下一轮直接接入真实传输。
