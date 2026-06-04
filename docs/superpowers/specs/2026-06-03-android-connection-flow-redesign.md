# Android Connection Flow Redesign

**Date:** 2026-06-03

## Goal

把 Android 相机连接链路改造成一套可验证、可诊断、可逐步确认的执行逻辑。

产品上只分两大阶段：

1. 配对相机
2. 进入相册

底层仍拆成更细的步骤。产品层面不再暴露“自动模式 / 引导模式”两个概念；用户只看到当前步骤、明确提醒和失败后的一个主操作。底层可以保留内部推进策略，但 UI 必须由同一套步骤状态驱动。

- 能由 App 自动验证的步骤，验证成功后才继续。
- 需要用户确认的步骤，用户确认后 App 再做验证。
- 验证失败时停在当前步骤，只给出 `重试` 或 `重新配对` 等明确操作。

## Current Problem

现有流程的问题不是步骤完全错误，而是很多步骤完成条件不够明确，导致代码只能基于线索推断并等待超时。

典型表现：

- WiFi 阶段会串行尝试多个 SSID / hidden 候选，每个等待 30 秒，失败一次可能超过 2 分钟。
- BLE handshake 完成后，不等于相机端配对 ACK 已完成；用户提前进入相册会进入半配对状态。
- 本地 remembered pairing、系统 Bluetooth bond、当前 handshake、相机真实状态可能不同步。
- 需要用户操作的问题被当成可自动恢复问题继续等待，例如旧系统蓝牙配对、相机未进入配对注册、WiFi 系统弹窗未确认、隐藏 WiFi 未手动加入。

新的执行逻辑必须减少猜测，改成：

```text
当前步骤有明确成功证据 -> 进入下一步
当前步骤无法确认成功 -> 停在当前步骤
失败后只暴露当前步骤的下一步操作，不跨阶段猜测
```

## Product Model

### Phase 1: Pair Camera

目标：让手机和相机建立可信蓝牙配对关系，并保存 App 可用的相机记录。

完成后产品状态：

```text
已保存配对 / 已配对 <camera-name>
主操作：进入相册
辅助操作：忘记这台相机 / 重新配对
```

配对阶段失败不能进入相册。

`PAIRED` 只表示本地已有可用配对记录，不等同于“本次配对刚刚成功”。UI 不应仅因为 `ConnectionState.PAIRED` 显示“配对成功”。只有底层 `confirmPairing()` 明确成功并保存记录后，才可以把状态推进到 `PAIRED`；页面文案仍使用“已保存配对 / 已配对 <camera-name>”。

### Phase 2: Enter Gallery

目标：让已配对相机进入传图模式，手机加入相机 WiFi，并建立 PTP 相册连接。

进入相册阶段失败默认不应倒回重新配对，除非状态机明确判断配对记录不可用或系统 bond 冲突。

进入相册阶段不显示配对阶段提醒。即使底层同样使用 BLE 唤醒相机，也必须通过 `activeStep` 区分 `ReconnectPairedBle / TransferAuthorization / ActivateCameraWifi` 与配对阶段的 `BleScan / BleHandshake / PairingConfirmation`。

## Execution Steps

### Phase 1: Pair Camera

| Step | Name | App Action | Success Condition | Failure Handling |
|---|---|---|---|---|
| P1 | EnvironmentCheck | 检查 Bluetooth runtime permission、Bluetooth 开关、必要系统能力 | 权限和开关满足扫描/连接需求 | 缺权限或蓝牙关闭时停在当前步骤，提示用户处理 |
| P2 | StaleBondCheck | 检查系统蓝牙是否已有同名/同地址旧 bond | 无冲突 bond，或 App remembered pairing 与系统 bond 一致 | 有旧 bond 且 App 记录不可信时，提示用户到系统蓝牙忽略设备 |
| P3 | CameraPairingMode | 点击配对后先提示相机进入 `配对注册 / PAIRING REGISTRATION`，不立即扫描 | 用户确认相机停在正确页面后，App 才开始 BLE 扫描 | 用户未确认前停在本步骤，不进行 BLE 扫描 |
| P4 | BleScan | BLE 扫描 CameraVendor 广播 UUID | 找到目标相机 ScanResult | 超时则提示相机未在配对注册或距离过远 |
| P5 | BleHandshake | GATT 连接、发现服务、读取 metadata、订阅 notify、执行 token / secure / identifier flow | 写入识别信息，并拿到相机名/序列号/WiFi 候选 | GATT 断开或服务缺失可短重试，失败停在配对阶段并提示重试或重新配对 |
| P6 | PairingConfirmation | 等相机端确认后，手机端确认并 replay ACK | `confirmCameraPairingSucceeded()` 成功 | ACK 未完成时停在本步骤，不允许进入相册 |
| P7 | SavePairing | 保存相机名、序列号、Bluetooth 地址、WiFi 候选 | 本地 remembered pairing 写入成功 | 保存失败时显示配对未完成，不进入已配对态 |

### Phase 2: Enter Gallery

| Step | Name | App Action | Success Condition | Failure Handling |
|---|---|---|---|---|
| G1 | ExistingPtpProbe | 如果上次失败后用户可能已手动加入相机 WiFi，先尝试 PTP | `PtpConnection.connect()` 成功 | 失败只说明当前不在可用 PTP，不倒回配对 |
| G2 | ReconnectPairedBle | 通过 remembered Bluetooth 地址直连，或扫描已配对相机 | 拿到可用 `CameraVendorBleHandshake` | 超时停在进入相册阶段，提示打开相机蓝牙并停在传图/连接界面 |
| G3 | TransferAuthorization | 刷新 WiFi 信息并确认传图授权 | 可以读取/复用 WiFi 候选，并可写传图命令 | handshake 丢失或 ACK 不完整时返回配对阶段对应问题 |
| G4 | ActivateCameraWifi | 通过 BLE 写入传图启动命令 | 相机开始启动 WiFi AP | 如果缺传图特征，提示相机未在可传图状态 |
| G5 | WaitCameraWifiReady | 读取或订阅 AP 状态 | AP state 为 ready，例如 `0x8001` 或 `0x8003` | 第一版可以保留短等待；长期不要只靠固定 delay |
| G6 | JoinCameraWifi | 用 Android WiFi API 请求加入相机 WiFi | `ConnectivityManager.NetworkCallback.onAvailable`，并 bind process | 失败后展示 WiFi 名称；有密码时展示并允许复制，用户可手动加入后点重试 |
| G7 | ConnectPtp | 连接 `192.168.0.1:55740` 并完成 PTP init/open session | PTP legacy init ack、OpenSession、ReferenceApp gallery handshake 成功 | WiFi 已连但 PTP 未 ready 时只重试 PTP，不重新配对 |
| G8 | LoadGallery | 读取图库对象列表 | 文件列表成功返回 | 读取失败停在相册连接/图库加载问题，不倒回 WiFi 或 BLE |

### Large Gallery First Pass

几千张照片时，首次进入相册不能等全部 `ObjectInfo` 串行读完。第一版采用“首批优先显示”：

```text
specifiedHandles <= 500:
  保持完整读取，保留 hidden / forward / standard 补偿探测。

specifiedHandles > 500:
  只读取排序后的前 200 个 handle。
  跳过 hidden / forward 补偿探测。
  跳过额外 standard enumeration。
  先让相册页面显示首批结果。
```

这个版本的目标是把首屏等待从“全量几千张元数据”降到“首批 200 张元数据”。它不是完整分页方案；后续如果要浏览全部历史照片，需要继续做 `加载更多 / 后台补全 / 本地缓存`。

## BLE Command Contract

BLE UUID 定义位于 `CameraVendorBleProfile.kt`。

### Discovery

扫描 CameraVendor 广播 UUID：

```text
LEGACY_REMOTE_ADVERT
LEGACY_REFERENCE_APP_ADVERT
MODERN_SECURE_ADVERT
STANDBY_ADVERT
```

### Metadata Reads

GATT 连接后读取标准 metadata：

```text
DEVICE_NAME_CHAR
MODEL_NUMBER_CHAR
SERIAL_NUMBER_CHAR
FIRMWARE_VERSION_CHAR
MANUFACTURER_NAME_CHAR
```

这些信息用于展示相机名、保存序列号、生成 WiFi 备用候选。

### Pairing Services

配对服务：

```text
LEGACY_PAIR_SERVICE
MODERN_PAIR_SERVICE
```

配对相关特征：

```text
PAIR_TOKEN_CHAR
IDENTIFIER_CHAR
SECURE_STATUS_CHAR
```

现有代码支持三类 flow：

1. Token flow：写 `PAIR_TOKEN_CHAR`，必要时写 `IDENTIFIER_CHAR`。
2. Secure flow：写 `IDENTIFIER_CHAR`，读 `SECURE_STATUS_CHAR`，再写 ACK。
3. Identifier-only flow：写 `IDENTIFIER_CHAR`。

Secure ACK payload 规则：

```text
identificationNumber[0], identificationNumber[1], identificationNumber[2], 0x20
```

这部分命令链路明确，但不同机型上 ACK 完成时机需要继续用日志验证。

### WiFi Configuration Reads

优先从 BLE 读取：

```text
CAMERA_WIFI_SSID_CHAR
CAMERA_WIFI_PASSPHRASE_CHAR
```

如果读取失败，则用相机名和序列号生成备用候选。备用候选只能作为短尝试，不应无限串行等待。

### Transfer Activation Writes

进入相册阶段通过 BLE 写入传图启动命令：

```text
IMAGE_TRANSFER_SETTING_CHAR     = 00
IMAGE_TRANSFER_SETTING_EX_CHAR  = 01
IMAGE_RESIZE_SETTING_CHAR       = 01 when compressed, 00 when original
LAUNCH_REQUEST_CHAR             = 03 00
```

AP ready 相关特征：

```text
AP_STATE_CHAR
TRANSFER_STATE_CHAR
```

当前代码可识别 `AP_STATE_CHAR` 的 ready 值：

```text
0x8001
0x8003
```

但当前策略 `shouldFastHandoffAfterCommandWrites() = true`，写完命令后会快速切 WiFi，没有强制等待 AP ready。改造时应把这个点变成可配置策略，并在 UI 中暴露为明确步骤。

## WiFi Contract

Android 端通过 `WifiNetworkSpecifier` 请求相机 WiFi：

```text
SSID
WPA2 passphrase
isHiddenSsid
```

成功条件：

```text
ConnectivityManager.NetworkCallback.onAvailable
bindProcessToNetwork(network)
```

失败判断不能只解释为密码错误。可能原因包括：

- 相机 AP 未启动
- 系统 WiFi 加入弹窗未确认
- Android 厂商限制临时无互联网网络
- 隐藏 SSID 匹配失败
- WiFi 候选不对

WiFi 请求策略：

- 优先尝试相机 BLE 提供的首选 SSID。
- 最多尝试 1 个备用候选。
- 单次等待时间要短于当前 30 秒，失败后停在 `JoinCameraWifi`。

失败后的 UI 策略：

- 提示用户确认系统弹窗。
- 对隐藏网络给出手动输入 SSID/密码说明。
- 展示 WiFi 名称；有密码时展示密码和复制按钮。
- 用户手动加入 WiFi 后点 `重试`，App 只验证 PTP，不重新走蓝牙配对。

## Interaction Gates

### Pairing Start Gate

点击“连接相机”后，App 必须先停在 `CameraPairingMode`：

```text
提示用户：请确认相机已经进入 配对注册 / PAIRING REGISTRATION 页面
用户确认：相机已在配对界面，开始搜索
App 动作：清除提示，开始 BLE 扫描
```

这个 gate 的目的不是改变底层 BLE 命令，而是避免 App 在相机还没进入可发现状态时盲扫、长等和误判。

### Pairing Reminder Gate

连接相机阶段需要单独提示两件事：

```text
1. 需要相机确认：如果相机屏幕出现 OK、确定、配对或允许连接提示，先在相机上按 OK/确定。
2. 手机操作：如果手机弹出蓝牙配对请求，点配对/允许，并留在当前页面。
```

这两条提醒只允许在配对阶段显示：

```text
BleScan
BleHandshake
PairingConfirmation
```

进入相册阶段禁止显示这两条配对提醒，即使当前粗状态也是 `CONNECTING_BLE`。进入相册阶段的 BLE 是传图唤醒，不是重新配对。

### Gallery Entry Gate

进入图片筛选页不能只看 `ConnectionState.CONNECTED`。`CONNECTED` 是连接状态，不是一次性导航事件。

UI 路由必须由 `galleryConnectionEvent` 触发：

```text
connectPairedCameraToGallery() 成功
或 manual WiFi PTP verification 成功
或 existing PTP probe 成功
-> publishGalleryConnectionEvent()
-> MainActivity 消费未处理过的新事件
-> 打开 Browse
```

如果只是页面重组、旧 `CONNECTED` 状态残留、或者已处理过的 event，不能再次进入图片筛选页。

### Failure Action Gate

失败态只给一个主按钮，避免用户同时看到多个路径：

```text
PAIR_CAMERA 阶段失败 -> 重新配对
ENTER_GALLERY 阶段失败 -> 重试
```

WiFi 加入失败可以额外展示手动 WiFi 信息：

```text
Wi-Fi 名称
密码
复制密码
```

但主动作仍然是重试当前相册连接步骤，不应倒回蓝牙配对。

## PTP Contract

PTP 连接目标：

```text
host = 192.168.0.1
commandPort = 55740
```

初始化顺序：

```text
TCP connect
CameraVendor legacy INIT_COMMAND_REQUEST
INIT_COMMAND_ACK
OpenSession (0x1002)
ReferenceApp gallery handshake
```

ReferenceApp gallery handshake 当前顺序：

```text
ReadDeviceProperty D212 REFERENCE_APP_GALLERY_OBJECT_CONTEXT
ReadDeviceProperty DF01 INIT_SEQUENCE
SetDeviceProperty DF01 = 20
ReadDeviceProperty DF28 REFERENCE_APP_IMAGE_HOST
SetDeviceProperty DF28 = 3
ReadDeviceProperty D244 REFERENCE_APP_GALLERY_ACCESS_STATE
ReadDeviceProperty D212 REFERENCE_APP_GALLERY_OBJECT_CONTEXT
ReadDeviceProperty D244 REFERENCE_APP_GALLERY_ACCESS_STATE
GetLatestObjectInfo 0x9054 current image handle
GetExtensionThumb 0x9055 current image handle
GetSearchModeDescAll 0x9050
ReadDeviceProperty D22B CURRENT_OBJECT_HANDLE
GetSpecifiedObjectCountGroupByDate 0x9053
ReadDeviceProperty D212 REFERENCE_APP_GALLERY_OBJECT_CONTEXT
ReadDeviceProperty D620 SPECIFIED_OBJECT_COUNT
ReadDeviceProperty D621 SPECIFIED_OBJECT_HANDLES
```

PTP 失败处理：

- TCP connect 超时：通常说明 WiFi 未连上、AP 未 ready、或不在相机 WiFi。
- PTP init/open session 失败：停在 PTP 连接步骤重试。
- 图库对象读取失败：停在图库加载步骤，不倒回重新配对。

## Step Progression

连接流程保持“一键开始”的体验，但产品上不显示模式切换。

推进规则：

1. 每一步都必须有明确成功条件。
2. 能自动验证的步骤连续推进。
3. 需要用户动作的步骤，先给出明确提醒；用户确认后，App 再验证。
4. 同一步只允许短重试，不允许长时间猜测。
5. 失败后停在当前阶段，显示一个主按钮。

步骤推进不应无限兜底：

```text
Do not guess many candidates with long timeout.
Do not proceed past PairingConfirmation without ACK.
Do not retry Bluetooth pairing when the failure is only WiFi or PTP.
```

## UI Guidance

UI 提醒用于稳定完成连接，但不作为单独“模式”展示给用户。

每一步 UI 只展示必要信息：

```text
现在在哪一步
下一步用户要做什么
如果失败，为什么失败
```

UI 不应该暴露所有高级操作。按钮应由状态机提供：

```text
primaryAction
secondaryAction
allowedActions
blockedActions
```

示例：

| State | User Message | Allowed Action |
|---|---|---|
| StaleSystemBond | 手机系统里还保留旧蓝牙配对，会阻止重新配对 | 去系统蓝牙忽略设备，然后点“我已清理” |
| WaitingCameraPairingMode | App 还没搜到相机，相机需要停在配对注册界面 | 在相机上打开配对注册，然后重试 |
| WaitingCameraAck | App 已写入识别信息，正在等相机端确认完成 | 确认相机屏幕提示，然后点“相机已确认” |
| WifiJoinTimeout | 手机没有自动加入相机 WiFi | 确认系统弹窗或手动加入 WiFi |
| PtpNotReady | 已进入 WiFi 阶段，但相册服务还没准备好 | 保持相机在传图/相册模式，重试 PTP |

### UI State Sources

UI 不能只根据 `ConnectionState` 决定所有文案和提醒。

当前实现必须同时使用：

```text
ConnectionState: 粗粒度页面状态，如 IDLE / PAIRED / CONNECTING_WIFI / CONNECTED
activeStep: 精确执行步骤，如 BleHandshake / ReconnectPairedBle / JoinCameraWifi
connectionIssue: 当前失败或阻塞原因
galleryConnectionEvent: 相册连接成功的一次性导航事件
```

关键约束：

- `activeStep` 决定是否显示配对提醒。
- `ConnectionState.PAIRED` 只代表本地已有配对记录，UI 显示“已保存配对 / 已配对 <camera-name>”。
- `galleryConnectionEvent` 决定是否进入图片筛选页。
- `connectionIssue.phase` 决定失败主按钮是 `重试` 还是 `重新配对`。

## State Machine Boundary

第一版改造重点放在 Android 流程编排层，不重写 BLE/WiFi/PTP 底层驱动。

保留：

- `CameraVendorBleHandshake` 的 GATT 读写能力
- `WifiConnector` 的 Android WiFi 请求能力
- `PtpConnection` / `PtpCommands` 的 PTP 协议能力

需要新增或重构：

- `CameraConnectionStep`
- `CameraConnectionPhase`
- `CameraConnectionMode` 可以作为内部策略保留，但不作为产品 UI 模式暴露
- `CameraConnectionIssue`
- `CameraConnectionAction`
- `activeStep`
- `galleryConnectionEvent`
- 连接 orchestrator，用于替代隐式串联的 `connectToCamera()` / `confirmPairing()` / `connectPairedCameraToGallery()` 编排逻辑

`ConnectionViewModel` 应消费状态机输出，而不是根据状态字符串猜按钮和页面状态。任何从状态文案反推步骤的逻辑都只能作为过渡实现，最终应由显式 step/event 驱动。

## Diagnostics Contract

每个步骤都必须记录结构化诊断：

```text
phase
step
mode
attempt
input summary
success/failure
failure category
next action
```

不要只记录异常栈。日志应该能回答：

```text
卡在哪一步
App 当时发了什么命令
相机/系统返回了什么
为什么没有继续
用户应该做什么
```

## Open Verification Items

这些点已有代码实现或推断，但需要后续真机日志继续确认：

1. X-H2 与 X-T30 III 的 secure ACK 完成时机是否一致。
2. `AP_STATE_CHAR = 0x8001 / 0x8003` 是否能稳定表示 Android 可加入 WiFi。
3. Android 16 小米、一加对 `WifiNetworkSpecifier` + hidden SSID 的差异。
4. 系统 Bluetooth bond 与 App remembered pairing 冲突时，是否所有机型都允许反射调用 `removeBond()`。
5. WiFi 自动失败后，用户手动加入相机 WiFi，再执行 PTP 验证是否稳定。

## Current Android Implementation Order

1. 定义状态和 issue/action 数据结构，不改 BLE/WiFi/PTP 命令。
2. 把 Pair Camera 阶段接入状态机，并用现有日志场景验证旧 bond、ACK 未完成、GATT 断开。
3. 把 Enter Gallery 阶段接入状态机，并把 WiFi timeout 与 PTP timeout 分开。
4. 让 `ConnectionViewModel` 由状态机驱动 UI 按钮，而不是根据状态文案推断。
5. 让 UI 使用 `activeStep` 区分配对 BLE 与进入相册 BLE。
6. 让 Browse 导航只消费 `galleryConnectionEvent`。
7. 收敛失败态按钮：配对阶段失败显示重新配对，进入相册阶段失败显示重试。
8. 根据新日志再收敛机型策略和等待时间。

## Out of Scope for First Pass

- 重写 BLE GATT 驱动。
- 重写 PTP packet / command 实现。
- 支持所有 CameraVendor 机型的完整 profile。
- 后台自动连接。
- 跨平台 iOS 同步改造。

第一版目标是把 Android 的连接过程从“猜测 + 长超时”改成“步骤确认 + 清晰失败动作”。
