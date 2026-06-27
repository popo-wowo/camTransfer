# iOS Android Architecture Parity Design

更新日期: 2026-06-23

## 目标

iOS 相机链路必须按 Android 当前文档重建模块边界和上层编排。UI 不再直接操作 BLE、Wi-Fi、PTP 或下载实现；所有入口统一走 iOS 编排层。每个模块只能做自己的事情，失败时停在当前阶段，不跨阶段兜底。

本设计以 `docs/android-current-execution-logic.md` 为唯一执行标准。旧 iOS 路径只能作为协议代码迁移来源，不能作为流程标准。

## 模块边界

### RegistrationGuard

职责:

- 在 App 启动、进入配对、重新配对、进入相册前执行一致性校验。
- 输入本地配对记录、当前扫描到的 BLE endpoint、iOS 可获得的系统/外设状态。
- 输出 `pass`、`needsSystemBondCleanup`、`needsRePairing`。

禁止:

- 不推进 Wi-Fi/PTP。
- 不读取相册。
- 不修改 Gallery 或 Download 行为。

### Pairing

职责:

- 执行官方配对流程。
- 扫描并连接相机 BLE。
- BLE handshake 读取 `cameraID`、相机名、序列号、BLE endpoint、官方 `SSID`、`passphrase`、`MAC/BSSID`。
- 完成手机确认写入。
- 按 `cameraID` 保存配对记录。

禁止:

- 配对完成后不自动进入相册。
- 不启动下载。
- 不读取缩略图。

### Connection

职责:

- 只负责已配对相机进入相册主链路。
- 输入当前 `cameraID` 的配对记录和底层 BLE/Wi-Fi/PTP 能力。
- 输出已打开的 PTP gallery session。

步骤必须固定:

1. `ReconnectPairedBle`
2. `TransferAuthorization`
3. `ActivateCameraWifi`
4. `WaitCameraWifiReady`
5. `JoinCameraWifi`
6. `ConnectPtp`
7. `LoadGallery`

规则:

- 不猜 SSID。
- 不使用默认密码。
- 不在 BLE 缺本次官方 Wi-Fi 凭据时用旧记录顶上。
- 不在相册页里再决定 Wi-Fi 策略。
- 不允许 PTP 失败后回头重新配对或重新扫描。

### Gallery

职责:

- 只在 Connection 成功后读取相册数据。
- 先发布 handle 占位网格，再后台补完整 `ObjectInfo`。
- 可见缩略图按需加载。
- 列表缩略图只用 `GET_THUMB`，失败只记录失败，不用 `GET_PARTIAL_OBJECT` 兜底。
- 负责日期、格式、排序状态。

禁止:

- 不重连 BLE。
- 不切 Wi-Fi。
- 不修改配对记录。
- 不启动下载主链路之外的连接策略。

### Download

职责:

- 基于 Gallery 已有对象下载原图或压缩图。
- 管理当前队列、已完成记录、持久化下载历史。
- 持久化 `ObjectInfo` 和 thumbnail bytes。
- `清理记录` 只清理 App 内下载历史和已下载标记，不删除相机文件或手机相册文件。

禁止:

- 不重启 BLE。
- 不重新选择 Wi-Fi。
- 不修改配对记录或连接策略。

## iOS 文件结构

新增目录:

```text
ios/Runner/CameraCore/
  Models/
  Registration/
  Pairing/
  BLE/
  Connection/
  WiFi/
  PTP/
  Gallery/
  Download/
  Orchestration/
  Diagnostics/

ios/Runner/UI/
  Home/
  Pairing/
  Gallery/
  Downloads/
```

第一阶段先建立可编译的核心模型、接口和纯逻辑模块。第二阶段把 `CameraVendorBluetoothService.swift` 里的真实 BLE/PTP 实现迁移进这些接口。第三阶段把 UIKit 页面改成只调用编排层。

## 上层编排

新增 `CameraAppFlowCoordinator`，作为 UI 唯一入口:

- `startApp()`
- `startPairing()`
- `rePair(cameraID:)`
- `enterCameraGallery(cameraID:)`
- `loadGallery()`
- `startDownload(handles:)`
- `openDownloadCenter()`
- `clearDownloadRecords(cameraID:)`

编排器负责:

- 在入口先调用 `RegistrationGuard`。
- 串联 Pairing、Connection、Gallery、Download。
- 记录每一步诊断日志。
- 把结构化状态交给 UI/ViewModel。

编排器禁止:

- 不直接实现 BLE 指令。
- 不直接解析 PTP object。
- 不直接保存图片到系统相册。

## UI 对齐

首页:

- 顶部对齐。
- 已配对状态展示配对信息、下载模式、进入相机相册、重新配对/诊断/断开/有线导入。
- 发现相机和配对入口必须放在上方主区域，不藏在底部或 modal 里。

相册:

- 顶部左返回图标，中间 `CAMERA GALLERY`，右下载中心图标。
- 筛选/排序支持日期全部/今天/指定日期/日期范围，格式全部/JPG/HEIF/RAW/视频，排序最新/最早/未下载。
- 底部浮层默认显示，包含全选、`已选 x / 共 y 张`、压缩开关、下载按钮。

下载中心:

- 顶部左返回图标，中间 `DOWNLOADS`，右文字按钮 `清理记录`。
- 不用垃圾桶图标表示清理记录。
- 缩略图展示复用 Gallery 的裁剪和旋转策略。

## 迁移策略

1. 新建 Swift 核心模型和接口，不改变旧 UI 行为。
2. 增加测试锁住 Android 顺序和模块边界。
3. 建立 `CameraAppFlowCoordinator`，用 mock adapter 跑通编排。
4. 把旧 BLE pairing/connection 入口包成 adapter，接入编排器。
5. 把 Gallery state/filter/thumbnail/download history 从大文件迁出。
6. 改 UIKit 页面，使按钮只调用编排层。
7. 删除旧路径中的猜 SSID、默认密码、相册页 Wi-Fi 决策、`GET_PARTIAL_OBJECT` 缩略图兜底。

## 验证

最小自动验证:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS'
```

实机验证:

- 首次打开 App 执行 RegistrationGuard。
- 发现相机后配对入口在首页上方。
- 配对完成后停在已配对状态，不自动进相册。
- 点击进入相机相册前完成连接主链路。
- 相册首屏先出现占位，缩略图按可见项加载。
- 下载中心重进后仍显示持久化历史和缩略图。
