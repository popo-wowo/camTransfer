# iOS Mainline 功能收敛与 Build 18 取消路径修复设计

## 目标

在 `origin/main@4e7fdaa9` 的现有动态兼容性架构上，迁移两个并行 iOS 分支中已证实缺失的行为，不整体 cherry-pick 旧分支；同时修复 Build 18 日志暴露的连接取消路径，使用户主动取消不会被记录成普通连接失败。

## 证据边界

- `origin/main` 没有 `Connected Application Information` 特征、应用信息 payload 或写入 ACK 门禁。
- `origin/main` 的首次 Catalog 仍执行 D604 baseline 与 expanded 两次读取，并保留同一 session 的 `0x2013` recovery/replay。
- Build 18 日志在 `reconnectPairedBle` 阶段出现 `connecting-overlay-user-cancel`、`RUNTIME_CONNECTION_WORKER_CANCEL` 和 `Swift.CancellationError`；日志没有 `BLE_CONNECTED` 或 Wi‑Fi 起始事件。因此 BLE 取消路径与 Gallery Catalog 是两个独立验证项。
- XApp 可吸收的行为原则是“先完成相机状态初始化，再读取首个稳定目录”，不复制 XApp 的类结构或所有命令序列。

## 设计

### 1. Connected Application Information

在当前 BLE Handshake owner 中增加能力条件分支：

1. 发现 UUID `8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7` 时，记录该特征。
2. 写入 `80 01 01`，使用 `.withResponse`。
3. 只有当前 generation、当前 peripheral、当前 characteristic 的成功写回调才允许完成 handshake。
4. 5 秒内没有成功回调或收到错误时，发布握手失败并停止后续传图激活。
5. 未发现该特征时保持现有握手流程，不影响不需要该协议的相机。

旧分支的独立 generation 字段不直接搬运，复用 `main` 已有的 BLE connection token、activation token 和 callback gate。

### 2. 首次 Gallery Catalog

在现有 `CameraGalleryCatalogRuntime` / `CameraCatalogQueryEngine` owner 边界内实现：

1. 首次 Catalog 请求前执行一次 legacy Gallery prepare。
2. 首次请求读取一个可校验、可安装的 base snapshot，不在入口阶段做 D604 baseline/expanded 差集。
3. 删除同一 PTP session 中 `0x2013` 后的 bootstrap replay；失败交给上层重新建立 session。
4. Catalog snapshot 通过计数、日期组、句柄唯一性校验并安装后，才发布 `GalleryReady`。
5. HEIF/RAW/视频格式扩展与 post-ready enrichment 作为 ready 后事务，带 generation/snapshot fence，不阻塞首次进入。

### 3. Build 18 取消路径

以用户主动点击取消为单独状态处理：

1. 取消连接 worker 后，底层 `CancellationError` 不再作为普通 BLE 失败重复上报。
2. 连接执行状态记录 `cancelled`，保留 `firstMissingBarrier` 作为诊断，但不发布“无法加入网络/连接失败”类业务错误。
3. 取消后的晚到 BLE 回调继续由现有 token/generation gate 丢弃。
4. 日志明确区分 `user-cancelled`、系统/上层 supersede 和真实 BLE failure。

## 验收

- XCTest：Connected Application Information 的条件发现、payload、ACK、超时、旧回调拒绝。
- XCTest：首次 Catalog 的 prepare 顺序、单次 base snapshot、无同 session replay、GalleryReady 安装门禁。
- XCTest：用户取消不产生普通失败回调或错误 UI，晚到 completion 被丢弃。
- `git diff --check`、focused XCTest、完整可用的 iOS build/test。
- 真机矩阵仍是最终证据；自动化和 build 不能替代 BLE/Wi‑Fi/PTP 真实设备验证。
