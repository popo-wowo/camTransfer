# CamTransfer iOS 对齐 XApp 的多机型兼容终态架构

原始日期：2026-08-06

最终修订：2026-08-07

状态：终态技术方案（本次 evidence review 定稿）

范围：iOS 无线配对、BLE 激活、Wi-Fi handover、PTP/IP、相册会话初始化、首次 Catalog 和多机型/固件兼容

不包含：USB、遥控拍摄、固件升级、云端业务、直接复制富士私有 SDK、未经验证的机型支持承诺

## 0. 最终结论

CamTransfer 的终态不是“在当前固定连接链上继续增加机型判断”，也不是“为每台相机建立一套 Runtime/Profile”，而是：

~~~text
复用 XApp 可见的分层思想
+ 用 FujifilmProtocolEngine 显式替代不可获得的富士 SDK/FFIR
+ 保留 CamTransfer 已验证的 Runtime、CommandLane、Catalog 和 Download 所有权
+ 以会话级事实和版本化 ConnectionPlan 隔离兼容家族、能力和固件差异
~~~

终态只有：

1. 一个 App 级 CameraSessionRuntime。
2. 一个 CameraConnectionOrchestrator。
3. 一份当前连接的 CameraConnectionExecutionState。
4. 一个无状态 CameraConnectionPlanResolver。
5. 一个 FujifilmProtocolEngine 作为富士协议能力边界。
6. 一个由 Runtime 持有的 FujifilmCameraSession。
7. 一条 CameraCommandLane。
8. 一个 CameraGalleryCatalogRuntime。
9. 一个 download owner。

X-T5、X-M5、X-E5 不属于架构节点，也不拥有独立 Runtime、Coordinator 或 ProtocolEngine。它们只会出现在：

- CameraCompatibilityRegistry 的规则数据中。
- 真机验证矩阵中。
- 日志和诊断事实中。

## 1. 设计方法与证据等级

本方案只接受可追溯的架构决策。

### 1.1 证据等级

| 等级 | 含义 | 能否进入终态设计 |
|---|---|---|
| S | 当前 CamTransfer 源码事实 | 可以 |
| X | XApp Java/Kotlin 反编译可见事实 | 可以，但不能外推 Native SDK 内部 |
| L | 当前真机日志事实 | 可以限定失败层 |
| A | git-ai 作者上下文或明确历史约束 | 可以解释现有边界；无 transcript 时必须标注代码推断 |
| H | 高价值假设或实验候选 | 不能作为正式策略 |

### 1.2 当前源码证据

S-01：IOSCameraGalleryConnectionCoordinator 和 IOSCameraConnectionStateMachine 已经强制 BLE → Wi-Fi → PTP 的有序推进，并保存 completedSteps。

S-02：CameraVendorGalleryMainlineSessionLoader 把 BLE/Wi-Fi 作为 route-independent trunk，PTP route 失败时只重新执行 route 部分。

S-03：executeConfirmGalleryModeStep() 没有与相机通信，直接返回 galleryModeConfirmed。

S-04：executeLoadGalleryStep() 只检查 PTP session ID 非空，直接返回 galleryLoaded；真正的目录加载由 Catalog Runtime 完成。

S-05：当前 PTP INIT 只尝试 vendor legacy + client IP GUID 和 vendor legacy 两个变体，成功后固定返回 cameraVendorLegacy。

S-06：IOSCameraIdentity 只有 cameraID、displayName、serialNumber 和 BLE endpoint，不能表示兼容家族、GATT 能力、固件、INIT 结果和 Function Version。

S-07：FujifilmXSeriesProfile 当前只有 xt5Current，主要保存启动 delay 和下载 read size，不是连接兼容模型。

S-08：CameraSessionRuntime 只有在 Catalog ready、当前 generation/snapshot 已安装后，才发布 GalleryReady 并完成 pending activation。

S-09：CameraCommandLane、Catalog generation、snapshot identity、Catalog owner 和 download owner 已形成媒体阶段的单一所有权。

### 1.3 XApp 可见证据

X-01：XApp 定义 Legacy、RED、X-Half、X-Half RED 等不同 BLE Service。

X-02：BTCameraService 分别维护 RED 与 non-RED Service/Characteristic Map。

X-03：CameraModel/CameraInfoModel 维护机型、固件支持范围、XAppSupportVersion、SDCardHotSwapVersion、RemoteBoot 等主数据。

X-04：CameraInfoModel.checkVersion() 按机型和固件判断支持范围，未知机型不会直接通过。

X-05：CameraConnectModel 只调用 CameraConnectWrapper.open(..., ConnectType.KWlan)，socket/session 的大量细节被 SDK 隐藏。

X-06：ControlFFIR 通过 Java_SDK_Open、Java_SDK_SetFunctionMode、Java_SDK_GetFunctionVersion、Java_SDK_SetFunctionVersion、Java_SDK_GetSpecifiedObjectCountGroupByDate 等 Native API 提供协议能力。

X-07：ImportImageModel 执行 Function Mode/Version、Dual Slot Status、initializeFirst() 和 initialize()。

X-08：CommRetry 默认 maxAttempts=5、delay=100ms，并提供错误分类；doWithRetry() 的反编译不完整，不能据此推断全部错误码行为。

X-09：ImportImage UI 存在初始化状态，可以显示页面初始化内容，但这不能单独证明 XApp 的外部 GalleryReady 成功语义。

边界说明：本文把 Legacy、RED、X-Half 称为“兼容家族”，依据是 XApp 可见的 BLE Service/Characteristic 分组；它不等价于已经证明三套完整 PTP wire protocol，也不代表同一家族的所有机型后续链路完全相同。

### 1.4 真机日志证据

L-XM5：

- BLE identity/activation 成功。
- Wi-Fi handover 成功。
- PTP INIT ACK 成功。
- OpenSession 成功。
- Gallery handshake 成功。
- 首个明确失败点是首次 9053 返回 0x2013。

结论：X-M5 当前失败不在 BLE、Wi-Fi 或 PTP transport。

L-XE5：

- BLE identity/activation 成功。
- AP launched。
- Wi-Fi、IPv4 和 TCP 192.168.0.1:55740 成功。
- 当前两个 vendor legacy INIT 均没有稳定 ACK。
- 没有 OpenSession，也没有 Catalog。

结论：X-E5 当前失败在 PTP INIT，不能用 D212、D226 或 905x 解释。

### 1.5 作者上下文证据

A-01：git-ai 找到 CameraVendorGalleryMainlineSessionLoader 对应会话和作者，但没有返回原始 prompt/response，因此不能把设计动机称为 transcript 已证明。

A-02：从代码可确认，现有 Loader/Coordinator/StateMachine 的价值是单一有序连接 owner、取消、步骤记录和首个 barrier 归属。

A-03：从代码可确认，ConfirmGalleryMode/LoadGallery 是过渡 evidence adapter，不是终态协议或 Catalog 成功门槛。

A-04：CameraSessionRuntime 的 Catalog ready gate 是可用性证明；即使实现拆分，GalleryReady 仍必须绑定当前 session/generation/snapshot。

### 1.6 可复核证据索引

| 证据 | 文件或日志 | 关键符号/事件 |
|---|---|---|
| S-01/S-03/S-04 | `ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift`、`CameraConnectionStateMachine.swift`、`CameraVendorGalleryMainlineSessionLoader.swift` | `completedSteps`、`executeConfirmGalleryModeStep()`、`executeLoadGalleryStep()` |
| S-05 | `ios/Runner/CameraVendorPtpSession.swift` | `performInitHandshake()`、`CameraVendorOfficialGalleryPtpInitPolicy.initAttempts(...)` |
| S-06/S-07 | `ios/Runner/CameraCore/Models/CameraCoreModels.swift`、`ios/Runner/CameraAdapters/Fujifilm/FujifilmXSeriesProfile.swift` | `IOSCameraIdentity`、`xt5Current` |
| S-08/S-09 | `ios/Runner/CameraSessionRuntime.swift`、`ios/Runner/CameraCommandLane.swift`、`ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift` | `installCatalogPresentation(...)`、generation/snapshot install、CommandLane |
| X-01/X-02 | `.analysis/xapp/jadx/sources/com/fujifilm/xapp/common/BTConstansKt.java`、`model/bleconnect/BTCameraService.java` | Legacy/RED/X-Half Service、RED/non-RED map |
| X-03/X-04 | `.analysis/xapp/jadx/sources/com/fujifilm/xapp/model/common/CameraInfoModel.java`、`.analysis/xapp/jadx/sources/com/fujifilm/xapp/model/jsonentity/CameraModel.java` | `checkVersion(...)`、support version、RemoteBoot |
| X-05/X-06 | `.analysis/xapp/jadx/sources/com/fujifilm/xapp/model/camera_connect/CameraConnectModel.java`、`common/ffir/ControlFFIR.java` | `open(..., KWlan)`、Function Mode/Version Native API |
| X-07/X-08/X-09 | `.analysis/xapp/jadx/sources/com/fujifilm/xapp/model/importimage/ImportImageModel.java`、`CommRetry.java` | `initializeFirst()`、`initialize()`、retry defaults、初始化 UI |
| L-XM5 | `/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-05T08-23-08Z.log` | `PTP_INIT_ACK`、OpenSession 后首次 `0x9053 -> 0x2013` |
| L-XE5 | `/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-05T11-36-03Z.log` | TCP 55740 connected、两个 INIT 无 ACK/reset、无 OpenSession |

## 2. XApp 的真实架构

当前能确认的 XApp 架构是：

~~~mermaid
flowchart TD
    UI["ImportImage Activity / ViewModel"] --> Import["ImportImageModel"]
    Import --> Retry["CommRetry"]
    Import --> Connect["CameraConnectModel"]
    Connect --> Wrapper["CameraConnectWrapper"]
    Import --> Wrapper
    Wrapper --> FFIR["ControlFFIR / Native SDK"]

    BLE["BTManager / BTCameraService"] --> Info["CameraInfoModel / CameraModel Master Data"]
    Info --> Connect
    BLE --> Camera["Fujifilm Camera"]
    FFIR --> Camera
~~~

### 2.1 BLE 和注册层

负责：

- 扫描和连接 BLE。
- 区分 RED/non-RED/X-Half Service。
- 发现 characteristic。
- 读取身份、序列号和配对信息。
- 启动相机 AP 和文件传输功能。

### 2.2 相机主数据层

负责：

- 机型和展示名。
- 固件支持门槛。
- 功能版本门槛。
- RemoteBoot、SD 卡热插拔等能力信息。
- 未知机型和不支持固件的拒绝。

这是一套主数据和能力判断，不是每个机型一个连接类。

### 2.3 CameraConnectModel

负责：

- 调用 SDK open。
- 管理 open cancel。
- 区分 socket open failure 和 session open failure。
- 向 Repository 发布连接状态。

它没有在 Java/Kotlin 层显式实现全部 PTP INIT/OpenSession。

### 2.4 CameraConnectWrapper / ControlFFIR

这是 XApp 最关键的黑盒边界，可能封装：

- socket 建立。
- PTP INIT。
- OpenSession。
- Function Mode/Version。
- 设备属性和 Gallery 命令。
- transaction、错误码和部分重试。
- 不同固件或协议响应的兼容。

由于实际实现是 Native SDK，不能从外部包装方法推出全部内部顺序。

### 2.5 ImportImageModel

负责：

- 设置图片浏览 Function Mode。
- 获取和选择 Function Version。
- 初始化卡槽和搜索模式。
- initializeFirst/initialize。
- 获取目录、图片句柄和缩略图。
- 业务错误和初始化状态。

## 3. 为什么不能直接复制 XApp

### 3.1 私有 SDK 不可获得

直接复制 CameraConnectModel、ImportImageModel 或 ControlFFIR 包装层，仍然缺少 Java_SDK_Open 等 Native 实现。

结果会变成：

~~~text
复制 XApp 外层类
→ 缺少真正 SDK
→ 仍需自行实现 BLE/PTP/Function/Catalog
→ 同时引入 XApp 的全局状态和历史耦合
~~~

### 3.2 XApp 外层依赖 SDK 状态机

XApp 可以调用 open、setFunctionMode、initialize，是因为 SDK 已经替它持有 camera handle、transaction、协议状态和错误映射。

CamTransfer 没有这个黑盒，必须显式建立相同能力边界。

### 3.3 平台和现有所有权不同

CamTransfer iOS 已经拥有：

- App 级 CameraSessionRuntime。
- CameraCommandLane。
- Catalog generation/snapshot。
- Catalog/download owner。
- thumbnail、HD preview、quick download。
- iOS Wi-Fi handover 和生命周期恢复。

为了复制 XApp Android 类结构而放弃这些边界，没有技术依据。

### 3.4 XApp 可见结构不等于理想终态

反编译可见多个 singleton、静态状态、Native handle 和大 Model。它能作为兼容行为参考，不能自动作为 CamTransfer 的代码组织标准。

## 4. 方案选择

### 方案 A：继续按机型在当前 Service/Session 中加判断

优点：

- 单次实验最快。

缺点：

- 模型、固件、characteristic、协议响应混在一起。
- 影响范围无法控制。
- 无法替代 SDK 的稳定能力边界。

结论：只允许临时实验，不是终态。

### 方案 B：完整复制 XApp Java/Kotlin 外层

优点：

- 命名和调用关系看起来接近 XApp。

缺点：

- 最关键 Native SDK 仍缺失。
- Android Repository/Singleton/Callback 模型不适合当前 iOS Runtime。
- 无法获得真正兼容逻辑。

结论：不可行。

### 方案 C：XApp 可见分层 + 显式 FujifilmProtocolEngine

优点：

- 对齐 XApp 的能力边界。
- 将 SDK 黑盒变成可测试的显式实现。
- 保留 CamTransfer 已验证的所有权。
- 协议和固件差异限定在当前 Session 的 ConnectionPlan。
- 不形成机型树或每机型 Runtime。

结论：终态采用。

## 5. 终态总体架构

~~~mermaid
flowchart TD
    UI["UI / Presentation"] --> Runtime["CameraSessionRuntime<br/>App 级唯一 Session Owner"]

    Runtime --> Orchestrator["CameraConnectionOrchestrator<br/>唯一连接编排器"]
    Runtime --> Catalog["CameraGalleryCatalogRuntime<br/>唯一 Catalog Owner"]
    Runtime --> Download["Download Owner"]

    Orchestrator --> ExecState["CameraConnectionExecutionState<br/>唯一连接状态和 Evidence"]
    Orchestrator --> Resolver["CameraConnectionPlanResolver<br/>无状态"]
    Resolver --> Registry["CameraCompatibilityRegistry<br/>协议/能力/固件规则"]
    Resolver --> Plan["CameraConnectionPlan<br/>会话级版本化快照"]

    Orchestrator --> Engine["FujifilmProtocolEngine<br/>显式替代富士 SDK"]
    Engine --> BLE["FujifilmBluetoothAdapter"]
    Engine --> WiFi["IOSCameraWifiAdapter"]
    Engine --> PTP["FujifilmPtpAdapter"]

    Engine --> Session["FujifilmCameraSession"]
    Runtime --> Session
    Session --> Lane["CameraCommandLane"]

    Catalog --> Lane
    Download --> Lane
    Catalog --> Repository["Catalog Repository<br/>Generation + Snapshot"]
    Repository --> Runtime
    Runtime --> UI
~~~

## 6. 终态所有权

### 6.1 CameraSessionRuntime

唯一 App 级 owner，负责：

- 当前相机 Session 生命周期。
- 创建和取消 Orchestrator。
- 接收 prepared FujifilmCameraSession。
- Catalog、download、thumbnail、HD preview 和 recovery。
- session/generation/snapshot fence。
- 对 UI 发布不可变 presentation。

不负责：

- 判断机型。
- 选择 INIT packet。
- 执行 Function Mode。
- 直接发送 PTP 命令。

### 6.2 CameraConnectionOrchestrator

唯一连接编排器，由现有 IOSCameraGalleryConnectionCoordinator 和 IOSCameraConnectionStateMachine 演进而来，不平行新增第二条链。

负责：

- 执行有序连接阶段。
- 持有当前 CameraConnectionExecutionState。
- 请求 Resolver 生成或修订 ConnectionPlan。
- 调用 FujifilmProtocolEngine。
- 处理阶段取消、超时和 retry owner。
- 输出 prepared FujifilmCameraSession。

不负责：

- Catalog generation 和发布。
- download。
- UI 导航。
- 保存全局机型开关。

### 6.3 CameraConnectionExecutionState

连接事实的唯一运行时状态：

~~~swift
struct CameraConnectionExecutionState {
  let connectionSessionID: UUID
  let facts: CameraCompatibilityFacts
  let plan: CameraConnectionPlan
  let completedBarriers: [CameraConnectionBarrier]
  let evidence: [CameraConnectionBarrier: CameraConnectionEvidence]
  let currentBarrier: CameraConnectionBarrier?
  let firstFailure: CameraConnectionFailure?
}
~~~

它吸收并替代分散的 completedSteps 和临时 route 标志，不新增第二个 Ledger。现有 `hasGalleryReadyEvidence` 从连接状态机删除；GalleryReady 只属于 CameraSessionRuntime/Catalog 状态，不进入该连接状态。

### 6.4 FujifilmProtocolEngine

这是 CamTransfer 对应 XApp CameraConnectWrapper/ControlFFIR 的终态边界。

~~~swift
protocol FujifilmProtocolEngine {
  func reconnectOrPair(
    plan: CameraConnectionPlan,
    state: CameraConnectionExecutionState
  ) async throws -> FujifilmBleSession

  func activateWirelessGallery(
    bleSession: FujifilmBleSession,
    plan: CameraConnectionPlan
  ) async throws -> CameraAccessPointEvidence

  func joinCameraWifi(
    activation: CameraAccessPointEvidence,
    plan: CameraConnectionPlan
  ) async throws -> CameraWifiBinding

  func openPtpTransport(
    wifi: CameraWifiBinding,
    plan: CameraConnectionPlan
  ) async throws -> FujifilmPtpTransportBinding

  func initializePtp(
    transport: FujifilmPtpTransportBinding,
    plan: CameraConnectionPlan
  ) async throws -> FujifilmPtpInitializedConnection

  func openCameraSession(
    initialized: FujifilmPtpInitializedConnection,
    plan: CameraConnectionPlan
  ) async throws -> FujifilmCameraSession

  func inspectGalleryFunction(
    session: FujifilmCameraSession,
    plan: CameraConnectionPlan
  ) async throws -> GalleryFunctionFacts

  func negotiateGalleryFunction(
    session: FujifilmCameraSession,
    plan: CameraConnectionPlan
  ) async throws -> GalleryNegotiationEvidence

  func prepareGallerySession(
    session: FujifilmCameraSession,
    plan: CameraConnectionPlan
  ) async throws -> GallerySessionPreparedEvidence
}
~~~

规则：

- ProtocolEngine 不拥有 App presentation。
- ProtocolEngine 不拥有 Catalog snapshot。
- ProtocolEngine 不创建第二条 CommandLane。
- 一个 Engine 方法可以完成多个 BLE 子步骤，但返回值必须包含每个已完成 barrier 的独立 evidence；不能只返回笼统 success。
- TCP connect、PTP INIT ACK 和 OpenSession 必须分别返回证据；不能用一个 `open()` 成功掩盖具体失败层。
- `inspectGalleryFunction` 只收集当前 Session 的 Function facts；Resolver 产生新 plan revision 后，`negotiateGalleryFunction` 才应用选择。
- 所有 OpenSession 后 PTP 操作必须进入当前 FujifilmCameraSession 的 CommandLane。
- 模型和固件差异只能来自 ConnectionPlan，不能读取全局开关。

这里的“对应 XApp SDK 边界”只表示职责对齐，不表示 CamTransfer 已获得或复现 SDK 内部全部兼容行为。每一个 Strategy 仍需独立协议证据。

### 6.5 FujifilmCameraSession

代表当前真实物理相机会话，至少绑定：

- connectionSessionID。
- camera identity。
- PTP transport/session ID。
- selected INIT strategy。
- negotiated function facts。
- 生效的 plan ID/revision 和不可变 Strategy 快照。
- CameraCommandLane。
- termination exactly-once 状态。

Runtime 持有它；Catalog/download 只能通过它访问相机。

### 6.6 CameraGalleryCatalogRuntime

继续作为唯一 Catalog owner：

- 创建 generation。
- 执行 initial Catalog transaction。
- 只消费当前 Session 绑定的 immutable plan/strategy snapshot；不直接查询 Registry 或重新按机型判断。
- 校验 count/date group/unique handles。
- 原子安装 snapshot。
- 发布 ready/empty/failed/transportLost。
- 拒绝旧 session/generation/snapshot。

FujifilmProtocolEngine 只提供经过 Session/CommandLane 约束的 Catalog source，不拥有 Catalog。

## 7. 兼容规则不是机型树

终态不存在：

~~~text
RED Common
├── X-T5 Runtime
├── X-M5 Runtime
└── X-E5 Runtime
~~~

正确模型是正交规则：

~~~text
Compatibility Family
+ Advertised Services
+ GATT Characteristics
+ Model Support Metadata
+ Firmware Range
+ Current Session Wire Response
→ CameraConnectionPlan
~~~

### 7.1 CameraCompatibilityFacts

~~~swift
struct CameraCompatibilityFacts {
  let compatibilityFamily: CameraCompatibilityFamily?
  let advertisedServices: Set<String>
  let discoveredCharacteristics: Set<String>

  let modelName: String?
  let firmwareVersion: String?

  let successfulInitStrategy: PtpInitStrategyID?
  let operationTransport: CameraPtpTransport?

  let functionMode: UInt32?
  let cameraFunctionVersion: UInt32?
  let selectedFunctionVersion: UInt32?
}
~~~

要求：

- modelName 只是事实，不是类名。
- compatibilityFamily 允许未知；未知不能默认按 RED 或 Legacy 执行。
- firmwareVersion 允许未知。
- serialNumber 不作为路由条件。
- 当前 wire response 的事实只属于当前 Session。

### 7.2 CameraCompatibilityRule

~~~swift
struct CameraCompatibilityRule {
  let id: CameraCompatibilityRuleID
  let priority: Int

  let compatibilityFamily: CameraCompatibilityFamily?
  let requiredServices: Set<String>
  let requiredCharacteristics: Set<String>
  let modelPredicate: CameraModelPredicate?
  let firmwareRange: CameraFirmwareRange?
  let responsePredicate: CameraResponsePredicate?

  let selection: CameraStrategySelection
}
~~~

modelPredicate 只在有同机型证据时使用；不同机型可以选择同一 Strategy，同一机型不同固件也可以选择不同 Strategy。

### 7.3 CameraCompatibilityRegistry

作用等价于 XApp CameraModel 主数据和部分可见能力表：

- 声明支持的兼容家族。
- 记录机型和固件支持范围。
- 记录 required Service/Characteristic。
- 注册经过验证的 Strategy ID。
- 标明 verified/experimental/unsupported。

它保存规则数据，不保存 socket、Session 或 mutable state。

首个终态版本使用随 App 发布、带 schema/version 的只读 Registry；本方案不引入远程动态下发。远程规则会扩大安全、回滚和兼容责任，当前没有必要性证据，必须单独评审。

### 7.4 CameraConnectionPlanResolver

纯函数：

~~~swift
resolve(
  facts: CameraCompatibilityFacts,
  registry: CameraCompatibilityRegistry
) -> CameraConnectionPlanDecision
~~~

输出：

- plan ID/revision。
- support status。
- selected strategies。
- matched rules。
- rejected rules。
- unresolved facts。
- decision confidence。

优先级：

~~~text
当前会话真实响应
> 当前 GATT 能力
> 已验证固件规则
> 已验证机型规则
> 兼容家族 baseline
> 安全 unsupported
~~~

这套优先级是 CamTransfer 的安全设计，不声称 XApp Native SDK 已被证明完全相同。

“当前会话真实响应”只指固定 checkpoint 产生、经过 parser 校验的 typed evidence，例如合法 INIT ACK 或 Function Version；任意 timeout、reset、0x2013 不能直接改写为另一条生产 Plan。

## 8. CameraConnectionPlan

~~~swift
struct CameraConnectionPlan {
  let id: CameraConnectionPlanID
  let revision: Int
  let supportStatus: CameraSupportStatus

  let pairingStrategy: PairingStrategyID
  let activationStrategy: ActivationStrategyID
  let ptpInitStrategy: PtpInitStrategyID
  let negotiationStrategy: SessionNegotiationStrategyID
  let galleryBootstrapStrategy: GalleryBootstrapStrategyID
  let initialCatalogStrategy: InitialCatalogStrategyID

  let retryPolicy: CameraConnectionRetryPolicy
}
~~~

这些 Strategy 是稳定能力 ID，不要求每个字段立即建立独立 class/file。Wi-Fi handover 当前保持为共享 `IOSCameraWifiAdapter` 行为；在出现已验证 wire/系统行为差异前，不预设 `WifiHandoverStrategy`。

只有满足以下任一条件，才创建新的 Strategy 实现：

1. 已有两个不同 wire 行为。
2. 同机型/同固件 A/B 证明必须不同。
3. XApp 可见 API 明确存在不同能力，并且 CamTransfer 需要调用。
4. 当前实现无法在不污染公共链的情况下表达差异。

禁止为了“终态看起来完整”预先创建空 PairingPolicy、WifiPolicy 或每机型 Strategy 文件。

### 8.1 Plan revision

部分事实只能在连接后获得，因此允许在固定 checkpoint 生成新的 plan revision：

- GATT discovery 完成后。
- PTP INIT ACK 后。
- `inspectGalleryFunction` 获得 Function Mode/Version facts 后。

初始 Plan 只能依据扫描广播、已保存 pairing record 和已验证 Registry baseline 选择安全的 BLE 阶段；在 GATT、INIT 或 Function facts 尚未获得前，不得预选依赖这些事实的实验策略。

硬规则：

- 新 revision 只影响尚未执行的阶段。
- completed barrier 不重放。
- 当前 revision 只属于当前 Session。
- 切换原因和 matched rules 必须记录。
- 不修改 Registry 全局规则。
- 如果新事实证明当前 Session 不兼容，明确终止 Session，不在原 socket 上强行换协议。

## 9. 终态连接状态机

~~~mermaid
stateDiagram-v2
    [*] --> Discovering
    Discovering --> IdentityResolved
    IdentityResolved --> PairedOrReconnected
    PairedOrReconnected --> TransferAuthorized
    TransferAuthorized --> CameraAccessPointReady
    CameraAccessPointReady --> WifiBound
    WifiBound --> PtpTransportConnected
    PtpTransportConnected --> PtpInitAcknowledged
    PtpInitAcknowledged --> PtpSessionOpened
    PtpSessionOpened --> FunctionNegotiated
    FunctionNegotiated --> GallerySessionPrepared
    GallerySessionPrepared --> [*]
~~~

Catalog 不属于连接 Orchestrator 的 completedSteps：

~~~mermaid
stateDiagram-v2
    [*] --> CatalogLoading
    CatalogLoading --> CatalogReady
    CatalogLoading --> CatalogRetryableFailed
    CatalogLoading --> CatalogFatalFailed
    CatalogLoading --> TransportLost
~~~

### 9.1 Barrier evidence

| Barrier | 必须 evidence |
|---|---|
| IdentityResolved | camera identity + endpoint + compatibility-family evidence |
| PairedOrReconnected | 当前 GATT identity 已验证；首次配对创建 record，重连时与已有 record 一致 |
| TransferAuthorized | 官方 Wi-Fi credential 或该 Plan 的等价授权 |
| CameraAccessPointReady | activation ACK + Plan 声明的 AP ready 状态 |
| WifiBound | SSID/IP/route 与当前相机匹配 |
| PtpTransportConnected | 当前相机地址和端口的 TCP connect 成功 |
| PtpInitAcknowledged | 具体 INIT strategy 获得合法 ACK |
| PtpSessionOpened | OpenSession 成功和有效 session ID |
| FunctionNegotiated | required negotiation 成功，或 notRequired(planID) |
| GallerySessionPrepared | required bootstrap 成功，允许 Catalog Runtime 启动 |
| CatalogReady | 当前 generation/snapshot 校验并安装 |

任何 notRequired 都必须包含 Plan 和规则依据，不能伪装为执行成功。空目录属于带空 snapshot 的 CatalogReady，不是连接失败或独立的未就绪状态。

## 10. 当前连接步骤必要性审计

| 当前步骤 | 终态判断 | 依据 | 终态处理 |
|---|---|---|---|
| ReconnectPairedBle | 条件必要 | S-01、S-02；无线重连需要当前身份/GATT | 合并为 reconnectOrPair |
| TransferAuthorization | 当前 RED baseline 必要 | L-XM5、L-XE5 均通过该阶段 | 由 Plan 选择授权策略 |
| ActivateCameraWifi | 无线图库必要 | 当前主链和 XApp BLE/AP 层 | ProtocolEngine 执行 |
| WaitCameraWifiReady | 必要 | AP 未 ready 时不能 handover | 使用 Plan 指定的真实状态 barrier |
| JoinCameraWifi | 必要 | iOS 必须绑定相机 SSID/IP/route | IOSCameraWifiAdapter |
| ConnectPtp | 必须拆分 | X-E5 证明 TCP、INIT、OpenSession 不是同一 barrier | 拆为 TCP/INIT ACK/OpenSession evidence |
| ConfirmGalleryMode | 当前实现不成立 | S-03、A-03 | 替换为 FunctionNegotiated/GallerySessionPrepared |
| LoadGallery | 当前命名不成立 | S-04、A-03 | 从连接状态机删除；Catalog Runtime 启动实际 transaction |
| First Catalog | GalleryReady 必要 | S-08、A-04 | 保留为 Catalog Runtime 成功门槛 |

## 11. PTP INIT、Function 和 Gallery Bootstrap

### 11.1 PTP INIT

PtpInitStrategy 必须声明：

- strategy ID。
- packet builder。
- timeout。
- socket rebuild policy。
- ACK parser/family。
- 是否需要 event channel。

当前正式 baseline 只有：

- vendorLegacyWithClientIPGuid。
- vendorLegacy。

standardPtpIp：

- builder 可以保留。
- 默认不进入任何正式 Plan。
- 只能由 X-E5 实验或后续验证规则启用。

切换 INIT strategy 必须关闭并重建 socket，不能在污染的 socket 上继续。

L-XE5 只证明当前两个策略失败，不证明 standardPtpIp 一定成功。

### 11.2 Function negotiation

X-06、X-07 证明 XApp 存在 SetFunctionMode/GetFunctionVersion/SetFunctionVersion。

因此终态必须能表达 Function negotiation，但不能默认所有相机都执行同一序列。

允许：

- required strategy。
- notRequired(planID)。
- experimental single-variable strategy。

禁止：

- 未验证时把 Function Mode 20 设为所有 RED baseline。
- 失败后由 UI 重跑整条连接链。

### 11.3 Gallery bootstrap

XApp initializeFirst/initialize 证明 Gallery 前存在业务初始化阶段；L-XM5 证明当前差异可能出现在 OpenSession 后、Catalog 前。

终态需要 GalleryBootstrapStrategy，但以下命令仍属于 H：

- D226=0。
- D212 特定顺序。
- 9054。
- 9055。
- 9050。
- D22B。

它们必须通过同一相机、同一固件、同一状态、单变量 A/B 后才能进入 verified Strategy。

不得建立任意命令数组或通用 DSL，让生产 Plan 可以自由堆叠实验命令。

## 12. Catalog、GalleryReady 与页面状态

终态分开三个状态维度：

~~~text
ConnectionState
CatalogState
GalleryPresentationState
~~~

示例：

~~~text
ConnectionState = gallerySessionPrepared
CatalogState = loading
GalleryPresentationState = shellPresented
~~~

这表示页面容器可以存在，但图库尚不可用。

对外语义保持：

~~~text
GalleryReady
= 当前 Session 的首个 Catalog transaction 成功
+ count/date-group/handle 校验通过
+ snapshot 原子安装
+ session/generation/snapshot identity 一致
~~~

空目录也可以 CatalogReady；门槛是成功查询和安装，不是必须有照片。

X-09 支持“页面可显示初始化状态”，但是否在 Catalog 前导航属于产品行为，不是多机型协议兼容的必要条件。

若选择提前显示 Gallery Shell：

- shellPresented 不能命名为 GalleryReady。
- download/thumbnail/preview 不能在 CatalogReady 前消费不存在的 snapshot。
- Catalog failed 可以留页显示，也可以由产品决定退出。
- pending activation 的成功语义仍以 CatalogReady 为准，除非另立产品契约并完成独立评审。

## 13. 错误、重试与恢复

错误必须保留原始层级：

~~~text
Discovery
Pairing/GATT
Activation
Wi-Fi
TCP
PTP INIT
OpenSession
Function Negotiation
Gallery Bootstrap
Catalog
Transport Lost
~~~

### 13.1 Retry owner

| 错误层 | Owner |
|---|---|
| BLE scan/GATT | ProtocolEngine reconnect/pair |
| AP activation | Activation Strategy |
| Wi-Fi association | IOSCameraWifiAdapter |
| TCP connect | FujifilmPtpAdapter / ProtocolEngine |
| INIT timeout/reset | PtpInitStrategy |
| OpenSession | ProtocolEngine session open |
| Function negotiation | Negotiation Strategy |
| Gallery bootstrap | Bootstrap Strategy |
| 9053/D620/D621 | Catalog Runtime |
| transport lost | CameraSessionRuntime |

规则：

1. UI 不直接执行协议重试。
2. Catalog 业务失败不默认回 BLE。
3. INIT 失败不执行 OpenSession 后命令。
4. route retry 不重复已经验证的 BLE/Wi-Fi trunk。
5. 每个重试必须有最大次数、取消和终态。
6. CommRetry 的 5 次/100ms 只能作为 XApp 参考，不直接复制。
7. 0x2013 当前不能默认分类为 transportLost 或无限 retryable。

## 14. 机型和固件隔离

每次连接生成当前 Session 专属的 Plan：

~~~text
Facts
→ Resolver
→ planID/revision
→ Orchestrator
~~~

禁止：

~~~text
globalNeedD226 = true
useStandardInit = true
currentCameraModelGlobal = X-M5
~~~

要求：

- Registry 规则不可由某次 Session 修改。
- Plan revision 只影响当前 Session。
- 实验规则默认关闭。
- 公共 Strategy 只包含跨目标机型已验证行为。
- modelPredicate 不能覆盖缺失 required characteristic。
- firmware 未知时不能猜测高版本能力。

共享基础设施仍可能跨机型影响：

- PTP codec。
- socket lifecycle。
- CameraCommandLane。
- CameraSessionRuntime。
- Catalog generation/snapshot。
- BLE I/O。
- Wi-Fi handover。

因此所有共享基础设施修改必须跑全机型回归；Strategy 规则修改至少跑其匹配范围和公共 baseline 回归。

## 15. 每一个终态改动的必要性

| 改动 | 是否进入终态 | 直接依据 | 如果不做的后果 |
|---|---|---|---|
| FujifilmProtocolEngine | 必须 | X-05/X-06；当前协议行为散落在 BLE/PTP/Loader | 无法形成对应 SDK 的统一能力边界，差异继续污染 Runtime/UI |
| FujifilmCameraSession | 必须 | XApp camera handle；S-08/S-09 单 Session 所有权 | socket、lane、function facts 无统一身份 |
| CameraCompatibilityFacts | 必须 | X-01/X-02；S-06 | Resolver 无法依据真实 Service/Characteristic/响应 |
| CameraCompatibilityRegistry | 必须 | X-03/X-04 | 无法表达固件支持和 verified/unsupported |
| Registry 随 App 版本化只读发布 | 必须作为首个终态实现 | 会话规则必须不可变；当前无远程下发需求或安全依据 | 动态规则会引入未评审的回滚、签名和跨版本风险 |
| CameraConnectionPlanResolver | 必须 | XApp 的事实分阶段出现；X-M5/X-E5 当前 first missing barrier 不同 | 只能按机型名或兼容家族硬编码，无法使用当前 Session 的真实响应 |
| CameraConnectionPlan | 必须 | 需要会话隔离和策略可追踪 | 实验开关会跨相机泄漏 |
| CameraConnectionOrchestrator | 必须，但由现有组件演进 | S-01/S-02/A-02 | 多个 owner、重放已完成 trunk |
| CameraConnectionExecutionState | 必须，替代分散状态 | S-01/S-03/S-04 | completed/evidence/first failure 多事实源 |
| PtpTransportConnected 独立 barrier | 必须 | L-XE5 明确证明 TCP 已连接而 INIT 无 ACK | 仍会把 X-E5 错误归为笼统 ConnectPtp 失败 |
| INIT ACK 与 OpenSession 分离 | 必须 | L-XM5 两者均成功；L-XE5 停在 INIT 前 | 无法判断能否执行 OpenSession 后命令 |
| PtpInitStrategy | 必须 | S-05、L-XE5 | 无法隔离 INIT packet/timing/socket 策略 |
| SessionNegotiationStrategy 槽位 | 必须；暂不要求多个实现 | X-06/X-07 | 无法表达 Function Mode/Version required/notRequired；但当前证据不足以预建机型分支 |
| GalleryBootstrapStrategy 槽位 | 必须；具体命令仍为实验 | X-07；L-XM5 将失败层限定在 OpenSession 后 | OpenSession 后实验只能堆入公共链；但 L-XM5 不证明任何具体前置命令 |
| InitialCatalogStrategy 槽位 | 必须；当前 baseline 保持不变 | L-XM5 首个失败为 9053；S-08 Catalog 为真实 ready gate | 无法隔离首 Catalog 的单变量实验；但 0x2013 本身不证明必须换查询序列 |
| 删除无条件 ConfirmGalleryMode 成功 | 必须 | S-03/A-03 | 连接状态会声明一个从未被相机证明的 barrier |
| LoadGallery 移出连接状态机 | 必须 | S-04/A-03 | 只凭 session ID 就伪装 Catalog 已加载 |
| GalleryReady 继续由 Catalog Runtime 发布 | 必须保留 | S-08/S-09/A-04 | UI、download 和恢复会消费未安装或过期 snapshot |
| Gallery Shell 与 GalleryReady 分离 | 状态模型必须支持；是否提前导航由产品决定 | X-09、S-08 | 页面展示时机与协议成功语义继续互相污染 |
| 新 PairingPolicy class | 暂不要求 | 尚无三台 RED 配对分支差异证据 | 先由 Plan strategy ID + Engine 方法表达 |
| 新 WifiPolicy class | 暂不要求 | 当前三台已通过同一 Wi-Fi handover | 先保留 IOSCameraWifiAdapter |
| 每机型 Runtime/Profile | 禁止 | XApp 可见层是主数据+SDK，不是机型类树 | 重复所有权和公共链 |
| standard INIT 默认启用 | 禁止 | L-XE5 只证明当前 candidate 失败 | 未验证 packet 可能进一步污染 Session |
| Gallery Shell 提前导航 | 独立产品决定 | X-09 只证明初始化 UI | 不应绑架协议兼容架构 |
| 第二套 BarrierLedger | 禁止 | S-01 已有状态机/completedSteps | 双状态源 |
| 长期 V1/V2 双主链 | 禁止 | 单一 owner 终态约束 | 回归面翻倍且行为漂移 |

表中的“Strategy 槽位”是 Plan 中的稳定 ID 和现有 owner 内的受控分派点，不等价于立即新增一个 class/file。没有两个已验证行为时，只有一个 baseline 实现和显式 `notRequired`，不得制造空抽象。

## 16. X-M5 与 X-E5 在终态中的位置

它们不是架构分支，只是不同 facts 和 rules 的验证对象。

### 16.1 X-M5

当前 facts：

~~~text
RED compatibility-family Service/GATT
official activation success
Wi-Fi success
vendor legacy INIT ACK
OpenSession success
first 9053 -> 0x2013
~~~

允许实验范围：

- SessionNegotiationStrategy。
- GalleryBootstrapStrategy。
- InitialCatalogStrategy。

不允许因为 X-M5 改：

- Pairing baseline。
- Wi-Fi baseline。
- X-E5 INIT。
- 全局 RED Strategy。

### 16.2 X-E5

当前 facts：

~~~text
RED compatibility-family Service/GATT
official activation success
Wi-Fi/TCP success
current vendor INIT no ACK/reset
no OpenSession
~~~

允许实验范围：

- PtpInitStrategy。

Activation-to-TCP delay 目前只属于 H；只有同一台 X-E5 的单变量对照证明其影响 INIT ACK 后，才进入 Strategy。

INIT ACK 前不允许加入 D212、D226、905x。

## 17. 尚未解决的协议卡点

终态架构不会伪装解决以下未知：

1. X-M5 的必要 Gallery 前置到底是什么。
2. X-E5 的正确 INIT packet/timing 是什么。
3. 富士 SDK 对不同机型隐藏了哪些等待、重试和错误映射。
4. 当前失败相机准确固件版本。
5. 已有 XApp 抓包是否与失败相机同机型、同固件、同 SD 卡状态。
6. Legacy/X-Half 的完整无线图库链是否与 RED 共用多少实现。

解决方式：

- 同一相机/固件的 XApp 成功对照。
- wire capture。
- 单变量 A/B。
- 反向移除验证。
- 真机重复冷启动和 re-entry。

## 18. 从当前架构迁移到终态

迁移阶段只改变实施顺序，不改变目标架构。

### 阶段 0：冻结现有行为

- 固化 X-T5 当前成功 wire 顺序。
- 固化 X-M5/X-E5 first missing barrier。
- 增加 characterization tests。
- 增加 strategy/plan/barrier 结构化日志。
- 不改变相机命令。

### 阶段 1：建立终态类型和 Facade

- CameraCompatibilityFacts。
- CameraCompatibilityRegistry。
- CameraConnectionPlan/Decision。
- CameraConnectionPlanResolver。
- FujifilmProtocolEngine Facade。
- FujifilmCameraSession。

此阶段 Engine 可以委托当前 CameraVendorBluetoothService/CameraVendorPtpSession，wire 行为不变。

### 阶段 2：收口唯一 Orchestrator

- 让现有 Coordinator/StateMachine 演进为 CameraConnectionOrchestrator/ExecutionState。
- 迁移 completedSteps 和 evidence。
- 不创建平行 V2 coordinator。
- route retry 保留已完成 BLE/Wi-Fi trunk。

### 阶段 3：修正终态语义

- ConnectPtp 拆出 INIT ACK 和 OpenSession evidence。
- 删除虚假的 galleryModeConfirmed。
- LoadGallery 从连接状态机移除。
- 增加 FunctionNegotiated/GallerySessionPrepared。
- CatalogReady 继续由 Catalog Runtime 发布。

### 阶段 4：接入可验证 Strategy

- PtpInitStrategy。
- SessionNegotiationStrategy。
- GalleryBootstrapStrategy。
- InitialCatalogStrategy。

只迁移当前 baseline，不顺手增加 XApp 可选命令。

### 阶段 5：X-M5/X-E5 独立实验

- X-M5 只改 OpenSession 后阶段。
- X-E5 只改 INIT 前后阶段。
- verified 后写入 Registry。

### 阶段 6：删除旧入口

- 删除旧 route policy 和已被 Engine 替代的转发 API。
- 删除迁移开关。
- 确认只有一条生产连接链。

## 19. 诊断

每次连接必须输出：

~~~text
CAMERA_PLAN_RESOLUTION
connectionSessionID=...
planID=...
revision=...
supportStatus=verified/experimental/unsupported
compatibilityFamily=...
model=...
firmware=...
matchedRules=...
unresolvedFacts=...
~~~

每个步骤：

~~~text
CONNECTION_BARRIER_BEGIN
→ CONNECTION_BARRIER_SUCCEEDED
  / CONNECTION_BARRIER_NOT_REQUIRED
  / CONNECTION_BARRIER_FAILED
  / CONNECTION_BARRIER_CANCELLED
~~~

终态失败：

~~~text
CONNECTION_TERMINAL
firstMissingBarrier=...
planID=...
strategyID=...
lastWireOutcome=...
retryOwner=...
~~~

日志必须能回答：

- 识别了什么兼容家族。
- 使用了哪些真实 capability。
- 选择了哪个 Plan/Strategy。
- 哪个 barrier 首先失败。
- 是否发生 plan revision。
- 是否保留了已经完成的 trunk。

## 20. 自动化测试

### 20.1 Resolver/Registry

1. RED/non-RED/X-Half Service 识别。
2. required characteristic 缺失时规则不能匹配。
3. 未知 firmware 不得选择仅高版本支持的 Strategy。
4. modelPredicate 不能覆盖 capability conflict。
5. 不同机型可选择同一 Strategy。
6. 同一机型不同 firmware 可选择不同 Strategy。
7. plan revision 只改变剩余阶段。
8. Registry 不被 Session 修改。

### 20.2 Orchestrator

1. Barrier 顺序合法。
2. TCP connected、INIT ACK、OpenSession 分别记录，不能合并成功或失败。
3. completed trunk 不重放。
4. route retry 只重建 PTP route。
5. cancellation exactly-once。
6. firstMissingBarrier 正确。
7. notRequired 必须带 Plan evidence。
8. 旧 plan revision 回调不能推进当前状态。

### 20.3 ProtocolEngine

1. INIT strategy 切换重建 socket。
2. TCP connect 成功不能伪装 INIT ACK 成功。
3. standard INIT 默认不进入 verified Plan。
4. OpenSession 和 INIT ACK 分开。
5. Function facts inspection 只更新当前 Session，plan revision 后才应用 negotiation。
6. Function negotiation required/notRequired。
7. experimental bootstrap 不能进入 production Plan。
8. 所有 OpenSession 后命令通过同一 CommandLane。
9. terminate exactly-once。

### 20.4 Catalog/Runtime

1. GallerySessionPrepared 不等于 GalleryReady。
2. Catalog ready 才完成 pending activation。
3. 空目录成功可 ready。
4. 0x2013 不自动变 transportLost。
5. Catalog failure 不回 BLE。
6. transportLost 交回 Runtime。
7. 旧 session/generation/snapshot 不能安装。
8. download 只消费 ready snapshot。

## 21. 真机验收矩阵

| 场景 | X-T5 | X-M5 | X-E5 | X-S20 | GFX100RF |
|---|---:|---:|---:|---:|---:|
| 首次配对 | 必测 | 必测 | 必测 | 回归 | 回归 |
| 记忆重连 | 必测 | 必测 | 必测 | 回归 | 回归 |
| Wi-Fi handover | 必测 | 必测 | 必测 | 回归 | 回归 |
| INIT ACK | 必测 | 回归 | 实验 | 回归 | 回归 |
| OpenSession | 必测 | 回归 | INIT 后 | 回归 | 回归 |
| Function/Bootstrap | 必测 | 实验 | 后续 | 回归 | 回归 |
| First Catalog | 必测 | 实验 | 后续 | 回归 | 回归 |
| GalleryReady | 必测 | Catalog 后 | 后续 | 回归 | 回归 |
| 退出重进 | 必测 | 必测 | 后续 | 回归 | 回归 |
| App kill 重连 | 必测 | 必测 | 后续 | 回归 | 回归 |

每个正式支持结论至少要求：

- 同一相机连续冷启动。
- 退出重进。
- App kill 后重连。
- AP 关闭后恢复。
- 日志能还原 Plan、Strategy 和 first missing barrier。
- 反向移除关键 Strategy 后能复现失败或明显退化。

## 22. 实施职责边界

最终职责建议：

~~~text
CameraCore/Connection
  CameraConnectionOrchestrator
  CameraConnectionExecutionState
  CameraConnectionBarrier

CameraCompatibility
  CameraCompatibilityFacts
  CameraCompatibilityRegistry
  CameraConnectionPlan
  CameraConnectionPlanResolver

CameraAdapters/Fujifilm
  FujifilmProtocolEngine
  FujifilmCameraSession
  FujifilmBluetoothAdapter
  FujifilmPtpAdapter

CameraCore/Gallery
  CameraGalleryCatalogRuntime
  CameraGalleryRepository
  CameraCatalogQueryEngine

Runtime
  CameraSessionRuntime
  CameraCommandLane
  Download Owner
~~~

这只是职责边界，不要求一类型一文件。实施计划必须根据源码大小和依赖进一步收敛文件数量。

明确禁止：

- 每个机型一个 Runtime。
- 每个机型一个 Coordinator。
- 每个机型复制一套 PTP Session。
- CameraCore 直接依赖 Fujifilm opcode/UUID。
- UI 直接发送 BLE/PTP 命令。
- ProtocolEngine 安装 Catalog snapshot。
- Catalog Runtime 管理 BLE/Wi-Fi。
- 长期保留两套生产主链。

## 23. 终态验收标准

架构层：

1. 只有一个 CameraSessionRuntime。
2. 只有一个 CameraConnectionOrchestrator。
3. 只有一个 CameraConnectionExecutionState。
4. 只有一条 CameraCommandLane。
5. 只有一个 Catalog owner 和一个 download owner。
6. Fujifilm 协议细节全部位于 Adapter/ProtocolEngine。
7. CameraCore 不根据机型名发送 vendor 指令。
8. Resolver 是纯函数，Registry 是不可变规则数据。
9. Plan 是当前 Session 的版本化快照。
10. 不存在机型类树。

语义层：

1. INIT ACK、OpenSession、FunctionNegotiated、GallerySessionPrepared、CatalogReady 分开。
2. ConfirmGalleryMode 不再无条件成功。
3. LoadGallery 不再伪装已加载 Catalog。
4. GalleryReady 必须绑定当前 Catalog snapshot。
5. Catalog failure 与 transportLost 分开。
6. 页面 Shell 与 GalleryReady 分开。

兼容层：

1. 兼容家族、Service、Characteristic、固件和 wire response 都能进入事实模型。
2. 不同机型可以共用 Strategy。
3. 同一机型不同固件可以选择不同 Strategy。
4. 某个 Session 的实验不会修改全局 baseline。
5. 未验证机型明确 experimental/unsupported。

交付层：

1. 全部新增规则有自动化测试。
2. X-T5 baseline wire 行为没有意外变化。
3. X-M5/X-E5 实验相互隔离。
4. 真机矩阵逐台通过后才宣布正式支持。

## 24. 最终架构表达

~~~text
XApp 可见架构：
BLE Service/Characteristic
→ CameraInfo Model/Firmware
→ CameraConnectModel
→ CameraConnectWrapper/ControlFFIR SDK
→ ImportImageModel

CamTransfer 终态：
CameraCompatibilityFacts/Registry
→ CameraConnectionPlanResolver
→ CameraConnectionOrchestrator
→ FujifilmProtocolEngine
→ FujifilmCameraSession/CommandLane
→ CameraGalleryCatalogRuntime
→ CameraSessionRuntime/Presentation
~~~

二者的关系是：

~~~text
兼容决策和能力分层对齐 XApp
协议引擎显式替代 XApp 私有 SDK
会话、Catalog、下载和生命周期保留 CamTransfer 终态所有权
~~~

这套架构不依赖先知道每一台相机的全部命令；它保证未知协议事实只能进入当前 Session 的受控 Strategy 实验，不能污染其他机型和公共主链。

架构完成不代表全部机型兼容完成。正式兼容仍必须由同机型、同固件、同状态的真实协议证据和真机矩阵证明。
