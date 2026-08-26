# iOS 多机型动态媒体适配终态架构

状态：已 review，进入落地

## 目标

在不复制 X-T5/X-M5 Runtime、PTP session、CommandLane、Catalog owner 或 Download owner 的前提下，让几十种 Fujifilm 机型通过同一条相册主链路运行；只有经过当前 session 协议事实验证的具体 operation 差异，才以 session-local override 生效。

## 终态原则

```text
一套 Runtime / Session / CommandLane / Catalog owner / Download owner
+ 公共 Fujifilm media baseline
+ 当前 session 的 capability/evidence facts
+ 一个聚合 media operation definition
```

X-T5、X-M5 只是验证矩阵中的样本，不是生产架构节点。modelName、firmwareVersion、serialNumber 是事实、日志和支持矩阵输入，不能单独决定 SearchMode、Catalog membership 或任何整套媒体实现。

## XApp 对齐边界

参考 XApp 的分层思想，但不复制其 Java/Kotlin Model、singleton 或私有 Native SDK：

- CameraModel/CameraInfoModel 对应只读支持矩阵和 facts；
- BLE/GATT 发现、FunctionMode/FunctionVersion 和 PTP 响应逐阶段补全 facts；
- ControlFFIR 的黑盒能力由 FujifilmProtocolEngine 显式承载；
- ImportImageModel 的相册初始化、Catalog、thumbnail、preview、download 仍由 CamTransfer 现有 owner 承载。

XApp 反编译只能证明能力边界和调用语义，不能把未知 Native SDK 内部顺序直接变成 iOS 硬门禁。

## Facts 与策略生命周期

事实是逐阶段产生的：

```text
BLE/GATT facts
  -> PTP transport/open facts
  -> FunctionMode/FunctionVersion facts
  -> SearchMode descriptor/readback facts
  -> Catalog response and format coverage facts
```

同一个无状态 resolver 依据逐步补全的 facts 生成不可变、带 revision/fingerprint 的 session-local strategy snapshot。策略只在 session/generation 边界替换；一个已开始的 Catalog transaction 不得中途换策略。

未知保持 unknown。没有同机型、同固件、同状态的 wire/真机证据时，不启用 override，也不猜测为 X-T5 或 X-M5 行为。

## 聚合 Media Operation Definition

`FujifilmProtocolStrategySnapshot` 只保留一个 `mediaOperations` 聚合定义，内部至少区分以下维度：

```text
galleryInitialization
searchModeTransaction
catalogBaseline
catalogMembership / per-format membership
thumbnail
metadata
preview
download
d621Reference
```

`searchModeTransaction` 只定义备份、显式 ALL、readback 和恢复；它不等于 Catalog membership，也不保证 ALL 响应覆盖所有格式。

`catalogMembership` 负责定义 exact、subtract-baseline 或 unknown 等成员获取策略。后续加入 MOV/MP4 时只扩展同一聚合定义，不新增第二套 Registry/Resolver。

## Catalog 语义

一次空条件 SearchMode 查询不天然等于完整目录。Catalog 结果必须能表达：

- `complete(knownFormats)`：已证明覆盖全部产品格式；
- `partial(knownFormats)`：只覆盖已证明格式；
- `unknown`：无法证明成员完整性。

“全部”是已验证格式集合的可证明并集，不是简单复用一次 baseline 查询。合并必须在同一 Catalog owner、同一 PTP session、同一 CommandLane 内完成，并按 session/generation/snapshot fencing 发布。

## 所有权与故障边界

- 一个物理 PTP session 只能由 `CameraSessionRuntime` 关闭、恢复和替换；
- 所有 PTP 命令通过一个 serialized CommandLane；
- framing/transaction mismatch 使旧 lane/session 进入 terminal/unknown，禁止 socket 复用；
- Catalog transaction 失败保留 last-good catalog，并与真实 empty result 分离；
- D621 继续是 session/catalog scoped opaque reference，不跨 session 推断标准 ObjectHandle；
- thumbnail、metadata、preview 和 download 结果必须带 session/generation/snapshot identity。

## 页面边界不等于传输边界

下载页、筛选页和缩略图页是 UI 展示边界，不是 PTP 传输边界。页面离开只能说明 UI 不再观察某个结果，不能自动证明后台 task 已经停止、socket reader 已经退出、data/response packet 已经消费完，或物理 session 已经安全可复用。

因此页面操作必须经过 `CameraSessionRuntime` 的生命周期协议：

```text
页面进入/离开
  -> submit/cancel child intent
  -> runtime 标记 child generation 失效
  -> 等待物理 operation 完整结束或达到取消硬截止
  -> operation 正常结束：复用当前 session
  -> operation 超时/边界不可信：废弃整个 session，创建 fresh session
  -> 新页面只绑定新的 session/generation
```

页面切换不能直接释放或重建自己的 PTP session，也不能把旧页面的 command callback 继续留在全局队列中。下载页离开时，下载 owner 必须显式完成、取消或转入受控后台状态；筛选页进入时，Catalog owner 只能提交当前 intent，不能读取一个仍由旧下载 worker 持有的 command socket。

换句话说，UI 层的“上一个页面结束”与传输层的“上一个 operation 已结束”是两个不同事件。只有后者完成，下一条 PTP command 才能安全发送。

## 终态运行时不变量

### 物理操作必须完整收口

一个 PTP operation 只有在以下步骤全部完成后才能释放 CommandLane：

```text
write command
  -> consume complete data phase
  -> consume complete response phase
  -> validate response code and transaction
  -> publish operation result or terminal failure
  -> release lane
```

只读完 data、只收到 response，或只让 Swift task 返回，都不能视为物理 operation 已结束。

### 取消必须有硬截止

取消不是无限等待的软信号。取消流程必须定义 deadline：

```text
request cancellation
  -> interrupt reader
  -> join reader before deadline
  -> within deadline: session remains reusable
  -> deadline exceeded or framing uncertain: mark session terminal and discard it
```

超时后不得继续在旧 socket 上排队筛选、缩略图或下载命令；必须先创建新的 session/generation。这样可以避免取消中的大文件读取长期占用 CommandLane，并把残留 packet 带入下一次筛选。

### 筛选采用 latest-wins

快速连续的筛选请求只保留最后一个尚未执行的 intent。旧 intent 可以在 UI 层被覆盖，但已经发出的物理 operation 必须按取消协议结束，不能通过多个并发 task 争抢同一条 socket。

失败时 Catalog presentation 保留 last-good snapshot，并明确区分 `transportFailure`、`cancelled` 和真实 `empty`，禁止用 `items=0` 覆盖一个仍然有效的旧 Catalog。

### 缩略图严格绑定当前 identity

thumbnail 请求 key 至少包含：

```text
sessionID + catalogGeneration + catalogOpaqueIdentity + objectHandle
```

generation 变化时必须先使旧 viewport child、pending 集合和 retry 状态失效，再安装新 membership。相同 identity 的请求需要去重；retry 只能针对当前 generation 的可见对象，不能跨筛选复用。

## 架构优化推进顺序

优化不采用一次性重写，而采用每个阶段都有 RED/GREEN 和真机证据的受控迁移：

1. **冻结基线**：记录 branch/status、RunnerTests、build/install、下载吞吐、筛选失败、thumbnail 成功率和取消后 lane 持有时间。
2. **PTP framing**：先用 wire fixture 验证 data/response 完整消费、transaction 校验、非法长度和 terminal session 隔离；先确认 RED，再做最小实现。
3. **取消与下载独占窗口**：为长传输建立 transfer lease；取消有硬截止，超时废弃 session；筛选 intent 只保留最后一次。
4. **Catalog/filter 调度**：单一 Catalog owner 执行 latest-wins，旧 callback 不能覆盖新 presentation，transport failure 不得伪装成 empty。
5. **thumbnail 生命周期**：generation 切换时 await 旧 child 结束、清空 pending/retry/cache admission，再请求当前 viewport。
6. **吞吐优化**：在 framing 和取消稳定后，再根据真机 `socketReceiveMs`、`recvCallCount`、buffer 实际值优化 receive cadence；不以 Photos 写入耗时作为假设。
7. **受控迁移收尾**：每接管一个 operation，就删除旧入口、全局搜索旧 owner/lane/resolver 符号，并重复自动化、build 和真机验收。

## 历史遗留清理规则

不得长期保留两套行为并行运行。旧实现只能作为受控迁移期间的可回退点：

- 先为旧行为补充回归测试；
- 新物理执行路径只接管一个 operation；
- 用同一 session 的诊断日志对比新旧 wire 行为；
- targeted tests、全量 RunnerTests、build 和真机证据通过后删除旧入口；
- 最后执行旧符号、第二 owner、第二 CommandLane 和重复 recovery 路径搜索。

终态不是“能编译”或“偶尔成功”，而是同时满足单一 owner 架构、完整 packet 收口、可证明的取消边界、generation fencing、全量自动化证据和连续真机筛选/缩略图/下载验收。

## 交付顺序

1. 先完成 CommandLane/session/generation/last-good catalog 稳定性边界；
2. 建立聚合 media operation definition 和 Catalog coverage 语义；
3. 移除 modelName 直接生产路由；
4. 用 RED -> GREEN 测试证明相同 facts、不同 modelName 不产生不同媒体策略；
5. 仅在真实协议证据支持时增加 per-operation override；
6. 分别报告自动化、build/install/launch、真机和 XApp 对照证据。

## 明确不做

- 不建立 X-T5/X-M5 两套 Runtime 或 Registry；
- 不把 RED family 直接映射为 `explicitAllRestore`；
- 不把 `explicitAllRestore` 当作“全部格式”保证；
- 不在本阶段凭空实现 MOV/MP4 的具体 wire 策略；
- 不把 XApp 私有 SDK 未知行为当作已验证生产规则；
- 不清理或覆盖已有 WIP。
