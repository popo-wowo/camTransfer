# iOS 无线连接失败：日志因果闭环与当前修复

日期：2026-10-15
范围：四份诊断日志、当前 `codex/ios-connect` 工作树、Build 18/历史 mainline 实现。

## 结论

这几次“连接失败”不是同一个问题，也不是 BLE、Wi-Fi、PTP、Catalog 任一层可以代表全链路。四份日志的第一失败点分别落在：

| 日志 | 机型/场景 | 第一失败 barrier | 结论 |
|---|---|---|---|
| [诊断日志-20260830.log](/Users/g01d-01-1224/Desktop/传图/日志/诊断日志-20260830.log) | X-T30 III | UI 主动取消 worker | `WIFI_APPLY_RESULT error=nil` 只是配置提交成功；随后 `connecting-overlay-user-cancel` 取消了连接任务，`CancellationError` 是取消结果，不是相机拒绝 Wi-Fi。 |
| [CamTransfer-Diagnostics-2026-08-24T00-11-28Z.log](/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-24T00-11-28Z.log) | X100VI | PTP socket | 已关联 Wi-Fi、已有 IPv4，但连接相机时报 `No route to host`，后续 INIT 无 ACK、reset/timeout；Wi-Fi 关联不等于 PTP 路由已稳定。 |
| [CamTransfer-Diagnostics-2026-08-25T12-47-24Z.log](/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-25T12-47-24Z.log) | X-M5 成功基线 | 无失败 | `9053 → 0x2001`，随后 `D620/D621`，Catalog 1642 项并进入 `GALLERY_READY`。`9050` 不是所有机型的硬性前置条件。 |
| [CamTransfer-Diagnostics-2026-08-25T12-55-59Z.log](/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-25T12-55-59Z.log) | X-M5 特定状态 | Catalog `9053 → 0x2013` | 相机 Store/SearchMode 状态暂不可用；历史路径执行一次恢复后重试 `9053` 成功。后续 transaction mismatch/旧 generation 污染是另一条并发一致性问题。 |

当前用户最近一次真机失败属于第四类：BLE、激活、Wi-Fi、IPv4、PTP INIT、OpenSession 都已成功，第一失败是 Catalog 的 `0x9053 → 0x2013`。因此不能把它归类成“无线没连上”，也不能靠重新做 BLE/Wi-Fi 重试解决。

## 当前连接失败的根因

当前版本的 Catalog 主链在 [CameraVendorRealtimeGalleryService.swift:560](/Users/g01d-01-1224/Documents/camtransfer/ios/Runner/CameraVendorRealtimeGalleryService.swift:560) 中先执行 Gallery bootstrap，再执行一次 `cameraVendorInitialCatalogSnapshot()`。当 `9053` 返回 `0x2013` 时，旧实现只做 `revise(facts)`，然后重新抛出原错误；它没有执行恢复动作，也没有第二次 Catalog 读取。这造成了一个断裂的因果链：

```text
PTP session 已打开
  -> Gallery bootstrap 已完成
  -> 9053 访问 Store
  -> 相机返回 0x2013（Store/SearchMode 尚未可用）
  -> 代码只修订策略版本
  -> 代码直接结束 Catalog
  -> UI 永远收不到 GalleryReady
```

历史实现 [4a2b60bd `CameraVendorRealtimeGalleryService.swift`](/Users/g01d-01-1224/Documents/camtransfer/ios/CameraVendorRealtimeGalleryService.swift) 曾经在这个响应后调用 `recoverInitialCameraCatalogAfterStoreNotAvailable()`，然后重新 fetch。后续 `5bfd91a5` 为了避免同一 session 的无条件重放，把恢复分支删成“只记录策略修订并抛错”，但没有补上等价的受控恢复，因此把 Build 18/早期 mainline 能工作的恢复闭环删掉了。

这也解释了“优化后反而更差”：架构层的动态 compatibility plan 本身没有阻断 PTP；真正退化的是错误响应后的执行语义，从“响应驱动恢复并重读”变成了“只改 plan，不恢复、不重读”。

## 已实施的最小修复

### 恢复策略

当前实现只在已经收到 `9053 → 0x2013` 后执行一次恢复：

1. 保留当前物理 PTP session 和串行 command lane。
2. 记录 Catalog response facts 并把 plan revision 切换到 `storeNotAvailableRecovery`。
3. 发送 `9050` SearchModeDescAll，刷新相机 SearchMode 描述。
4. 读取 `D22B` 当前对象上下文。
5. 重新读取 `9053/D620/D621` Catalog。
6. 恢复失败或第二次 Catalog 仍失败时，原始错误继续向上抛出。

实现位置：

- [CameraVendorPtpSession.swift:869](/Users/g01d-01-1224/Documents/camtransfer/ios/Runner/CameraVendorPtpSession.swift:869)：响应驱动的 `9050 + D22B` 恢复。
- [CameraVendorRealtimeGalleryService.swift:198](/Users/g01d-01-1224/Documents/camtransfer/ios/Runner/CameraVendorRealtimeGalleryService.swift:198)：首次 Catalog 失败后的 `revise → recover → recoveryFetch`。
- [CameraVendorRealtimeGalleryService.swift:560](/Users/g01d-01-1224/Documents/camtransfer/ios/Runner/CameraVendorRealtimeGalleryService.swift:560)：把恢复闭环接入当前动态 strategy runtime。

首次 `9053` 前仍不会默认写 `9051`。`9051` 只应作为相机明确要求的后续策略动作，不能再作为所有机型的固定初始化前置步骤。

### 测试证据

先把恢复行为写成失败测试：当前代码当时得到的事件序列是 `fetch`，期望是 `recover → fetch`，测试因此 RED。修复后以下定向测试全部通过：

- `testInitialCatalogDefinitionsReplayStoreRecoveryOnceThenFetchAgain`
- `testResponseDrivenInitialCatalogExecutorRevisesRecoversAndReplaysOnce`
- `testResponseDrivenInitialCatalogMainlinePropagatesRecoveryFailure`
- `testProductionInitialCatalogFetchPreparesBeforeSingleFetchWithoutReplay`
- `testStoreNotAvailableFactsReviseOnlyInitialCatalogStrategy`
- `testCatalogResponseClassifierRejectsWrongOperationOrResponseForRecovery`
- `testFilteredCatalogTransactionRestoreFailureDoesNotTriggerInitialStrategyRevision`

命令：

```text
xcodebuild -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' test \
  -only-testing:RunnerTests/RunnerTests/<上述测试>
```

### 真机构建与安装

已用当前工作树构建并安装到已配对设备：

- Bundle ID：`com.camtransfer.app`
- 设备：`iPhone`（CoreDevice ID `00008150-001C7D2C2E7A401C`）
- 构建：`Debug-iphoneos`
- 结果：`BUILD SUCCEEDED`，`devicectl device install app` 成功，随后启动成功。

安装/启动只能证明新二进制已经落到手机，不能替代相机连接验收。设备之后的 CoreDevice 查询出现网络超时，因此本次尚未获得“相机再次触发连接后出现 `RECOVERY_9050` 并进入 `GALLERY_READY`”的真机证据；这一步需要下一次实际连接操作后的最新日志确认。

## 四份日志的详细因果判断

### X-T30 III：取消传播问题

日志中先有：

```text
WIFI_APPLY_RESULT ... error=nil
```

随后三秒内出现：

```text
connecting-overlay-user-cancel
RUNTIME_CONNECTION_WORKER_CANCEL
WIFI_ASSOCIATION_FAILED ... Swift.CancellationError
```

所以这次第一失败是 UI/worker cancellation。Wi-Fi 配置 API 成功并不代表已关联、拿到 IPv4 或 PTP 可达。`093fed19` 已修复错误分类，使取消保持 `CancellationError` 语义；但 UI 若仍主动取消，连接仍会被中止。

### X100VI：关联成功后的路由/PTP 不稳定

日志同时出现 `WIFI_ASSOCIATED`、`ip=192.168.0.127`、`ptpReachable=true`，但随后 TCP 连接返回 `No route to host`，INIT 没有 ACK，重试最终超时。这说明“同网段/关联成功”不是 PTP 服务可用的充分条件。`02a9f69d` 已加入整体 30 秒预算和重试前网络检查；它只能阻止向明显过期网络继续重试，不能把相机端 AP/PTP 服务重置自动变成可用。

### X-M5 成功基线：9050 可选

成功日志明确记录 `PTP_GALLERY_BOOTSTRAP_9050_SKIPPED`，但 `9053` 返回 `0x2001`，`D620/D621` 返回 1642 个句柄，随后 `GALLERY_READY`。因此不能把 `9050` 固定塞进所有机型的首次链路；它应该是收到相机状态证据后的恢复动作。

### X-M5 特定状态：0x2013 需要恢复

失败日志的第一轮是 `9051 → 9053(0x2013)`；随后旧实现执行 Gallery/SearchMode 恢复，第二轮 `9053` 返回 `0x2001`，最终得到 2563 项。这个事实证明 `0x2013` 可由相机状态恢复，而不是连接层必须重建 BLE/Wi-Fi/PTP。

同一日志后半段又出现请求 transaction 154、收到 transaction 153，并记录 `PTP_CAMERA_CATALOG_FAILED`，同时有旧 generation 缩略图任务继续发布。这是独立的 transaction/generation 一致性问题；`5f50655d` 已把 transaction mismatch 提升为 `sessionTerminal`，但它不属于本次 `9053 → 0x2013` 修复范围。

## 当前覆盖矩阵

| 问题 | 当前状态 | 证据 |
|---|---|---|
| UI 主动取消导致 Wi-Fi 连接中断 | 部分解决 | 取消语义已保留；仍需 UI 行为和真机复现确认。 |
| Wi-Fi 关联后路由/PTP 不稳定 | 部分解决 | 已有重试预算和网络门禁；相机 AP/PTP 端重置仍需真机验证。 |
| 首次 `9053 → 0x2013` 直接失败 | 已加入代码修复，待真机验收 | 现在会 `revise → 9050 → D22B → retry 9053`；定向测试通过。 |
| 首次连接默认写 `9051` | 已避免 | 当前首次 bootstrap 明确跳过 9051；恢复也不写 9051。 |
| transaction mismatch/旧 generation 污染 | 已隔离，未完全闭环 | `5f50655d` 结束 session；重新建 socket/OpenSession/Catalog 的自动恢复仍需后续处理。 |

## 下一次真机验收必须看到的日志

对于复现本次问题的相机，验收标准是：

```text
PTP_OPEN_SESSION_OK
PTP_INITIAL_CAMERA_CATALOG_9053 ... response=0x2013
CAMERA_PLAN_REVISION ... strategyID=...store-not-available-recovery
PTP_INITIAL_CAMERA_CATALOG_BOOTSTRAP_RECOVERY response=0x2013
PTP_INITIAL_CAMERA_CATALOG_RECOVERY_9050
PTP_INITIAL_CAMERA_CATALOG_RECOVERY_D22B
再次 9053 → 0x2001
PTP_INITIAL_CAMERA_CATALOG_END
GALLERY_READY
```

如果恢复后的第二次 `9053` 仍返回 `0x2013`，应保留相机原始响应并报告 Catalog barrier；不要把它包装成 BLE 或 Wi-Fi 错误，也不要无限重放恢复链。
