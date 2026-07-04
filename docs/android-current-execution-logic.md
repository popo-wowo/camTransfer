# Android Current Execution Logic

更新日期: 2026-07-04

本文记录 Android 当前已经落地的连接、相册、下载和 UI 执行规则。后续改动应先对照本文和 `docs/android-official-xapp-connection-analysis.md`，保持“每一步确认后再进入下一步”和“稳定性优先”的原则。不要使用 iOS 实现或旧跨平台文档决定 Android 连接行为。

## 当前稳定回滚点

- 分支: `codex/android-raw-d621-diagnostics`
- 稳定 tag: `android-stable-20260704-thumbnail-hd-raw-fix`
- 提交: `db6ce45 Stabilize Android gallery preview loading`
- 实机状态: 2026-07-04 Android 手机 + X-T5 测试确认进入相册速度恢复、缩略图恢复显示、高清预览模式下 `加入 RAW` 不再按普通 HEIF/JPG 候选入队。
- 本 tag 之后继续小步迭代；每个 P0/P1 改动必须可单独回滚。

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

`LoadGallery` 当前已确认的 `9053` 规则:

- `9053 GetSpecifiedObjectCountGroupByDate` 的职责是按当前搜索条件返回“每个日期有多少张”，它不是缩略图接口，也不是文件下载接口。
- 进入图库卡在“正在读取相机照片数量”时，应先看 `9050 -> D22B -> 9053 -> D620 -> D621` 这条链是否完整，而不是先怀疑配对、Wi-Fi 或 PTP open。
- 2026-07-02 X-T5 实机日志已证明：旧 Kotlin 代码把 `9053` 首包按普通 legacy data packet 处理会误读包边界，随后把 UTF-16 日期字符串字节当成“下一包头”，最终 `Read timed out`。
- 本次成功进入图库的修复点不是改主链路，而是修正 `9053` 首包 framing：该首包带有额外嵌套的 legacy envelope，必须先完整读出，再解出内层 payload。
- 旧“稳定版”并不是主链路坏了，而是一直带着这个潜在 `9053` 解包缺陷；当相机返回到这类首包 shape 时，同样会卡在照片数量阶段。
- `9054/9055` current-image context prime 不属于首屏必需数据；如果它们和首屏稳定性冲突，Android 主链路应直接进入 `9050 -> D22B -> 9053 -> D620 -> D621`，不要让这两个可选 prime 挡住进入相册。
- 2026-07-03 X-T5 + Android 实机再次确认：在当前设备环境里，`9054` 与 `9055` 连续各超时 7 秒、`9050` 再超时 15 秒，会把“正在读取相机照片数量”阶段整体拖到约 29 秒并最终失败；移除阻塞路径里的 `9054/9055` 后，可以恢复进入相册。
- 因此 Android 主链路当前规则是：`9054/9055` 只保留为诊断/可选 prime，不再作为进入相册前的必经阻塞步骤。首屏真正必需的是 `9050 -> D22B -> 9053 -> D620 -> D621`，以及必要的 `HEIF/RAW` 扩展 `9053/D620/D621`。

连接耗时诊断:

- 每个官方连接步骤都会在诊断日志中记录 `Official gallery step confirmed step=... elapsedMs=...`。
- 如果用户反馈“连接慢”，先按 `ReconnectPairedBle`、`WaitCameraWifiReady`、`JoinCameraWifi`、`ConnectPtp` 四个阶段定位最大耗时，再决定优化点。
- 2026-07-03 当前样本的进入相册耗时主要分布是：
  - `ReconnectPairedBle`: 约 `9877 ms`（直连 BLE 失败后走短扫描成功）
  - `WaitCameraWifiReady`: 约 `5974 ms`
  - `JoinCameraWifi`: 约 `4999 ms`
  - `ConnectPtp`: 约 `104 ms`
  - `ConfirmGalleryMode`: 约 `451 ms`
- 所以“现在还能进但还是慢”时，优先看 BLE 重连、相机 AP ready、系统 Wi-Fi handoff，再看 `9050/9053`；不要先怀疑缩略图线程或下载逻辑。

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
- 进入相册前的阻塞路径只允许保留这一次基线读取和必要的 `HEIF/RAW` 扩展读取；`JPG/MOV/MP4` 额外格式轮询、标准 `GetStorageIDs/GetObjectHandles` 诊断、SearchMode restore/快照读取都不能混进首屏主链路。
- `9054/9055` current-image prime 也不能再挡在首屏前；它们是否成功，不影响首批占位符和后续 `D621` handle 列表生成。
- 2026-07-02 实机进一步确认：`D604=31` 的基线 `9053` 已能稳定走通并继续到 `D620/D621`；但切到 `D604=HEIF` 或 `D604=RAW` 后，`9053` 还会出现第二种首包 shape（当前日志样本 `length=664`），这属于扩展列表阶段的后续协议问题，不是“进不去图库”的主 blocker。
- 初始占位符必须保留相机返回的 `D621` 顺序，不要按 handle 数字倒序重排。同一天内 RAW/HEIF/JPG 可能以 `1267,1268,1265,1266...` 这种顺序出现，数字排序会破坏原厂时间线。
- 可见缩略图按需加载，保持受控节流，避免和 PTP metadata 命令抢通道。
- 如果完整信息后续补齐，应合并回现有列表并保留已加载缩略图。
- 列表缩略图走标准 `GET_THUMB`；标准缩略图不可用时记录失败，不再用 `GET_PARTIAL_OBJECT` 作为兜底。
- hidden gap probe 只作为扩展 `D621` 失败后的诊断/兜底，不是 RAW/HEIF 正式发现路径。

缩略图显示规则:

- 2026-07-04 当前稳定规则: 列表缩略图不再使用 `9054` current-image context prime 作为必经步骤；但 `GET_THUMB` 前仍会先执行标准 `GET_OBJECT_INFO(handle)`，用于拿到当前对象信息并让标准缩略图读取保持稳定。
- 这个步骤和首屏 `LoadGallery` 不同：它发生在单个缩略图按需加载时，不阻塞进入相册；不要把它重新挪回 GalleryReady 前。
- 列表和下载中心共用展示前处理。
- 解码后根据 EXIF/object orientation 做展示旋转。
- 如果相机返回的缩略图边缘包含大面积纯黑 letterbox，展示前裁掉边缘黑条，再交给网格 `Crop`。
- 裁剪只处理边缘几乎整行/整列为黑色的条带，避免误裁正常暗部照片。

## 高清预览模式

高清预览模式是 Gallery 内部浏览模式，不属于连接主链路:

- 进入相册后可以在 `缩略图` 和 `高清预览` 两种模式之间切换；切换模式不重连 BLE、不重开 Wi-Fi、不重启 PTP。
- 进入高清预览模式时，`GalleryFilesController` 和 `GalleryThumbnailController` 会进入独占暂停，避免后台 metadata 或缩略图抢占 PTP。
- 高清预览读取使用原厂已确认的 screen preview 路径: `D226 ImageForceCompression=1 -> GET_OBJECT_INFO(handle) -> GET_PARTIAL_OBJECT(handle, 0, fresh compressedSize) -> D226=0`。
- 高清预览 session 默认按日期构建，一次只激活一个日期；加载优先级按当前可见窗口，而不是无脑从头扫到底。
- UI 上每张高清预览项可以加入普通显示图下载；如果同一照片有 RAW sidecar，则提供单独 `加入 RAW` 按钮。
- `加入 RAW` 只允许把 RAW-only 候选或已解析 RAW 文件加入下载队列。对于初始阶段 HEIF/RAW 都未解析出来的模糊占位符，当前稳定规则是把显示图候选标为 `HEIF` hint，把 RAW 侧车候选标为 `RAW` hint，避免 RAW 下载被普通 HEIF/JPG 候选污染。
- RAW-only 候选进入下载队列后强制使用原图模式；用户当前选择压缩也不能把 RAW 侧车按压缩图下载。
- 诊断日志 `HD preview session ... rawPairs=preview[hints]->raw[hints]` 用于确认前几个预览项和 RAW sidecar 的配对，不作为业务逻辑输入。
- 预览读取被取消时不能标记为失败；取消通常来自切换模式、切日期或下载独占暂停。
- 大尺寸 JPEG 缺 EOI 但仍可解码的相机预览不会直接失败；明显过小且不完整的数据必须拒绝缓存，避免黑图被标记为已加载。

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

## 当前风险和待确认清单

更新日期: 2026-07-04

这部分记录当前 Android 分支后续必须持续处理的问题。处理顺序按 P0/P1/P2 走；每次改动都要补日志证据、测试结果和实机现象，不能靠猜测删除或新增主链路逻辑。

### 持续问题台账

后续每次处理问题，都先更新这张台账，再更新下面的详细规则。状态只允许写:

- `open`: 已确认存在或有高风险，尚未闭环。
- `measuring`: 已加日志或测试，等待实机证据。
- `fixing`: 正在修改。
- `verified`: 已通过测试和实机现象验证。
- `deferred`: 暂缓处理，且必须写清楚原因。

| ID | 级别 | 状态 | 问题 | 当前依据 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| A-P0-01 | P0 | measuring | `Connect -> GalleryReady` 主链路必须保持最小阻塞路径，不能混入诊断、兜底、标准枚举或 UI 重入修复。 | 当前文档已确认首屏只允许 BLE/Wi-Fi/PTP 和 `9050 -> D22B -> 9053 -> D620 -> D621`，加必要 `D604=HEIF/RAW` 扩展。 | 用 `GalleryStartup step=... elapsedMs=...` 证明每一步耗时和失败率；无收益步骤移出阻塞路径。 |
| A-P0-02 | P0 | verified | `D222 current handle snapshot` 是否还在挡首屏，需要确认。 | 2026-07-04 已把 `D222-current-handle-snapshot` 从阻塞启动路径降级为非阻塞诊断；当前稳定 tag 实机确认进入相册速度恢复。 | 保持非阻塞；除非有原厂阶段证据和实机收益，不得重新放回 GalleryReady 前。 |
| A-P0-03 | P0 | measuring | `9050 SearchModeDescAll` 重试可能拖慢进入相册。 | 当前对 `0x2019` 有最多 3 次重试和 500ms/1000ms 等待。 | 统计 `SearchModeDescAll attempt` 和 retry 日志；只有证明能提高成功率才保留。 |
| A-P0-04 | P0 | verified | HEIF/RAW 必须在初始占位符阶段出现，不能靠 hidden gap 猜 handle。 | X-T5 实测 `D604=31` 不是全格式；当前稳定 tag 使用 `D604=HEIF/RAW -> 9053/D620/D621` 扩展列表并保留 D621 原始顺序，实机确认 HEIF/RAW 初始显示恢复。 | 持续保留日志观察扩展列表耗时；hidden gap 仍只能做诊断/兜底。 |
| A-P0-05 | P0 | measuring | 下载必须独占 PTP；下载期间不能继续缩略图、metadata、高清预览请求。 | 代码检查确认直接下载和队列启动都走 `prepareGalleryLoadingForTransfer()`，会暂停 files/thumbnail/preview；测试覆盖 HD 卡片只入队、底部统一开始下载。 | 实机继续验证下载页期间是否还有 `Thumbnail request`、`Preview image request`、`Resolve file metadata` 日志。 |
| A-P0-06 | P0 | measuring | 缩略图模式、高清预览模式、下载模块要共享同一下载队列和同一互斥门。 | 缩略图、单图预览和 HD 预览下载入口都进入同一个 `TransferViewModel`/`TransferService`，HD 单卡只入队，`onStartQueuedDownloads` 统一启动。 | 实机验证两种模式混合入队后下载顺序、模式快照和失败停止队列是否一致。 |
| A-P1-01 | P1 | open | 后置完整 `ObjectInfo` 补齐不能影响首屏和下载。 | `fastInitialFiles()` 应只发 D621 占位符；完整信息、标准枚举和 hidden metadata 都应低优先级。 | 标记 `galleryObjectInfos()` 的 Android用途，移除或隔离 `iOS logic` 标注分支对首屏/下载的影响。 |
| A-P1-02 | P1 | measuring | 缩略图可见窗口需要适配缩放、筛选、快速滚动，不能因为列数变化卡住几个不加载。 | `GalleryThumbnailRequestWindowPolicy` 已按真实 visible handles 和当前 `columnCount` 计算窗口，并覆盖 stale visible/fallback 测试。 | 实机继续压测缩放、筛选、快速滚动是否还会留下不加载空洞。 |
| A-P1-03 | P1 | measuring | 筛选不能依赖“已经加载出缩略图”的项目。 | `GalleryUiPolicy.matchesFormat()` 对 `UNDEFINED` 占位符使用 `formatHints`，筛选不依赖缩略图缓存。 | 实机继续验证视频/RAW/HEIF 在缩略图未加载前是否能筛出占位符。 |
| A-P1-04 | P1 | measuring | 高清预览必须按当前浏览位置优先加载，而不是一路向下扫。 | `HighDefinitionPreviewSession.prioritizeVisibleHandles()` 已按可见 handles 构建 active window：当前可见优先，后 20、前 5；测试覆盖向下和向上滚动。 | 实机继续观察快速滚动/切日期后是否从当前屏幕开始加载。 |
| A-P1-05 | P1 | verified | 高清预览取消不能写成失败，也不能把黑图/半图标记成已加载。 | 当前稳定 tag 已单独处理 `CancellationException`，并只拒绝明显过小的不完整 JPEG；实机未再复现黑图卡死。 | 继续用日志观察 `Preview image missing JPEG EOI` 和取消场景，不把取消计入失败。 |
| A-P1-06 | P1 | verified | 高清预览的 RAW sidecar 只能作为同一照片的下载按钮，不能重排 D621 时间线。 | 当前稳定 tag 已把模糊 HEIF/RAW 配对后的显示图标为 `HEIF` hint、RAW 侧车标为 `RAW` hint，并加入 `rawPairs` 日志；实机确认 `加入 RAW` 看起来正常。 | 继续收集异常日期/handle 顺序样本；如果配对错误，只改 HD sidecar policy，不改连接主链路。 |
| A-P1-07 | P1 | open | 下载模式必须在下载前写入并重新读 fresh `ObjectInfo`，不能保存缩略图大小。 | 原图/压缩都曾落到缩略图大小；当前规则要求 `D226/D22E -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT`。 | 保留 `Download mode prepare` 和 `Download partial freshSize/readSize` 日志；任何几百 KB 结果都视为失败。 |
| A-P1-08 | P1 | open | 交互问题继续收敛：多选滑动过敏、日期范围两个输入框、单图底部悬浮条一致性。 | 用户已明确提出这些 UX 问题；它们不应影响连接主链路。 | 作为 UI 层独立任务处理，禁止借 UI 调整触发 gallery startup 或改变 PTP 调度。 |
| A-P2-01 | P2 | measuring | HD 预览缓存只能是浏览会话资产，退出后必须清理。 | 2026-07-04 保留本次会话 `hd-preview-cache` 用于回滚动复用，但它不计入长期缓存；`GalleryPreviewController.reset()` 会删除该目录。 | 实机观察退出/切模式后目录是否清理，以及 HD 长时间浏览是否仍有卡顿。 |
| A-P2-02 | P2 | measuring | 缩略图长期缓存需要落盘、上限和清理策略。 | 2026-07-04 新增 `thumbnail-disk-cache` 旁路：缩略图显示前先读本地，未命中才请求相机；用户上限为 200MB/500MB/1GB，按最旧文件清理。 | 实机验证二次进入相册是否减少 `Thumbnail request`，以及清理不会碰配对/下载文件。 |
| A-P2-03 | P2 | open | RAW/视频下载必须保持流式保存，不能退回整文件进内存。 | 大 RAW/视频会超过普通 ByteArray 安全范围；当前 64MB 以上走 stream。 | 任何下载重构必须保留大文件 stream 策略，并记录 transfer/save 分段耗时。 |

### P0: 配对、连接、进入相册和首屏图片加载稳定性

1. `Connect -> GalleryReady` 主链路必须保持最小阻塞路径。
   - 当前允许的首屏阻塞路径是 BLE 身份确认、官方 Wi-Fi 凭据、AP ready、系统 Wi-Fi `Network`、PTP open、`9050 -> D22B -> 9053 -> D620 -> D621`，以及必要的 `D604=HEIF/RAW -> 9053/D620/D621` 扩展。
   - 禁止把标准 `GetStorageIDs/GetObjectHandles` 枚举、hidden gap probe、JPG/MOV/MP4 额外格式轮询、无依据 SearchMode restore 或当前对象 prime 混入首屏阻塞路径。
   - 当前待确认: `loadCameraVendorGalleryObjectHandles()` 里的 `D222 current handle snapshot` 是否仍有必要挡在首屏前。下一步看 `GalleryStartup step=D222-current-handle-snapshot` 的耗时和失败率；若无稳定收益，应移出阻塞路径或降级为非阻塞诊断。

2. `9050 SearchModeDescAll` 重试是否必要。
   - 当前实现对 `0x2019` 最多重试 3 次，并带 500ms、1000ms 的等待。
   - 下一步看 `SearchModeDescAll attempt=... elapsedMs=...` 与 `retryable failure ... delayMs=...` 日志。如果重试经常发生但后续仍能成功，需要保留并解释依据；如果极少发生或只拖慢，应改成更窄的诊断/恢复策略。

3. HEIF/RAW 初始占位符发现必须继续走 `D604=HEIF/RAW -> D621` 扩展列表。
   - 这是 RAW/HEIF 一开始就有占位符的正式路径，不是 hidden handle 猜码。
   - 下一步看 `FormatSpecifiedHandles HEIF/RAW probe elapsedMs=... handles=...` 和 `promotedToInitial`，确认扩展读取是否稳定、耗时是否可接受、是否总是只需要 HEIF 或 RAW 其中一个就能提升到全量。

4. 下载必须独占 PTP。
   - 缩略图模式和高清预览模式点击下载后都必须进入下载页，并暂停 metadata、thumbnail、preview 的后续相机请求。
   - 下载期间如果出现 `Socket is closed`、`Not connected to camera`、`Connection reset`，必须停止剩余队列并提示重新进入相册后重试，不能继续让后续任务刷错误。

### P1: 速度和功能可用性

1. 后置完整 `ObjectInfo` 补齐不能影响首屏和下载。
   - `fastInitialFiles()` 只负责尽快发布 D621 占位符。
   - `listFiles()`、标准枚举、hidden metadata、完整 ObjectInfo 补齐都必须是低优先级、可取消、可暂停的后置工作。
   - 当前待确认: `PtpCommands.galleryObjectInfos()` 里仍有标注为 `iOS logic` 的标准枚举分支。Android 后续必须把它明确成小图库/诊断/后置补齐策略，不能作为 Android 主发现路径，也不能抢首屏或下载通道。

2. 高清预览取消不能变成失败。
   - 当前风险: 预览 worker 被切换模式、下载前暂停、退出页面取消时，如果把正常 cancellation 记入 failed handles，会导致图片后续不再加载。
   - 后续修复要求: `CancellationException` 必须按取消处理，不写入失败状态；失败只记录真实协议/解码/数据异常。

3. 高清预览必须拒绝不完整图片。
   - `D226=1 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT(compressedSize) -> D226=0` 是 screen preview 路径。
   - 如果 JPEG 缺 EOI 或数据不像图片，不能标记为已加载成功，避免黑图、半图、已加载但无图。

4. 高清预览顺序和 RAW 配对不能破坏 `D621` 顺序。
   - 当前风险: 暧昧 HEIF/RAW 占位符如果按 handle 倒序重组，会和“保留相机 D621 返回顺序”的规则冲突。
   - 后续修复要求: HD 预览 item 构造应尽量按当前相册列表顺序生成，RAW sidecar 只作为同项下载按钮，不应重排时间线。

5. 筛选和下载队列状态要一致。
   - 高清预览底部下载按钮如果按全局 pending 启用，而当前日期显示加入数为 0，会让用户误解。
   - 后续要么显示全局队列数量，要么只按当前 HD 日期队列启用下载。

### P2: 性能、内存和缓存

1. HD 预览缓存只允许作为浏览会话缓存。
   - 当前状态: 本次浏览中仍可临时使用 `cacheDir/hd-preview-cache` 复用已打开过的高清预览，避免同一会话反复占用 PTP。
   - 返回 CONNECT 主界面、断开相机或 ViewModel reset 时必须删除该目录；它不计入长期可清理缓存，也不跨启动保留。
   - Android 不依赖“退出 app”概念；清理点绑定在可控的相册返回主界面和 reset 路径。
   - 边界: 不改变 `D226 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT` 高清预览协议，不把 screen preview 和原图/压缩下载混用。

2. 缩略图长期缓存是唯一跨会话图片缓存。
   - 当前状态: `GalleryThumbnailController` 在请求相机前先查 `thumbnail-disk-cache`，命中则直接合并到 UI；未命中才走 `getThumbnailWithInfo`。
   - 写入策略: 相机返回缩略图后立即更新 UI；磁盘写入和每 32 次写入后的 trim 都调度到独立后台 job，不能卡住后续缩略图请求。
   - 上限策略: 用户可选 `200MB / 500MB / 1GB`，默认 `500MB`；清理只删除 `thumbnail-disk-cache` 和 `diagnostics` 下的旧文件。
   - UI 策略: 缓存大小统计不在进入相册首屏立即递归扫描；等文件列表加载完成并延迟后再后台统计，避免和首屏缩略图抢 IO。
   - 禁止清理: 配对/连接记录、下载目录配置、MediaStore/SAF 已保存照片视频、下载完成标记都不属于缓存清理范围。

3. 缩略图内存缓存需要上限。
   - 当前状态: `GalleryThumbnailController` 的额外 thumbnail byte map 已限制为 300 entries LRU。
   - 边界: 这个上限只限制 controller 内部用于合并/恢复的额外缓存，不主动清掉当前页面 `CameraFile.thumbnail` 里已经显示的图片，避免滚动中图片突然消失。
   - 后续建议: 如果要进一步降内存，需要单独设计页面列表 thumbnail 的窗口化策略。

4. 缩略图磁盘缓存不能进入主链路。
   - 进入相册仍先按官方式 `D621/9053/ObjectInfo` 生成占位符和顺序。
   - 本地缩略图命中只是显示阶段的旁路优化；不能用本地缓存决定占位符数量、日期分组、格式筛选或下载队列。
   - key 不能只有 handle；当前包含 handle、format、compressedSize、filename，降低删图/重拍后 handle 复用导致错图的风险。

5. 下载大文件必须继续走流式路径。
   - 当前策略是视频和大于等于 64MB 的文件走 stream，避免 RAW/视频整文件进内存。
   - 后续任何下载优化都不能把 RAW/视频退回整文件 `ByteArray` 保存路径。

### 当前新增诊断日志

以下日志用于决定是否删除或优化某一步，先收集实机证据，再改逻辑:

- `GalleryStartup start/complete elapsedMs=...`
- `GalleryStartup step=<label> start/done/failed elapsedMs=...`
- `SearchModeDescAll attempt=... elapsedMs=...`
- `SearchModeDescAll retryable failure ... delayMs=...`
- `Current object handle snapshot elapsedMs=...`
- `FormatSpecifiedHandles HEIF/RAW probe elapsedMs=... handles=...`

判断规则:

- 如果某一步耗时高、失败率高、且没有影响后续 D621 首屏占位符生成，就优先移出阻塞路径。
- 如果某一步耗时低、能稳定避免后续错误，并且有官方或实机证据支撑，才保留在主链路。
- 如果证据不足，只能作为可开关诊断或后置低优先级任务，不能默认进入首屏主链路。
