# CamTransfer Camera Flow and Product Notes

> 目的：把当前已经验证过的 CameraVendor 相机连接、图库加载、HEIF/RAW 发现、产品首页和图库 UI 逻辑写清楚。后续改动必须先对照本文，避免把已验证的链路再次改坏。
>
> Android 连接边界：本文包含历史 iOS 调试记录。Android 已配对进入相册、BLE/Wi-Fi/PTP 主链路必须以
> `docs/android-current-execution-logic.md` 和 `docs/android-official-xapp-connection-analysis.md`
> 为准，不使用 iOS 行为作为 Android 实现依据。

## 当前结论

> **2026-07-16 口径更新：** 本节中 2026-06-24 的 Android
> `D604=31` / `D604=HEIF` / `D604=RAW` 结果，是“初始占位符发现/扩展
> 目录”证据，不是精确的 HEIF 或 RAW 筛选证据。两种扩展请求曾返回同一
> 批更大的 handle 集合，后续依赖 ObjectInfo 分类。它必须作为历史经验
> 保留，但不能作为当前 iOS catalog membership 的实现依据。当前 iOS
> Gallery 的唯一权威规范是
> `docs/superpowers/specs/2026-07-13-ios-camera-filter-download-final-solution.md`；
> HEIF 精确 transaction 当前明确延期，不得宣称已支持。

当前 Android X-T5 真正能把 HEIF/RAW 一开始加载出来的关键，不是标准 PTP 全卡枚举，也不是 `D222` ready 轮询，也不是 hidden gap 猜 handle，而是：

1. 使用 ReferenceApp 的 BLE 传图激活流程进入相机 Wi-Fi / PTP 状态。
2. 使用 CameraVendor legacy PTP 初始化和 ReferenceApp 图库链路读取相机当前列表。
3. 先读取 `D604=31` 下的 `9053/D620/D621` 基线列表。
4. 再设置 `D604=HEIF` 或 `D604=RAW` 并重新读取 `9053/D620/D621`。
5. 如果相机返回更大的 specified handle 列表，把这个扩展 `D621` 提升为初始占位符来源。
6. 保留相机返回的 `D621` 顺序发布占位符，不按 handle 数字倒序重排。

2026-06-24 Android 实机验证:

```text
D604=31   -> 1152 handles, JPG=1138, Video=14
D604=HEIF -> 1268 handles
D604=RAW  -> 1268 handles
full-object-info-final total=1268 formats={HEIF=37, RAW=79, JPG=1138, Video=14}
hidden metadata selected=0
```

上述结果证明的是“扩展目录可以让初始列表看到更多对象”，不证明
`D604=HEIF` 返回的 1268 个 handle 全部是 HEIF，也不证明
`D604=RAW` 返回的 1268 个 handle 全部是 RAW。后续筛选若把这个扩展目录
当作精确格式目录，就会出现 HEIF/RAW 互相污染、数量随 ObjectInfo 补齐
变化，以及全目录被错误发布的问题。

已验证有效的关键构建：

- `BUILD_MARK_20260504_FIX134_PROBE_HIDDEN_HANDLE_GAPS`
- `BUILD_MARK_20260504_FIX148_ACCEPT_CAMERA_SUBNET_FOR_PTP`

`FIX148` 的当前成功结论：

1. BLE 侧必须按 ReferenceApp 顺序写入 `CAEDB497=00 -> 98934B2C=01 -> 82A9F452=00 -> 600655E6=0300`。
2. 看到 `AP_STATE_READY ... Launched(0x8001)` 后，进入 Wi-Fi / PTP 图库流程。
3. iOS 免费开发账号环境下经常读不到当前 SSID；如果 `en0` IP 是 `192.168.0.x`，应允许进入 PTP，不要因为 `SSID=nil` 阻断。
4. 不要再加入“baseline IP 必须变化”的防误判逻辑。实测它会把已经连上的 CameraVendor Wi-Fi 也挡掉，导致 App 一直提示用户连接 Wi-Fi。
5. 下载图片原图当前走 `downloadOriginal(for:) -> session.object() -> CameraVendorPhotoLibrarySaver.save(data:)`，图片下载已验证可用；不要再把照片强行改成统一文件流路径，否则容易绕过已有的图片数据修正逻辑。

`FIX135` 的目的只是移除会破坏链路的 `D222` 轮询。hidden handle gap 探测现在只作为扩展 `D621` 失败后的兜底诊断，不应再作为 RAW/HEIF 的正式发现路径。对于 Android 历史初始占位符路径，仍可记录并复现 2026-06-24 的 `D604=HEIF/RAW -> D621` 扩展列表；但它不是 iOS 精确筛选逻辑，也不得被当作格式 catalog membership。

这条 Android 经验不能直接迁移成 iOS 精确筛选逻辑。对于 iOS，旧的
format-pass、candidate promotion、`formatHints` 和 ObjectInfo-owned
membership 路径均已被终态规格否定；保留它们只会把“对象可见”误当成
“格式筛选正确”。

## 高风险误区

### 1. 不要在正式图库路径里轮询 `D212/D222`

曾经添加 `waitForCameraVendorGalleryReadyMarker()`，希望等 `D222` 变成 `0x0992/0x0993` 再读取列表。

实测结果：

- 轮询会把 `D212` 读成 `01 00 2f d2 01 00 00` 或 `00 00`
- `D222` 变成 `nil`
- 后续 `0x9054` / `0x9055` 返回 `0x2009`
- 最终出现 PTP 超时或 `Connection refused`

因此正式链路中不能调用：

```swift
waitForCameraVendorGalleryReadyMarker(stage: ...)
```

函数可以保留作诊断，但不能接入正式 `performCameraVendorLegacyReferenceAppGalleryHandshake()`。

### 2. 标准 PTP 全卡枚举不可用

曾尝试走：

```text
GetStorageIDs (0x1004) -> GetObjectHandles -> GetObjectInfo
```

实测在 CameraVendor legacy 会话下：

```text
PTP operation 0x1004 返回 PTP 响应码 0x2005
```

结论：不能依赖标准 `StorageIDs -> ObjectHandles` 作为 HEIF/RAW 全量发现方案。

### 3. 已配对读取和连接必须分离

历史问题：`restoreLastPairedCameraIfAvailable()` 曾经实际做两件事：

1. 从本地读取已配对相机记录。
2. 立即尝试 auto reconnect。

这会导致首页只想展示已配对相机时，意外触发连接和传图。

现在应保持职责分离：

- `restoreLastPairedCameraIfAvailable()`：只读取本地记录，不连接。
- `connectLastPairedCameraIfAvailable()`：用户点击“连接这台相机”后才启动连接。
- 已配对连接也应先扫描等待相机广播，不直接使用 `retrievePeripherals` 静默重连；这样删除配对和重新配对流程不会被系统已记住外设绕过。

启动页只想显示已配对相机时，必须使用：

```swift
service.rememberedCameraSummary
```

不能在 `viewDidLoad()` 自动调用：

```swift
service.connectLastPairedCameraIfAvailable()
```

否则 App 一打开就会自动连接相机、触发传图模式、进入图库，用户还没准备好时就容易出现 `0x2009`、超时或 `Connection refused`。

### 4. iOS 安装新包不一定杀掉旧进程

实测安装新 build 后，手机上旧的 CamTransfer 进程可能仍在后台运行。判断是否真的运行新版本，必须看日志开头：

```text
运行构建标记: BUILD_MARK_...
```

如果日志没有最新 build marker，要先手动从 iOS 后台划掉 CamTransfer，再重新打开。

## 产品入口逻辑

文件：

- `ios/Runner/NativeConnectViewController.swift`
- `ios/Runner/CameraVendorBluetoothService.swift`

首页目标：

- 固定显示已配对相机卡片。
- 允许用户主动点击卡片连接已配对相机。
- 保留“连接新设备”入口，用于扫描和配对新相机。
- 首页不应该自动连接相机。

当前职责划分：

```text
NativeConnectViewController.viewDidLoad
  -> setupUI()
  -> updateRememberedCameraCard()
  -> 不自动调用 restoreLastPairedCameraIfAvailable()

用户点击已配对相机卡片
  -> connectRememberedCameraTapped()
  -> service.connectLastPairedCameraIfAvailable()
  -> BLE reconnect
  -> pairing handshake
  -> transfer activation
  -> didCompleteHandshake
  -> push NativeGalleryViewController

用户点击连接新设备
  -> searchTapped()
  -> service.startScan()
  -> 用户选择扫描结果
  -> service.connect(to:)
```

注意：如果以后需要“只读取已配对记录”的公开 API，应该新增一个只读方法，例如：

```swift
func loadRememberedCameraSummary() -> CameraVendorConnectionSummary?
```

不要复用 `restoreLastPairedCameraIfAvailable()` 做只读展示。

## BLE 传图激活逻辑

文件：

- `CameraVendorReferenceAppTransferActivationPlan`
- `CameraVendorBluetoothService.beginTransferActivation`
- `CameraVendorBluetoothService.writeNextTransferActivationStep`

当前正式传图策略：

```text
Official Import Image
```

写入顺序：

```text
CAEDB497 = 00
98934B2C = 01
82A9F452 = 00
600655E6 = 0300
```

含义：

- `CAEDB497=00`：ReferenceApp 源码中的 `setChImageTransferSetting()`
- `98934B2C=01`：ReferenceApp 源码中的 `setChImageTransferSettingEX()`
- `82A9F452=00`：关闭 resize，避免只给缩略/压缩图
- `600655E6=0300`：启动图像导入/图库传输

日志中应看到：

```text
ACTIVATION_START ... writes=CAEDB497=00,98934B2C=01,82A9F452=00,600655E6=0300
BLE_WRITE_ACK uuid=CAEDB497...
BLE_WRITE_ACK uuid=98934B2C...
BLE_WRITE_ACK uuid=82A9F452...
BLE_WRITE_ACK uuid=600655E6...
AP_STATE_READY ... Launched(0x8001)
```

如果没有这些日志，说明 BLE 激活未按预期执行。

## PTP 图库握手逻辑

文件：

- `CameraVendorPtpSession.connect`
- `performCameraVendorLegacyReferenceAppGalleryHandshake`

当前正式链路：

```text
PTP INIT (Android XApp native plain legacy, GUID fourth word = 0)
OpenSession
D212 读取图库上下文
DF01 读当前 ClientState
DF01 写 20
DF28 读 ImageHost
DF28 写版本 3
D244 读图库访问状态 #1
D212 读图库上下文 #2
D244 读图库访问状态 #2
9054 读取 current image info (handle 0x10000001)
9055 读取 current image thumbnail (handle 0x10000001)
9050 读取 SearchModeDescAll
跳过 9052 GetSearchModeAll
跳过 9051 SetSearchModeAll
D22B 读取 current object handle
9053 读取 SpecifiedObjectCountGroupByDate
D212 读取 before specified list
D620 读取 SpecifiedObjectCount
D621 读取 SpecifiedObjectHandles
```

### 官方日期分组与格式数量逻辑（2026-06-20）

已确认的官方 App 线索：

- Android 官方包 `ControlFFIR.java` 暴露了 `getSearchModeDescAll`、`getSpecifiedObjectCountGroupByDate`、`getSpecifiedObjectCount`、`getSpecifiedObjectHandles`、`getSearchModeAll`、`setSearchModeAll`。
- `CameraConnectWrapper.java` 的 WLAN 路径 `getSpecifiedObjectCount(timeout)` 没有格式参数；USB/XSDK 路径 `getSpecifiedObjectCountForXSDK(lObjectFormatCode)` 才有格式参数。
- `ObjectCountByDate` 只有 `dateValue1` 和 `numberOfImages`；`ImportImageModel` 会用 `ObjectCountByDate.numberOfImages` 去切分后续 handle 列表，先形成日期 section，再逐步补缩略图和对象信息。
- `FilterItem` 存 `initialNumberOfImages` / `numberOfImages`；筛选 ViewModel 会围绕 SearchMode 读图像数量。格式筛选的 property code 在官方 UI 中是 `54788`。
- iPhone 官方抓包里能看到 `0x9050 GetSearchModeDescAll` 和 `0x9053 GetSpecifiedObjectCountGroupByDate`，未在该样本中看到 `0x9051/0x9052`，所以不能仅凭该 pcap 证明生产链路会设置 SearchMode。

当前结论：

1. 日期分组不要等所有 `ObjectInfo`。相机已经通过 `0x9053` 返回“每个日期多少张”，我们应继续用这个结果把 `D621` handle 列表按数量切开，首屏占位图出来时就能显示日期 section。
2. HEIF/RAW 数量现在没有，不是相机一定没有，而是我们的筛选数量来自本地 `CameraFile` 元数据。首屏占位图格式是 `UNDEFINED`，完整 `ObjectInfo` 没补齐前无法本地统计 HEIF/RAW。之前把未知格式假装成 JPG 会让 JPG 数量虚高；现在不再伪造，所以 HEIF/RAW 数量缺口暴露出来。
3. 官方 WLAN 侧更可能是“设置/读取 SearchMode -> 调用 `getSpecifiedObjectCount` 让相机返回数量”，而不是把所有对象信息拉到本地后统计。也就是说，格式数量应该优先走相机侧权威 count。
4. 不能直接恢复生产路径的 `0x9051 SetSearchModeAll`。旧文档已经明确正式路径中不要清空或改写 SearchModeAll，除非有真机日志证明 payload 和恢复流程完全正确。

当前实现策略：

- UI 统计策略先支持“相机侧权威格式数量”入口；拿不到时继续按本地 `ObjectInfo` 统计。
- 调试版在 `0x9050` 后额外记录 `0x9052 GetSearchModeAll` 的原始长度和头部 hex，用来反推官方 SearchMode payload。
- 暂不发送 `0x9051 SetSearchModeAll`。后续只有在日志确认格式 property `54788` 的 payload 写法，并且能在 `finally` 中恢复原始 SearchModeAll 时，才启用按 JPG/HEIF/RAW/Video 分别读取 `D620` 的格式数量。
- 即使相机侧格式数量暂不可用，后台补齐 `ObjectInfo` 后也必须继续更新本地 HEIF/RAW 标签和筛选行为，不能把未知格式合并进 JPG。

2026-06-21 官方 Android 反编译复核：

- `ImportImageModel.applyFilterConditions()` 不是修改 `GetSearchModeAll` 返回 blob 里的单个 `D604` 值。它会重新创建 `SearchModeAllInfo`，按当前已选日期、文件夹、评分、格式、主体条件追加 `SearchModeStr` / `SearchModeLong`。
- 格式筛选 `D604` 使用 bitmask 合并选择项：JPG=`1`、HEIF=`2`、MOV=`4`、MP4=`8`、RAW=`16`。例如同时选 RAW/HEIF 时应把值合成 `18`，不是逐个格式覆盖全局状态。
- `getFiltersLoadThumbImg(searchModeAllInfo)` 先调用 `setSearchModeAll(searchModeAllInfo)`，随后调用 repository 的 `createImageHandlesByDate()`，也就是重新读取日期分组和 handles，再加载缩略图/对象信息。
- `FilteringConditionsModel.getImageNum()` 为筛选面板数量逐个构造临时 `SearchMode`，读取 `getSpecifiedObjectCount()` 后恢复原 SearchMode。这个流程用于数量刷新，不等同于图库首屏加载。
- 因此，未证明的实现禁止在主链路中发送手写 raw `9051` payload。实机日志已经证明“只改当前 `9052` blob 的 `D604` 值再读 `D621`”会让 HEIF/RAW/MOV/MP4 返回同一组 handles，污染格式筛选。
- 2026-06-24 更新: 当前 Android 正式路径不再依赖完整元数据后的 bounded hidden handle gap 探测 HEIF/RAW。首屏应先用 `D604=31` 读取基线 `9053/D620/D621`，再用 `D604=HEIF` 或 `D604=RAW` 读取扩展 `9053/D620/D621`，并把更大的相机返回列表提升为初始占位符来源。占位对象格式仍必须保持 `UNDEFINED`，直到 `ObjectInfo` 补齐。

2026-06-21 Android 修正：

- 快速占位对象的格式必须是 `UNDEFINED`，不能把未知对象伪装成 `JPEG`。否则首屏和后台补齐期间 JPG 数量会持续虚高，HEIF/RAW 会显示为 0。
- 大图库首屏仍然不能做 hidden probe，避免拖慢官方式 `9053 + D621` 首屏加载。
- 完整 `ObjectInfo` 后台补齐完成后，可以对已知 handle 的小缺口做有上限的 hidden probe，只选择 HEIF/RAW 合并进图库。这个阶段不改连接、缩略图、下载和 `SearchModeAll` 主链路。
- hidden probe 必须有候选数上限；缺口太多时直接跳过，并通过诊断日志记录 `Gallery hidden metadata ...`，避免给相机施压。

明确禁止：

```text
正式路径中不要轮询 D222 ready
正式路径中不要清空 SearchModeAll
正式路径中不要依赖标准 GetStorageIDs
```

## HEIF/RAW 发现逻辑

文件：

- `cameraVendorLegacySpecifiedObjectInfos`
- `cameraVendorLegacyHiddenObjectInfos`
- `CameraVendorHiddenObjectHandleProbePolicy`

背景：

相机 `D621` 有时只返回可见列表，例如：

```text
0x00000001, 0x0000000A, 0x00000016, 0x00000018, 0x0000001A
```

但对象 handle 本身存在缺口，缺口中可能有 HEIF/RAW。实测直接对缺口 handle 做 `GetObjectInfo` 能拿到隐藏对象。

当前逻辑：

```text
读取 D621 指定列表
读取指定列表中的 ObjectInfo
如果指定列表没有 HEIF/RAW
  -> 计算 handle 缺口
  -> 对缺口 handle 执行 GetObjectInfo
  -> 如果发现 HEIF/RAW
       -> 合并进图库
```

候选 handle 规则：

- 取 `D621` 返回 handle 的最小值和最大值。
- 如果范围不超过 `120`，探测中间缺失的 handle。
- 如果范围太大，跳过，避免无穷探测拖垮相机。

日志中应看到：

```text
PTP_HIDDEN_OBJECT_PROBE_BEGIN candidates=...
PTP_HIDDEN_OBJECT_INFO handle=... format=HEIF filename=...
PTP_HIDDEN_OBJECT_INFOS_SELECTED specified=... hidden=... merged=...
```

如果 HEIF/RAW 没显示，优先查这些日志。

### RAW 格式码注意事项

CameraVendor RAF 不只会返回 `0xB101`。当前日志里 DEVICE-A 返回过：

```text
对象 3: DSCF6002.RAF 0xB103
PTP_HIDDEN_OBJECT_INFO handle=0x00000003 format=0xB103 filename=DSCF6002.RAF
```

因此 `CameraVendorCameraObjectInfo.formatLabel` 必须把 `0xB103` 也映射为 `RAW`。否则 hidden handle 已经找到了 RAF，也会因为格式标签不是 `RAW` 而不被合并、不被 RAW 筛选显示。

## 图库 UI 和筛选逻辑

文件：

- `NativeGalleryViewController`
- `NativeGalleryFilterPolicy`
- `NativeGalleryFilterState`

当前产品 UI：

- 网格展示缩略图。
- 点击图片进入预览。
- 左上角选择框可多选。
- 底部下载栏在有选择时出现。
- 顶部筛选：
  - 时间：全部 / 今天 / 7 天
  - 格式：全部 / JPG / HEIF / RAW / 视频

筛选是本地筛选，不会重新请求相机：

```text
allGalleryItems = 相机返回的完整列表
filterState = 当前筛选
galleryState.items = NativeGalleryFilterPolicy.filteredItems(allGalleryItems, filterState)
```

因此如果 HEIF 没出现在 `allGalleryItems`，UI 筛选不可能变出 HEIF。必须回到 PTP 日志看 `PTP_HIDDEN_OBJECT_INFO`。

### 自动加载和 Wi-Fi 判定策略

当前成功方案不是依赖系统自动加入 Wi-Fi，而是：

```text
BLE 传图激活成功
-> 用户手动连接 CAMERA-* Wi-Fi
-> 回到 CamTransfer
-> App 看到当前 Wi-Fi IP 为 192.168.0.x
-> 自动进入 PTP 图库读取
```

关键规则：

- `CameraVendorGalleryLoadPolicy.shouldRetryAutomaticallyWhenAppBecomesActive = true`。
- `CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(...)` 在 `currentWifiIP` 为 `192.168.0.x` 且图库为空、未加载中时返回 `true`。
- `CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(...)` 在 `SSID=nil` 但 `isCameraPtpReachable=true` 时必须返回 `true`。
- `CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(...)` 在 `currentIP` 为 `192.168.0.x` 时必须返回 `true`，不能要求它和 baseline IP 不同。

不要再恢复下面这类逻辑：

```text
currentIP == manualPromptBaselineIP 时阻止 PTP
SSID=nil 时即使 192.168.0.x 也阻止 PTP
```

这两个逻辑都已经实测会造成误伤：用户实际已经连上相机 Wi-Fi，但 App 仍然一直提示“请连接相机 Wi-Fi”。

如果未来要做更严格的误判防护，只能增加“PTP 端口探测但不占用相机连接”的专用机制；不能在 UI 层用 baseline IP 阻断正式 PTP。

### 图片下载成功路径

当前图片下载可用路径：

```text
NativeGalleryViewController.startDownload(for:)
-> CameraVendorRealtimeGalleryService.downloadOriginal(for:)
-> CameraVendorPtpSession.object(handle:expectedSize:)
-> CameraVendorPhotoLibrarySaver.save(data:filename:)
```

注意：

- 照片继续走 data 路径，不要改成 `downloadOriginalFile(for:)`。
- 视频暂时仍按策略不支持下载，避免把未稳定的视频文件流路径影响照片下载。
- 下载列表目前只显示 `queued / downloading / saved / failed`，没有字节级进度。
- `CameraVendorGalleryItem.byteSizeText` 已经有原图大小文本，应在下载列表里显示，避免用户误以为下载慢是卡住。

## 当前“失败”的判定方式

每次说“不行”时，先按下面顺序看日志：

1. 是否是最新构建：

```text
运行构建标记: BUILD_MARK_...
```

2. 是否启动后自动连接了：

```text
系统返回了已记住外设，直接重连
AUTO_TRANSFER_AFTER_PAIRING
```

如果用户没有点击卡片但出现这些日志，说明启动页仍然误触发连接。

3. 是否进入了图库 fetch：

```text
GALLERY_FETCH_START
```

4. PTP 是否在 `9054/9055` 处失败：

```text
PTP_CURRENT_IMAGE_CONTEXT_PRIME_FAILED ... 0x2009
PTP_CURRENT_THUMB_CONTEXT_PRIME_FAILED ... 0x2009
```

这通常说明相机没有处于可读图库状态，或者前面有破坏上下文的读写。

5. 是否触发 hidden handle 探测：

```text
PTP_HIDDEN_OBJECT_PROBE_BEGIN
PTP_HIDDEN_OBJECT_INFO
```

如果没有触发，需要看 `D621` 和 `CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(...)`。

## 下一步建议

### 必须先修

把“显示已配对相机”和“连接已配对相机”彻底拆开：

```text
新增只读 API：loadRememberedCameraSummary()
保留连接 API：restoreLastPairedCameraIfAvailable()
首页 viewDidLoad 只能调用只读 API
用户点击卡片才调用连接 API
```

当前虽然 UI 层已经避免在 `viewDidLoad()` 调用连接 API，但服务层命名和职责仍然混乱，容易再次误用。

### 下载中心设计建议

下载列表应该从“当前图库筛选结果”里独立出来，原因：

- 当前 `NativeDownloadListViewController` 初始化时只拿一次 `downloadListItems()`。
- `downloadListItems()` 来自当前 `galleryState.items`，也就是当前筛选后的图库列表。
- `CameraVendorGalleryState.replaceItems()` 会按当前 items 过滤 `downloadStates`，筛选或刷新后可能丢掉已下载状态。
- 这会阻碍“独立下载列表”“已下载提示”“未下载筛选”等产品能力。

建议下一步把下载状态拆成独立模型，例如：

```text
NativeDownloadStore
  taskByHandle: [Int: NativeDownloadTask]

NativeDownloadTask
  handle
  filename
  thumbnailData
  formatLabel
  byteSizeText
  state: queued / downloading / saved / failed
  progress: completedBytes / totalBytes (先可为空)
  savedAt
```

推荐的产品行为：

1. 下载列表是独立页面，可以从图库页进入，离开后下载继续进行。
2. 用户在下载列表里查看状态时，仍然可以返回图库继续选择更多照片。
3. 已保存的照片再次点击下载时提示“已下载过”，并允许用户选择“重新下载”。
4. 图库筛选增加“未下载”，只显示 `state != saved` 的项目。
5. 下载列表每行显示：
   - 缩略图
   - 文件名
   - 格式和大小，例如 `RAW · 52.3 MB`
   - 状态，例如 `下载中 3/10` 或 `已保存`
6. 真正的字节进度需要协议层支持分段/回调。当前先做“任务级进度”（第几张/共几张）和大小展示，不要为了进度条重写照片下载链路。

### 然后做产品 UI

在确认启动不自动连接后，再继续：

- 优化首页视觉
- 优化连接新设备流程
- 优化筛选条
- 下载进度、大小展示、已下载状态和未下载筛选

### 不要同时改协议和 UI

协议层当前已经很脆。任何产品 UI 改动不应触碰：

- BLE 写入顺序
- PTP handshake 顺序
- `D604=HEIF/RAW -> D621` 扩展初始列表逻辑
- hidden handle gap 兜底探测
- `D212/D222`
- `SearchModeAll`

如果必须碰协议，必须先记录：

- 改动假设
- 对应日志证据
- 成功/失败判定日志

## 待办补充（2026-05-13）

### P1 体验

1. 扫描改成持续发现模型，不要 12 秒超时后彻底停住。
   - 现状：普通扫描超时后会停在“未发现相机”或“请选择相机”。
   - 目标：扫描结束后进入低频续扫，首页保留已配对相机卡片，同时允许手动刷新。

2. 已配对相机重连时不要清空当前列表。
   - 现状：自动重连扫描会先清空 `discoveredCameras`，页面会短暂变空。
   - 目标：保留上次已配对卡片，等找到目标广播后再切换状态，避免“像断开了一样”的空窗。

3. 下载期间不要把首屏缩略图体验全部停掉。
   - 现状：下载开始后会暂停后续缩略图加载，必要时还会打断正在进行的缩略图请求。
   - 目标：至少保住当前可见区域缩略图；非可见区域可继续暂停，兼顾速度和体感。

4. 清缓存入口再明确一点。
   - 现状：图库页右上角只有一个文字按钮，发现性一般。
   - 目标：在下载中心页内增加更明确的“清理全部缓存 / 清理单项缓存”入口，并补“重试失败项”。

### P1 性能 / 稳定性

1. 连续下载时复用文件下载前准备状态，减少每张图重复准备。
   - 现状：单张下载前会重复做 `D212`、`D235`、`D227/D226`、fresh `objectInfo` 这套准备。
   - 目标：同格式连续下载时尽量复用已准备状态，减少协议往返。

2. 保留当前 JPG / HEIF 保真链路，不要再把 fast-start 扩回去。
   - 现状：`RAW` 允许走 ReferenceApp fast-start；`JPG/HEIF` 已恢复到真实大小链路。
   - 目标：后续性能试验只在 RAW 或专门实验开关上做，避免再次把 JPG / HEIF 拉回预览文件模式。

3. 对 RAW 下载做固定块大小 A/B。
   - 现状：当前策略是 `8 MB -> 慢了回退 4 MB -> 再视情况升回 8 MB`。
   - 问题：日志证明相机在 RAW 后段会抖，当前还不能证明 `8 MB` 一定优于 `12 MB` 或 `6 MB`。
   - 目标：做固定 `8 MB`、固定 `12 MB`、固定 `6 MB` 三组实验，基于同一张 RAW 比较：
     - 总耗时
     - 每块耗时
     - 是否出现半块返回
     - 是否掉线

4. 下载性能分析继续优先看“传输前准备”和“chunk 往返”，不是保存阶段。
   - 现状：最新日志里保存通常只有几十到几百毫秒，不是主瓶颈。
   - 目标：后续日志和优化继续聚焦：
     - `PTP_DOWNLOAD_FILE_PREPARE_BEGIN`
     - `PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST`
     - `PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK`
     - `UI: [主通道] 下载传输完成`

### P2 工程整理

1. `fetchLock` 仍然直接用在 async 上下文，后续要替换成 async-safe 方案。
   - 现状：Xcode 已给出 Swift 6 兼容告警。
   - 目标：在不改当前行为的前提下，替换成更安全的并发控制实现。

2. 下载中心文案和结构继续收口。
   - 现状：下载中心更像状态页，不像操作页。
   - 目标：把“清缓存 / 重试失败 / 已下载状态 / 未下载筛选”收敛到统一模型和统一入口里。
