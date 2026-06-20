# Android Official XApp Connection Analysis

更新日期: 2026-06-19

本文记录从已安装官方 FUJIFILM XApp Android 包中读到的连接逻辑。后续 Android 改造以这里的证据作为对照，避免靠猜测等待或串行试探。

当前 Android 实现的完整执行规则见 `docs/android-current-execution-logic.md`。本文继续作为官方 XApp 行为对照和协议证据记录。

## 证据等级与决策规则

后续 Android 连接、相册、预览、导入相关决策按以下证据优先级判断:

1. 实机网络抓包或实机诊断日志能直接证明的行为优先。
2. 官方 Android XApp APK 静态分析能证明的 Android 平台连接流程优先于跨平台推测。
3. iPhone 原厂 XApp 抓包可证明相机 Wi-Fi/PTP 层的实际协议行为，但不能证明 BLE/GATT、Android `requestNetwork`、Android 权限弹窗等平台层行为。
4. 没有实机证据、APK 证据或稳定日志支撑的 fallback 不进入主链路；历史上证明有害或无证明有用的 fallback 应删除或隔离到显式实验路径。
5. 任何新优化必须能说明自己属于哪个阶段: 配对、BLE 唤醒/AP ready、Wi-Fi handover、PTP open、列表缩略图、高清预览、原图导入。不能跨阶段兜底。

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

## 原厂 XApp 配对与连接执行逻辑

本节是后续 Android 连接改造的官方对照基准。除非有新的原厂 APK 反编译证据或实机日志证据，否则不要用 iOS 逻辑、SSID 猜测、无身份扫描兜底或固定等待替代这里的步骤。

```mermaid
sequenceDiagram
    autonumber
    participant User as 用户
    participant XApp as FUJIFILM XApp
    participant Repo as BTEntryCameraRepository
    participant BLE as BTCamera / BLE GATT
    participant Camera as 相机
    participant WiFi as WiFiHandOverService
    participant Android as Android ConnectivityManager
    participant FFIR as ControlFFIR / native SDK
    participant PTP as 相机 192.168.0.1

    User->>XApp: 配对/注册相机
    XApp->>BLE: connectGatt + discoverServices
    BLE->>Camera: read GAP device name
    Camera-->>BLE: productName
    BLE->>BLE: cameraID = serialNumber + "_" + productName
    BLE->>Camera: read Y number / serial / SSID / MAC / firmware
    Camera-->>BLE: SSID, MAC, serial, firmware
    BLE->>Camera: read Wi-Fi passphrase
    Camera-->>BLE: passphrase
    XApp->>BLE: write CHARACTERISTIC_FF_PAIRING_KEY
    XApp->>BLE: write CHARACTERISTIC_FF_CONNECTED_DEVICE_NAME_STRING
    XApp->>Repo: save cameraID / SSID / passphrase / MAC / pairing info

    User->>XApp: 进入相册/导入图片
    XApp->>Repo: getCameraSSID(cameraID)
    Repo-->>XApp: exact SSID
    XApp->>Repo: getCameraWifiPassPhrase(cameraID)
    Repo-->>XApp: exact passphrase
    XApp->>Repo: getMacAddress(cameraID)
    Repo-->>XApp: MAC/BSSID

    XApp->>BLE: reconnect paired camera BLE/GATT for cameraID
    XApp->>BLE: write ImageTransferSetting = 00
    XApp->>BLE: write ImageTransferSettingEx = 01
    XApp->>BLE: write ImageResizeSetting = 00/01
    XApp->>BLE: write FunctionLaunchRequest = 0300
    loop wait AP state
        BLE->>Camera: read/notify CHARACTERISTIC_FF_AP_STATE
        Camera-->>BLE: AP_STATE
    end
    alt AP ready
        XApp->>WiFi: startWifiHandover(ssid, macAddress, passPhrase)
    else AP not ready / timeout
        XApp-->>User: stop at camera Wi-Fi/AP launch failure
    end

    WiFi->>Android: WifiNetworkSpecifier.setSsidPattern(exact SSID)
    WiFi->>Android: optional setBssid(MAC)
    WiFi->>Android: setWpa2Passphrase(passphrase)
    WiFi->>Android: NetworkRequest Wi-Fi + remove INTERNET + requestNetwork
    Android-->>WiFi: onAvailable(network)
    Android-->>WiFi: onCapabilitiesChanged(networkCapabilities)
    WiFi->>WiFi: verify capabilities SSID == targetSSID; save targetNetwork
    alt onUnavailable
        WiFi->>XApp: failure message 103
        XApp->>XApp: retry only when retryCount < 3, needsRetry, and not firstConnect
    end

    XApp->>FFIR: ControlFFIR.Open(smartPhoneID, timeout)
    FFIR->>Android: iterate Wi-Fi Networks
    FFIR->>Android: bindProcessToNetwork(network)
    FFIR->>Android: network.getSocketFactory()
    FFIR->>PTP: socket connect 192.168.0.1:55740 timeout=5000ms
    alt socket OK
        FFIR->>FFIR: Java_SDK_SetOpenSocket(fd, 55740)
        FFIR->>PTP: Java_SDK_Open(native PTP/IP init/open)
    else socket/native failure
        FFIR->>FFIR: close socket
        FFIR->>FFIR: wait 500ms
        FFIR-->>XApp: Open failure
    end
    FFIR-->>XApp: camera communication session opened
```

执行约束:

1. 配对阶段必须读到并保存 `cameraID`、精确 `SSID`、`passphrase`、`MAC/BSSID`。`cameraID` 来自 `serialNumber + "_" + productName`，BLE address 只是 endpoint，不是身份本身。
2. 进入相册阶段必须先通过 BLE/GATT 让相机进入 import-image / gallery Wi-Fi 模式，不能在未唤醒相机时直接猜 Wi-Fi 或直接打 PTP。
3. 相机 Wi-Fi 启动指令按官方顺序写入: `ImageTransferSetting=00`、`ImageTransferSettingEx=01`、`ImageResizeSetting=00/01`、`FunctionLaunchRequest=0300`。
4. Wi-Fi handover 使用配对记录或 BLE 读到的精确 `SSID + passphrase + optional BSSID`，通过 `WifiNetworkSpecifier` / `requestNetwork` 交给系统，不生成 FUJ 前缀候选。
5. Wi-Fi 成功不只看系统默认网络，必须保存目标 `Network` 并在 PTP socket 前绑定到相机 Wi-Fi 的 `Network`。
6. PTP/IP 入口由 `ControlFFIR.Open()` 调 `SDK_SetOpenSocket(55740)` 后交给 native `Java_SDK_Open()`。Java 层可见 socket 连接 `192.168.0.1:55740`，connect timeout 为 `5000ms`；native 内部 INIT/open 细节不在 Java 层完全展开。
7. `SDK_SetOpenSocket()` 失败时关闭 socket 并等待 `500ms` 后返回；这不是无条件快速循环重试。
8. `55741` 和 `55742` 在 `InitiateOpenCapture` 等拍摄/through/event 阶段才由官方代码另行打开；普通相册 open 首先只需要 base socket `55740`。
9. `WiFiHandOverService.onUnavailable()` 的重试是受条件控制的: `retryCount < 3`、`needsRetry == true`、并且不是首次连接；不是无边界 requestNetwork 循环。
10. 主链路失败时应停在当前失败阶段提示用户处理，不应跨阶段兜底。例如 BLE/AP ready 没确认时，不应直接进入 Wi-Fi/PTP。

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

- 相机 IP 固定走 `192.168.0.1`。
- 端口:
  - base socket: `55740`
  - through socket: `55741`
  - event socket: `55742`
- `SDK_SetOpenSocket(portNo)` 会优先使用当前相机 WiFi 对应的 `Network.getSocketFactory()`。
- 如果系统里保存了目标 `Network`，还会调用 `ConnectivityManager.bindProcessToNetwork(network)`。
- socket connect timeout 是 `5000ms`。这是官方 native `SDK_SetOpenSocket` 里的 socket connect 窗口，不等同于 Kotlin 侧已验证可工作的 PTP open 窗口。
- socket 创建 / 交给 native 失败后，`SDK_SetOpenSocket` 内部等待 `500ms` 再返回；Android 主链路不要 0ms 连续打 `55740`。
- `libFTLPTPIP.so` 内置的 `< PTP-IP Init_Command_Request >` 模板为 legacy plain INIT: `52 00 00 00 01 00 00 00 f2 e4 53 8f ad a5 48 5d 87 b2 7f 0b d3 d5 de d0 00 00 00 00 ...`。这证明 plain 模板存在，但不是当前 X-T5 实机唯一可用的 INIT 形态；昨天稳定版本和今天日志对照显示，Kotlin 路径需要先发送写入手机 `192.168.0.x` 的 legacy INIT 变体。

这说明进入 PTP/IP 前，关键是把进程和 socket 明确绑定到相机 WiFi 的 `Network`，不能只依赖系统默认网络。

## 2026-06-19 iPhone 原厂 XApp 实机抓包结论

本节记录 iPhone 原厂 XApp 通过 USB RVI 抓到的相机 Wi-Fi/PTP 实机流量。它是“相机 Wi-Fi 已连接后”的网络证据，用来校验 PTP 相册、预览、导入行为；它不能证明 BLE 配对/GATT、iOS Wi-Fi handover UI、系统授权弹窗等非 IP 层行为。

样本:

- 抓包文件: `.analysis/packet-captures/iphone-xapp-clean-rvi2-20260619-213437.pcap`
- 抓包接口: `rvi2`
- `tcpdump` 结果: `158630 packets captured`、`158736 packets received by filter`、`0 packets dropped by kernel`
- 用户动作时间:
  - `21:36:16` 相册列表出来
  - `21:36:59` 单图打开
  - `21:37:37` 放大完成
  - `21:38:10` 左右开始导入
- 分析脚本: `.analysis/analyze_xapp_pcap.py`

注意: RVI/PKTAP 会让同一 TCP payload 出现重复记录。本文所有字节数以 TCP seq + payload 去重并重组 PTP 流后的结果为准，不能直接用原始包数相加。

抓包能确定的连接事实:

- 普通相册浏览、单图预览、放大、导入都走 `192.168.0.101 -> 192.168.0.1:55740` 这一条 PTP command socket。
- 本样本没有看到 `55741` / `55742` 承载普通相册预览或导入；这与 Android 官方 APK 静态分析一致: `55741`、`55742` 属于拍摄/through/event 等阶段，不是普通相册 open 的主路径。
- PTP payload 是 CameraVendor legacy packet 格式，和 Android 当前 `CameraVendorLegacyOperationRequest` 的 `length + kind + opCode + transactionId + params/data` 结构一致。
- 有效去重 payload:
  - camera -> phone: `19,433,691 bytes`，约 `18.53 MiB`
  - phone -> camera: `21,830 bytes`
- 样本内主要 opcode:
  - `GET_DEVICE_PROP_VALUE(0x1015)`: `810`
  - `GET_OBJECT_INFO(0x1008)`: `525`
  - `SET_DEVICE_PROP_VALUE(0x1016)`: `6`
  - `GET_PARTIAL_OBJECT(0x101B)`: `3`
  - `VENDOR_GET_LATEST_OBJECT_INFO(0x9054)`: `1`
  - `VENDOR_GET_EXTENSION_THUMB(0x9055)`: `1`

原厂进入相册后的初始化行为:

- `SET_DEVICE_PROP_VALUE(0xDF01)=20`
- `SET_DEVICE_PROP_VALUE(0xDF28)=3`
- `SET_DEVICE_PROP_VALUE(0xD226)=0`
- `VENDOR_GET_LATEST_OBJECT_INFO(0x9054, handle=0x10000001)` 返回 `144 bytes`
- `VENDOR_GET_EXTENSION_THUMB(0x9055, handle=0x10000001)` 返回 `41061 bytes`，抽出后是 `640x480` JPEG
- 后续存在大量 `GET_DEVICE_PROP_VALUE(0xD212)` 轮询，用于相册/当前对象上下文状态；这类状态轮询不应和缩略图、预览、导入并发抢 PTP 通道。

单图打开的确定行为:

1. 原厂先发 `SET_DEVICE_PROP_VALUE(0xD226)=1`。
2. 随后发 `GET_OBJECT_INFO(handle=0xb6)`。
3. 该 ObjectInfo 的 `compressedSize` 为 `0x1f7427`，即 `2061351 bytes`。
4. 原厂发 `GET_PARTIAL_OBJECT(handle=0xb6, offset=0, length=0x1f7427)`。
5. 抽出的返回数据是完整 JPEG，尺寸 `3840x2560`，结尾有 JPEG EOI。
6. 预览完成后原厂发 `SET_DEVICE_PROP_VALUE(0xD226)=0`。

因此，原厂单图清晰不是因为把 `640x480` 缩略图放大，也不是立刻下载完整原图；而是通过 `D226=1 + ObjectInfo.compressedSize + GET_PARTIAL_OBJECT` 读取一张中间档高清预览 JPEG。

放大行为:

- `21:36:59-21:37:37` 放大期间没有显著图片数据传输，主要是 `GET_DEVICE_PROP_VALUE` 状态轮询。
- 这说明放大直接使用单图打开时已经拿到的 `3840x2560` 预览图，不会在手势缩放时再临时下载更大图。

导入行为:

1. 原厂发 `SET_DEVICE_PROP_VALUE(0xD226)=2`。
2. 原厂分段读取同一 handle:
   - `GET_PARTIAL_OBJECT(handle=0xb6, offset=0, length=0xbfffe0)` -> `12582880 bytes`
   - `GET_PARTIAL_OBJECT(handle=0xb6, offset=0xbfffe0, length=0x46b737)` -> `4634423 bytes`
3. 两段拼接后是完整 JPEG，尺寸 `7728x5152`，总计 `17217303 bytes`，结尾有 JPEG EOI。

分时窗口:

- 相册列表/预列表: camera -> phone 约 `0.07 MiB`
- 单图打开: camera -> phone 约 `2.02 MiB`
- 放大: camera -> phone 约 `0 MiB`
- 导入: camera -> phone 约 `16.44 MiB`

对后续 Android 决策的约束:

1. 配对与进入相册主链路仍以 Android 官方 APK 静态分析和 Android 实机日志为准: BLE 身份确认、精确 SSID/passphrase/BSSID、AP ready、Network 绑定、`55740` PTP open 这些步骤不能被这次 iPhone IP 抓包替代或省略。
2. 这次抓包反向确认: 相机 Wi-Fi 已建立后，普通相册/预览/导入只需要 base command socket `55740`；不要为了单图预览或导入打开额外 PTP session 或 `55741/55742`。
3. 列表缩略图、高清预览、原图导入必须分层:
   - 缩略图: 小图通道，不能用未证明有效的 partial fallback 顶替。
   - 高清预览: `D226=1 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT(compressedSize)`，缓存完整 `3840x2560` 预览 JPEG。
   - 原图导入: `D226=2 -> GET_PARTIAL_OBJECT` 分段读取完整原图，和预览缓存状态分离。
4. `GET_PARTIAL_OBJECT` 不是缩略图兜底的证据。它在本样本里用于高清预览和原图导入，并且都依赖明确的压缩模式和 `ObjectInfo.compressedSize`。
5. PTP 请求必须由统一调度器串行/优先级控制。原厂行为显示状态轮询、ObjectInfo、预览、导入都复用同一条 command socket；Android 不应让缩略图 worker、预览、下载各自并发抢相机。
6. 单图预览缓存是必要设计: 原厂打开一次单图会传约 `2 MiB` 高清预览；放大不再传输。Android 应以内存 + 磁盘缓存避免每次打开同一张图都重新走 PTP。
7. 不能把本节作为“可以跳过 BLE/AP ready/Network 绑定”的证据。抓包开始时手机已经完成系统 Wi-Fi 连接，BLE 配对和 Wi-Fi handover 的前置过程不在 pcap 的可见范围内。

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

## 当前 Android 官方路径约束

2026-06-18 复查官方 XApp 后，Android 进入相册主链路按“严格官方协议适配层”执行。这个链路只使用已经确认的相机身份和官方 BLE/配对记录里的精确连接信息，不在正常路径里猜测、无身份扫描兜底或预热 WiFi。

主链路顺序:

1. `ReconnectPairedBle`: 读取当前选中的配对记录，先使用保存的 Bluetooth address 做 GATT direct connect；直连超时后，按官方 `PairingMode.RE_CONNECT` 对当前 `cameraID` 做受限扫描并连接匹配候选。不能做无身份扫描，也不能把扫描结果绕过身份校验直接推进 Wi-Fi/PTP。
2. `TransferAuthorization`: 通过 BLE 确认配对状态，并读取官方 SSID、WiFi passphrase、MAC/BSSID。没有拿到官方 SSID 和密码，不进入 WiFi 步骤。
3. `ActivateCameraWifi`: 写官方 AP launch/transfer activation 指令，让相机打开 WiFi。
4. `WaitCameraWifiReady`: 只等待 BLE transfer/AP ready 逻辑返回，不在等待期间启动 WiFi prewarm。
5. `JoinCameraWifi`: 使用一个精确的官方 `ssid + passphrase + optional bssid` 发起一次系统 `requestNetwork`。不生成 FUJ 前缀候选，不串行尝试多个 SSID，也不在主链路里用旧候选替代本次官方信息。
6. `ConnectPtp`: 在相机 WiFi 对应 `Network` 上打开 PTP/IP 相机通信会话。官方 native `SDK_SetOpenSocket` 证明 socket 必须绑定相机 Wi-Fi Network；当前 Kotlin 实现保留已验证稳定窗口: 单次 socket connect 1.5 秒，最多 5 次，失败间隔线性增加，INIT ACK read timeout 15 秒。
7. `ConfirmGalleryMode`: PTP 连通后再确认相机已经进入相册模式。

恢复入口单独处理:

- 如果用户已经手动连上相机 WiFi，可以走“检测当前 WiFi/PTP 后继续”的恢复入口。
- 这个恢复入口不能混入正常“点击进入相机相册”的官方主链路；主链路失败说明对应步骤没有按协议完成，应停在具体步骤展示原因。

## 下一步优化方向

优先级从高到低:

1. 对齐 WiFi handover: 使用已保存的精确 SSID/passphrase/MAC，减少 SSID 猜测和无依据重试。
2. 对齐 AP readiness: 读取或监听 AP state/transfer state，压缩固定等待。
3. 对齐 Network 绑定: 确保 PTP socket 使用相机 WiFi 的 `Network`。
4. 大图库首屏: 首屏限制 handle 数量、优先读取最新缩略图，完整 metadata 延后。
5. 方向信息: 继续记录并解析 object info/vendor extension 字段，确认是否能直接获得方向或至少可靠宽高。

## 2026-06-04 优化记录

从日志看，旧实现会把 BLE 读到的精确 WiFi 凭据标记为隐藏网络，导致第一个 `hidden=true` attempt 直接等待到 30 秒超时，然后才继续试其他候选。官方 XApp 的 `WiFiHandOverService` 使用精确 SSID pattern、可选 BSSID、可选 passphrase，没有看到 `setIsHiddenSsid(true)` 分支。

因此 Android 侧将 `referenceAppConfiguration(ssid, passphrase)` 改为 `isHidden=false`。2026-06-14 后进入相册主链路只使用官方 BLE 返回的精确配置，不再靠名称推导 fallback 候选。

同一轮也给 BLE WiFi 凭据刷新加了早返回: 如果 `performHandshake()` 已经拿到并保存了 SSID/passphrase，进入相册阶段不再重复读取这两个 characteristic。2026-06-14 后，如果当前 BLE 会话没有官方 WiFi 凭据，主链路会停在 `TransferAuthorization`，不再用猜测候选继续。

## 2026-06-04 WiFi 重试规则

WiFi handoff 失败时，相机通常已经停在“等待手机连接 WiFi”的界面。这个状态下 App 的重试不能重新走 BLE 唤醒/传图启动，因为那会让相机和手机状态更不一致。

历史恢复规则曾调整为:

- `JoinCameraWifi` 失败: 先探测当前 PTP；如果没有连上，就复用已保存的 WiFi SSID/passphrase 重新 requestNetwork，然后再打开 PTP。不重新 BLE 唤醒。
- `ConnectPtp` / `LoadGallery` 失败: 只探测当前相机 WiFi/PTP，不重新 BLE 唤醒。
- 只有用户主动点“进入相机相册”开始新一轮，才会重新走 BLE 确认和相机 WiFi 启动。

UI 侧也同步调整: 已配对状态下如果还挂着进入相册阶段的问题，主按钮显示“重试”，不再显示“进入相机相册”，避免误触完整重连流程。

## 2026-06-04 WiFi 与首屏相册优化

日志显示 MIUI 可能在相机 WiFi 刚启动后很快返回 `onUnavailable`，本次样本为 3454ms。此时 SSID/passphrase 并不一定错误，因为同一相机稍后重试可在 2957ms 内 `onAvailable` 并完成 PTP。当时 Android 侧曾增加同一精确 WiFi 的内部自动重试；2026-06-14 后主链路已撤销该内部重试:

- 每个精确 WiFi candidate 最多自动 requestNetwork 3 次。
- 第 1 次失败后等待 1500ms，第 2 次失败后等待 2000ms。
- 这些内部重试不重新 BLE 唤醒相机；只有全部失败后才暴露给用户处理。

相册首屏也从“等完整 ObjectInfo 后再显示”改成“两段式”:

- PTP 连接阶段已经拿到 `specifiedObjectHandles`，进入筛选页时先用这些 handle 生成占位 `CameraFile`，立即显示网格并开始加载可见缩略图。
- 后台继续读取完整 `ObjectInfo`，读完后替换列表，并保留已经加载好的缩略图。
- 这样首屏不再被 8s+ 的完整对象信息枚举阻塞；格式、尺寸、日期等完整信息以后台结果为准。

## 2026-06-04 连接恢复与首屏缩略图优化

这一轮曾经为了恢复体验加入过多轮 scan fallback 和 WiFi 重试。2026-06-18 复查后，主链路以“当前 Android 官方路径约束”为准:

- 历史上已配对相机曾使用: 保存的 BLE address 直连 -> 短 scan -> 多轮 scan fallback。多轮 scan fallback 已退出进入相册主链路；当前主链路保留 `DirectAddress -> OfficialReconnectScan`，其中扫描必须等价于原厂 `PairingMode.RE_CONNECT`，受当前 `cameraID`/同一相机身份约束。
- WiFi 失败后的重试先探测当前 PTP。用户如果已经去系统 Wi-Fi 手动连上相机热点，App 会直接打开相册通道，不重新 BLE 唤醒相机，也不重新 requestNetwork。
- 历史上曾在 WiFi 已连接后立即尝试 PTP，并按 500ms、1000ms、1500ms... 短退避重试。2026-06-19 复查官方 XApp 后，主链路按官方 `cameraOpen` 窗口执行: 每次 open 5 秒，总窗口约 30 秒；socket/open 失败间隔固定 500ms，对齐 `SDK_SetOpenSocket`，不使用 0ms 连续重试或自定义线性退避。
- 首屏缩略图读取从单 worker 改为 2 个受控 worker。保持小并发窗口，避免无限并发压垮相机 PTP，同时减少首屏缩略图串行等待。

## 2026-06-04 首屏缩略图回归修正

实机日志显示，占位列表出现后立即加载缩略图会和后台完整 `ObjectInfo` 枚举抢同一条 PTP 通道，导致 `Gallery discovery vendorInfos` 从约 8s 拉长到 49s。部分 JPEG fallback 还会解码成 7728x5152 的大 bitmap，造成筛选页操作卡顿。

修正后的规则:

- 完整 `ObjectInfo` 仍在加载时，只显示占位网格，不发缩略图请求。
- 完整列表替换后再按可见项加载缩略图。
- 缩略图 worker 回到 1 个，避免和 metadata/相机状态命令抢 PTP。
- 缩略图 bitmap 解码最大边长采样到 1024，避免 fallback 大图直接进入网格 UI。

## 2026-06-12 大图库首屏缩略图节流

实机日志显示，最新相机样本在 `specifiedHandles=999`、首批 `initialHandles=200` 时，占位网格能立即显示，但如果完整 `ObjectInfo` 仍在后台枚举时连续读取几十张缩略图，会让同一条 PTP 通道在 metadata 和 thumbnail 之间反复切换。本次样本中 `Gallery discovery vendorInfos=200` 耗时约 15.9s，同时每个 167936 字节的 JPEG preview 在 Android 解码边界上报告为 `7728x5152`，如果在 Compose UI 线程解码会造成筛选页卡顿或看起来图片不显示。

当前规则:

- 进入筛选页后仍先发布首批占位 `CameraFile`，保证列表不被完整 `ObjectInfo` 阻塞。
- 完整 `ObjectInfo` 加载期间，只允许最多 8 个已加载/排队缩略图请求，用于首屏感知；超过预算的可见项等完整 metadata 完成后再请求。
- 缩略图 worker 保持 1 个，避免压垮相机 PTP。
- 网格缩略图解码放到后台线程，最大边长采样到 512；预览弹层仍按 1024 采样，避免影响大图预览质量。

## 2026-06-12 标准缩略图优先修正

后续实机截图确认，图库已经显示 `200 / 200`，但 tile 全部停留在 `JPG` 占位。日志显示相机返回的 `ObjectInfo` 已带 `thumbInfo=640x480`，但读取策略仍因为 `compressedSize=167936` 直接走 `GET_PARTIAL_OBJECT`，返回 `reason=smallPreviewObject` 的 167936 字节 JPG 对象，Android 解码边界为 `7728x5152`，不是适合列表展示的标准缩略图。

当前规则:

- 如果 `ObjectInfo.thumbFormat == JPEG` 且 `thumbPixWidth/thumbPixHeight > 0`，缩略图必须先走标准 `GET_THUMB`。
- 2026-06-19 抓包复核后，列表缩略图不再使用 `GET_PARTIAL_OBJECT` fallback；标准 `GET_THUMB` 不可用时记录缩略图失败。
- 这样列表优先拿相机提供的 640x480 缩略图，避免把整张小 JPG/partial 对象当作缩略图显示。

## 2026-06-12 大图库首屏阻塞修正

最新实机日志显示，`Fast gallery placeholders count=1000` 后立刻进入 `Gallery discovery initialHandles=200/1000`，后台 200 次 `GetObjectInfo` 耗时约 42 秒。在这 42 秒内抢先发出的首屏 `GET_THUMB` 连续超时，`GET_PARTIAL_OBJECT` fallback 又返回不完整 JPEG；直到 `Gallery discovery vendorInfos=200` 完成后，标准 `GET_THUMB` 才恢复到每张约 50-110ms。

因此旧策略“完整 ObjectInfo 加载期间允许少量首屏缩略图并发”仍然会与相机 PTP 状态竞争。Android 侧当前策略改为:

- 大图库已经拿到 vendor handle 占位列表时，先发布完整 handle 占位并结束列表 loading。
- 不立即启动完整 ObjectInfo 枚举，避免它在首屏前占用 40 秒以上相机通道。
- 首屏可见项优先读取标准 `GET_THUMB`；完整文件名、日期、尺寸、RAW/HEIF 信息后续再低优先级补齐。
- 2026-06-19 后不再把 `GET_PARTIAL_OBJECT` 作为列表缩略图兜底，避免把 partial 原图/预览片段当作网格缩略图。

## 2026-06-12 富士扩展缩略图与 UI 缓存修正

补充分析官方 XApp 后，确认其 WLAN 相册路径封装了 `getExtensionThumb` / `ReadThumbnail` / `ReadImageInfo`，并在 UI 侧按 handle 缓存已解码的 `ImageBitmap`。本项目不复制官方代码、JNI 实现或资源，只根据可观察到的协议行为重新实现兼容路径。

当前规则:

- `0x9055 GetExtensionThumb(handle=0x10000001)` 只用于官方初始化链路里的 current image thumbnail context prime。
- 列表单张缩略图按官方 `ReadThumbnail` 语义走标准 `GET_THUMB(handle)`；`GET_PARTIAL_OBJECT` 不再作为最后兜底。
- 诊断日志区分 `Thumbnail vendorExtension` 和 `Thumbnail standard`，后续实机可以直接判断命中的通道。
- `BrowseViewModel` 增加 handle 级缩略图缓存，完整 `ObjectInfo` 回来或占位列表刷新时不覆盖已经加载好的缩略图。
- 网格和下载中心优先用 `BitmapFactory` 采样解码，减少部分 Android/厂商 ROM 上 `ImageDecoder` 失败导致一直显示占位的风险。

## 2026-06-16 Android 官方 XApp 缩略图链路复核

从安卓测试机拉取官方 `com.fujifilm.xapp` 2.7.3(1) 的 base/split APK 后，只做符号和日志字符串级分析。官方包包含 `FTLPTP.so`、`libFTLPTPIP.so`、`libXAPI.so`、`libFFEXIF.so`；Java/native 符号能看到:

- `Java_SDK_ReadThumbnail`、`ReadImageInfoAndThumbnail`、`Java_SDK_ReadImageInfo`
- `Java_SDK_GetExtensionThumb Start/End`
- `backgroundInit/getExtensionThumb`
- `loadThumbnailCoroutine ---> semaphore acquire`

结论:

- 官方有专门的 `ReadThumbnail` 缩略图通道，并用 semaphore 控制缩略图读取，不会把 `GET_PARTIAL_OBJECT` 返回的原图开头片段当网格缩略图。
- `GET_PARTIAL_OBJECT` 读到的 167936 字节 JPEG 如果没有 EOI，只是未完整的原图/预览片段；即使 Android 能读出 `7728x5152` 或 `5472x3648` 的 header，也不能作为列表缩略图缓存。
- 大图库占位列表发布后，不应立刻启动完整 `ObjectInfo` 枚举和缩略图读取抢同一条 PTP 通道；首屏应优先保证标准 `GET_THUMB` 连续完成。

## 2026-06-16 Android 下载链路 PTP 互斥修正

实机日志复核显示，下载失败不是固定格式错误，而是时序竞争:

- 失败场景中，`TransferService Download start` 后 1 秒内 `BrowseViewModel` 继续发 `Get thumbnail`，最终原图下载 `Read timed out`。
- 成功场景中，前两张下载前缩略图队列刚好结束，因此下载顺利；但第三张下载期间缩略图又插入，缩略图侧开始 `Read timed out`。这证明问题是 PTP 通道竞争，只是每次输赢不同。
- 下载项来自大图库占位列表时，`Download start expected=0`，保存前必须重新解析真实 `ObjectInfo`，避免用 `0x00000476.JPG` 这类占位文件名保存或标记下载状态。

当前规则:

- 原图下载是独占 PTP 操作。启动下载前必须暂停缩略图请求、清空待执行缩略图队列，并等待当前缩略图 worker 退出。
- 下载中不接受新的可见缩略图或预览缩略图请求；下载完成后再恢复首屏缩略图加载。
- 保存到系统相册前，先按 handle 解析真实 `ObjectInfo`，用真实文件名/格式保存；原图读取仍沿用现有 `GetPartialObject` + EOI 停止逻辑，不按 167936 这类 context size 截断。

## 2026-06-04 MIUI WiFi 短失败重试修正

历史记录: 这一轮曾为 MIUI 短 `onUnavailable` 增加同一 WiFi 的内部自动重试。2026-06-14 后，进入相册主链路不再使用这个规则；当前规则是一个官方 SSID/passphrase/BSSID 对应一次系统 `requestNetwork` 等待窗口，失败就停在 `JoinCameraWifi` 并展示 SSID/密码给用户手动处理。

实机日志显示，同一个相机 WiFi、同一组 SSID/passphrase 下，首次进入相册阶段连续 3 次 `requestNetwork` 会被 MIUI 很快返回 `onUnavailable`:

- 第 1 次约 3278ms 返回 `onUnavailable`。
- 第 2/3 次约 1.1s 返回 `onUnavailable`。
- 用户随后点重试，同一个 WiFi 在 2946ms 内 `onAvailable` 并完成 PTP。

当时推断失败不是凭据错误，而是手机系统短时间内还没完成/允许 WiFi handoff。历史规则曾调整为:

- 同一个精确 WiFi candidate 内部自动尝试 5 次。
- 失败间隔改为 1500ms、3000ms、4000ms、6000ms。
- 短 `onUnavailable` 不立即暴露给用户，先继续后台等待并自动重试。

## 2026-06-04 对齐官方 WiFi handover 关键点

官方 XApp 的 `WiFiHandOverService` 会用精确 SSID、可选 BSSID、passphrase 发起 `requestNetwork`，并在后续 socket 层使用目标 `Network.getSocketFactory()`。Android 侧同步对齐:

- 新增读取 `CAMERA_WIFI_MAC_ADDRESS_CHAR`，兼容 12 位十六进制字符串和 6 字节原始 MAC。
- `CameraVendorWifiNetworkConfiguration` 保存规范化后的 `bssid`，旧的 3 字段本地配对记录继续兼容。
- `WifiNetworkSpecifier` 改用 literal `setSsidPattern(...)`，有 BSSID 时调用 `setBssid(...)`，继续设置 WPA2 passphrase。
- PTP 连接在自动 WiFi handoff 成功后使用当前相机 WiFi 的 `Network.socketFactory` 创建 socket；日志记录 `hasNetworkSocketFactory` 便于验证。

## 2026-06-12 AP ready 协议对齐

进入相册不再把 BLE 启动命令写完视为相机 WiFi 已准备好。Android 侧现在按官方 ReferenceApp import-image 启动顺序执行:

1. `ImageTransferSetting = 00`
2. `ImageTransferSettingEx = 01`
3. `ImageResizeSetting = 00/01`
4. `FunctionLaunchRequest = 0300`
5. 等待 `AP_STATE` 返回 `0x8001` 或 `0x8003`

只有 AP ready 后才主动断开 BLE 并进入 WiFi handoff。诊断日志会记录每次 `AP_STATE` 值和耗时，例如 `ReferenceApp AP ready elapsedMs=...`。如果 12 秒内没有 ready，流程会停止并提示相机 WiFi/相册服务未确认，避免手机提前 requestNetwork 后在 PTP 通道长时间等待。

实机 X-T5 日志补充: 写入 `FunctionLaunchRequest=0300` 后，相机屏幕可能已经进入 WiFi 等待界面，但 BLE `AP_STATE` 仍持续返回 `0x8000`。该状态只能证明 AP 启动中 / launch accepted，不能证明相册 PTP 服务已经准备好。Android 侧因此不再把 `0x8000` 作为进入 WiFi 的放行条件；必须等到 `0x8001` 或 `0x8003`，否则停止在 BLE/AP ready 阶段。

## 2026-06-14 已配对相机身份优先

官方 XApp 的 `BTCamera.readCharacteristicGapDeviceName()` 会把相机序列号和产品名组合成 `cameraID`，后续 `FunctionLaunchRequest`、`AP_STATE` 过滤、SSID/passphrase/MAC 读取都围绕这个相机身份执行。

Android 侧同步补齐身份层:

- 本地配对记录新增 `cameraId`，优先使用 `serialNumber_productName`，旧记录或系统蓝牙 bond 兜底时使用序列号、蓝牙地址或 SSID 生成过渡身份。
- 已配对进入相册时，必须围绕当前选中 `cameraId` 记录执行 BLE 重连：先使用保存蓝牙地址走 `DirectAddress`，直连失败后才进入官方 `RE_CONNECT` 受限扫描。
- 无身份约束的扫描兜底不属于进入相册主链路。任何扫描都必须通过 `cameraId`、序列号、蓝牙地址或设备名确认仍是同一台相机；GATT 连上后必须再次读取身份并强校验。
- 如果连接到的相机身份与已配对记录不一致，流程停止并要求重新配对，不能继续启动 WiFi 或进入 PTP。

## 2026-06-14 多相机配对仓库

为了对齐官方按 `cameraID` 管理多台相机的模型，Android 侧不再把本地配对信息视为单条记录:

- `CameraVendorPairedCameraStore` 保存多条 `CameraVendorPairedCameraRecord`，每条包含 `cameraId`、设备名、序列号、蓝牙地址、WiFi 配置和最近连接时间。
- 旧版单相机 SharedPreferences 字段会在读取时迁移为一条多相机记录；删除最后一条多相机记录后不会再被旧字段重新迁移回来。
- `load()` 继续作为兼容 API 返回当前选中相机；新增 `loadAll()`、`select(cameraId)`、`remove(cameraId)` 用于多相机列表、选择和删除。
- 进入相册、WiFi 重试、忘记配对都只针对当前选中的 `cameraId`。
- UI 在存在多台已配对相机时显示选择列表；只有一台时保持原来的简洁入口。

## 2026-06-14 官方协议适配层执行顺序

进入相册阶段新增 Android 侧 `CameraVendorOfficialGalleryConnectionAdapter`。它不是复用官方代码或官方 JNI，而是把已确认的官方协议行为转成项目内可测试的状态机，原则是每一步成功确认后才允许下一步:

1. `ReconnectPairedBle`: 当前选中 `cameraId` 的已配对相机先使用保存的 BLE address 直连；直连失败后进入官方 `RE_CONNECT` 受限扫描。不能进入无身份扫描或多轮 scan fallback。
2. `TransferAuthorization`: 通过 BLE 确认相机允许当前手机传图，并读取/刷新精确 SSID、passphrase、BSSID/MAC。
3. `ActivateCameraWifi`: 写入 ReferenceApp import-image 启动命令，包括传输尺寸偏好和 `FunctionLaunchRequest=0300`。
4. `WaitCameraWifiReady`: 等待 `AP_STATE` 明确返回 `0x8001` 或 `0x8003`。`0x8000` 仍只代表启动中，不能放行。
5. `JoinCameraWifi`: Android 使用精确 Wi-Fi 配置加入相机热点；有 BSSID 时绑定 BSSID。
6. `ConnectPtp`: 使用相机 Wi-Fi 对应的 `Network.socketFactory` 打开 `192.168.0.1:55740`。PTP legacy INIT 沿用当前实机稳定顺序：先发送带手机 `192.168.0.x` 的 legacy INIT 变体；未收到 ACK 时再发送官方 native plain legacy 模板，GUID 后 4 字节保持 `0`。friendly name 使用当前已确认手机名，字段超长才回退。Kotlin open 窗口保持单次 1.5 秒、最多 5 次、线性退避；INIT ACK read timeout 保持 15 秒。
7. `ConfirmGalleryMode`: PTP open session 成功后，只执行官方图片浏览 function mode 设置: `SetFunctionMode(20)`、两次 `GetFunctionVersion(57128)`、按相机返回版本 `SetFunctionVersion(57128, version)`、`GetDualSlotStatus()`。照片 handle、缩略图、搜索模式、日期分组等读取全部移动到图库加载阶段。

兼容说明:

- `CameraVendorPtpIdentityPolicy` 优先使用当前已确认手机名；超出 54 字节 legacy 字段时才回退到 `CamTransfer`，避免把过长标识截断进富士 legacy INIT 包。
- `CameraVendorBleHandshake.prepareTransferActivation()` 保持原 API，但内部已经拆成“写启动命令”和“等待 AP ready”，方便服务层按步骤确认。
- 手动 Wi-Fi 重试路径仍保留短路径: 如果用户已经手动连上相机 Wi-Fi，先探测 PTP 并继续打开相册，不强制重新 BLE 唤醒。

## 2026-06-14 BLE 会话复用边界

为优化进入 Wi-Fi 前的等待，Android 侧允许复用上一轮仍然有效的 BLE/GATT 会话，但复用边界必须保守:

- 只有 `BluetoothGatt` 仍存在、传图启动必需特征仍能找到、当前相机身份与选中 `cameraId` 匹配、且会话年龄不超过 2 分钟时，才复用 `CameraVendorBleHandshake`。
- 复用只跳过 BLE reconnect，不跳过 `TransferAuthorization`、`ActivateCameraWifi`、`WaitCameraWifiReady` 等官方步骤。
- 如果缓存会话断开、缺特征、身份不匹配或过期，立即丢弃缓存并回到已配对地址直连；直连失败后只允许当前 `cameraID` 的官方 `RE_CONNECT` 受限扫描，仍失败就停止在 `ReconnectPairedBle`。
- `AP_STATE` 不做缓存。每次进入相册都必须重新等待相机返回 `0x8001` 或 `0x8003` 后才允许 Wi-Fi handoff。
- 已配对地址直连的 GATT 连接超时使用 15 秒；超时后暴露为已配对 BLE 连接失败，提示用户重试或重新配对。

## 2026-06-16 已配对身份与 BLE endpoint

当前 Android 侧按官方 `cameraID` 模型收敛为:

- `cameraID` 是配对记录主键，优先使用 `serialNumber_productName`。本地仓库按 `cameraID` 保存多台相机记录，并保留旧单相机字段迁移读取能力。
- BLE GATT 不能直接用 `cameraID` 发起连接；Android 连接入口仍是 `BluetoothDevice` 地址。因此 `cameraID` 用于选择和校验相机身份，BLE 地址只是该身份下的连接 endpoint。
- 进入相册时，先从当前 `cameraID` 记录和系统已配对 bond 构造同一相机的 BLE endpoint 候选；直连失败后才按原厂 `RE_CONNECT` 做受限扫描。扫描命中只是候选，必须在 GATT 身份校验通过后才能进入 Wi-Fi/PTP。
- 每次 GATT 连上后必须读取相机序列号/设备名，并与当前 `cameraID` 匹配。身份不匹配时停止在 `ReconnectPairedBle`，不能继续 Wi-Fi 或 PTP。
- 已配对 direct GATT 超时调整为 15 秒。实机日志显示 Android BLE 地址解析有时超过 6 秒才完成连接，6 秒会把可成功的已配对连接误判失败。

## 2026-06-17 Android 执行规则同步

本轮 Android 侧把连接、图库和下载中心的当前实现写入 `docs/android-current-execution-logic.md`，作为后续开发的主执行文档。要点:

- 已配对进入相册继续按 `cameraID` 身份模型执行。BLE address 只是 endpoint；GATT 连上后必须确认身份再进入 Wi-Fi/PTP。
- BLE session 复用只允许在 GATT 仍活着、transfer activation 特征齐全、当前 `cameraID` 匹配、相机配对确认 ACK 已完成且未过 TTL 时使用。`AP_STATE` 每次仍重新等待。
- 相册日期选择不再依赖照片日期去重，也不为了打开日期弹窗触发全量 metadata 加载；用户可以直接选择最近约 5 年内日期。
- 列表和下载中心缩略图共用展示前处理: 旋转后裁剪边缘大面积黑色 letterbox，再交给网格裁切。
- 下载历史记录开始持久化缩略图 bytes；旧记录仍兼容读取，但旧记录可能没有缩略图。
- 下载中心右上角清理入口使用文字 `清理记录`，表示只清理 App 下载记录，不删除照片。

## 2026-06-14 AP launching 阶段 Wi-Fi 预热

历史记录: 这一轮曾尝试在 `AP_STATE=0x8000` 阶段提前 requestNetwork。2026-06-14 后官方主链路禁用 Wi-Fi prewarm；等待相机 AP ready 和手机加入 WiFi 是两个明确步骤，不能提前合并。

实机日志显示，相机在写入 `FunctionLaunchRequest=0300` 后通常会保持 `AP_STATE=0x8000` 约 5-7 秒，之后才返回 `0x8001`。当时为了减少 `AP_STATE` ready 后手机再 requestNetwork 的等待，Android 侧曾增加保守预热；2026-06-14 后主链路已撤销该预热:

- 只有 `AP_STATE=0x8000` 已持续至少 2.5 秒，并且 Wi-Fi 配置是单个精确可见网络时，才启动一次后台 Wi-Fi prewarm。
- prewarm 使用相同的精确 SSID/passphrase/BSSID，超时 10 秒。
- prewarm 成功只代表手机可能已经提前加入相机 Wi-Fi；状态机仍必须等 `AP_STATE=0x8001/0x8003` 后才确认 `WaitCameraWifiReady`。
- `JoinCameraWifi` 步骤会优先消费 prewarm 成功结果；如果 prewarm 失败或没有启动，就走原来的正式 Wi-Fi join。
- prewarm 失败不暴露给用户、不终止官方连接流程；取消或 AP ready 失败时会清理 network callback，避免残留 requestNetwork。
