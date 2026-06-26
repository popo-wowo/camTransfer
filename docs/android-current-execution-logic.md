# Android Current Execution Logic

更新日期: 2026-06-20

本文记录 Android 当前已经落地的连接、相册、下载和 UI 执行规则。后续改动应先对照本文和 `docs/android-official-xapp-connection-analysis.md`，保持“每一步确认后再进入下一步”和“稳定性优先”的原则。不要使用 iOS 实现或旧跨平台文档决定 Android 连接行为。

## 总原则

- 底层连接只保留一套官方协议适配逻辑；UI 可以提供更清晰的引导，但不能绕过步骤。
- Android 连接逻辑只以官方 Android XApp 分析和当前 Android 执行规则为准，不参考 iOS 代码路径。
- 每个阶段必须有明确依据后再进入下一阶段：BLE 身份确认、Wi-Fi 凭据确认、相机 AP ready、系统 Wi-Fi `Network` 可用、PTP 可打开。
- 正常进入相册链路不做无依据扫描、SSID 猜测或多候选串行试探。BLE 只允许围绕当前 `cameraID` 执行保存地址直连和原厂 `RE_CONNECT` 等价的受限扫描；失败说明当前步骤未满足，应停在对应步骤提示用户处理。
- 稳定性优先于速度。缓存和复用只能跳过已经被证明仍然有效的连接对象，不能跳过身份校验或 AP ready。

## 模块边界与分工

相机链路必须拆成四个互不反向影响的模块:

1. `Pairing`: 只负责原厂配对流程，读取并保存 `cameraID`、相机名、序列号、BLE endpoint、官方 `SSID`、`passphrase`、`MAC/BSSID`。配对模块不进入相册、不下载照片、不读取缩略图。
2. `Connection`: 只负责已配对相机进入传图/相册模式，严格执行原厂 BLE -> Wi-Fi -> PTP 顺序。连接模块不猜 Wi-Fi、不生成候选、不启动下载、不根据相册或下载结果回头改变连接策略。
3. `Gallery`: 只在连接成功后读取 object handles、ObjectInfo、缩略图、方向、筛选和排序。Gallery 失败只停在相册读取阶段，不能触发重新配对、重新扫描或修改 Wi-Fi 策略。
4. `Download`: 只在 Gallery 已有对象后执行下载和下载记录管理。Download 不能重启 BLE、不能重新选择 Wi-Fi、不能改变配对记录或连接主链路。

注册一致性预检是独立守卫，不属于 Wi-Fi/PTP 主链路:

- `RegistrationGuard`: 只负责在 App 启动、进入配对页、点击重新配对或进入相册前，检查本地配对记录、Android 系统蓝牙 bond 和扫描到的 BLE address 是否冲突。
- 该模块可以读取 `BluetoothAdapter.getBondedDevices()`，也可以在用户明确进入配对/重新配对时做短 BLE 扫描来拿到相机 `deviceAddress`。
- 该模块只输出三种结果: `pass`、`needsSystemBondCleanup`、`needsRePairing`。它不能直接推进 Wi-Fi/PTP，也不能修改 Gallery/Download 行为。
- 如果发现“扫描到的相机 BLE address 已存在于系统 bonded devices，但当前 App 没有可用的一致注册记录”，必须先提示删除系统蓝牙注册或执行一键重置，再允许正式配对。
- 如果预检通过，后续仍必须进入正常 `Pairing` 或 `Connection` 主链路，不能跳过 BLE/GATT 身份校验。

配对和连接内部的每一步也必须独立:

- 每一步只有明确输入、官方指令/API、成功条件、失败原因和输出。
- 步骤之间只能传递显式结果，不能共享隐式状态来偷偷推进。
- 当前步骤失败就停在当前步骤，不跨阶段兜底。
- 不允许出现“本次 BLE 没读到 Wi-Fi，就用旧 Wi-Fi 顶上”“AP 没 ready，先连 Wi-Fi 试试”“PTP 失败就重新配对/扫描”“按相机名猜 SSID/默认密码”等逻辑。
- 允许保留的工程胶水只有日志、状态展示、错误提示、Android API 封装和测试；这些不能改变原厂协议顺序，也不能增加额外分支。

## 配对阶段

配对入口负责让相机和手机建立可信记录:

1. 用户先确认相机进入配对注册界面。
2. App 先执行 `RegistrationGuard`。如果 BLE 扫描到的相机 `deviceAddress` 已存在于 Android 系统 `bondedDevices`，且当前 App 没有一致的可用注册记录，先提示删除系统蓝牙注册或执行一键重置。
3. 用户确认手机侧旧蓝牙记录已清理，避免系统 bond 干扰。
4. App 扫描并连接相机 BLE。
5. BLE handshake 读取相机身份、SSID、Wi-Fi passphrase、MAC/BSSID 等官方连接信息。
6. 手机确认配对后，需要向相机完成配对确认写入；相机侧必须能显示配对成功。
7. 本地按 `cameraID` 保存配对记录。

原厂 XApp 对“需要删除注册”的判断点:

- 官方 Android XApp 在 `PairingMode.PAIRING` 的 BLE 扫描阶段检测系统 bond 冲突。
- 判断条件是 `BluetoothAdapter.getBondedDevices()` 是否包含扫描到的相机 BLE `deviceAddress`。
- 弹框设备名只用于展示，不是身份判断条件。
- 该检测发生在 GATT 连接、Wi-Fi handover 和 PTP open 之前，因此我们的实现也必须作为配对前守卫处理，不能等 PTP 卡住后才提示重新配对。

当前身份模型:

- `cameraID` 是配对记录主键，优先使用 `serialNumber_deviceName`。
- 支持多台已配对相机；当前选中相机由 `selected_camera_id` 决定。
- BLE address 是 endpoint，不是相机身份。进入相册时必须用 `cameraID` 校验连接到的相机身份。

## 已配对进入相册

已配对相机启动状态:

- 打开 App 后，如果本地存在 remembered pairing 且注册一致性检查通过，可以按原厂 App 行为预连接当前相机 BLE/GATT，并把 UI 更新为“相机在线”。
- 启动在线预连接只允许建立并保留可复用 BLE 会话；不得写 `FunctionLaunchRequest`，不得启动相机 Wi-Fi，不得加入相机 Wi-Fi，不得连接 PTP，也不得启动 `CameraSessionKeepAlive`。
- 原厂 Android XApp 另有 `PeriodicFetchingInformationService` 低频周期任务: 已注册相机、无已连接相机、非 remote booting 时，每轮遍历注册相机并约 60 秒后再循环；单台相机还受 1800 秒信息刷新间隔、remote boot、standby 条件限制。它通过 `START_CONNECT` 做 BLE 重连和信息同步，不进入 Wi-Fi/PTP。我们若实现同类自动恢复在线，只能作为低频 BLE 状态刷新模块，不能自动启动相册 Wi-Fi/PTP。
- 用户点击进入相册时，如果启动预连接的 BLE 会话仍在 TTL 内且身份匹配，必须复用该会话继续后续主链路，不能再重复 `ReconnectPairedBle`。
- 如果启动在线预连接仍在进行中，进入相册先等待一个短接管窗口；预连接完成后复用其 GATT，会话仍未完成才取消并执行主链路 BLE 重连。不能在用户点击时立即取消正在进行的在线预连接。
- 如果会话已断开/过期/身份不匹配，才重新执行已配对 BLE 重连。

已配对相机进入相册的主链路:

1. `ReconnectPairedBle`: 先使用当前 `cameraID` 记录中的保存 BLE endpoint 候选直连。直连窗口为 5 秒；失败且当前记录有稳定 `serialNumber_deviceName` 身份时，再执行原厂 `PairingMode.RE_CONNECT` 等价的短扫描，只允许连接与当前记录匹配的候选；GATT 连上后必须重新读取并校验相机身份。无稳定身份时不扫描。
2. `TransferAuthorization`: GATT 连上后读取/确认相机身份和本次 BLE 返回的官方 Wi-Fi 凭据；身份不匹配或本次缺凭据就停止，不使用旧配对记录里的 Wi-Fi 作为主链路兜底。
3. `ActivateCameraWifi`: 按官方 BLE 写入顺序让相机启动相册 Wi-Fi/AP。
4. `WaitCameraWifiReady`: 等待 BLE AP/transfer ready，不靠固定长等待推进。
5. `JoinCameraWifi`: 使用唯一的精确 `SSID + passphrase + optional BSSID` 调 Android `WifiNetworkSpecifier` / `requestNetwork`。主链路只请求这个官方网络一次，不生成 FUJ 前缀候选，不用默认密码，不在内部循环 requestNetwork。
6. `ConnectPtp`: 在相机 Wi-Fi 对应 `Network` 上打开 PTP/IP；socket 必须绑定到相机 Wi-Fi Network。Wi-Fi 可用后立即尝试 PTP，不再固定等待 3 秒。X-T5 当前实机稳定路径先发送带本机 `192.168.0.x` 的 CameraVendor legacy INIT 变体；未 ACK 时再 fallback 到官方 XApp native 内置的 plain legacy INIT 模板，plain 模板 GUID 后 4 字节保持 `0`。Kotlin PTP open 窗口保持单次 socket connect 1.5 秒，最多 5 次，失败间隔 500ms/1000ms/1500ms...；INIT ACK 读取窗口 15 秒。
7. `LoadGallery`: PTP 连通后进入相册列表和缩略图读取。

连接耗时诊断:

- 每个官方连接步骤都会在诊断日志中记录 `Official gallery step confirmed step=... elapsedMs=...`。
- 如果用户反馈“连接慢”，先按 `ReconnectPairedBle`、`WaitCameraWifiReady`、`JoinCameraWifi`、`ConnectPtp` 四个阶段定位最大耗时，再决定优化点。

连接保活规则:

- `CameraSessionKeepAlive` 只能在 PTP/相册连接成功后启动，用于后台/锁屏期间维持已建立的相机 Wi-Fi 和 PTP 会话。
- 不允许在 `ReconnectPairedBle`、`TransferAuthorization`、`ActivateCameraWifi`、`WaitCameraWifiReady` 或 `JoinCameraWifi` 阶段提前启动保活，也不允许在 Wi-Fi handoff 前持有 `WifiLock`。
- 2026-06-20 实机 A/B 结论: 仅把 BLE/PTP 设备名从 `iPhone-6970` 改为安卓真实机型名时，进入相册仍可成功；仅把保活提前到 Wi-Fi handoff 前时，`requestNetwork` 对同一精确 `SSID + passphrase + BSSID` 连续 30 秒超时。因此 Wi-Fi 自动连接失败的根因收敛为“handoff 前启动保活/持有 Wi-Fi lock”，不是设备名。

BLE session 复用规则:

- 只允许复用还活着的 GATT。
- 必须仍有 transfer activation 所需 characteristic。
- 必须与当前选中 `cameraID` 匹配。
- 必须已经完成相机配对确认 ACK。
- 复用有 TTL；过期、断开、缺特征或身份不匹配时立即丢弃并走 `DirectAddress -> OfficialReconnectScan` 的已配对 BLE 重连顺序。
- `AP_STATE` 不缓存。每次进入相册仍要重新确认相机 AP ready。

## 相册列表和缩略图

相册首屏规则:

- 优先使用官方/厂商扩展拿到的 handle 列表发布占位网格，避免完整 `ObjectInfo` 枚举阻塞首屏。
- Android X-T5 实测不能把 `D604=31` 视为全格式。`D604=31` 只返回 `JPG + MOV` 的 `D621` 列表；必须额外设置 `D604=HEIF` 或 `D604=RAW` 并重新读取 `9053/D620/D621`，如果相机返回更大的列表，则把这个扩展列表作为初始占位符来源。
- 初始占位符必须保留相机返回的 `D621` 顺序，不要按 handle 数字倒序重排。同一天内 RAW/HEIF/JPG 可能以 `1267,1268,1265,1266...` 这种顺序出现，数字排序会破坏原厂时间线。
- 可见缩略图按需加载，保持受控节流，避免和 PTP metadata 命令抢通道。
- 如果完整信息后续补齐，应合并回现有列表并保留已加载缩略图。
- 列表缩略图走标准 `GET_THUMB`；标准缩略图不可用时记录失败，不再用 `GET_PARTIAL_OBJECT` 作为兜底。
- hidden gap probe 只作为扩展 `D621` 失败后的诊断/兜底，不是 RAW/HEIF 正式发现路径。

缩略图显示规则:

- 列表和下载中心共用展示前处理。
- 解码后根据 EXIF/object orientation 做展示旋转。
- 如果相机返回的缩略图边缘包含大面积纯黑 letterbox，展示前裁掉边缘黑条，再交给网格 `Crop`。
- 裁剪只处理边缘几乎整行/整列为黑色的条带，避免误裁正常暗部照片。

## 筛选和排序

当前筛选维度:

- 日期: 全部、今天、指定日期、日期范围。
- 格式: 全部格式、JPG、HEIF、RAW、视频。
- 排序: 最新、最早、未下载。

日期选择规则:

- 日期选择器不再依赖相机照片日期去重。
- 打开日期选择器不触发为了生成日期列表的完整 metadata 加载。
- 默认提供从今天往前约 5 年的日期供直接选择。
- 如果选择日期没有照片，页面显示“当前筛选没有照片”，不把这视为错误。

## 下载和下载中心

下载中心展示来源:

- 当前下载队列。
- 已完成下载记录。
- 持久化下载历史。

下载记录规则:

- `清理记录` 只清理 App 内下载记录和已下载标记，不删除相机照片，也不删除手机相册里的媒体文件。
- 下载历史持久化 `ObjectInfo` 和缩略图 bytes。旧版本记录可能没有缩略图，仍兼容读取，但只能显示占位。
- 新下载完成的记录应保留缩略图，重新进入下载中心也能显示。

下载模式:

- `压缩` 是下载前的相机侧压缩/resize 选择。BLE `ImageResizeSetting(82A9F452)` 只保留为相机全局/初始状态来源；真正生效的本次选择在 Wi-Fi PTP 下载前通过 `D22E/D226` 写入。
- `下载` 是执行动作，视觉上保持主按钮；压缩开关保持次级样式，避免和下载按钮混淆。
- 点击下载时会把当前模式写入下载队列项；队列执行中不再读取可变全局偏好，避免用户切换开关后影响已入队任务。
- 原图模式按原厂下载前切换：`D226 ImageForceCompression=2 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT -> D226=0`。
- 压缩模式按原厂下载前切换：`D22E ObjectCompressionSetting=1 -> D226 ImageForceCompression=1 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT -> D226=0`。
- `D226/D227/D22E` 的 PTP payload 使用 `UINT16`。原厂 native 里的 `FTL_PTP_DATA_TYPE=0x0004` 在这里对应 PTP `UINT16`，实机读取 `D226/D227` 也返回 2 bytes。不要按 4-byte integer 写这些属性。
- 连接前 BLE `ImageResizeSetting` 只作为相机全局设置/初始状态来源，不再作为本次下载选择原图或压缩的唯一依据。
- `D227 ImageCompressionRealInfo` 仍在图库初始化时复位，但不再作为 Android 下载主链路里的模式切换开关。
- 压缩下载不是缩略图下载；原图下载也不能落到缩略图缓存。两种模式都必须在写入模式后重新读取 `ObjectInfo`，再按 fresh size 走 `GET_PARTIAL_OBJECT`。
- 下载日志必须能同时看到 `Download mode prepare` 的 property/response 和后续 `Download partial` 的 `freshSize/readSize`。如果 response 成功但 fresh size 仍是几百 KB，说明协议状态或尺寸读取还没有复刻成功，不能用缩略图结果当成功。
- 如果下载过程中出现 `Socket is closed`、`Not connected to camera`、`Connection reset` 等连接失效错误，停止剩余队列并把后续 pending 项标记为需要重新进入相册后重试。

## UI 结构

相机相册页:

- 顶部: 左返回图标，中间 `CAMERA GALLERY`，右下载中心图标。
- 筛选/排序: 圆润浮层 + 小胶囊控件，和顶部、底部工具条保持统一。
- 网格: 每行固定列数，缩略图圆角统一；选择状态用圆形选择点。
- 底部浮层: 默认显示；左侧圆形全选控件，中间 `已选 x / 共 y 张`，右侧压缩开关和下载按钮。

下载中心:

- 顶部: 左返回图标，中间 `DOWNLOADS`，右侧文字按钮 `清理记录`。
- 不使用垃圾桶图标表示清理记录，避免用户理解为删除照片。
- 缩略图展示与相册页保持一致的裁剪和旋转规则。

连接首页:

- 页面顶部对齐，不再垂直居中导致上方大留白。
- 已配对状态只展示配对信息、下载模式、进入相机相册、重新配对/诊断/断开/有线导入等必要操作。

## 验证要求

代码合入或推送前至少执行:

```bash
./gradlew testDebugUnitTest assembleDebug
```

需要实机验证的项目:

- 已配对进入相册是否严格按当前 `cameraID` 直连。
- 相机 AP ready 后 Wi-Fi handoff 是否进入目标 SSID。
- 相册首屏是否能显示缩略图且没有明显黑边。
- 日期筛选能直接选择任意日期，且空结果展示正确。
- 下载中心新下载记录重新进入后仍显示缩略图。
