# iOS 相册连接文案与 D22B 单变量优化设计

## 目标

在不改变 BLE、Wi-Fi、PTP、Catalog、GalleryReady 和 Runtime 所有权边界的前提下：

1. Wi-Fi join 完成前显示“正在等待相机 Wi-Fi”。
2. Wi-Fi join 已完成、开始 PTP/相册加载后显示“正在进入相机相册”。
3. 通过单变量 A/B 判断首次 Catalog 前的 `0xD22B` 是否可以安全跳过或延后，以争取恢复约 3–4 秒连接耗时。

## 已确认事实

- 2026-08-05 10:52:30 与 10:53:22 的两次闪退均为后台线程修改 UIKit 导致的 `SIGABRT`。
- 问题来自 Gallery loader 的 step 回调直接调用 `publishSnapshot()`，不是文案字符串本身，也不是 Wi-Fi、Catalog、HEIF 或视频处理。
- 两次闪退前相机均已达到 `APState=Launched`，App 在真正执行手机 Wi-Fi join 前终止。
- 当前 X-T5 日志中 `D22B requestToFirstByteMs` 约为 3.7 秒，是相对旧体验新增耗时的主要可见候选，但尚无跨机型 A/B 证据证明可以删除。

## 非目标

- 不修改 D227 payload 宽度。
- 不移除或调整 D212。
- 不修改 BLE 配对、Wi-Fi join、PTP retry/INIT、D244/卡槽切换。
- 不修改 Catalog owner、generation fence、`CameraCommandLane` 或 `CameraSessionRuntime` 生命周期。
- 不修改 HEIF/video enrichment、缩略图、HD Preview、下载和后台行为。

## 阶段一：主线程安全的连接文案

### 状态边界

| 连接阶段 | 文案 |
| --- | --- |
| `ReconnectPairedBle` 至 `JoinCameraWifi` 完成前 | 正在等待相机 Wi-Fi |
| `ConnectPtp`、`ConfirmGalleryMode`、`LoadGallery` | 正在进入相机相册 |

`ConnectPtp` 只能在 `JoinCameraWifi` 已通过状态机证据后开始，因此它是“手机已经连接相机 Wi-Fi”的明确切换点。

### 并发边界

- Gallery step 回调必须声明为 `@MainActor`，从非主执行器触发时必须通过 `await` 进入 MainActor。
- `CameraVendorConnectFlowBridge.publishSnapshot()` 只能在 MainActor 上调用。
- UIKit 不读取或处理 PTP/loader 后台回调；只消费 MainActor 发布的 `IOSCameraHomeSnapshot`。
- 不在 `NativeGalleryLoadingPhrase` 增加兜底字符串映射，避免形成第二条文案来源。

### 测试要求

- 先写纯状态映射测试。
- 先写从后台 Task 触发 step、断言 observer 在 MainActor/主线程执行的运行时测试。
- 旧的源码字符串包含测试不能作为线程安全证据。
- 聚焦测试通过后，运行连接协调器成功、失败、中间 step 回归和签名设备 build。
- 单独安装阶段一包，真机验证不闪退、Wi-Fi 能 join、文案只在 `ConnectPtp` 前后切换。

## 阶段二：D22B 单变量 A/B

### A 包

- 保留当前 pre-Catalog `D22B`。
- 记录点击进入相册、AP ready、Wi-Fi join、PTP open、D22B、首次 9053、Catalog install、GalleryReady 时间。

### B 包

- 只跳过或延后首次 Catalog 前的 `D22B`。
- 其他命令顺序、状态机、Catalog 查询、GalleryReady Gate 与 A 包完全一致。
- B 包不得与阶段一文案改动同时首次验证；必须在阶段一真机通过后单独安装。

### Gate

- X-T5 与 X-M5 均需至少验证首次进入、退出后再次进入、筛选和断开重连。
- 不出现 `0x2013`、空 Catalog、双 snapshot、同 session replay 或 GalleryReady 提前发布。
- 若 B 包稳定且耗时改善接近 D22B 等待时间，才进入生产方案。
- 任一机型失败则恢复 A 包，不继续叠加其他协议改动。

## 架构影响

阶段一只强化现有 actor 边界，并复用现有 `IOSCameraConnectionStep` 状态机；阶段二只测试一个 wire-visible 变量。两阶段均不引入第二 Runtime、第二 Catalog owner、并行 PTP owner 或新的 generation 体系。

## 交付与证据

- 两阶段分别产生测试结果、设备 build、安装记录和真机日志。
- 不创建提交、不 push。
- 自动化证据与 X-T5/X-M5 真机 Gate 分开报告。
