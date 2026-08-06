# iOS 对齐 XApp 的多机型兼容架构技术方案

日期：2026-08-06

修订日期：2026-08-07

状态：评审修订版，待最终确认

范围：iOS 无线相机身份识别、BLE 激活、Wi-Fi handover、PTP INIT/OpenSession、相册会话协商与首次 Catalog

不包含：USB、遥控拍摄、固件升级、云端业务、完整复制 XApp、Gallery 页面视觉重构

## 0. 结论

CamTransfer 需要补齐多机型兼容能力，但不需要推倒当前连接与媒体架构，也不需要完整复刻 XApp。

推荐架构是：

~~~text
保留一条现有连接主链
→ 在当前 IOSCameraConnectionContext 中逐步收集身份和能力事实
→ CameraCompatibilityResolver 只生成一份 CameraConnectionPolicy
→ 现有 Coordinator 和 StateMachine 执行主链
→ Policy 只控制已经证实可能不同的四个策略点
→ CameraSessionRuntime 和 Catalog Runtime 继续负责图库最终可用性
~~~

第一阶段只允许将以下四个真实差异点策略化：

1. activation readiness policy
2. PTP INIT candidates
3. post-Open negotiation
4. initial Catalog strategy

第一阶段明确不做：

- 不新增第二套 CameraConnectionOrchestrator。
- 不新增独立 ConnectionBarrierLedger。
- 不建立 PairingProfile、WifiHandoverProfile 等七层子 Profile。
- 不把 Gallery Shell 提前展示作为兼容架构的前置任务。
- 不把 Unknown RED 宣称为正式支持。
- 不默认启用 standard PTP/IP INIT。
- 不把 XApp 参考命令一次性全部加入 X-M5。

这次架构升级解决的是“差异可以被识别、选择、记录、隔离和验证”，不直接等价于已经修复 X-M5、X-E5 或全部 RED 相机。

## 1. 决策依据与证据等级

所有兼容决策必须标明证据等级。

### 1.1 已由当前 iOS 源码确认

1. 当前已经有 IOSCameraGalleryConnectionCoordinator、IOSCameraConnectionStateMachine 和 IOSCameraConnectionContext。
2. StateMachine 已维护步骤推进和 hasGalleryReadyEvidence。
3. CameraSessionRuntime、Catalog owner、download owner、generation fence 和 CommandLane 已形成单一所有权。
4. 当前主链固定执行：

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

5. ConfirmGalleryMode 当前没有执行实际协议操作，只返回 galleryModeConfirmed。
6. LoadGallery 当前只验证 PTP session ID，就返回 galleryLoaded。
7. 当前 PTP INIT 只尝试两个 vendor legacy 变体。
8. standard INIT builder 虽然存在，但没有进入实际 INIT candidate 链。
9. 当前 BLE activation 虽声明三种 strategy，自动选择实际只有 officialImportImage。
10. FujifilmXSeriesProfile 当前只有 xt5Current，主要控制启动延迟和下载参数，不是连接兼容策略。
11. CameraSessionRuntime 只有在 Catalog ready 并安装当前 generation/snapshot 后才发布 GalleryReady。

### 1.2 已由 XApp 静态反编译确认

1. XApp 定义并使用多组 BLE Service：
   - Legacy camera information
   - RED camera information
   - RED connected device information
   - X-Half file transfer
   - X-Half RED file transfer
   - RED startup information
2. XApp 分别维护 RED 与 non-RED Service/Characteristic Map。
3. XApp CameraModel 包含机型、XAppSupportVersion、XAppNotSupportVersion、SDCardHotSwapVersion 和 RemoteBoot 等字段。
4. CameraInfoModel.checkVersion() 会按机型和固件做支持判断，未知机型不会直接通过。
5. CameraConnectModel.cameraOpen() 通过 SDK 以 ConnectType.KWlan 打开相机会话。
6. ControlFFIR 提供 SetFunctionMode、GetFunctionVersion、SetFunctionVersion。
7. ImportImageModel.setImageViewFunctionMode() 执行 Function Mode/Version 和 Dual Slot Status 相关操作。
8. ImportImageModel 具有 initializeFirst() 与 initialize() 两段初始化流程。
9. CommRetry 默认 maxAttempts=5、delay=100ms，并有不可持续错误分类。
10. ImportImage 页面具有初始化 UI，可以在目录完成前显示初始化状态。

CommRetry.doWithRetry() 的反编译结果不完整，因此本方案不根据静态代码推断每一种错误码的精确重试次数和终止行为。

### 1.3 已由当前实机日志确认

#### X-M5

- BLE 身份和激活成功。
- Wi-Fi handover 成功。
- PTP INIT ACK 成功。
- OpenSession 成功。
- Gallery handshake 成功。
- 首个明确失败点为第一次 9053 返回 0x2013。

因此当前不能把 X-M5 归因于 BLE、Wi-Fi 或 PTP transport。

#### X-E5

- BLE 身份和激活成功。
- AP launched。
- Wi-Fi 和 IPv4 成功。
- TCP 192.168.0.1:55740 可以连接。
- 两个当前 vendor legacy INIT 变体均没有稳定获得 ACK。
- 没有 OpenSession，也没有 Catalog。

因此当前不能用 D212、D226 或 905x 解释 X-E5。

### 1.4 尚未确认

1. X-M5 的根因是否为 D226=0。
2. X-M5 是否需要不同的 D212 顺序。
3. 9054、9055、9050、D22B 中哪些是 X-M5 的必要前置。
4. X-E5 是否需要 standard PTP/IP INIT。
5. X-E5 是否需要不同 GUID、client name、client IP 编码或 INIT 时机。
6. APState 和 TransferState 是否共同构成 X-E5 的硬 barrier。
7. 最新 X-M5、X-E5 日志对应的准确固件版本。
8. 已有 XApp 成功抓包是否与当前失败相机为同机型、同固件、同 SD 卡状态。

以上内容只能作为实验候选，不能进入正式 Policy。

## 2. XApp 对我们的真实启示

XApp 值得复制的是兼容方法，而不是类结构和全部命令。

### 2.1 可以复制

1. 身份逐步建立。
   - 扫描阶段获得协议族候选。
   - GATT 阶段获得真实 characteristic。
   - OpenSession 后获得业务协议响应。
2. 连接流程保持统一，差异集中在局部策略。
3. 机型、固件、BLE 能力和实际 wire 响应共同参与支持判断。
4. Function Mode/Version 属于相册会话初始化的一部分。
5. ImportImage 自己拥有初始化和错误处理，不由 UI 重跑整条连接链。
6. 未知机型不能因为属于 RED 就自动视为完整支持。

### 2.2 不能声称已经复制或证明

以下内容不是当前反编译已经证明的 XApp 原始架构：

- XApp 使用七个独立 Profile。
- XApp 存在一个与本方案同名的动态 Resolver。
- XApp 在每个阶段都会重新计算整条连接链。
- XApp 在 Catalog ready 前完成对外 Gallery activation。
- X-E5 使用 standard PTP/IP INIT。
- 当前参考抓包的全部 Gallery 命令都是 X-M5 的必要前置。

“真实 capability 和 wire 响应优先于机型名”是 CamTransfer 应采用的安全设计原则，不应写成 XApp 已被完整证明的内部实现。

## 3. 当前架构保留边界

以下组件必须保留单一所有权：

- CameraSessionRuntime：App 级相机会话、恢复和最终 presentation owner。
- IOSCameraGalleryConnectionCoordinator：连接步骤编排。
- IOSCameraConnectionStateMachine：连接步骤合法推进。
- IOSCameraConnectionContext：本次连接的事实容器。
- CameraCommandLane：所有 PTP 指令串行化。
- CameraGalleryCatalogRuntime：Catalog generation、transaction、验证和发布。
- Catalog owner / download owner：目录和下载互斥边界。
- generation fence / snapshot identity：拒绝旧会话和旧 Catalog 回调。

兼容架构只能向这些组件提供不可变策略或增加事实字段，不能再创建平行 Runtime、Coordinator、StateMachine、Catalog owner 或 CommandLane。

## 4. 方案选择

### 方案 A：继续在大 Service/Session 中增加机型判断

优点：

- 单次实验改动最少。

缺点：

- 机型、固件、characteristic 和响应条件继续混在一起。
- 无法可靠记录选择原因。
- 每台相机都会扩大主链复杂度。

结论：只允许用于受控实验，不作为正式架构。

### 方案 B：现有主链 + 最小兼容 Policy

优点：

- 保留当前所有权和状态机。
- 第一阶段可以做到 wire 行为不变。
- X-M5 与 X-E5 可以在不同失败层独立实验。
- 改动量和回归面可控。
- 不预先抽象尚未出现的差异。

结论：推荐。

### 方案 C：协议插件 + 七层子 Profile + 新 Orchestrator

优点：

- 理论隔离最彻底。

缺点：

- 与现有 Coordinator/StateMachine 重复。
- 当前没有足够证据定义七类差异。
- 容易形成双事实源和大量空壳类型。
- RED 内部仍需局部策略，完整管线会重复公共逻辑。

结论：当前属于过度设计，不实施。

## 5. 推荐目标架构

~~~mermaid
flowchart TD
    Discovery["Discovery / Advertisement Facts"] --> Context["现有 IOSCameraConnectionContext"]
    GATT["GATT Characteristics"] --> Context
    Identity["现有 IOSCameraIdentity / Pairing Record"] --> Context

    Context --> Resolver["CameraCompatibilityResolver"]
    Resolver --> Policy["CameraConnectionPolicy"]
    Resolver --> Trace["CameraCompatibilityDecision"]

    Policy --> Coordinator["现有 IOSCameraGalleryConnectionCoordinator"]
    Coordinator --> StateMachine["现有 IOSCameraConnectionStateMachine"]

    Policy --> Activation["Activation Readiness"]
    Policy --> Init["PTP INIT Candidates"]
    Policy --> Negotiation["Post-Open Negotiation"]
    Policy --> CatalogStrategy["Initial Catalog Strategy"]

    StateMachine --> Prepared["Gallery Session Prepared"]
    Prepared --> Runtime["现有 CameraSessionRuntime"]
    Runtime --> Catalog["现有 CameraGalleryCatalogRuntime"]
    Catalog --> Ready["Validated Catalog Ready"]
    Ready --> GalleryReady["GalleryReady"]
~~~

核心原则：

1. 只有一条连接执行主链。
2. Resolver 只生成策略，不执行 BLE、socket、PTP 或 UI。
3. Policy 不持有 mutable session state。
4. Context 保存事实，StateMachine 保存推进规则。
5. Policy 重新求值不允许重放已经完成的物理步骤。
6. 新机型只新增被证实存在差异的规则，不复制 Runtime。
7. Catalog ready 继续是 GalleryReady 的最终可用性证明。

## 6. 最小领域模型

### 6.1 CameraProtocolFamily

~~~swift
enum CameraProtocolFamily: String, Codable {
  case legacy
  case red
  case xHalf
  case unknown
}
~~~

它只表达 BLE/注册协议世代，不能单独决定 PTP 和 Gallery 全链。

### 6.2 CameraCompatibilityFacts

第一阶段优先扩展现有 IOSCameraConnectionContext，或由一个轻量 facts 值对象包装，不创建第二套可持久化 Identity。

~~~swift
struct CameraCompatibilityFacts: Equatable {
  let protocolFamily: CameraProtocolFamily
  let advertisedServiceUUIDs: Set<String>
  let discoveredCharacteristicUUIDs: Set<String>
  let modelName: String?
  let firmwareVersion: String?
  let successfulPtpInitCandidateID: PtpInitCandidateID?
  let operationTransport: CameraVendorPtpOperationTransport?
  let functionMode: UInt32?
  let cameraFunctionVersion: UInt32?
  let selectedFunctionVersion: UInt32?
}
~~~

要求：

- firmwareVersion 必须允许为空。
- 未拿到 firmware 不能阻止当前已验证 baseline 连接。
- 序列号不进入 Policy 匹配规则。
- 日志只记录 serial hash 或尾部短标识。

### 6.3 CameraConnectionPolicy

~~~swift
struct CameraConnectionPolicy {
  let id: CameraConnectionPolicyID
  let revision: Int
  let activationReadiness: ActivationReadinessPolicy
  let ptpInitCandidates: [PtpInitCandidate]
  let postOpenNegotiation: PostOpenNegotiationPolicy
  let initialCatalog: InitialCatalogStrategy
}
~~~

Policy 是四个策略的组合，不拆出 PairingProfile 和 WifiHandoverProfile。

### 6.4 CameraCompatibilityDecision

~~~swift
struct CameraCompatibilityDecision {
  let policyID: CameraConnectionPolicyID
  let revision: Int
  let confidence: CameraPolicyConfidence
  let matchedRules: [CameraPolicyRuleID]
  let rejectedRules: [CameraPolicyRejection]
  let unresolvedFacts: Set<CameraCompatibilityFact>
}
~~~

任何连接都必须能从日志回答：

- 当前识别为什么协议族。
- 使用什么 Policy 和 revision。
- 依据哪些 characteristic、机型或响应。
- 还有哪些事实未知。
- 哪个 barrier 首先失败。

## 7. 四个策略点

### 7.1 ActivationReadinessPolicy

控制：

- 使用哪个已验证 BLE activation strategy。
- 必须订阅哪些 characteristic。
- APState 什么值允许进入 Wi-Fi handover。
- TransferState 是硬门槛、软证据还是当前不参与判断。
- handover 前后是否保持 BLE。

第一阶段：

- X-T5、X-M5、X-E5 继续使用当前 officialImportImage 主链。
- 不建立独立 PairingProfile。
- 不加入 RemoteBoot、ReservedReceive、USB 等当前范围外能力。
- X-E5 的 TransferState 只记录，不提升为硬门槛，直到同机对照验证。

### 7.2 PtpInitCandidate

~~~swift
struct PtpInitCandidate {
  let id: PtpInitCandidateID
  let packet: Data
  let ackTimeout: TimeInterval
  let socketPolicy: PtpInitSocketPolicy
  let expectedAckFamily: PtpInitAckFamily
}
~~~

第一阶段正式 candidate 仅保留当前两项：

- vendorLegacyWithClientIPGuid
- vendorLegacy

standardPtpIp：

- builder 可以保留。
- 默认 Policy 不启用。
- 只能通过 X-E5 实验开关或验证后的正式 Policy 启用。

切换 candidate 时必须：

1. 终止前一 socket。
2. 创建新 socket。
3. 重新发送 INIT。
4. 记录 candidate ID、packet length、timeout 和 ACK 结果。

operationTransport 必须由成功 ACK 和后续协议响应共同确认，不能所有成功都硬编码为 cameraVendorLegacy。

### 7.3 PostOpenNegotiationPolicy

控制 OpenSession 后、首次 Catalog 前的必要会话协商：

- ClientState。
- Function Mode。
- Function Version。
- App/Camera version selection。
- Card slot status。

第一阶段只需要两种策略：

1. currentBaseline：保持当前 X-T5 wire 行为。
2. experimental：只允许一个明确的 wire-visible 变量。

不得建立一个可以任意堆叠 D212、D226、9054、9055、9050、D22B 的通用命令 DSL。

实验步骤经同机型重复验证后，才能成为新的稳定策略。

### 7.4 InitialCatalogStrategy

控制：

- 首次 9053 请求参数。
- D620/D621 的读取顺序。
- 空目录语义。
- count/date group/unique handle 校验。
- 0x2013 的分类。
- Catalog 业务失败是否可以在当前 session 内重试。

当前 baseline：

~~~text
prepare inside exclusive CommandLane mutation
→ one unfiltered 9053
→ D620
→ D621
→ validate snapshot
→ atomically install current generation
~~~

InitialCatalogStrategy 只改变 Catalog 查询策略，不拥有 BLE/Wi-Fi/PTP 重连。

只有 transportLost 才交回 CameraSessionRuntime 做连接恢复。

0x2013 当前默认分类为：

~~~text
camera state / catalog protocol precondition not satisfied
~~~

在没有同机型证据前，不能默认无限重试，也不能直接升级为 transportLost。

## 8. 连接步骤必要性审计

| 步骤 | 第一阶段是否保留 | 必要性依据 | 调整 |
|---|---|---|---|
| ReconnectPairedBle | 保留，条件执行 | 需要重新确认已配对相机身份和当前 GATT | 无活动 PTP session 时执行 |
| TransferAuthorization | 保留 | 当前 RED 成功主链依赖官方 Wi-Fi 凭据与授权 | 继续使用当前实现 |
| ActivateCameraWifi | 保留 | 相机必须启动 AP/图片导入模式 | 由 ActivationReadinessPolicy 提供参数 |
| WaitCameraWifiReady | 保留 | 不能在 AP 未就绪时直接 handover | 以可观察状态为主 |
| JoinCameraWifi | 保留 | iOS 必须绑定相机 Wi-Fi 与 IPv4 路由 | 第一阶段保持共用实现 |
| ConnectPtp | 保留 | 必须完成 TCP、INIT ACK 和 OpenSession | INIT candidate 由 Policy 提供 |
| ConfirmGalleryMode | 不按现状保留 | 当前实现没有消费真实协议 evidence | 替换为 PostOpenNegotiation |
| LoadGallery | 不按现状保留 | 当前实现只检查 PTP session ID，并没有加载 Catalog | Coordinator 输出 GallerySessionPrepared，Catalog 由 Runtime 启动 |
| First Catalog | 必须 | 这是首个图库真实可用性证明 | 继续由 Catalog Runtime 验证和安装 |

修订后的语义：

~~~text
Connection Coordinator 成功
= PTP session 已建立
+ 当前 Policy 声明的必要 post-Open negotiation 已完成

GalleryReady
= 当前 session/generation 的首个 Catalog 已验证并原子安装
~~~

如果某 Policy 不要求额外 negotiation，StateMachine 必须记录 notRequired(policyID) evidence，而不是生成没有协议依据的 galleryModeConfirmed。

## 9. StateMachine 与 barrier

不新增 ConnectionBarrierLedger。

在现有 IOSCameraConnectionContext、IOSCameraConnectionStateMachine 和 completedSteps 基础上增加：

- policyID / revision
- 当前 compatibility facts
- 每一步的 evidence source
- successful INIT candidate
- firstMissingBarrier 计算

建议 barrier：

~~~text
identityResolved
→ transferAuthorized
→ cameraAccessPointReady
→ wifiBound
→ ptpInitAcknowledged
→ ptpSessionOpened
→ postOpenNegotiated
→ gallerySessionPrepared
→ catalogReady
~~~

其中：

- Coordinator 管理到 gallerySessionPrepared。
- CameraSessionRuntime/Catalog Runtime 管理 catalogReady。
- gallerySessionPrepared 不能命名为 GalleryReady。

页面生命周期重入不能依靠新 Ledger 跳过步骤，而应由当前 session binding、completedSteps、generation fence 和 Runtime owner 共同决定是否仍属于同一有效会话。

## 10. GalleryReady 与页面展示

当前对外成功语义保持：

~~~text
GalleryReady = 首个已验证 Catalog snapshot 成功安装
~~~

Catalog 结果为空也可以 ready；门槛是查询成功、校验成功并安装当前 snapshot，而不是必须存在照片。

本兼容方案不修改以下行为：

- Catalog ready 前 pending activation 不报告成功。
- Catalog failed/unsupported/transportLost 会结束本次 pending activation。
- Catalog identity 绑定 session epoch、generation 和 snapshot ID。
- 旧 generation 回调不能污染新会话。
- presentation 与 Catalog 原子发布后才完成导航回调。

XApp 的初始化 UI 证明“页面可以显示初始化状态”，但不能单独证明 CamTransfer 应修改 activation contract。

如果产品决定 Catalog 前展示 Gallery Shell，需要单独技术方案覆盖：

- 导航 exactly-once。
- loading/empty/retryable/fatal 状态。
- 页面退出和 re-entry。
- Catalog 失败是否留页。
- download/recovery admission。
- 与当前 pending activation contract 的兼容。

该 UI 方案不阻塞多机型兼容架构实施。

## 11. 初始 Policy

### 11.1 xt5-current-baseline

用途：迁移当前已验证成功链。

要求：

- wire 顺序保持不变。
- 当前两个 vendor INIT candidate 顺序保持不变。
- 不增加 XApp 可选命令。
- 不改变 Catalog ready 成功门槛。
- 记录完整 Policy decision 与 barrier。

只有 X-T5 迁移前后同机回归通过，才能把 Policy 机制视为没有破坏当前主链。

### 11.2 xm5-red-experimental

不是正式支持 Policy，只允许实验环境使用。

已确认：

- official RED BLE 激活成功。
- Wi-Fi handover 成功。
- vendor legacy + client IP GUID INIT 成功。
- OpenSession 成功。
- 首次 9053 返回 0x2013。

允许实验区域：

- postOpenNegotiation
- InitialCatalogStrategy

不允许修改：

- Pairing
- Wi-Fi handover
- PTP INIT transport
- Runtime/Catalog owner

每次实验只能改变一个 wire-visible 变量。

### 11.3 xe5-red-experimental

不是正式支持 Policy，只允许实验环境使用。

已确认：

- official RED BLE 激活成功。
- AP launched。
- Wi-Fi、IPv4 和 TCP 55740 成功。
- 当前两个 vendor INIT 均没有稳定 ACK。

允许实验区域：

- activation readiness/timing
- PTP INIT candidate

在取得 INIT ACK 前，不允许加入 D212、D226 或 905x。

### 11.4 unknown-red-diagnostic

Unknown RED 不作为正式兼容承诺。

规则：

- 只有 required characteristic 完整时，才允许执行当前 baseline activation。
- 默认只运行当前已验证 legacy candidate set。
- 不自动加入 standard INIT。
- 不自动执行 X-M5 experimental negotiation/bootstrap。
- 失败必须输出 firstMissingBarrier。
- UI 和日志明确标记 unsupported/best-effort，而不是 supported。

## 12. 错误、重试与恢复

第一阶段不新增一套完整 CameraCompatibilityError 枚举。

优先扩展现有：

- IOSCameraConnectionIssue
- IOSCameraConnectionRetryTarget
- Catalog failure/state
- transportLost

每个错误至少携带：

- connectionSessionID
- policyID / revision
- barrier
- strategy/candidate ID
- attempt
- elapsedMs
- last wire outcome
- retry owner

重试 owner：

| 错误层 | Owner |
|---|---|
| BLE reconnect/GATT | 现有 reconnect/pairing coordinator |
| AP activation | ActivationReadinessPolicy 执行器 |
| Wi-Fi association | 现有 Wi-Fi handover |
| INIT timeout/reset | PTP INIT policy |
| Function negotiation | PostOpenNegotiation 执行器 |
| 9053/D620/D621 | Catalog Runtime + InitialCatalogStrategy |
| transport lost | CameraSessionRuntime recovery |

规则：

1. UI 不直接重跑底层协议指令。
2. candidate 切换必须新建 socket。
3. Catalog 业务失败不能默认回到 BLE 全链。
4. transportLost 才能触发物理连接恢复。
5. 每个重试必须有次数上限、取消语义和终态。
6. XApp CommRetry 的默认值只能作为参考，不能未经验证直接复制到所有 CamTransfer 步骤。

## 13. 诊断设计

诊断必须在 Policy 架构之前或同步完成，不能推迟到最后。

### 13.1 Policy decision

~~~text
CAMERA_COMPATIBILITY_DECISION
session=...
policy=xt5-current-baseline
revision=1
confidence=verified
protocolFamily=red
matched=red-service,official-import-characteristics,model-x-t5
unresolved=firmware,function-version
~~~

### 13.2 Protocol step

~~~text
PROTOCOL_STEP_BEGIN
→ PROTOCOL_STEP_SUCCEEDED
  / PROTOCOL_STEP_FAILED
  / PROTOCOL_STEP_CANCELLED
  / PROTOCOL_STEP_NOT_REQUIRED
~~~

### 13.3 Terminal summary

~~~text
CONNECTION_TERMINAL
policy=xe5-red-experimental
revision=1
firstMissingBarrier=ptpInitAcknowledged
candidate=vendorLegacy
transport=tcp-connected
lastWireOutcome=connection-reset-by-peer
retryOwner=ptp-init
~~~

任何一次失败日志必须能直接区分：

- BLE/GATT 没成功。
- Wi-Fi 没成功。
- TCP 可达但 INIT 没 ACK。
- OpenSession 成功但 negotiation 失败。
- session 已准备但 Catalog 失败。
- transport 已丢失。

## 14. 分阶段迁移

### 阶段 0：冻结事实和增加诊断

必须完成：

1. 保存 X-T5 当前成功 wire 顺序。
2. 固化 X-M5、X-E5 的首个失败 barrier。
3. 为当前步骤顺序、INIT candidate 顺序和 Catalog success gate 增加 characterization tests。
4. 增加 Policy/candidate/barrier 结构化日志字段。
5. 不改变相机命令。

### 阶段 1：最小 Facts、Policy 与 Resolver

新增或扩展：

- CameraProtocolFamily
- CameraCompatibilityFacts
- CameraConnectionPolicy
- CameraCompatibilityDecision
- CameraCompatibilityResolver

第一版只稳定输出 xt5-current-baseline。

unknown-red-diagnostic 只用于诊断，不作为成功支持。

### 阶段 2：接入现有 Coordinator/StateMachine

要求：

- 不创建新 Orchestrator。
- 不创建新 BarrierLedger。
- Coordinator 接收不可变 Policy。
- Context 记录 Policy 和运行事实。
- StateMachine 校验 required/notRequired evidence。
- ConfirmGalleryMode 和 LoadGallery 的假 evidence 被移除或改成真实语义。
- X-T5 wire 行为保持不变。

### 阶段 3：PTP INIT candidate 机制

要求：

- 当前 baseline candidate 不变。
- 每个 candidate 有 ID 和独立日志。
- candidate 切换重建 socket。
- standard candidate 默认关闭。
- 成功 ACK 不再无条件标记为 legacy。

### 阶段 4：X-M5 和 X-E5 单变量实验

两条实验线相互独立：

- X-M5 只调查 post-Open/Catalog 前状态。
- X-E5 只调查 activation timing/PTP INIT。

实验结果不能直接覆盖 xt5-current-baseline。

### 阶段 5：形成正式机型 Policy

只有满足以下条件才建立正式 Policy：

1. 同一机型重复成功。
2. 反向移除变量后能复现失败或明显退化。
3. 退出重进和 App kill 重连通过。
4. 不影响 X-T5。
5. 日志能还原 Policy、candidate 和第一失败点。

Gallery Shell 提前展示不属于上述迁移阶段。

## 15. 发布与回滚

不长期维护 compatibilityArchitectureV2 与旧主链两套实现。

推荐方式：

- 一条 Coordinator/StateMachine 主链。
- xt5-current-baseline 保持旧 wire 行为。
- 每个实验策略使用独立、默认关闭的实验开关。
- 正式 Policy 通过 policyID + revision 控制。
- 回滚某机型 Policy revision，不回滚整个 Runtime/Catalog 架构。

如果迁移期需要总开关，只用于短期回滚 Resolver 选择，不允许复制一份旧 Coordinator 和旧 PTP Session。

## 16. 测试方案

### 16.1 自动化测试

必须覆盖：

1. RED/Legacy/X-Half/Unknown 识别。
2. characteristic 缺失时不能执行依赖该能力的 activation。
3. firmware 缺失不阻塞 xt5-current-baseline。
4. Resolver 输出稳定 policyID/revision/matchedRules。
5. xt5-current-baseline 的步骤和 INIT candidate 顺序不变。
6. required/notRequired evidence 推进正确。
7. firstMissingBarrier 计算正确。
8. Policy 重新求值不重复已经完成的物理步骤。
9. candidate 切换会关闭并重建 socket。
10. standard INIT 默认不进入 baseline。
11. Catalog 0x2013 不会被自动分类为 transportLost。
12. Catalog failure 不回退到 BLE 全链。
13. Catalog ready 仍是 pending activation 成功门槛。
14. 旧 generation/snapshot 回调不能污染新会话。
15. 页面生命周期不能重放同一个 Catalog session。

### 16.2 真机矩阵

| 机型 | Pairing | Reconnect | Wi-Fi | INIT | OpenSession | Negotiation | First Catalog | Re-entry |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| X-T5 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 | 必测 |
| X-M5 | 回归 | 回归 | 回归 | 回归 | 回归 | 单变量实验 | 单变量实验 | 必测 |
| X-E5 | 回归 | 回归 | 回归 | 单变量实验 | INIT 成功后测试 | 后续 | 后续 | 后续 |
| X-S20 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 |
| GFX100RF | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 | 回归 |

每个正式支持结论至少需要：

- 同一台相机连续冷启动。
- 退出相册再进入。
- App kill 后重连。
- 相机关闭 AP 后重试。
- 可从日志还原 Policy、candidate、barrier 和 wire 终态。

## 17. X-M5 取证计划

当前参考 XApp 流程中的命令顺序只能作为候选基线，不能直接视为 X-M5 必需链。

实验原则：

1. 固定相机、固件、SD 卡、图片数量和启动方式。
2. 先获取同一 X-M5 的 XApp 成功对照。
3. 保留一条不修改的 CamTransfer control。
4. 每次只改变一个 wire-visible 变量。
5. 记录 D212/D222、顺序、间隔、返回码和 socket 状态。
6. 单次成功不能进入正式 Policy。
7. 必须做反向移除验证。

建议实验顺序：

1. D226=0。
2. D212 的位置或次数。
3. 9054。
4. 9055。
5. 9050。
6. D22B。
7. 最后才验证必要变量组合。

任何 optional prime 都不能在未验证前进入 X-T5 首次 Catalog 阻塞路径。

## 18. X-E5 取证计划

X-E5 当前 firstMissingBarrier 是 ptpInitAcknowledged。

优先级：

1. 获取同一 X-E5 使用 XApp 的 activation → Wi-Fi → TCP → INIT ACK 抓包。
2. 比较 BLE launch payload、A68E、BD17、BLE 断开时机。
3. 比较 INIT packet length、GUID、client IP、client name、protocol version 和超时。
4. 验证 standard PTP/IP candidate，但只能通过实验开关。
5. 每个差异独立实验。

在 INIT ACK 前：

- 不执行 OpenSession 后命令。
- 不执行 D212/D226/905x。
- 不调查 SD 卡和 Catalog。

## 19. 实施文件边界

第一阶段预计新增不超过三个职责文件：

- ios/Runner/CameraCompatibility/CameraCompatibilityPolicy.swift
- ios/Runner/CameraCompatibility/CameraCompatibilityResolver.swift
- ios/Runner/CameraCompatibility/CameraCompatibilityTrace.swift

如果类型足够小，Policy 和 Facts 可以先放在同一文件，避免为了目录结构拆文件。

预计修改：

- ios/Runner/CameraCore/Models/CameraCoreModels.swift
- ios/Runner/CameraCore/Connection/CameraConnectionSteps.swift
- ios/Runner/CameraCore/Connection/CameraConnectionStateMachine.swift
- ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift
- ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift
- ios/Runner/CameraVendorBluetoothService.swift
- ios/Runner/CameraVendorPtpSession.swift
- ios/Runner/CameraSessionRuntime.swift
- ios/RunnerTests/RunnerTests.swift
- ios/project.yml，仅在新增源码文件时修改

明确不创建：

- CameraConnectionOrchestrator.swift
- CameraConnectionBarrierLedger.swift
- PairingProfile.swift
- WifiHandoverProfile.swift
- 每个机型独立 Runtime
- 每个机型独立 Coordinator

实施前仍需根据最新源码确认是否能进一步减少新文件数量。

## 20. 验收标准

第一阶段架构完成必须同时满足：

1. X-T5 由 xt5-current-baseline Policy 驱动。
2. X-T5 wire 顺序和成功率没有意外退化。
3. 仍只有一套 Coordinator、StateMachine、Runtime 和 Catalog owner。
4. 日志包含 policyID、revision、candidate 和 firstMissingBarrier。
5. ConfirmGalleryMode 不再生成无协议依据的成功 evidence。
6. LoadGallery 不再把 PTP session ID 误称为 Catalog 已加载。
7. PTP INIT candidate 可配置，但 standard candidate 默认关闭。
8. Catalog ready 继续作为 GalleryReady 成功门槛。
9. X-M5 与 X-E5 实验可以独立接入，不修改 X-T5 baseline。
10. 所有新增 Resolver 分支和状态推进都有自动化测试。

以下不属于第一阶段完成标准：

- 所有 RED 相机都能连接。
- X-M5 已修复。
- X-E5 已修复。
- Gallery Shell 可以提前展示。
- Legacy/X-Half 已完整支持。

多机型正式兼容只能按目标真机逐台宣布，不能由架构完成自动推出。

## 21. 最终实施顺序

~~~text
1. 先补诊断和 characterization tests
2. 建最小 Facts / Policy / Resolver
3. 接入现有 Coordinator / StateMachine，保持 X-T5 wire 不变
4. 修正 ConfirmGalleryMode / LoadGallery 假 evidence
5. 将 PTP INIT candidate 化，但不默认增加新 candidate
6. 验证 X-T5 迁移没有退化
7. 分别执行 X-M5 Catalog 前状态实验
8. 分别执行 X-E5 PTP INIT 实验
9. 证据充分后再形成正式机型 Policy
~~~

最终架构不是“为每台相机复制一条链”，也不是“先搭一个足够通用的大框架”，而是：

~~~text
复用当前可靠所有权
+ 最小兼容决策
+ 真实差异策略
+ 可还原诊断
+ 同机型单变量验证
~~~

每一个新类型、新步骤和新分支都必须能回答：

1. 当前哪台相机已经证明存在这个差异？
2. 这个抽象替代了哪一处重复或错误判断？
3. 如果删除它，哪一个已验证场景会无法表达？
4. 它是否引入第二份连接、会话或 Catalog 事实源？

如果不能回答，就不进入第一阶段实现。
