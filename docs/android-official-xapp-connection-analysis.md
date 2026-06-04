# Android Official XApp Connection Analysis

更新日期: 2026-06-04

本文记录从已安装官方 FUJIFILM XApp Android 包中读到的连接逻辑。后续 Android 改造以这里的证据作为对照，避免靠猜测等待或串行试探。

## 样本来源

- 包名: `com.fujifilm.xapp`
- 版本: `2.7.3(1)`
- 来源: 已连接 Android 设备导出的 split APK
- 反编译目录: `/tmp/fujifilm_xapp_jadx`
- 关键文件:
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/common/BTConstansKt.java`
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/model/bleconnect/BTCamera.java`
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/repository/bleconnect/BTEntryCameraRepository.java`
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/model/camera_connect/WiFiHandOverService.java`
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/ui/camera_connect/CameraConnectViewModel.java`
  - `/tmp/fujifilm_xapp_jadx/sources/com/fujifilm/xapp/common/ffir/ControlFFIR.java`

## 总体链路

官方 App 的大链路可以拆成两块:

1. 配对阶段: 通过 BLE 与相机建立关系，读取并保存相机连接所需信息。
2. 进入相册阶段: 通过 BLE 让相机启动 WiFi/AP，然后手机用保存的 SSID、密码、MAC 发起系统 WiFi handover，最后通过 PTP/IP 和原生 SDK 进入图片列表与传输。

这里的核心结论是: 官方 App 并不是靠猜测相机 WiFi 名称，也不是按 FUJ 前缀串行试很多网络。它在配对时就读取了精确的 SSID、WiFi 密码和 MAC，后面进入相册时直接使用这些值。

## BLE 配对读到的信息

`BTConstansKt.java` 暴露了关键 BLE characteristic:

- `CHARACTERISTIC_FF_CAMERA_SSID_NAME_STRING = BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4`
- `CHARACTERISTIC_FF_CAMERA_WIFI_PASSPHRASE_STRING = E809256A-915C-4967-92E8-53B7D4CAD213`
- `CHARACTERISTIC_FF_CAMERA_MAC_ADDRESS = 49A12959-DFAA-4EB2-89CE-62548AD948F3`
- `CHARACTERISTIC_FF_AP_LAUNCH_REQUEST = FB15C357-364F-49D3-B5C5-1E32C0DED038`
- `CHARACTERISTIC_FF_AP_STATE = A68E3F66-0FCC-4395-8D4C-AA980B5877FA`

`BTCamera.java` 中的读取逻辑:

- `readCharacteristicSSIDNameString(byte[] value)` 把字节转成字符串后写入 `SSID`。
- 同一方法里还通过 `SSID.substring(9)` 推导本地显示名。
- `readCharacteristicCameraWifiPassPhraseString(byte[] value)` 把字节转成字符串后写入 `cameraWifiPassPhrase`。

`BTEntryCameraRepository` 提供按 cameraID 读取已保存信息的方法:

- `getCameraSSID(cameraID)`
- `getCameraWifiPassPhrase(cameraID)`

## 进入相册的 WiFi handover

`CameraConnectViewModel.java` 在进入连接阶段时从 repository 取值:

- `getCameraSSID()` 返回保存的 SSID。
- `getPassPhrase()` 返回保存的 WiFi passphrase。
- `startWifiHandoverService(ssid, macAddress, passPhrase)` 把三项信息传给 `WiFiHandOverService`。

`WiFiHandOverService.startWifiHandover()` 的关键行为:

- 创建 `WifiNetworkSpecifier.Builder()`。
- `setSsidPattern(new PatternMatcher(ssid, 0))`，目标是精确 SSID。
- 如果有 MAC，则把连续 MAC 字符串补冒号后调用 `setBssid(MacAddress.fromString(...))`。
- 如果有密码，则调用 `setWpa2Passphrase(passPhrase)`。
- 创建 `NetworkRequest`:
  - `addTransportType(NetworkCapabilities.TRANSPORT_WIFI)`
  - `removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)`
  - `setNetworkSpecifier(wifiNetworkSpecifier)`
- 通过 `ConnectivityManager.requestNetwork(request, callback)` 请求系统连接目标 WiFi。

回调逻辑:

- `onAvailable(network)`: 认为 WiFi 网络可用，把目标 `Network` 存起来，并通知上层成功。
- `onCapabilitiesChanged(network, capabilities)`: 校验当前能力里的 SSID 是否等于目标 SSID。
- `onUnavailable()`: 注销网络回调并通知上层失败。
- 重试不是无条件循环。只有在 retryCount 小于 3、需要重试、且不是首次连接时才进入重试分支。

## WiFi 后的相机通信

`ControlFFIR.java` 显示 WiFi 接通后使用原生 SDK/Socket:

- 相机 IP 固定走 `192.168.1.1`。
- 端口:
  - base socket: `55740`
  - through socket: `55741`
  - event socket: `55742`
- `SDK_SetOpenSocket(portNo)` 会优先使用当前相机 WiFi 对应的 `Network.getSocketFactory()`。
- 如果系统里保存了目标 `Network`，还会调用 `ConnectivityManager.bindProcessToNetwork(network)`。
- socket connect timeout 是 `5000ms`。

这说明进入 PTP/IP 前，关键是把进程和 socket 明确绑定到相机 WiFi 的 `Network`，不能只依赖系统默认网络。

## 相册列表与缩略图

官方 App 暴露了更多扩展接口，而不是只串行读取所有对象:

- `getSpecifiedObjectCount`
- `getSpecifiedObjectHandles`
- `getSpecifiedObjectCountGroupByDate`
- `getExtensionObjectInfo`
- `getExtensionThumb`
- `ReadImageInfo`
- `ReadThumbnail`
- `ReadImage`

原生库中也能看到 PTP 操作:

- `FTL_PTP_GetObjectHandles`
- `FTL_PTP_GetObjectInfo`
- `FTL_PTP_GetThumb`
- `FTL_PTP_GetObject`
- `FTL_PTP_VendorExtensionOperation`

推论: 官方 App 大概率用 vendor extension 做分页、筛选、日期分组或批量信息读取，所以几千张照片时不会按完整对象逐个同步。我们当前优化应优先让首屏只取必要 handle 和缩略图，把完整元数据延后到详情或后台补齐。

## 方向信息

官方包里有 `libFFEXIF.so`，并且原生层包含 EXIF、RAF、HEIF 相关能力。这说明官方 App 可能在原生层读取方向信息，尤其是 JPEG/HEIF/RAF 的预览和方向处理。

当前从我们日志看，缩略图返回链路没有稳定确认方向字段。后续策略应保持两层:

1. 优先从相机返回的 object info/vendor extension 中解析方向或尺寸字段，并记录日志。
2. 如果列表阶段拿不到方向，不要为了列表首屏同步二次读取完整图片元数据；只在打开大图或后台低优先级补齐。

## 对我们 Android 改造的要求

1. 配对成功必须以 BLE 读取并保存 cameraID、SSID、WiFi passphrase、MAC 等关键字段为依据。
2. 进入相册时，如果已有精确 SSID/passphrase/MAC，不应该再按 FUJ 前缀串行猜测。
3. WiFi 连接状态需要围绕系统 `NetworkCallback`、目标 SSID 校验、目标 Network 保存来推进。
4. PTP/IP socket 要绑定到相机 WiFi 对应的 `Network`，避免手机仍走蜂窝或其他 WiFi。
5. AP 启动等待应尽量依赖 BLE 的 AP launch/AP state 或 transfer state，而不是固定长等待。
6. UI 每一步只展示当前阶段的必要动作:
   - 配对前: 相机进入配对注册界面、手机清理旧蓝牙记录。
   - 配对中: 相机需要按确定、手机需要接受配对。
   - 进入相册: 正在让相机启动 WiFi、正在等待手机加入指定 WiFi、正在打开相册。
7. 失败时只给用户一个清晰主动作: 重试或重新配对；WiFi 失败时展示 SSID 和密码，并允许复制密码去系统设置手动连接。

## 下一步优化方向

优先级从高到低:

1. 对齐 WiFi handover: 使用已保存的精确 SSID/passphrase/MAC，减少 SSID 猜测和无依据重试。
2. 对齐 AP readiness: 读取或监听 AP state/transfer state，压缩固定等待。
3. 对齐 Network 绑定: 确保 PTP socket 使用相机 WiFi 的 `Network`。
4. 大图库首屏: 首屏限制 handle 数量、优先读取最新缩略图，完整 metadata 延后。
5. 方向信息: 继续记录并解析 object info/vendor extension 字段，确认是否能直接获得方向或至少可靠宽高。

## 2026-06-04 优化记录

从日志看，旧实现会把 BLE 读到的精确 WiFi 凭据标记为隐藏网络，导致第一个 `hidden=true` attempt 直接等待到 30 秒超时，然后才继续试其他候选。官方 XApp 的 `WiFiHandOverService` 使用精确 SSID pattern、可选 BSSID、可选 passphrase，没有看到 `setIsHiddenSsid(true)` 分支。

因此 Android 侧将 `referenceAppConfiguration(ssid, passphrase)` 改为 `isHidden=false`。只有没有官方 BLE SSID/passphrase、必须靠名称推导 fallback 时，才继续保留候选网络逻辑。

同一轮也给 BLE WiFi 凭据刷新加了早返回: 如果 `performHandshake()` 已经拿到并保存了 SSID/passphrase，进入相册阶段不再重复读取这两个 characteristic。这样能减少进入相册前的 BLE 读等待；如果当前连接没有凭据，仍会按原逻辑尝试读取或回退到已保存配置。

## 2026-06-04 WiFi 重试规则

WiFi handoff 失败时，相机通常已经停在“等待手机连接 WiFi”的界面。这个状态下 App 的重试不能重新走 BLE 唤醒/传图启动，因为那会让相机和手机状态更不一致。

Android 侧重试规则调整为:

- `JoinCameraWifi` 失败: 先探测当前 PTP；如果没有连上，就复用已保存的 WiFi SSID/passphrase 重新 requestNetwork，然后再打开 PTP。不重新 BLE 唤醒。
- `ConnectPtp` / `LoadGallery` 失败: 只探测当前相机 WiFi/PTP，不重新 BLE 唤醒。
- 只有用户主动点“进入相机相册”开始新一轮，才会重新走 BLE 确认和相机 WiFi 启动。

UI 侧也同步调整: 已配对状态下如果还挂着进入相册阶段的问题，主按钮显示“重试”，不再显示“进入相机相册”，避免误触完整重连流程。

## 2026-06-04 WiFi 与首屏相册优化

日志显示 MIUI 可能在相机 WiFi 刚启动后很快返回 `onUnavailable`，本次样本为 3454ms。此时 SSID/passphrase 并不一定错误，因为同一相机稍后重试可在 2957ms 内 `onAvailable` 并完成 PTP。Android 侧因此增加同一精确 WiFi 的内部自动重试:

- 每个精确 WiFi candidate 最多自动 requestNetwork 3 次。
- 第 1 次失败后等待 1500ms，第 2 次失败后等待 2000ms。
- 这些内部重试不重新 BLE 唤醒相机；只有全部失败后才暴露给用户处理。

相册首屏也从“等完整 ObjectInfo 后再显示”改成“两段式”:

- PTP 连接阶段已经拿到 `specifiedObjectHandles`，进入筛选页时先用这些 handle 生成占位 `CameraFile`，立即显示网格并开始加载可见缩略图。
- 后台继续读取完整 `ObjectInfo`，读完后替换列表，并保留已经加载好的缩略图。
- 这样首屏不再被 8s+ 的完整对象信息枚举阻塞；格式、尺寸、日期等完整信息以后台结果为准。

## 2026-06-04 连接恢复与首屏缩略图优化

进入相册阶段继续按“每一步有依据”收敛:

- 已配对相机重连顺序改为: 保存的 BLE address 直连 -> 短 scan -> scan fallback。这样有地址时不再先显示/执行“查找已配对相机”，直连失败才回退扫描。
- WiFi 失败后的重试先探测当前 PTP。用户如果已经去系统 Wi-Fi 手动连上相机热点，App 会直接打开相册通道，不重新 BLE 唤醒相机，也不重新 requestNetwork。
- WiFi 已连接后不再固定等 500ms 才打开 PTP。现在立即尝试 PTP，失败后再按 500ms、1000ms、1500ms... 短退避重试。
- 首屏缩略图读取从单 worker 改为 2 个受控 worker。保持小并发窗口，避免无限并发压垮相机 PTP，同时减少首屏缩略图串行等待。

## 2026-06-04 首屏缩略图回归修正

实机日志显示，占位列表出现后立即加载缩略图会和后台完整 `ObjectInfo` 枚举抢同一条 PTP 通道，导致 `Gallery discovery vendorInfos` 从约 8s 拉长到 49s。部分 JPEG fallback 还会解码成 7728x5152 的大 bitmap，造成筛选页操作卡顿。

修正后的规则:

- 完整 `ObjectInfo` 仍在加载时，只显示占位网格，不发缩略图请求。
- 完整列表替换后再按可见项加载缩略图。
- 缩略图 worker 回到 1 个，避免和 metadata/相机状态命令抢 PTP。
- 缩略图 bitmap 解码最大边长采样到 1024，避免 fallback 大图直接进入网格 UI。
