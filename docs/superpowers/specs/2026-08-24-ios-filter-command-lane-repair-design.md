# iOS Gallery 筛选 Command Lane 稳定性修复与架构优化方案

> 状态：review 修订版，实施前冻结边界
>
> 基线：`main@363593ffd99ee7d5e22e4e31577fc8a8807d9fc0`
>
> 证据：TestFlight 19 诊断日志 `CamTransfer-Diagnostics-2026-08-24T13-29-32Z.log`
>
> 目标分支：`codex/ios-filter-lane-repair`

## 1. 方案结论

本修订版明确 owner 边界：`CameraSessionRuntime` 只负责页面与连接生命周期；
`CameraVendorPtpSessionRuntime` 是唯一 PTP owner，负责唯一物理 session、CommandLane
和 transport/session generation；`CameraGalleryCatalogRuntime` 只负责 Catalog
transaction/generation；`CameraGalleryThumbnailPipeline` 只负责当前 Catalog generation
的 child work。页面保留不等于 transport 可用，`GalleryVisible + TransportBroken`
必须与 `GalleryReady` 分离。

本轮不把 `codex/ios-xm5-catalog-ab` 的大范围动态协议改动整体迁移到 `main`。先在新分支上实现一个可验证的最小修复集，解决已经被真机日志证明的筛选错误：PTP Command Lane 错帧、筛选与缩略图并发、失败筛选发布空目录，以及错帧后的物理会话恢复。

HEIF 的原图传输链路已经被 TestFlight 19 日志证明可用，因此本轮不重写 HEIF 下载协议，不把未证实的 D621 映射、SearchMode reset、subtract-baseline、count-sweep 或 operation contract 硬门禁作为生产前置条件。

整体策略：

```text
main 基线
  -> 修复 Command Lane 错帧和 session 隔离
  -> 修复筛选/缩略图并发与 generation fencing
  -> 修复失败状态投影，保留正常 Catalog
  -> 闭合错帧后的重连与 ALL Catalog 恢复
  -> 真机 A/B 验证 JPG/HEIF/RAW 显示、缩略图、下载和连续筛选
  -> 再单独评估动态协议架构

本轮不在旧 `CameraVendorPtpSession` 对象内执行原地 transport recovery。framing/
transaction 错误会使旧 session generation 终态失效；恢复必须由唯一 PTP owner 创建
新的 session generation，重新建立 PTP session、fresh ALL Catalog 和新的 Catalog identity。
```

## 1.1 本轮范围：两个目标，两个阶段

本轮不是“修 Bug 或做架构重构”二选一，而是按风险顺序分成两个目标：

### 目标 A：必须解决的当前 Bug

以下事项是本轮的强制交付范围，因为它们已经被 TestFlight 19 的同一会话日志直接证明：

1. `legacy PTP 包长度异常 0` 后仍继续使用旧 command lane；
2. `PTP response transaction 181 does not match request transaction 184` 的错帧扩散；
3. 筛选命令与缩略图/metadata 命令并发读写同一 PTP socket；
4. 筛选失败被发布成 `items=0`，把传输失败伪装成“没有该格式”；
5. 旧 session、旧 D621 reference、旧异步结果在新筛选或恢复后继续生效；
6. 错帧后没有闭合到 fresh PTP session、fresh ALL Catalog 和新 generation 的恢复路径。

目标 A 的验收标准是：JPG、HEIF、RAW 的 ALL/显示/下载原有成功路径无回归；筛选失败不再出现假空目录；错帧后旧 session 不再接收新命令，并能恢复到新的 ALL Catalog。

### 目标 B：只实施确定性、直接支撑稳定性的架构优化

架构优化只允许满足三个条件：有当前日志或代码证据；能直接降低目标 A 的复发概率；可以用单元测试、构建和真机矩阵验证。按此标准，本轮只保留以下七项边界：

| 架构边界 | 为什么必须 | 解决的问题 | 回归风险 | 验收方式 |
|---|---|---|---|---|
| 单一 PTP Command Lane owner | 日志已证明共享 socket 发生错帧；多个任务各自读写无法证明帧归属 | transaction mismatch、长度 0 后继续读写 | 串行化可能降低吞吐 | 并发筛选/缩略图测试；真机连续筛选 |
| `CameraSessionRuntime` 作为物理 session 唯一 owner | 错帧后必须统一关闭 socket、重建 session；不能由 UI 或子任务各自重连 | 旧 session 复用、重复重连 | 恢复路径未闭合会回到 Gallery | session 生命周期测试；fresh ALL Catalog 真机验收 |
| `CameraGalleryCatalogRuntime` 作为 Catalog transaction/generation 唯一 owner | 筛选失败发布空目录说明查询和展示状态边界混淆 | 旧查询覆盖新查询、错误 items=0 | 需要补充显式 pending/failed 状态 | query 状态测试；筛选失败保留旧目录 |
| session/generation/snapshot identity fencing | 缩略图、metadata、preview 是异步结果，必须证明归属 | 旧 generation 结果污染当前 UI/cache | 丢弃过严可能少显示一张图 | stale-result 单元测试；真机切换筛选 |
| UI 只提交 intent，不直接控制协议 | UI 层取消/刷新不能安全管理 PTP socket 和 session | 筛选与协议重启耦合 | 需要适配现有回调 | UI intent 测试；不触发额外 BLE/Wi-Fi/PTP 重启 |
| 失败状态与空结果状态分离 | 日志已证明失败被投影成 `items=0` | 用户误判格式不支持/照片不存在 | 新状态需要 UI 文案和埋点 | 状态机测试；真机故障提示不清空旧目录 |
| D621 保持 opaque，并绑定 session/generation | 目前没有 XM5 `D621 opaque key -> 实际图片数据` 的完整映射证据 | 防止把未证实私有 key 当标准 handle，造成跨 session 误用 | 不能依赖标准 ObjectInfo 推断 | 类型/身份测试；不改变已成功下载命令序列 |

这七项不是抽象层面的“为了优化而优化”：每一项都对应已观测的错帧、状态污染或恢复缺口，并且都有独立的验收证据。除上述边界外，本轮不扩张架构范围。

### 明确不做的优化

本轮不做 D621 标准 handle 映射、SearchMode reset 默认启用、subtract-baseline、count-sweep、首屏同步 ObjectInfo 扫描、operation contract 硬门禁、HD Preview/Wired Import/UI 大重构，也不整体迁移 `codex/ios-xm5-catalog-ab`。这些改动当前没有足够的同会话协议证据，且可能改变已经能工作的 JPG/HEIF/RAW 主链路。

## 2. 当前 main/TestFlight 19 的真实状态

### 2.1 版本身份

日志头明确显示：

```text
App Version: 1.0 (19)
System: iOS 27.0
Generated At: 2026-08-24T13:29:32Z
```

因此该日志来自 TestFlight 19，而不是当前用 `main` 编译的 Debug 包。TestFlight 19 对应 `ac5f61d4`，当前 `main` 是 `363593ff`；两者业务代码差异很小，不能把问题简单归因于 HEIF 协议在 main 被完全改坏。

### 2.2 已证实正常的功能

日志证明以下主链路成功：

| 功能 | 证据 | 结论 |
|---|---|---|
| XM5 BLE 连接 | `BLE_CONNECTED` | 正常 |
| 相机热点启动 | `AP_STATE_READY` | 正常 |
| PTP/Gallery 建链 | `PTP_HANDSHAKE_OK`、`IOS_GALLERY_SESSION_PREPARED` | 正常 |
| ALL Catalog | `PTP_INITIAL_CATALOG_END ... handles=2563` | 正常 |
| GalleryReady | `GALLERY_READY ... items=2563` | 正常 |
| JPG 原图下载 | `format=JPG` 多次成功 | 正常 |
| RAW 原图下载 | `format=RAW` 多次成功 | 正常 |
| HEIF 原图下载 | `format=HEIF`，约 5 MB，多次成功 | 正常 |

HEIF 成功下载证明：HEIF 对象可以被当前 D621/Legacy 路径访问，原图读取、接收、写入相册均可用。本轮不把“HEIF 不显示”解释为 HEIF 文件传输能力缺失。

### 2.3 已证实的 Bug

用户执行格式筛选时，日志出现：

```text
GALLERY_FILTER_UI_APPLIED ... formats=["jpg"]
PTP_COMMAND_SEND operation=0x9052 transaction=181
PTP_CAMERA_CATALOG_FAILED label=format-jpg
primary=CameraVendor legacy PTP 包长度异常 0
```

随后出现更明确的错帧：

```text
PTP_COMMAND_SEND operation=0x9052 transaction=184
PTP_COMMAND_RESPONSE operation=0x9052 transaction=181
PTP_CAMERA_CATALOG_FAILED
primary=PTP response transaction 181 does not match request transaction 184
```

筛选失败后，运行时发布：

```text
CATALOG_PRESENTATION_PUBLISH_END ... items=0
```

而返回全部照片时又恢复：

```text
CATALOG_QUERY_RESOLVED ... items=2563
CATALOG_PRESENTATION_PUBLISH_END ... items=2563
```

因此当前准确的故障链是：

```text
缩略图/详情命令仍在共享 PTP socket
  -> 9052 SearchMode 筛选进入同一命令通道
  -> 读到长度异常帧或旧 transaction 响应
  -> 当前 command lane framing 不可信
  -> 筛选事务失败
  -> 失败结果被投影为 items=0
  -> HEIF/JPG/RAW 在筛选页看起来消失
```

这不是“HEIF 文件不能下载”，也不是“D621 一定不能用”，而是命令通道和筛选状态处理的 Bug。

## 3. 根因边界

### 3.1 已确认根因

1. PTP 命令、数据、响应共享一个物理命令通道。
2. 筛选发生时仍可能有缩略图/详情请求在进行。
3. 客户端没有在第一次 framing/transaction 异常后立即废弃旧物理会话，导致后续响应继续错位。
4. Catalog 事务失败时将展示结果替换成空数组，制造了“格式不存在”的假象。
5. 筛选和缩略图结果需要 generation fence，但现有 main 不能充分阻止旧异步结果进入新展示状态。

### 3.2 尚未证明、因此本轮不作为根因的假设

- D621 数值是否对应标准 PTP ObjectHandle；
- D604/SearchMode descriptor 的完整私有 schema；
- HEIF 是否必须使用 subtract-baseline；
- XM5 是否必须 count-sweep 才能返回准确格式目录；
- iOS 27 beta 是否改变了 HEIF wire protocol；
- 某一次具体 UI 报错是否必然对应 UICollectionView 崩溃。

这些内容可以继续做实验，但不能在没有同会话协议证据时变成生产硬门禁。

## 4. 本轮功能修复方案

### 4.1 Command Lane 单一串行入口

所有会读写 PTP command socket 的操作必须经过同一个串行入口：

```text
9051 / 9052 / 9053
D620 / D621
9054 / 9055
1008 / 100A
原图读取
```

每个操作必须在同一个不可打断的 transaction scope 中完成：

```text
校验 session/lane 可用
  -> 分配 transaction ID
  -> 写 command/data
  -> 读取完整 data/response
  -> 校验 response transaction
  -> 校验 response code
  -> 释放 lane
```

禁止不同任务各自直接读写 socket。取消一个 Swift Task 不能等同于 socket 已清空；必须等待任务结束，且在 framing 不可信时废弃整个 session。

### 4.2 Framing/transaction 失败即隔离物理会话

以下任一错误出现时，当前 command lane 进入 `framingUnknown`：

- legacy PTP 包长度小于合法最小值；
- legacy 包长度为 0；
- response transaction 与 request 不一致；
- EOF、连接重置、未知 packet type；
- 读取阶段无法确认当前帧边界。

处理规则：

```text
记录 PTP_COMMAND_LANE_FRAMING_UNKNOWN
  -> 关闭 command/event socket
  -> 标记当前 PTP session 不可继续使用
  -> 拒绝后续 Gallery command
  -> 通知 CameraSessionRuntime 进入 session recovery
```

不能只把错误转换成普通筛选失败后继续复用旧 socket。

### 4.3 筛选与缩略图的边界

用户提交新筛选时：

```text
分配 pending filter intent
  -> suspend Catalog child work
  -> cancel thumbnail task
  -> cancel metadata/details task
  -> await cancelAndJoin
  -> 开始唯一的筛选 Catalog transaction
```

筛选 transaction 完成后才恢复新的可见窗口缩略图。

### 4.4 Generation fencing

每次 Catalog 事务分配新的 generation 和 snapshot identity。所有以下对象必须绑定 identity：

- Catalog presentation；
- D621 opaque key membership；
- thumbnail result；
- ObjectInfo/metadata result；
- preview result；
- download reference。

旧 generation 的结果只能被丢弃，不能写入当前 repository、thumbnail cache 或 UI。

### 4.5 筛选失败的展示策略

如果此前已有可用 Catalog，筛选失败时：

```text
保留上一份正常 Catalog
  + 发布显式失败状态/提示
  + 记录 query label、transaction、generation、错误类型
```

不能发布一个 `items=0` 的“成功空结果”，因为这会把传输错误伪装成“相机没有 HEIF/JPG/RAW”。UI 必须区分：

- 真正的空筛选结果；
- 筛选失败但仍保留旧目录；
- 当前 session 已失效，需要恢复连接。

### 4.6 错帧后的恢复闭环

第一阶段至少保证旧 session 不被继续使用。完整目标是：

```text
framingUnknown
  -> terminate current PTP session
  -> fresh Wi-Fi/PTP/OpenSession
  -> fresh Gallery bootstrap
  -> fresh ALL Catalog
  -> fresh generation/snapshot
  -> restart thumbnails
```

恢复时禁止复用旧：

- socket；
- transaction ID；
- SearchMode lease；
- D621 key reference；
- Catalog generation；
- download reference。

## 5. 架构优化方案

### 5.1 保留并固化的边界

本轮应保留以下架构原则：

1. `CameraSessionRuntime` 是物理 session/lifecycle 的唯一 owner。
2. `CameraGalleryCatalogRuntime` 是 Catalog generation、transaction 和 presentation 的唯一 owner。
3. `CameraGalleryThumbnailPipeline` 只处理当前 generation 的缩略图和详情子任务。
4. PTP command lane 由单一 owner 串行调度。
5. UIKit 只提交筛选 intent 和渲染 immutable presentation，不直接重启相机协议。
6. D621 在证据不足时保持 opaque；不可直接当成标准 ObjectHandle。
7. Unknown evidence 不得被转换成 supported、unsupported 或空目录。

### 5.2 后续可逐步引入的动态协议架构

以下设计保留为后续兼容层，但不阻塞当前主链路：

- session-scoped capability snapshot；
- typed `CameraMediaReference`；
- per-operation adapter；
- operation evidence/contract；
- D621 key 的 session/generation identity；
- 后台 ObjectInfo 分类和本地格式投影。

这些架构元素的作用是防止多机型协议事实被错误泛化，不是为了替代已经能工作的 HEIF/JPG/RAW 下载路径。

### 5.3 本轮明确不迁移的内容

暂不进入生产默认路径：

- D621 -> 标准 PTP handle 的未经证实映射；
- SearchMode reset 默认 arm；
- subtract-baseline；
- count-sweep；
- 首屏前同步 ObjectInfo 批量采样；
- 全量 operation contract 硬门禁；
- 与当前 Bug 无关的 HD Preview、Wired Import、UI 大范围重构。

这些内容可以保留在实验分支或诊断 API 中，但必须与正常 Gallery 路径隔离。

## 6. 执行计划

### 阶段 0：基线与证据冻结

1. 从 `main@363593ff` 使用分支 `codex/ios-filter-lane-repair`。
2. 保存 TestFlight 19 日志及本次真机环境信息。
3. 运行 `git status --short --branch`、`git diff --check`。
4. 确认真机 Debug build、安装、启动是独立证据。
5. 记录同一 XM5、同一张卡的 ALL/JPG/HEIF/RAW 矩阵。

### 阶段 1：先写失败测试

先增加并运行 RED 测试，覆盖：

1. transaction mismatch 会进入 framing-unknown；
2. 非法 legacy frame length 会阻止下一条 command；
3. framing-unknown 后旧 socket/D621 reference 不可继续使用；
4. 筛选提交会等待 thumbnail/details 任务结束；
5. 旧 generation 的 thumbnail/metadata 不得发布；
6. Catalog query 失败不会覆盖已有正常 items；
7. framing-unknown 能触发或明确进入 recovery path。

### 阶段 2：最小 Command Lane 修复

修改范围优先限制在：

- `ios/Runner/CameraVendorPtpSession.swift`；
- `ios/Runner/CameraTransportFailureDisposition.swift`；
- 对应 RunnerTests。

先实现 lane 状态、frame/transaction 校验和 session 隔离，不改变 HEIF/JPG/RAW 的成功下载命令序列。

### 阶段 3：筛选状态修复

修改范围优先限制在：

- `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`；
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`；
- 必要的 presentation/error model 和测试。

实现 suspend/cancel/join、generation fencing 和失败保留旧目录。

### 阶段 4：恢复闭环

审计并补齐：

- `CameraSessionRuntime`；
- Gallery session owner；
- PTP reconnect；
- fresh ALL Catalog reload；
- recovery 后新 generation 安装。

### 阶段 5：自动化验证

至少通过：

```text
目标 RunnerTests
完整 RunnerTests
git diff --check
iPhoneOS 真机构建
```

### 阶段 6：真机 A/B 验收

同一台 iPhone、同一台 XM5、同一张卡、同一系统版本执行：

| 场景 | 预期 |
|---|---|
| ALL Catalog | 正常显示完整目录 |
| 首屏缩略图 | 正常，错误对象不拖死全局 |
| JPG 筛选 | 不出现错帧；结果或明确失败提示 |
| HEIF 筛选 | 不因传输失败显示假空目录 |
| RAW 筛选 | 不因传输失败显示假空目录 |
| JPG 下载 | 成功 |
| HEIF 下载 | 成功 |
| RAW 下载 | 成功 |
| 连续筛选 | 不复用旧响应 |
| 错帧恢复 | 新 PTP session + 新 ALL Catalog + 缩略图恢复 |

只有代码测试、真机构建和真机矩阵全部通过，才能声称解决当前问题。

## 7. 风险与回滚

### 风险

- 关闭 framing-unknown socket 后，上层恢复链路可能尚未闭合，导致需要重新进入 Gallery；
- cancel/join 时序不完整仍可能留下相机端迟到响应；
- 保留旧 Catalog 时若 UI 状态建模不清，会把旧目录误认为新筛选结果；
- operation contract 过严会阻断已成功的 HEIF/JPG/RAW 下载。

### 回滚原则

- 每个阶段独立提交；
- 不修改当前工作目录的用户 WIP；
- 不合并整个 XM5 大分支；
- 真机出现 JPG/HEIF/RAW 下载回归时，优先回滚新增 admission gate，而不是回滚 command lane framing 保护；
- 诊断实验默认关闭。

## 8. 完成定义

本方案完成不等于“编译成功”。必须同时具备：

1. 失败测试先 RED、修复后 GREEN；
2. 目标测试和完整 RunnerTests 通过；
3. iPhoneOS Debug build 成功；
4. 真机安装/启动成功；
5. ALL、缩略图、JPG/HEIF/RAW 显示和下载无回归；
6. 连续格式筛选不再出现 transaction mismatch 扩散；
7. 筛选失败不再发布假空目录；
8. 错帧后旧 session 不可复用，且能够恢复到 fresh ALL Catalog。
