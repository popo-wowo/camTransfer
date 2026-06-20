# Camera Module Architecture Design

更新日期: 2026-06-19

## 目标

将相机链路拆成长期可演进的独立模块。后续优化配对、连接、相册、下载中的任意一个模块时，不能反向影响其它模块。连接模块内部也必须按原厂步骤拆成独立节点，方便定位失败环节并给用户明确动作。

## 模块边界

### Pairing

职责:

- 执行原厂配对流程。
- 扫描 BLE 相机、建立初始 GATT。
- 读取并保存 `cameraID`、相机名、序列号、BLE endpoint、官方 `SSID`、`passphrase`、`MAC/BSSID`。
- 完成相机 pairing ACK。

禁止:

- 不进入相册。
- 不启动相机 Wi-Fi。
- 不打开 PTP。
- 不读取缩略图或下载文件。

### Connection

职责:

- 只负责已配对相机进入传图/相册模式。
- 输入是当前配对记录和必要的底层适配器。
- 输出是已打开的 PTP 相册会话。
- 严格执行原厂步骤，不猜 SSID，不用默认密码，不跨阶段兜底。

连接步骤必须拆成独立 runner:

1. `ReconnectPairedBleStep`: 使用当前 `cameraID` 的保存 BLE endpoint 直连；直连失败后，只有稳定身份时才执行原厂 `RE_CONNECT` 受限扫描。输出已校验身份的 BLE handshake。
2. `TransferAuthorizationStep`: 通过 BLE 确认当前手机允许传图，并读取本次官方 Wi-Fi 凭据。输出唯一官方 Wi-Fi 配置。
3. `ActivateCameraWifiStep`: 写原厂传图/相册启动指令，启动相机 AP。
4. `WaitCameraWifiReadyStep`: 等待相机 AP/transfer ready，不用固定等待替代 ready 信号。
5. `JoinCameraWifiStep`: 使用唯一官方 `SSID + passphrase + optional BSSID` 让 Android 加入相机 Wi-Fi。
6. `ConnectPtpStep`: 在相机 Wi-Fi 对应 `Network.socketFactory` 上打开 PTP。
7. `ConfirmGalleryModeStep`: PTP 成功后确认相机处于相册模式。
8. `LoadGalleryStep`: 只读取相册 handle 数量，确认相册入口可用。

每个步骤都有:

- 明确输入类型。
- 明确输出类型。
- 明确 `CameraConnectionStep`。
- 失败时只暴露当前步骤的失败，不调用其它步骤。

禁止:

- BLE 失败后直接连 Wi-Fi。
- Wi-Fi 失败后重新配对。
- PTP 失败后重新扫描 BLE。
- LoadGallery 失败后修改连接策略。

### Gallery

职责:

- 只在连接成功后读取相册数据。
- 读取 handles、ObjectInfo、缩略图、方向、筛选和排序。
- 提供 `CameraFileSource` 给 UI 和 Download 使用。

禁止:

- 不重新配对。
- 不重连 BLE。
- 不切换 Wi-Fi。
- 不修改配对记录或连接策略。

Gallery 内部也必须继续拆成独立功能模块，上层按场景组合调用，不能把所有能力混到一个大接口、一个大 ViewModel 或一个大 UI 文件里。

终态模块:

1. `GalleryRoute`: 相册页面入口，只收集 state、分发 UI intent、组合子组件。
2. `GalleryGrid`: 只负责网格布局、可见 item、列数，不读取相机。
3. `GalleryGridItem`: 只负责单张照片格子的显示和点击，不调度缩略图。
4. `GalleryPreview`: 只负责全屏预览展示、翻页、旋转、预览选择按钮，不直接读取原图。
5. `GalleryDownloadBar`: 只负责底部选择、全选、下载入口，不知道相机协议。
6. `GalleryFilterPanel`: 只负责筛选、排序、日期选择，不触发连接。
7. `GalleryGestures`: 只负责缩放列数、滑动多选、自动滚动策略。
8. `GalleryImageDecode`: 只负责 Bitmap decode、采样、旋转和 EXIF/方向处理。
9. `GalleryFilesController`: 只负责初始 handles、完整 ObjectInfo、文件列表刷新。
10. `GalleryThumbnailController`: 只负责缩略图队列、可见项优先、缓存和取消。
11. `GalleryPreviewController`: 只负责预览图/原图显示数据、预览缓存和清晰度策略。
12. `GallerySelectionController`: 只负责单选、多选、全选、滑动范围选择。
13. `GalleryRequestScheduler`: 只负责相机读取请求的统一调度、优先级、串行化和取消。
14. `GalleryCameraSource`: 只定义相册数据读取能力，具体实现可以是 `PtpCameraGallerySource` 或有线相机 source。

模块调用规则:

- UI 只能调用 ViewModel 暴露的 intent，不能直接调用 `CameraFileSource`、`PtpCommands`、`PtpConnection`。
- ViewModel 只组合 controllers 和 state，不内联缩略图队列、预览缓存、图片解码、手势算法。
- Controllers 之间不能互相偷偷调用相机；所有相机读取必须走 `GalleryRequestScheduler`。
- `GalleryThumbnailController` 只能请求缩略图，不能读取预览图或原图。
- `GalleryPreviewController` 只能请求预览图/原图显示数据，不能控制网格缩略图队列。
- `GallerySelectionController` 只维护 handle 集合，不关心图片数据、下载状态以外的协议细节。
- `GalleryImageDecode` 只处理字节到显示 bitmap 的转换，不发起任何相机请求。
- `GalleryRequestScheduler` 只调度相册读取请求，不参与 UI 状态、不保存配对信息、不改变连接策略。
- `PtpCameraGallerySource` 是 PTP 相册读取实现，只负责把命令结果转成相册数据，不知道 UI 选择、排序、下载按钮。

相机读取优先级:

1. Download/original transfer: 下载和保存时优先，避免被缩略图抢占 PTP。
2. Preview/original display: 用户打开全屏预览时优先于网格缩略图。
3. Visible thumbnails: 当前屏幕可见缩略图优先。
4. Neighbor preview thumbnails: 全屏预览相邻页缩略图次之。
5. Background metadata: 完整 ObjectInfo、日期筛选补全等后台读取最后执行。

禁止:

- 不允许 UI 为了加速显示直接绕过 scheduler 调相机。
- 不允许下载、预览、缩略图各自维护独立并发请求去抢 PTP。
- 不允许排序或筛选逻辑触发重新连接。
- 不允许预览清晰度优化修改缩略图加载策略。
- 不允许缩略图加载优化修改原图下载策略。
- 不允许把多个功能塞进一个 `GalleryManager`、`GalleryRepository` 或新的巨大接口里。

### Download

职责:

- 只基于 `CameraFileSource` 下载文件。
- 保存到系统相册。
- 维护下载记录和下载中心。

禁止:

- 不知道 BLE/Wi-Fi/PTP 连接细节。
- 不重启相机传图模式。
- 不修改配对记录。

## Facade

`CameraService` 保留为 app facade，负责兼容现有 ViewModel 调用:

- `pairWithCamera()`
- `confirmPairing()`
- `connectPairedCameraToGallery()`
- `rememberedPairing()`
- `pairedCameras()`
- `selectPairedCamera()`
- `forgetPairing()`
- `CameraFileSource` 委托

`CameraService` 不再直接承载协议步骤实现，只组装并委托给模块。

## 错误模型

Connection 每个步骤失败都应映射到结构化 `CameraConnectionIssue`:

- `ReconnectPairedBle`: 提示打开相机蓝牙/进入连接或传图准备状态，必要时重新配对。
- `TransferAuthorization`: 提示当前配对未完成或相机未授权本手机传图。
- `ActivateCameraWifi`: 提示相机没有进入传图模式。
- `WaitCameraWifiReady`: 提示相机 Wi-Fi/AP 没准备好。
- `JoinCameraWifi`: 提供官方 SSID/password，让用户手动加入相机 Wi-Fi。
- `ConnectPtp`: 提示不是重新配对能解决，建议退出并重新进入传图模式或重启相机。
- `ConfirmGalleryMode`: 提示相机 PTP 已连上但未进入相册模式。
- `LoadGallery`: 提示已进入相册通道但列表读取失败。

UI 不应从普通字符串反推连接步骤。状态文案可以存在，但真实控制流以 step runner 和 `CameraConnectionStep` 为准。

## 验证

必须保留并扩展测试:

- 连接步骤顺序测试。
- 每个 connection step runner 的 step id 测试。
- Gallery 只依赖 `CameraFileSource`，不依赖 BLE/Wi-Fi。
- Download 只依赖 `CameraFileSource` 和 `GalleryService`。
- `CameraService` facade 委托测试或源码边界测试。

最小验证命令:

```bash
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew installDebug
```
