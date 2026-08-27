# iOS RED 动态主链路技术实现方案

## 1. 文档目的

本文定义 CamTransfer iOS 对 Fujifilm RED 协议族的动态主链路实现方式。

本方案只关注一个目标：在相机使用最新固件的前提下，不为每一台相机编写专属连接流程，而是依据 XApp 已被证实的实现原则、相机运行时暴露的 BLE/GATT/固件能力，动态选择一条可验证的主链路并完成连接。

本文不把异常恢复、失败重试、用户取消、系统蓝牙清理、Legacy 协议实现作为本阶段的主目标。这些属于主链路之外的异常处理层，必须与本方案分开设计和验收。

## 2. 范围与非目标

### 2.1 本阶段范围

- RED 广播协议族识别；
- BLE 建链和 GATT 能力发现；
- 型号、固件、Serial、Identification Number 等身份事实读取；
- Wi-Fi 配置和传图激活能力读取；
- 生成统一 RED Capability Snapshot；
- 根据 Snapshot 选择 registration、activation、PTP、Gallery 策略；
- 按阶段执行主链路；
- 为每个阶段定义独立成功证据；
- 让未知能力安全停止，而不是猜测或套用未验证策略；
- 将每次策略选择和事实输入写入诊断日志。

### 2.2 明确不做

- 不按 XM5、XT5、X100VI 等型号复制整套连接代码；
- 不为每个用户或每台物理相机建立专属分支；
- 不在本阶段实现 Legacy 主链路；
- 不复刻 XApp Native SDK 的不可见内部实现；
- 不复制未经证实的 XApp retry 次数、等待时间或私有 payload；
- 不把异常恢复策略混入主链路能力选择；
- 不因为某个后续 PTP/Catalog 失败而修改 BLE 配对策略；
- 不因为型号名称匹配就直接放行主链路。

## 3. 核心结论

当前代码已经具备动态适配骨架，但 RED production registry 的 verified 策略仍主要汇聚到 `currentWireBaseline`。本方案不推翻该 baseline，而是把它重新定义为：

> 满足 RED 最小能力合同、且没有更具体 verified 规则时的通用主链路策略。

动态适配的目标不是制造更多分支，而是完成以下决策：

1. 当前设备是否属于 RED；
2. 当前设备是否具备 RED 主链路的最小能力；
3. 当前设备实际暴露的能力组合对应哪一个已验证策略；
4. 如果没有可验证策略，应在哪个阶段停止；
5. 已执行阶段不能被后续事实重新改写。

## 4. XApp 依据与证据边界

### 4.1 可以复用的 XApp 原则

现有 Android XApp APK 分析、Android 实机日志和协议资料可以支持以下原则：

- XApp 先根据 BLE 广播的 Service/Manufacturer Data 判断协议族，而不是只根据型号名称选择整套流程；
- XApp 在 GATT 阶段读取真实的 Service、Characteristic、身份和连接参数；
- XApp 保存 Serial/Product、注册身份、配对信息和精确 Wi-Fi 配置；
- XApp 将 BLE、注册、传图激活、AP/Wi-Fi、PTP 和 Gallery 视为不同阶段；
- XApp 的连接策略由协议族、身份和能力共同决定；
- XApp 不会用后续相册命令结果代替前面的 BLE 或注册成功证据；
- XApp 的多机型兼容依赖共享连接框架和不同 Profile/Strategy，而不是每个型号一套重复 Runtime。

### 4.2 不能直接外推的内容

以下内容没有足够的 XApp Native 或 iOS 同机证据，不得直接写成 production 规则：

- ACK 后 BLE 断开的所有内部语义；
- 每个固件版本的精确 activation payload；
- 每个型号的私有状态值含义；
- XApp Native SDK 的内部等待时间和重试次数；
- Android BLE address 与 iOS `CBPeripheral.identifier` 的一一等价关系；
- Identification Number 在所有机型上的稳定性和永久身份语义；
- 所有 RED 设备都能使用当前 PTP INIT 变体的结论。

没有证据的规则只能标记为 `experimental` 或 `unsupported`，不能进入正式 RED 主链路。

## 5. 总体架构

```text
BLE 广播
  -> Discovery Profile
  -> RED protocol family
  -> BLE/GATT 建链
  -> GATT Capability Snapshot
  -> Identity/Registration Snapshot
  -> Compatibility Rule Resolver
  -> Connection Plan
  -> Strategy Snapshot
  -> Registration
  -> Transfer Activation
  -> AP/Wi-Fi handoff
  -> PTP INIT/OpenSession
  -> Gallery bootstrap
  -> GalleryReady
```

架构中的职责边界如下：

| 组件 | 职责 | 不负责 |
| --- | --- | --- |
| Discovery Profile | 识别广播协议族和候选设备 | 不确认注册成功 |
| GATT Capability Snapshot | 收集当前设备真实能力 | 不选择 UI 行为 |
| Identity Profile | 确认当前设备与目标 cameraID 的关系 | 不决定 PTP 命令 |
| Compatibility Rule Resolver | 根据事实选择连接计划 | 不直接发送 BLE/PTP 命令 |
| Connection Plan | 冻结本次会话的阶段策略 | 不承担异常重试 |
| Strategy Registry | 提供 pairing/activation/PTP/Gallery 策略定义 | 不读取设备状态 |
| Execution State | 保证阶段顺序、revision 和已执行阶段锁定 | 不猜测缺失事实 |
| Stage Runtime | 执行已选择的单阶段策略 | 不跨层兜底 |

## 6. RED Capability Snapshot

### 6.1 Snapshot 必须包含的事实

统一 Snapshot 由以下字段组成：

```swift
struct RedCapabilitySnapshot: Codable, Equatable {
  let protocolFamily: CameraCompatibilityFamily
  let modelName: String?
  let firmwareVersion: String?
  let serialNumber: String?
  let identificationNumber: RedIdentificationNumber?
  let peripheralID: UUID
  let advertisedServices: Set<String>
  let discoveredServices: Set<String>
  let discoveredCharacteristics: Set<String>
  let characteristicProperties: [String: Set<String>]
  let registrationCapabilities: RedRegistrationCapabilities
  let activationCapabilities: RedActivationCapabilities
  let wifiConfiguration: CameraVendorWifiNetworkConfiguration?
  let evidence: RedCapabilityEvidence
}
```

现有 `CameraCompatibilityFacts` 可以作为共享外层模型；`RedCapabilitySnapshot` 是 RED 适配器内部的结构化输入，避免不同阶段各自从散落属性重新推断。

### 6.2 固件读取

固件版本从 Device Information Service 的 Firmware Revision Characteristic `0x2A26` 读取。当前代码已经可以读取并记录该值：

- `ios/Runner/CameraVendorBluetoothService.swift`：`firmwareRevisionCharacteristicUUID` 和 `didUpdateValue` 固件解析；
- `ios/Runner/CameraCore/Connection/CameraCompatibility.swift`：`CameraObservedIdentity.firmwareVersion`；
- `ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift`：计划解析日志包含 `firmware`。

本方案要求：

1. 当前连接必须把固件放入 Snapshot；
2. 当前连接必须输出固件诊断字段；
3. 配对记录增加可选 `firmwareVersion` 字段，兼容旧记录缺失；
4. 固件版本只能作为规则输入之一，不能单独决定连接流程；
5. 固件未知时，不得假设当前 baseline 对所有能力都适用。

### 6.3 最小能力合同

RED 主链路的 verified baseline 至少要求：

- 广播或 GATT 证据确认协议族为 RED；
- RED secure pairing service 存在；
- 已连接设备识别号 characteristic 存在；
- 传图授权/激活 characteristic 存在；
- 能读取相机身份所需的最小字段；
- 能读取完整 Wi-Fi 配置，至少包括 SSID 和 passphrase；
- 能观察到 activation 完成所需的状态特征或已证实等价证据；
- 后续 PTP INIT 所需的 transport/strategy 有 verified 定义。

缺少以上任一必需事实时，不能把设备当作 RED baseline 成功，只能输出明确的缺失能力并停止在对应阶段。

## 7. 身份模型

### 7.1 长期身份和连接 endpoint 分离

```text
cameraID = Serial + Product/Model
endpoint = 当前 iOS CBPeripheral.identifier
```

`CBPeripheral.identifier` 只作为连接入口和 callback ownership 标识，不能作为相机永久身份。

当前 `CameraVendorPairedCameraRecord` 已保存 `peripheralID`、型号和 Serial；本方案要求继续保留这些字段，同时增加固件和协议事实摘要。endpoint 变化后的自动迁移不属于本阶段主链路核心功能，必须在当前 GATT 身份确认后才允许发生。

### 7.2 身份确认顺序

```text
广播命中 candidate
  -> GATT 建链
  -> 读取 model/serial/identification
  -> 与目标 cameraID 比较
  -> identity verified
  -> 才允许进入 registration/activation
```

不能因为：

- 型号名称相同；
- Service UUID 相同；
- endpoint UUID 相同；

就跳过身份确认。

## 8. 动态规则与策略选择

### 8.1 规则输入

`CameraCompatibilityRule` 的匹配输入应来自同一个 Snapshot/`CameraCompatibilityFacts`，至少支持：

- `compatibilityFamily`；
- required Services；
- required Characteristics；
- characteristic properties；
- model；
- firmware version range；
- registration capability；
- activation capability；
- PTP response facts（仅影响尚未执行的 PTP/Catalog 阶段）。

### 8.2 规则输出

每条 verified RED 规则输出一组完整策略选择：

```text
PairingStrategy
ActivationStrategy
PtpInitStrategy
SessionNegotiationStrategy
GalleryBootstrapStrategy
InitialCatalogStrategy
```

当前 `currentWireBaseline` 继续作为第一条 verified RED 规则，但它必须明确绑定自己的最小能力要求，而不是仅因型号为 XM5 就执行。

### 8.3 规则优先级

规则匹配顺序：

1. 协议族 + 固件 + 能力 + response predicate 的具体规则；
2. 协议族 + 固件 + 能力规则；
3. 协议族 + 必需 Services/Characteristics 规则；
4. 安全 fallback；
5. 无匹配则 `unsupported`。

更具体的规则优先于 baseline，但不能覆盖已经执行的阶段。当前 `CameraConnectionExecutionState` 的 stage lock 和 plan revision 继续作为边界。

### 8.4 规则状态

```text
verified     有 XApp/协议/同机成功证据，可进入 production
experimental 仅供内部受控实验，不得自动进入正式主链路
unsupported 事实不足或能力不兼容，停止在当前阶段
```

production registry 只允许 `verified` 规则。实验规则通过 Compatibility Lab 或 Debug policy 注入，不修改默认 baseline。

## 9. RED 主链路执行合同

### 9.1 Discovery

输入：BLE 广播。

必须输出：

- protocol family；
- candidate peripheralID；
- advertised Service UUID；
- Manufacturer Data 摘要；
- 匹配原因；
- 是否是 remembered candidate。

成功证据：`RED_CANDIDATE_DISCOVERED`。

### 9.2 BLE/GATT

输入：候选 peripheral。

执行：

- BLE connect；
- Service discovery；
- Characteristic discovery；
- notification/indication capability discovery；
- 读取基础身份和能力字段。

成功证据：

```text
BLE_CONNECTED
GATT_SERVICE_DISCOVERY_COMPLETE
GATT_CHARACTERISTIC_DISCOVERY_COMPLETE
```

### 9.3 Identity/Registration

执行：

- 读取型号、固件、Serial、Identification Number；
- 读取精确 Wi-Fi SSID/passphrase/BSSID（若设备提供）；
- 构造 RED Snapshot；
- 匹配目标 cameraID；
- 选择 registration strategy；
- 按 verified strategy 完成注册。

成功证据：

```text
IDENTITY_VERIFIED
REGISTRATION_PLAN_SELECTED
APP_REGISTRATION_ACCEPTED
```

### 9.4 Transfer Activation

执行：

- 使用 plan 选定的 activation strategy；
- 只写入该 strategy 定义的命令；
- 按定义订阅/读取状态特征；
- 使用 strategy 的 completion predicate 判断完成。

成功证据：

```text
ACTIVATION_PLAN_SELECTED
ACTIVATION_STATE_OBSERVED
AP_STATE_READY 或同等 verified ready evidence
```

ACK 本身不是 activation 成功证据。

### 9.5 Wi-Fi Handoff

执行：

- 使用 Snapshot/registration 中的精确 Wi-Fi 配置；
- 确认目标 SSID；
- 确认目标接口和 IPv4；
- 确认到相机地址的可达性。

成功证据：

```text
WIFI_ASSOCIATED
WIFI_IPV4_READY
PTP_REACHABLE
```

`NEHotspotConfiguration.apply` 返回成功不等于 Wi-Fi 主链路成功。

### 9.6 PTP/Gallery

执行：

- 使用 plan 选择的 PTP INIT strategy；
- 解析 INIT ACK；
- OpenSession；
- 绑定 Gallery bootstrap strategy；
- 建立 Catalog 并发布 GalleryReady。

成功证据：

```text
PTP_INIT_ACK
PTP_OPEN_SESSION
GALLERY_BOOTSTRAP_COMPLETE
GALLERY_READY
```

## 10. Plan Revision 与边界

动态适配允许在事实到达后修订尚未执行阶段，但不允许改变已经执行的阶段：

```text
BLE/GATT facts
  -> 选择 registration/activation
activation facts
  -> 只修订 Wi-Fi/PTP/Gallery 尚未执行部分
PTP ACK facts
  -> 只修订 Catalog/Gallery 尚未执行部分
```

以下阶段完成后必须锁定：

- pairing/registration；
- activation；
- PTP INIT；
- session negotiation；
- Gallery bootstrap。

这样可以避免：

- Catalog 错误反向修改 BLE 配对；
- PTP 错误反向重放 activation；
- 后续 response 改变已发送的 wire payload；
- 新旧策略混用导致会话串线。

## 11. 日志与可观测性

每次 RED 主链路必须输出以下上下文：

```text
connectionSessionID
cameraID（可脱敏）
peripheralID
protocolFamily
model
firmware
serial hash
identification evidence
advertised services
discovered services
discovered characteristics
selected rule
selected strategies
unresolved facts
plan revision
first missing barrier
terminal classification
```

建议事件：

```text
RED_DISCOVERY_FACTS
RED_GATT_CAPABILITY_SNAPSHOT
RED_IDENTITY_COMPARISON
RED_REGISTRATION_PLAN
RED_ACTIVATION_PLAN
RED_WIFI_CONFIGURATION_FACTS
RED_PTP_PLAN
CAMERA_PLAN_RESOLUTION
CAMERA_PLAN_REVISION
CONNECTION_BARRIER_BEGIN
CONNECTION_BARRIER_SUCCEEDED
CONNECTION_BARRIER_FAILED
```

日志只记录用于定位的摘要，不记录明文 pairing key、Wi-Fi passphrase 或完整敏感广播 payload。

## 12. 现有代码映射

| 目标能力 | 当前代码 | 本方案要求 |
| --- | --- | --- |
| RED/Legacy 广播识别 | `CameraVendorDeviceMatcher` | RED 作为当前主目标，Legacy 暂不扩展 |
| 能力事实模型 | `CameraCompatibilityFacts` | 补齐 RED Snapshot 所需事实 |
| 规则解析 | `CameraCompatibilityRuleResolver` | 让 firmware/capability 真正参与匹配 |
| 连接计划 | `CameraConnectionPlan` | 保持 plan lineage/revision/stage lock |
| 策略注册 | `FujifilmProtocolStrategyRegistry` | 先保持 baseline，按证据增加 RED strategy |
| activation | `ActivationStrategyDefinition` | 按能力选择，不按型号复制 Runtime |
| PTP INIT | `PtpInitStrategyDefinition` | 仅在有证据的 ACK 差异时增加变体 |
| 固件读取 | `CameraVendorBluetoothService` 读取 `0x2A26` | 加入 Snapshot、配对记录和计划日志 |
| 配对记录 | `CameraVendorPairedCameraRecord` | 增加可选 firmware/protocol/capability 摘要 |
| 执行状态 | `CameraConnectionExecutionState` | 保持已执行阶段锁定 |

## 13. 分阶段实现计划

### 阶段一：RED 事实闭环

- 将固件、协议族、Service、Characteristic、properties、身份和 Wi-Fi 配置收敛到一个 Snapshot；
- 将 firmwareVersion 加入配对记录，保持旧记录解码兼容；
- 输出 Snapshot 和 rule resolution 日志；
- 为当前 RED baseline 建立最小能力合同；
- 未满足合同时停止并记录缺失能力。

### 阶段二：RED 规则真正参与生产选择

- 让 protocol family、firmware 和 GATT capability 参与规则匹配；
- 保持当前已验证 baseline 的 wire payload 和顺序不变；
- 增加 rule rejection reason 和 unresolved facts；
- 通过测试确认未知能力不会误用 verified strategy；
- 任何新策略先标记 experimental。

### 阶段三：策略扩展

只有以下条件同时满足时才增加新的 RED strategy：

- XApp 或协议资料证明存在行为差异；
- 同一最新固件设备有差异日志；
- 差异会改变主链路命令、状态或成功谓词；
- 有成功和失败对照证据；
- 有独立回归测试；
- 能通过 policy revision 回滚。

### 阶段四：RED 主链路验收

至少验证：

- 正常 RED 设备完整到 GalleryReady；
- firmware 被读取、记录并进入计划日志；
- 能力完整时选择 baseline 并保持既有成功链路；
- 能力缺失时停在明确 barrier，不发送猜测命令；
- 未知协议族不会被当作 RED baseline 放行；
- 计划 revision 不会重写已经执行的阶段。

## 14. 验收标准

本方案的“主链路动态完成”必须同时满足：

1. 不依赖单一型号名称决定完整流程；
2. RED 设备经过广播、GATT 和身份事实确认后才能选择策略；
3. 固件版本出现在 Snapshot、日志和配对记录中；
4. 当前 baseline 只对满足最小能力合同的设备生效；
5. 策略选择输出可审计的 rule、strategy 和 unresolved facts；
6. 每个主链路阶段有独立成功证据；
7. 未知或未验证能力不会被猜测放行；
8. 已执行阶段不会被后续事实回写；
9. 新增策略不会改变当前成功 RED 设备的默认 wire 行为；
10. 至少一台最新固件 RED 设备完成完整主链路实机验证。

## 15. 当前已知卡点

以下是验证工作，不是架构不可实现的阻塞：

- 当前真实 RED 样本数量有限，不能据此生成所有固件/能力规则；
- XApp Native 内部策略不可见，只能复刻可观察行为和架构原则；
- Identification Number 的跨机型语义仍需更多同机证据；
- iOS endpoint 与 Android BLE address 不等价，不能直接照搬 Android 身份迁移；
- 不同 RED 设备是否真的需要不同 activation/PTP strategy，需要最新固件设备对照验证；
- 当前 production registry 主要只有 baseline，策略库需要在证据驱动下逐步扩展。

这些卡点不要求停止主链路实现。可以先完成通用 Snapshot、规则解析、最小能力合同、日志和 baseline 回归，再把有证据的差异逐步加入策略库。

## 16. 最终定位

本方案的目标不是“为所有相机提前写出所有差异”，而是：

```text
最新固件
  + RED 协议族
  + 真实 GATT 能力
  + 身份/固件事实
  + XApp 已证实的连接原则
  -> 一套能力驱动的通用 RED 主链路
```

当前 `currentWireBaseline` 不是要被废弃的静态路径，而是 RED 最小能力合同满足时的默认 verified strategy。动态适配的价值在于：

- 设备能力足够时安全复用共同路径；
- 能力不同但已有证据时选择对应策略；
- 能力未知时在正确阶段停止；
- 不为兼容单台设备而污染所有设备的主链路。

Legacy 和异常处理均在本方案之外，后续分别立项。
