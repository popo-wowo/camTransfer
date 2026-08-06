# iOS 对齐 XApp 的多机型兼容架构技术方案

日期：2026-08-06

状态：待评审

范围：iOS 无线配对、BLE 激活、Wi-Fi handover、PTP 会话、相册入口与首次 Catalog

不包含：USB、遥控拍摄、固件升级、云端业务、完整复制 XApp

## 0. 结论先行

CamTransfer 需要升级多机型兼容架构，但不应该完整复刻 XApp，也不应该先为 X‑M5 单独复制一条巨型流程。

推荐方案：

~~~text
渐进式识别 CameraIdentity
→ 解析 CameraCapabilities
→ CameraProfileResolver 生成分阶段 Profile
→ CameraConnectionOrchestrator 执行统一状态机
→ Profile 只提供真正存在差异的步骤和策略
→ Gallery Shell 与 Catalog 加载解耦
→ 所有协议实验通过 Profile 单变量接入
~~~

第一阶段只做：

1. 建立多 Profile 兼容骨架。
2. 把现有 X‑T5 成功链包装为默认已验证 Profile。
3. 把“相册页面可以展示”和“Catalog 已经成功”拆成两个状态。
4. 增加能够回答“识别成谁、选择了哪条路、在哪个 barrier 失败”的诊断日志。

第一阶段不直接宣称修复：

- X‑M5 首次 `0x9053 -> 0x2013 StoreNotAvailable`。
- X‑E5 PTP INIT 无 ACK / reset。
- 所有 RED 相机。

X‑M5 与 X‑E5 的协议差异应在架构骨架完成后，分别通过同机型、同状态、单变量 A/B 实验确定，再写入对应 Profile。

## 1. 背景与问题定义

当前已确认三台相机的失败点不同：

| 机型 | 已确认成功边界 | 首个失败边界 | 当前结论 |
|---|---|---|---|
| X‑T5 | 已存在可成功进入相册并安装 Catalog 的链路 | 当前无同批次失败证据 | 可作为首个迁移基线 |
| X‑M5 | BLE、Wi-Fi、PTP INIT、OpenSession、legacy gallery mode | 首次 `0x9053` 返回 `0x2013` | Transport 不是已证实根因，Catalog 前相机状态仍有差异 |
| X‑E5 | BLE、官方 Wi-Fi 凭据、AP launched、Wi-Fi、TCP 55740 可连接 | PTP INIT 无 ACK、超时或 reset | 尚未进入 OpenSession，更不能调查 `9053` |

“都是 RED”只能证明它们处于相近的 BLE 协议世代，不能证明：

- PTP INIT packet 一样。
- Function Mode / Function Version 一样。
- Gallery bootstrap 顺序一样。
- Catalog 前置状态一样。
- 错误恢复策略一样。

当前真正的问题不是缺少更多 `if model == ...`，而是缺少一个能在不同阶段继续修正身份和能力判断的兼容框架。

## 2. 证据边界

### 2.1 已确认

1. XApp 会综合 BLE Service、Manufacturer Data、GATT characteristic、相机主数据、固件门槛、Function Mode、Function Version 和业务响应决定后续行为。
2. 当前 iOS 已有统一连接步骤、CommandLane、Catalog Runtime 和 Session Runtime，但多机型差异尚未成为独立的一等模型。
3. 当前 `FujifilmXSeriesProfile` 只有一个 `xt5Current`，主要保存 PTP 启动延迟和下载 read size，不是完整连接兼容 Profile。
4. 当前 BLE 代码虽然声明了三种 activation strategy，但 `supportedStrategies` 实际只返回 `officialImportImage`。
5. 当前 `CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes` 实际只有 `strictReferenceApp` 一条路线。
6. 当前 PTP INIT policy 只生成两个 CameraVendor legacy packet：legacy + client IP GUID、legacy。
7. `CameraVendorPtpPacketBuilder` 虽然存在 standard INIT builder，但当前 INIT 选择链没有使用它，成功时也统一返回 `cameraVendorLegacy`。
8. `executeConfirmGalleryModeStep()` 不执行真实协议校验，只生成 `galleryModeConfirmed` evidence。
9. `executeLoadGalleryStep()` 只验证 PTP session ID 非空，就生成 `galleryLoaded` evidence。
10. `CameraSessionRuntime` 当前在 Catalog `ready` 后才从 `galleryLoading` 进入 `galleryReady`；Catalog `failed` 会失败结束 pending gallery activation。

### 2.2 尚未确认

1. X‑M5 的根因是否为缺少 `D226=0`。
2. X‑M5 的根因是否为 `D212` 读取顺序。
3. `9054 / 9055 / 9050 / D22B` 中哪些是 X‑M5 首次 `9053` 的必要前置。
4. X‑E5 是否需要 standard PTP/IP INIT、另一种 vendor INIT、不同 GUID、不同启动写入或不同 INIT 时机。
5. X‑M5 与 X‑E5 的固件版本。最新两份日志记录了机型和序列号，但没有明确、可解析的 firmware 字段。
6. 现有 XApp 成功抓包是否来自与 X‑M5 相同机型、相同固件和相同相机图库状态。

本方案只把上述差异设计成“可表达、可诊断、可实验”的能力，不把候选指令直接写成最终固定结论。

## 3. 当前 iOS 架构

### 3.1 当前主链

~~~mermaid
flowchart LR
    UI["Connect UI"] --> Loader["CameraVendorGalleryMainlineSessionLoader"]
    Loader --> BLE["CameraVendorBluetoothService"]
    BLE --> WiFi["Wi-Fi Handover"]
    WiFi --> PTP["CameraVendorPtpSession"]
    PTP --> Evidence["GalleryMode / GalleryLoaded Evidence"]
    Evidence --> Runtime["CameraSessionRuntime"]
    Runtime --> Catalog["CameraGalleryCatalogRuntime"]
    Catalog --> Page["GalleryReady"]
~~~

统一顺序：

~~~text
ReconnectPairedBle
→ TransferAuthorization
→ ActivateCameraWifi
→ WaitCameraWifiReady
→ JoinCameraWifi
→ ConnectPtp
→ ConfirmGalleryMode
→ LoadGallery
~~~

这套编排本身有价值，应该保留；问题在于它当前把“步骤名称”当成了“真实协议 barrier”，且没有将不同机型的步骤实现参数化。

### 3.2 当前身份模型不足

`IOSCameraIdentity` 当前只有 `cameraID`、`displayName`、`serialNumber` 和 `bleEndpoint`，不能表达：

- BLE 协议族：Legacy / RED / X-Half / Unknown。
- 广告来源和匹配证据。
- GATT 能力集合。
- 相机固件。
- PTP INIT 响应族。
- Function Mode / Function Version。
- 已验证的 Gallery bootstrap 版本。

结果是上层知道“它叫 X‑M5”，但不知道“为什么应该执行这套链路”。

### 3.3 当前路由实际上接近单链

| 层级 | 当前声明 | 当前实际选择 |
|---|---|---|
| BLE activation | official / legacy mode 20 / legacy mode 11 | 只自动选择 official |
| Gallery route | 4 个 route ID | 只执行 strictReferenceApp |
| PTP INIT | vendor legacy / standard builder | 只尝试两个 vendor legacy 变体 |
| PTP gallery handshake | legacy / standard 分支 | 当前成功 INIT 被固定标记为 legacy |
| 相机 Profile | `FujifilmXSeriesProfile` | 只有 `xt5Current`，且不控制连接链 |

当前不是“完整 Profile 架构已经存在但缺配置”，而是“已有部分抽象雏形，但决策输入、路由输出和运行时证据没有闭环”。

### 3.4 当前 Gallery 状态耦合

当前同时存在三个容易混淆的概念：

1. PTP session 已建立。
2. Gallery mode evidence 已生成。
3. Catalog 已成功安装、页面真正可用。

`executeConfirmGalleryModeStep()` 与 `executeLoadGalleryStep()` 的 evidence 目前没有证明 2 和 3；而 `CameraSessionRuntime` 又用 Catalog 成功决定最终 `galleryReady`。

这会导致：

- 日志显示“Gallery confirmed”，但相机还没有返回可用目录。
- Catalog 失败时，整个进入相册动作失败，用户看不到页面内加载、重试和诊断状态。

## 4. XApp 的兼容设计

XApp 的核心不是“为每台相机复制一个 ViewModel”，而是多层收敛：

~~~mermaid
flowchart TD
    Adv["BLE 广告与 Service"] --> Family["协议族识别"]
    Family --> GATT["GATT 服务发现"]
    GATT --> Identity["身份与注册信息"]
    Identity --> Support["机型 / 固件支持判断"]
    Support --> Capability["Characteristic 能力"]
    Capability --> Activate["业务启动 / AP"]
    Activate --> WiFi["Wi-Fi handover"]
    WiFi --> Open["SDK / PTP Open"]
    Open --> Function["Function Mode / Version"]
    Function --> Bootstrap["ImportImage initializeFirst / initialize"]
    Bootstrap --> Catalog["图片目录与错误恢复"]
~~~

XApp 有四个值得复用的思想：

1. 身份逐步建立：扫描阶段只能知道广告族和候选 endpoint；GATT 后才能知道真实身份与能力；PTP/SDK Open 后才能知道业务协议版本。
2. 能力优先于机型名：机型用于提高规则精度，真实 characteristic 和 wire 响应优先。
3. 统一业务通道、局部步骤差异：差异主要存在于注册、启动、INIT、Function 协商、Gallery bootstrap 和错误恢复。
4. 错误恢复属于协议层：重试次数和错误分类不应由 UI 通过重跑整条连接链实现。

应复制这些结构，但不能直接复制所有 XApp 命令和错误码策略。当前证据不能证明 `0x2013` 在 X‑M5 上应该简单重试。

### 4.1 当前 iOS 与 XApp 逐项对比

| 维度 | 当前 iOS | XApp 参考设计 | 目标调整 |
|---|---|---|---|
| 协议族识别 | 能从广告和 Service 观察 RED 等线索，但没有进入统一领域模型 | 广告、Service、Manufacturer Data 参与路由 | 新增 `CameraProtocolFamily` 和识别证据 |
| 身份 | 机型名、序列号、endpoint、Wi-Fi 凭据 | 注册身份、Camera ID、Serial、Pairing Key/Address 等共同参与 | 建立可逐步补全的 `CameraIdentitySnapshot` |
| 能力 | characteristic 判断散落在 BLE service | GATT characteristic 决定可用功能和启动方式 | 统一收敛为 `CameraCapabilities` |
| 机型/固件 | 机型主要用于展示和少量策略；日志无明确固件字段 | CameraModel 主数据和最低固件门槛参与支持判断 | 机型/固件成为 Resolver 输入，但不覆盖真实能力 |
| BLE activation | 声明三种 strategy，实际自动选择 official | 根据协议、能力和业务模式选择启动方式 | 由 `ActivationProfile` 输出写入与 ready barrier |
| Wi-Fi | 已有统一 handover 和 IPv4/PTP 可达判断 | BLE 启动 AP 后进入专用 Wi-Fi handover | 保留现有实现，参数和 barrier Profile 化 |
| PTP INIT | 只尝试两个 legacy packet，成功后固定标为 legacy | Open/SDK 层存在协议与版本协商 | 候选 packet 有 ID，ACK 反向确定 transport |
| Function 协商 | 部分 ClientState/ImageHost 操作直接写在 PTP session | Function Mode/Version 是业务连接正式阶段 | 新增 `SessionNegotiationProfile` |
| Gallery bootstrap | 固定 legacy 函数，实验命令容易堆叠 | `initializeFirst / initialize` 组织前置状态和错误恢复 | 步骤类型化并标记 required/optional/experimental |
| Catalog | Catalog Runtime 完整，但首次失败会使 pending activation 失败 | 图片导入模型有自身初始化、错误分类与重试 | Catalog owner 独立处理业务失败，transport loss 才回连接层 |
| 状态语义 | Connection evidence、Runtime phase、Catalog state 部分重叠 | 连接、Function、ImportImage 初始化分别推进 | 建立 barrier ledger，并拆 Gallery Shell/Catalog Ready |
| 诊断 | 有大量文本日志，但缺 profile 决策和首个缺失 barrier | XApp 内部有分层状态和错误结果 | 新增结构化 decision trace 与步骤终态 |
| 扩展方式 | 修改大 service/session 文件或新增 route 条件 | 多层能力收敛到业务通道 | 新机型优先新增规则/Profile，不复制 Runtime |

对比后的核心判断是：

> CamTransfer 已经具备较好的传输、Catalog、下载和会话所有权基础；真正缺少的是 XApp 那种“身份与能力驱动的路由层”。因此应补兼容决策层，而不是推倒现有媒体链路。

## 5. 三种可选方案

### 方案 A：继续在现有代码中按机型加条件

优点：初始改动最小，单次实验接入快。

缺点：

- 模型、固件、BLE 能力、PTP 响应会混在一起。
- 同一机型固件差异无法表达。
- 每修一台相机都会扩大主链复杂度。
- 难以回答实际选择了哪个分支。

结论：只适合临时实验，不适合作为正式架构。

### 方案 B：Profile + 渐进式 Resolver + 双状态机

优点：

- 保留统一主链，只把差异放入 Profile。
- 可以先迁移 X‑T5，不改变 wire 行为。
- X‑M5 和 X‑E5 能在不同层独立实验。
- 可以按能力、机型、固件和响应逐步修正选择。
- 日志与测试可以直接绑定 Profile 和 barrier。

缺点：第一阶段需要新增核心类型和适配层，并清理现有“假 evidence”的语义。

结论：推荐。

### 方案 C：每种协议实现完整插件式连接管线

优点：协议隔离最彻底。

缺点：

- 大量公共逻辑重复。
- RED 内部仍然存在机型和固件差异。
- 当前证据不足以一次定义三套完整管线。
- 第一阶段改动和回归风险过大。

结论：当前过度设计。只有未来出现完全不同的物理传输或会话所有权时，才升级为完整插件。

## 6. 推荐目标架构

~~~mermaid
flowchart TD
    Scan["Discovery Snapshot"] --> Resolver["CameraProfileResolver"]
    GATT["GATT Capability Snapshot"] --> Resolver
    Known["Remembered Identity / Model / Firmware"] --> Resolver
    PtpResult["PTP INIT / Function Result"] --> Resolver

    Resolver --> Decision["CameraCompatibilityDecision"]
    Decision --> Orchestrator["CameraConnectionOrchestrator"]

    Orchestrator --> Pairing["PairingProfile"]
    Orchestrator --> Activation["ActivationProfile"]
    Orchestrator --> Wifi["WifiHandoverProfile"]
    Orchestrator --> Init["PtpInitProfile"]
    Orchestrator --> Negotiate["SessionNegotiationProfile"]
    Orchestrator --> Bootstrap["GalleryBootstrapProfile"]

    Bootstrap --> TransportReady["GalleryTransportReady"]
    TransportReady --> Shell["GalleryShellPresented"]
    TransportReady --> Catalog["CatalogCoordinator"]
    Catalog --> Content["Ready / Empty / RetryableFailed / FatalFailed"]

    Catalog --> Lane["现有 CommandLane"]
    Catalog --> Owner["现有 Catalog / Download Owner"]
~~~

设计原则：

1. 不按机型复制整条链，只声明差异。
2. Resolver 可以在阶段推进后重新求值，但已经完成的 barrier 不重复执行。
3. 所有相机命令继续经过现有串行 CommandLane。
4. `CameraSessionRuntime`、Catalog owner、download owner 和 generation fence 继续保持单一所有权。
5. Profile 不能直接操作 UI，UI 不能根据错误字符串猜测协议分支。
6. 未验证机型只能使用安全 fallback，不能自动堆叠多套 bootstrap。

## 7. 核心领域模型

以下名称为设计建议，最终实现计划可按现有命名规范微调，但职责不能合并。

### 7.1 CameraProtocolFamily

~~~swift
enum CameraProtocolFamily: String, Codable {
  case legacy
  case red
  case xHalf
  case unknown
}
~~~

它只表达 BLE / 注册协议世代，不直接决定 PTP 和 Gallery 全链。

### 7.2 CameraIdentitySnapshot

~~~swift
struct CameraIdentitySnapshot: Equatable {
  let cameraID: String
  let displayName: String
  let serialNumber: String?
  let firmwareVersion: String?
  let protocolFamily: CameraProtocolFamily
  let bleEndpoint: IOSCameraBleEndpoint
  let advertisedServiceUUIDs: Set<String>
  let manufacturerDataFingerprint: String?
}
~~~

### 7.3 CameraCapabilities

~~~swift
struct CameraCapabilities: OptionSet {
  let rawValue: UInt64

  static let officialImportImageActivation
  static let legacyRemoteImageViewActivation
  static let officialWifiCredential
  static let apStateNotification
  static let transferStateNotification
  static let functionModeNegotiation
  static let functionVersionNegotiation
  static let reservedImageReceive
  static let remoteBoot
}
~~~

能力必须来自真实 Service / characteristic / 协商响应，不从机型名盲推。

### 7.4 CameraCompatibilityEvidence

~~~swift
struct CameraCompatibilityEvidence: Equatable {
  let identity: CameraIdentitySnapshot
  let discoveredCharacteristics: Set<String>
  let successfulPtpInitVariant: PtpInitVariantID?
  let operationTransport: CameraVendorPtpOperationTransport?
  let functionMode: UInt32?
  let cameraFunctionVersion: UInt32?
  let selectedFunctionVersion: UInt32?
}
~~~

### 7.5 CameraProfile

~~~swift
struct CameraProfile {
  let id: CameraProfileID
  let matchConfidence: CameraProfileConfidence
  let pairing: PairingProfile
  let activation: ActivationProfile
  let wifi: WifiHandoverProfile
  let ptpInit: PtpInitProfile
  let negotiation: SessionNegotiationProfile
  let galleryBootstrap: GalleryBootstrapProfile
  let catalog: InitialCatalogProfile
  let errorPolicy: CameraProtocolErrorPolicy
}
~~~

Profile 是策略组合，不持有 socket、Task、UI controller 或 Catalog snapshot。

### 7.6 CameraCompatibilityDecision

~~~swift
struct CameraCompatibilityDecision {
  let profile: CameraProfile
  let confidence: CameraProfileConfidence
  let matchedRules: [CameraProfileRuleID]
  let rejectedCandidates: [CameraProfileRejection]
  let unresolvedFacts: Set<CameraCompatibilityFact>
}
~~~

任何一次连接必须能从日志还原候选、选中原因、未知事实和后续 refine 原因。

## 8. Profile Resolver

### 8.1 决策优先级

从高到低：

1. 当前会话真实响应：成功 INIT variant、Function Version、实际返回能力。
2. 当前 GATT 服务和 characteristic。
3. 已验证的机型 + 固件规则。
4. BLE Service / Manufacturer Data 协议族。
5. 安全 fallback。

机型名不能覆盖与真实 characteristic 或 wire 响应冲突的事实。

### 8.2 分阶段解析

~~~mermaid
sequenceDiagram
    participant D as Discovery
    participant R as Resolver
    participant G as GATT
    participant P as PTP
    participant O as Orchestrator

    D->>R: service + manufacturer data
    R-->>O: discoveryProfile
    G->>R: identity + characteristics
    R-->>O: activationProfile
    P->>R: INIT ACK variant + transport
    R-->>O: sessionProfile
    P->>R: function mode/version
    R-->>O: galleryProfile
~~~

Resolver 允许在 `discoveryResolved`、`gattCapabilitiesResolved`、`ptpInitResolved` 和 `functionNegotiationResolved` 后 refine。

若机型规则说支持 official import image，但 characteristic 缺失：

- 不执行缺失 characteristic 写入。
- 降低 Profile confidence。
- 记录 `capability-conflict`。
- 有已验证 fallback 时选择 fallback，否则在对应 barrier 明确失败。

## 9. Profile 组成

### 9.1 PairingProfile

控制 Scan filter、广告解析、identity key、系统 Bond 冲突、首次注册读写顺序和 remembered endpoint 匹配。

### 9.2 ActivationProfile

控制 BLE activation writes、必订阅状态、AP ready barrier、TransferState 是硬门槛还是软证据，以及 handover 前后 BLE 是否保持。

### 9.3 WifiHandoverProfile

控制 SSID/passphrase/BSSID 来源、IPv4 ready 条件、PTP 端口可达条件和连接后的 settle 条件。

等待优先基于状态；只有抓包证明必须等待且没有可观察状态时，才允许受限 delay。

### 9.4 PtpInitProfile

~~~swift
struct PtpInitProfile {
  let candidates: [PtpInitCandidate]
  let socketRestartPolicy: PtpSocketRestartPolicy
  let ackTimeoutPolicy: PtpAckTimeoutPolicy
  let eventChannelPolicy: PtpEventChannelPolicy
}
~~~

候选 packet 必须带 ID：

- `vendorLegacyWithClientIPGuid`
- `vendorLegacy`
- `standardPtpIp`
- 后续实机证明的新变体。

成功 ACK 的 packet 决定实际 `operationTransport`，不能在所有成功场景下硬编码为 legacy。

### 9.5 SessionNegotiationProfile

控制 OpenSession 后的 ClientState、Function Mode、Function Version、App/Camera 版本选择，以及哪些结果可以降级。

### 9.6 GalleryBootstrapProfile

~~~swift
enum GalleryBootstrapStep {
  case readGalleryContext
  case setClientState(UInt32)
  case readFunctionVersion
  case setFunctionVersion(UInt32)
  case readCardSlotStatus
  case resetCompressionMode
  case primeCurrentImage
  case primeCurrentThumbnail
  case readSearchModeDescriptor
  case readCurrentObjectHandle
}
~~~

每个步骤声明 `required`、`optional` 或 `experimental`。正式 Profile 不允许包含尚未经过同机型验证的 experimental 步骤。

### 9.7 InitialCatalogProfile

控制首次 `9053` 参数、`D620 / D621` 顺序、空目录语义、count/date group/unique handle 校验，以及 `0x2013` 的分类和恢复。

Catalog profile 不负责 BLE/Wi-Fi/PTP 重连；只有 `transportLost` 才交回连接恢复。

## 10. 连接状态机

~~~text
idle
→ discovering
→ identityResolved
→ bleRegistered
→ transferAuthorized
→ cameraAccessPointReady
→ wifiBound
→ ptpInitAcknowledged
→ ptpSessionOpened
→ functionNegotiated
→ galleryTransportReady
~~~

每次推进必须有可验证 evidence，不能仅因函数返回而推进。

建议新增：

~~~swift
struct ConnectionBarrierLedger {
  let sessionID: UUID
  let profileID: CameraProfileID
  let completed: Set<ConnectionBarrier>
  let evidence: [ConnectionBarrier: ConnectionBarrierEvidence]
}
~~~

作用：

1. 页面生命周期重入时不重复步骤。
2. 日志准确指出第一个缺失 barrier。
3. Profile refine 后只执行尚未完成且仍适用的步骤。

| 首个缺失 barrier | 错误归属 | 示例 |
|---|---|---|
| identityResolved | 扫描 / 身份 | 协议族、endpoint、系统 Bond |
| cameraAccessPointReady | BLE activation | 写入、APState、TransferState |
| wifiBound | Wi-Fi | SSID、passphrase、IPv4、路由 |
| ptpInitAcknowledged | PTP INIT | X‑E5 当前失败层 |
| galleryTransportReady | 协商 / bootstrap | ClientState、Function Version、必要前置 |
| catalogReady | Catalog | X‑M5 当前失败层 |

错误恢复只能从第一个缺失 barrier 开始，不能默认从 BLE 全链重跑。

## 11. 相册入口与 Catalog 解耦

“进入页面”和“图库可用”必须分开：

~~~text
GalleryTransportReady
→ GalleryShellPresented
→ CatalogLoading
→ CatalogReady
   / CatalogEmpty
   / CatalogRetryableFailed
   / CatalogFatalFailed
   / TransportLost
~~~

- `GalleryShellPresented`：导航和页面容器已建立。
- `CatalogReady`：首个经过校验的 Catalog snapshot 已安装，才是图库业务真正可用。

这样既允许先进入页面，也不把 PTP open 或假 evidence 误称为 GalleryReady。

不要继续让一个 `CameraSessionPhase` 同时承担连接、导航、目录和下载四种语义。推荐目标：

~~~swift
struct CameraSessionPresentation {
  let connection: CameraConnectionPresentationState
  let gallery: CameraGalleryPresentationState
  let download: CameraDownloadPresentationState
  let catalog: CameraGalleryPresentation
}
~~~

最低风险迁移方式是先增加 `galleryShellPresented` 和独立 `catalogState`，保持现有下载状态不变，后续再逐步收敛。

| Catalog 状态 | 页面行为 |
|---|---|
| loading | 显示相机相册骨架和加载进度 |
| ready | 展示日期组和照片 |
| empty | 展示“相机中没有可读取照片” |
| retryableFailed | 留在页面，显示重试入口和诊断码 |
| fatalFailed | 留在页面，提示重新连接或重新配对 |
| transportLost | 进入 Runtime 恢复或明确断开 |

只有 Catalog 命令失败但 transport 仍存活时，不应自动退出页面或重跑配对。

## 12. 初始 Profile

### 12.1 X-T5CurrentProfile

定位：迁移当前已成功链路，第一阶段保持 wire 行为不变。

要求：

- 用适配器包装当前 BLE、Wi-Fi、PTP、bootstrap 和 Catalog 实现。
- 记录完整 barrier 和 decision trace。
- 不顺手增加 XApp 可选命令。
- 迁移前后做同机型回归，证明成功率和进入时间没有明显退化。

### 12.2 X-M5Profile

已确认：

- RED 广告 / GATT 身份可以识别。
- official import image BLE 激活成功。
- Wi-Fi handover 成功。
- vendor legacy + client IP GUID INIT 成功。
- OpenSession 成功。
- 首次 `9053` 返回 `0x2013`。

待验证实验：

1. 在对应 XApp 顺序位置加入 `D226=0`。
2. 只调整 `D212` 的读取次数和顺序。
3. 分别单独加入 `9054`、`9055`、`9050`、`D22B`。

不得一次加入整套命令后宣布根因。

### 12.3 X-E5Profile

已确认：

- RED 广告 / GATT 身份可以识别。
- official import image BLE 激活成功。
- APState 进入 launched。
- Wi-Fi 和 IPv4 成功。
- 55740 TCP 最终可连接。
- 当前两个 vendor legacy INIT 均未稳定得到 ACK。

待验证：

1. 同一 X‑E5 使用 XApp，从 activation 到 INIT ACK 的完整抓包。
2. standard PTP/IP INIT candidate。
3. GUID / friendly name / client IP 编码差异。
4. BLE launch writes 与 INIT 时间关系。
5. APState 和 TransferState 是否需要组合 barrier。

### 12.4 UnknownRedProfile

安全原则：

- 只执行当前 characteristic 明确支持的 activation。
- 使用经过验证且有序的 INIT candidate set。
- 每个 candidate 失败后关闭并重建 socket。
- 不自动堆叠 X‑M5 experimental bootstrap。
- Catalog 失败留在页面并输出诊断，不伪装成“所有 RED 均支持”。

## 13. 日志与诊断

每条结构化日志至少包含：

- `connectionSessionID`
- `cameraID`
- `model`
- `serialHash`
- `firmwareVersion`
- `protocolFamily`
- `profileID`
- `profileRevision`
- `profileConfidence`
- `barrier`
- `attempt`
- `elapsedMs`

序列号默认记录 hash 或末尾短标识，避免诊断文件暴露完整设备身份。

决策日志：

~~~text
PROFILE_RESOLUTION
profile=xm5-red-v1
confidence=provisional
matched=red-service,official-import-characteristics,model-x-m5
unresolved=firmware,function-version
rejected=xt5-current:wrong-model
~~~

协议步骤必须一一对应：

~~~text
PROTOCOL_STEP_BEGIN
→ PROTOCOL_STEP_SUCCEEDED
  / PROTOCOL_STEP_FAILED
  / PROTOCOL_STEP_CANCELLED
~~~

失败汇总：

~~~text
CONNECTION_TERMINAL
firstMissingBarrier=ptpInitAcknowledged
profile=xe5-red-provisional
transport=tcp-connected
lastWireOutcome=init-reset-by-peer
retryOwner=ptp-init-profile
~~~

## 14. 错误、重试和恢复

建议错误分类：

~~~swift
enum CameraCompatibilityError {
  case unsupportedIdentity
  case missingCapability
  case activationRejected
  case wifiHandoverFailed
  case ptpInitRejected
  case ptpSessionFailed
  case negotiationFailed
  case galleryBootstrapFailed
  case catalogRetryable
  case catalogFatal
  case transportLost
}
~~~

| 错误 | 重试 owner |
|---|---|
| BLE scan / GATT | Pairing or reconnect coordinator |
| AP activation | ActivationProfile |
| Wi-Fi association | WifiHandoverProfile |
| INIT packet / socket reset | PtpInitProfile |
| Function negotiation | SessionNegotiationProfile |
| `9053 / D620 / D621` | Catalog coordinator |
| transport lost | CameraSessionRuntime recovery |

规则：

- UI 不直接重跑底层指令。
- 每个重试有最大次数、退避、取消和终态。
- 切换 INIT candidate 必须按 profile 规则关闭并重建 socket。
- Catalog `0x2013` 当前不能默认定义为 retryable，先保持“协议状态不满足”的可诊断失败。

## 15. 现有组件的保留与调整

### 15.1 保留

- `CameraSessionRuntime` 作为 App 级相机会话 owner。
- `CameraCommandLane` 的 PTP 串行化。
- Catalog generation fence。
- Catalog owner / download owner。
- 现有下载、缩略图、HD Preview、快速下载实现。
- `IOSCameraGalleryConnectionCoordinator` 的步骤编排思想。

### 15.2 调整

- `IOSCameraIdentity` 扩展或由新 snapshot 包装。
- `FujifilmXSeriesProfile` 拆分为连接 Profile 与媒体参数 Profile。
- BLE activation 候选由 Profile 提供。
- 全局 Gallery route policy 收敛为 Profile 策略。
- PTP INIT candidates 由 `PtpInitProfile` 提供。
- `performInitHandshake()` 根据成功 candidate 返回真实 transport。
- `executeConfirmGalleryModeStep()` 接收真实 negotiation/bootstrap evidence。
- `executeLoadGalleryStep()` 改为表达 `galleryTransportReady`，不能生成 Catalog 已加载 evidence。
- `CameraSessionRuntime` 增加 Gallery Shell 与 Catalog 独立状态。

### 15.3 不做

- 不重写整个 PTP 编解码器。
- 不移除现有 CommandLane。
- 不把每个机型做成独立 Runtime。
- 不让 Profile 持有 mutable session state。
- 不在第一阶段引入远程配置平台。

## 16. 分阶段迁移

### 阶段 0：冻结证据和行为

- 保存 X‑T5 成功链 wire 顺序。
- 固化 X‑M5、X‑E5 首个失败 barrier。
- 为现有行为增加 characterization tests。
- 不改变相机命令。

### 阶段 1：兼容模型与 Resolver 骨架

新增 `CameraProtocolFamily`、`CameraIdentitySnapshot`、`CameraCapabilities`、`CameraCompatibilityEvidence`、`CameraProfile`、`CameraProfileResolver` 和 `CameraCompatibilityDecision`。

先只解析出 `X-T5CurrentProfile` 与 `UnknownRedProfile`。

### 阶段 2：迁移 X‑T5 当前成功链

用 adapter 把现有实现接入 Profile。要求 wire 行为不变，避免“搭框架同时改协议”。

### 阶段 3：Gallery Shell 与 Catalog 解耦

- `galleryTransportReady` 后允许页面容器展示。
- Catalog 在页面内异步加载。
- Catalog 失败不自动退出页面。
- transport lost 仍由 Runtime 统一恢复。

### 阶段 4：完整诊断

一次日志必须回答识别结果、协议族、Profile、实际步骤、首个缺失 barrier 和下一次单变量实验点。

### 阶段 5：X‑M5 单变量协议实验

实验不进入默认 Profile，直到同机型重复验证。

### 阶段 6：X‑E5 INIT 实验

先取得 XApp 同机型 INIT 成功对照，再加入 candidate；不能用 X‑M5 的 Catalog 逻辑推断 X‑E5。

### 16.1 改动量评估

| 模块 | 改动量 | 风险 | 原因 |
|---|---|---|---|
| Compatibility 新模型与 Resolver | 中 | 低到中 | 主要是新增纯类型、规则和单元测试 |
| BLE activation 接入 Profile | 中 | 中 | 现有 service 较大，需要避免改变已成功写入顺序 |
| PTP INIT candidate 化 | 中 | 中到高 | 触及物理会话建立，必须用 characterization test 和真机回归保护 |
| Gallery bootstrap 步骤化 | 中 | 高 | X‑M5 问题就在此区域，不能同时做协议修复 |
| Gallery Shell / Catalog 解耦 | 中到大 | 中到高 | 涉及 Runtime、导航和 UI 状态语义，但无需重写下载链 |
| 日志与 barrier ledger | 中 | 低 | 以新增结构化证据为主 |
| X‑M5 / X‑E5 正式 Profile | 未知 | 高 | 取决于同机型取证结果，不应提前估算为“只改几个指令” |

总体属于“中等偏大的架构升级”，但不是推倒重写。安全拆分后，阶段 0–2 可以基本不改变 wire；阶段 3 单独处理 UI/Catalog；阶段 5–6 才改变特定机型协议。

### 16.2 实施卡点与未决问题

| 卡点 | 是否阻塞搭框架 | 阻塞什么 |
|---|---|---|
| 最新日志没有明确 firmware | 否 | 阻塞按固件精确选择正式 Profile |
| 缺少同一 X‑M5 的 XApp 成功抓包 | 否 | 阻塞确认 X‑M5 Catalog 根因和正式 bootstrap |
| 缺少同一 X‑E5 的 XApp INIT 成功抓包 | 否 | 阻塞确认 X‑E5 正式 PTP INIT candidate |
| 当前 PTP INIT 成功后固定返回 legacy | 否，是阶段 1–2 要修的结构问题 | 阻塞真实 transport 选择 |
| Gallery evidence 命名与真实 barrier 不一致 | 否，是阶段 2–3 要迁移的问题 | 阻塞清晰状态和页面内失败 |
| 工作区已有大量并行改动 | 不阻塞设计 | 实施时必须用独立分支/工作树或严格路径级修改 |
| 真机矩阵设备和测试时间 | 不阻塞编码 | 阻塞“完整兼容”发布结论 |

所以目前没有阻塞“先搭架构”的未知项；未知项主要阻塞 X‑M5、X‑E5 的最终 Profile 内容和完整兼容结论。

## 17. 测试方案

### 17.1 自动化测试

1. Resolver 输入与 Profile 输出表。
2. characteristic 缺失时不能选择不满足能力的 Profile。
3. 同为 RED、不同机型可选择不同 PTP / Gallery 策略。
4. 成功 INIT candidate 决定真实 transport。
5. Profile refine 不重复已完成 barrier。
6. first missing barrier 计算正确。
7. Catalog failure 不回退到 BLE 全链。
8. `galleryTransportReady` 可展示 Gallery Shell。
9. `catalogRetryableFailed` 留在页面。
10. `transportLost` 才触发连接恢复。
11. 页面重现不重复启动同一个 Catalog session。
12. 旧 generation 回调不能污染新会话。

### 17.2 Profile contract

每个正式 Profile 必须满足：

- ID 和 revision 唯一。
- required capability 可验证。
- 没有 experimental step。
- 所有重试有上限。
- 每个 protocol step 有 BEGIN 和终态日志。
- Catalog 与 download 共用现有 CommandLane。

### 17.3 真机矩阵

| 机型 | 配对 | 重连 | Wi-Fi | INIT | OpenSession | Gallery Shell | Catalog | 退出重进 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| X‑T5 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 |
| X‑M5 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 | 单变量实验 | 必测 |
| X‑E5 | 必测 | 必测 | 必测 | 单变量实验 | 未到达前不测 | 未到达前不测 | 未到达前不测 | 后续 |
| X‑S20 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 |
| GFX100RF | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 |

每个“成功”至少需要同一台相机连续冷启动、退出重进、App kill 后重连、相机关闭 AP 后重试，并能从日志还原 profile、barrier 和 wire 终态。

## 18. X‑M5 后续取证计划

当前 XApp 参考顺序中，首次 `9053` 前出现：

~~~text
D212
DF01=20
DF28 read
D212
DF28=3
D244
D226=0
D244
9054
9055
9050
D22B
9053
D212
D620
D621
~~~

当前 X‑M5 已观察链路与之不同，但现有 XApp 抓包不是同机型物理证明。

实验规则：

1. 固定相机、固件、SD 卡、图片数量和启动方式。
2. 保留一条不修改的 control。
3. 每次只改变一个 wire-visible 变量。
4. 记录 `D212 / D222`、顺序、间隔、返回码和 socket 状态。
5. 单次成功不能进入正式 Profile，至少需要重复成功与反向移除验证。

建议顺序：先补同一 X‑M5 的 XApp 成功抓包，再依次验证 `D226=0`、`D212` 顺序、`9054`、`9055`、`9050`、`D22B`，最后才验证组合。

## 19. X‑E5 后续取证计划

X‑E5 当前首个缺失 barrier 是 `ptpInitAcknowledged`。

优先级：

1. X‑E5 使用 XApp 的 BLE activation → Wi-Fi → TCP → INIT ACK 抓包。
2. 比较 packet length、GUID、client IP、friendly name 编码、protocol version 和 event channel。
3. 比较 launch payload、APState、TransferState、BLE 是否断开和 INIT 时机。
4. 将每个差异作为独立 `PtpInitCandidate` 或 `ActivationProfile` 实验。

在 INIT ACK 前，不增加任何 `D212 / D226 / 905x` 命令。

## 20. 回滚和发布策略

第一阶段保留 `compatibilityArchitectureV2` 开关：

- 关闭：走现有 X‑T5 链。
- 开启：由 Resolver 选择 Profile。

开关只用于迁移回滚，不长期维持两套实现。X‑T5 验证完成后应删除旧入口。

Profile ID 与 revision 分开，例如 `xm5-red / revision 1`。日志必须携带 revision。

发布顺序：

1. 先让 X‑T5 走 V2。
2. Unknown RED 只启用诊断和安全 fallback。
3. X‑M5、X‑E5 分别在验证后启用正式 Profile。
4. 单个机型失败率上升时回滚该 Profile，不影响其他机型。

## 21. 验收标准

第一阶段架构完成的标准不是“所有相机都能连上”，而是：

1. X‑T5 当前成功链已由 Profile 驱动，wire 行为无意外变化。
2. 同为 RED 的不同机型可以选择不同 PTP / Gallery 策略。
3. 日志能输出 identity、capabilities、profile、revision、barrier 和 first failure。
4. PTP INIT 成功结果能决定实际 transport，不再一律标记 legacy。
5. `confirmGalleryMode` 不再生成无协议依据的 evidence。
6. Gallery Shell 可以在 Catalog 完成前展示。
7. Catalog 失败可留在页面并由 Catalog owner 重试。
8. transport loss 与 Catalog 业务失败被明确区分。
9. X‑M5 和 X‑E5 的实验可以分别接入，不修改 X‑T5 主链。
10. 所有新增状态与 Resolver 分支都有自动化测试。

多机型“完整兼容”只有在目标真机矩阵逐台通过后才能宣布，不能由架构完成自动推出。

## 22. 实施文件边界建议

后续实施计划建议创建：

- `ios/Runner/CameraCompatibility/CameraProtocolFamily.swift`
- `ios/Runner/CameraCompatibility/CameraIdentitySnapshot.swift`
- `ios/Runner/CameraCompatibility/CameraCapabilities.swift`
- `ios/Runner/CameraCompatibility/CameraCompatibilityEvidence.swift`
- `ios/Runner/CameraCompatibility/CameraProfile.swift`
- `ios/Runner/CameraCompatibility/CameraProfileResolver.swift`
- `ios/Runner/CameraCompatibility/CameraCompatibilityDecision.swift`
- `ios/Runner/CameraCompatibility/CameraConnectionBarrier.swift`
- `ios/Runner/CameraCompatibility/CameraConnectionOrchestrator.swift`
- `ios/Runner/CameraCompatibility/Profiles/X-T5CurrentProfile.swift`
- `ios/Runner/CameraCompatibility/Profiles/UnknownRedProfile.swift`

后续预计修改：

- `ios/Runner/CameraVendorBluetoothService.swift`
- `ios/Runner/CameraVendorPtpSession.swift`
- `ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift`
- `ios/Runner/CameraCore/Connection/CameraConnectionSteps.swift`
- `ios/Runner/CameraCore/Models/CameraCoreModels.swift`
- `ios/Runner/CameraSessionRuntime.swift`
- `ios/RunnerTests/RunnerTests.swift`
- `ios/project.yml`

正式实施计划必须再根据当前源码职责检查是否需要减少文件数量；本节只锁定职责边界，不授权开始编码。

## 23. 最终建议

最佳方案不是完整复刻 XApp，也不是只针对 X‑M5 打补丁，而是：

~~~text
复制 XApp 的兼容方法
≠ 复制 XApp 的所有命令

保留 CamTransfer 的 Session / CommandLane / Catalog / Download 架构
+ 补齐渐进式 Identity / Capability / Profile Resolver
+ 把 PTP INIT、Function Negotiation、Gallery Bootstrap 变成可选择策略
+ 将 Gallery Shell 与 Catalog Ready 解耦
+ 用同机型单变量实验完善 X‑M5、X‑E5 Profile
~~~

这个方案的改动量属于中等偏大，但可以分阶段完成，不需要推倒重写。

最重要的顺序是：

1. 先搭兼容骨架和诊断。
2. 迁移 X‑T5 成功链，证明架构没有破坏现状。
3. 解耦 Gallery Shell 与 Catalog。
4. 再分别解决 X‑M5 Catalog 前置状态和 X‑E5 PTP INIT。

只有这样，当前两类失败才能被放在正确的层级解决，后续新增机型也不需要继续扩大一条不可维护的固定连接链。
