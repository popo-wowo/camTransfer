# iOS Remembered BLE Bootstrap Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保留 `4a2b60bd` 的动态多机型架构，同时恢复 remembered camera 在缓存广告 Service 尚不能确定兼容家族时进入只读 BLE/GATT 的能力。

**Architecture:** 初始 Plan 只负责准入 `reconnectPairedBle`。已保存 endpoint 是启动 BLE 的可信路由证据，缓存广告 Service 仅是可能不完整的观测，不能阻止只读 GATT。GATT facts 返回后仍由现有 Resolver 修订为正式 Plan；若 family 或必需 Characteristic 不匹配，在任何激活写入前 fail closed。

**Tech Stack:** Swift 5、CoreBluetooth、现有 `FujifilmCompatibilityEnvironment`、`CameraConnectionExecutionState`、XCTest `RunnerTests`。

---

### Task 1: 固定动态分支基线

**Files:**
- Inspect: Git branch and ancestry only

- [ ] 确认 HEAD 为 `origin/main@0dcec690`。
- [ ] 确认 `4a2b60bd` 是 HEAD 的祖先。
- [ ] 确认工作树在测试修改前干净。

### Task 2: 增加 remembered endpoint 回归测试

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] 新增纯 Resolver 测试：`bleEndpointEvidence=.rememberedPairedPeripheral`、`compatibilityFamily=nil`、广告包含未分类 `804D...`、无 GATT Characteristic 时，应得到 verified BLE-only Plan。
- [ ] 断言初始 Plan 只保留当前 pairing/activation 定义，PTP、negotiation、gallery bootstrap 和 initial catalog 仍为 unsupported。
- [ ] 新增 Loader 测试：同样的初始 facts 必须真正调用 `performBleConnection`；返回不匹配的 GATT facts 时必须在生成写入前失败。
- [ ] 运行两个新测试并确认它们因当前 fallback 的 `advertisedServices.isEmpty` 限制而失败。

### Task 3: 最小修复动态 bootstrap

**Files:**
- Modify: `ios/Runner/CameraAdapters/Fujifilm/FujifilmCompatibility.swift`

- [ ] 将 remembered endpoint fallback 从“endpoint 且广告为空”收窄为“endpoint 且尚无 GATT Characteristic”。
- [ ] 不根据型号、RSSI、候选数量或未知 Service 推断正式 compatibility family。
- [ ] 不改变正式 GATT rule、activation write、Wi-Fi、PTP 或 Catalog 行为。
- [ ] 重新运行新测试并确认通过。

### Task 4: 回归验证

**Files:**
- Verify: `ios/RunnerTests/RunnerTests.swift`
- Verify: iOS project build

- [ ] 运行 remembered compatibility、Loader、Plan revision 定向测试。
- [ ] 运行完整 `RunnerTests`，记录实际执行数和失败数。
- [ ] 运行 iPhoneOS generic build。
- [ ] 运行 `git diff --check` 并检查最终 diff 仅包含计划、测试和 fallback 修复。
- [ ] 明确自动化不能替代 X-T5/X-M5 的真机 `GalleryReady` 证明。
