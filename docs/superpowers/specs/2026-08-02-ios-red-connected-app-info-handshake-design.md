# iOS RED Connected Application Information 握手终态设计

## 背景与故障边界

GFX100RF 已完成 BLE 重连、相机热点启动、手机加入相机 Wi-Fi，并成功建立到 `192.168.0.1:55740` 的 TCP 连接。失败发生在 PTP/IP Open：CamTransfer 发出 82 字节 `INIT_COMMAND_REQUEST` 后，相机没有返回 68 字节 `INIT_COMMAND_ACK`。

官方 XApp 对暴露 `8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7`（Connected Application Information）的相机，会在连接设备名称和识别号步骤之后写入 `80 01 01`，并在该写入成功后才继续连接准备。当前 iOS 实现发现了这个特征，但未把它注册成握手步骤；识别号 ACK 成功后便允许已配对相机进入传图准备。诊断日志同时记录了 `paired=true handshakeDone=false`。

本设计修复的是 BLE 握手完成条件，不修改 PTP/IP INIT 格式，不以 X-T5 或 GFX100RF 作为协议标准。

## 目标

- 以相机实际暴露的 BLE 特征生成必需握手步骤。
- 当 `8B5ECF55` 存在时，写入 `80 01 01` 并等待 CoreBluetooth write response。
- 所有必需 BLE 步骤完成后，才允许进入 Wi-Fi 传图激活。
- 新配对和已记住相机重连复用同一套能力步骤与完成门槛。
- 不暴露 `8B5ECF55` 的相机保持现有连接行为。
- 失败发生在 BLE 层时给出明确错误，不再进入 Wi-Fi/PTP 后无限等待。

## 非目标

- 不新增按 `GFX100RF`、`X-T5`、`X-S20` 等型号名称分支。
- 不把应用身份写入放进 `.currentBaseline` Profile。
- 不修改现有 82 字节 PTP/IP INIT 包、GUID 生成或 68 字节 ACK 解析。
- 不根据当前只有常量、没有 XApp 调用证据的 `EB4166B0` 增加协议步骤。
- 不处理当前基线中 `Info.plist` 后台定位声明与测试预期不一致的问题。

## 架构方案

### 1. 能力描述

在 BLE 握手策略层增加 Connected Application Information 能力描述，而不是在 `CameraVendorBluetoothService` 中写机型判断。

输入：

- 当前连接发现的 characteristic UUID 集合。
- 当前握手阶段和连接 generation。

输出：

- 是否要求 Connected Application Information 写入。
- 固定兼容负载 `80 01 01`。
- 写入成功、失败和超时后的下一状态。

能力判定规则：

- 存在 `8B5ECF55`：该写入是本轮握手的 required step。
- 不存在 `8B5ECF55`：不生成该步骤，原路径不增加等待。

### 2. 单一握手所有者

`CameraVendorBluetoothService` 继续负责 CoreBluetooth 特征发现和真实 write request，但握手完成决策由统一的纯策略/协调器持有。

识别号 ACK 成功后不再直接执行 `handleIdentifierWriteCompletion()`。统一流程为：

```text
ConnectedDeviceName write ACK
→ IdentificationNumber read/write ACK（相机要求时）
→ ConnectedApplicationInfo write 80 01 01（特征存在时）
→ 所有 required steps ACK
→ handleIdentifierWriteCompletion
→ pairing/reconnect route
→ transfer activation
```

新配对和已记住重连只允许在配对结果路由上不同，不允许复制两套 Connected Application Information 逻辑。

### 3. 状态语义

`HandshakeComplete` 只代表 BLE 连接所需步骤全部完成，不能由 AP `Launched(0x8001)` 或其他传图状态反向补齐。

状态边界：

```text
BLEHandshakeComplete
→ TransferAuthorization
→ ActivateCameraWifi
→ WaitCameraWifiReady
→ JoinCameraWifi
→ ConnectPtp
```

当 `8B5ECF55` 存在时，在收到对应 write response 之前：

- `didCompleteHandshakeCallback` 必须保持 `false`。
- 不允许调用传图激活计划。
- 不允许保存“本轮握手已经完整”的状态。

### 4. 并发与生命周期

- 每个连接 generation 最多发送一次 Connected Application Information 写入。
- 只接受当前 peripheral、当前 generation、当前 pending characteristic 的 write callback。
- 断开、取消、切换相机或新 generation 开始时，清理 pending step 和 timeout。
- 重复 callback 不得二次完成握手或二次启动 AP。
- timeout 和 CoreBluetooth write error 都终止本轮握手，不降级为“继续尝试 PTP”。

## 错误处理与诊断

新增结构化日志：

```text
BLE_APP_INFO_REQUIRED uuid=8B5ECF55...
BLE_APP_INFO_WRITE_REQUEST payload=800101 generation=<n>
BLE_APP_INFO_WRITE_ACK result=success generation=<n>
BLE_APP_INFO_WRITE_FAILED reason=<error|timeout> generation=<n>
BLE_HANDSHAKE_GATE required=<steps> completed=<steps> result=<waiting|complete|failed>
```

用户可见失败提示应说明“相机应用握手失败，请重新连接；若持续失败请清除旧配对后重新配对”，不显示 PTP 超时作为首因。

## 测试设计

实现必须遵循 RED → GREEN：先新增失败测试，确认当前代码无法满足，再写生产代码。

### 纯策略测试

- 有 `8B5ECF55` 时生成 `80 01 01` required step。
- 无 `8B5ECF55` 时不生成新步骤。
- payload 精确为 3 字节 `80 01 01`。
- required step 未 ACK 时握手不可完成。
- write ACK 后只完成一次。
- write error、timeout、旧 generation callback 都不能放行。

### 状态机与源码边界测试

- 识别号 ACK 后，若应用身份步骤未完成，不调用 `handleIdentifierWriteCompletion()`。
- 已记住重连与新配对使用同一能力策略。
- AP 激活不会发生在 BLE 握手门槛之前。
- `.currentBaseline` 不承载 BLE 应用身份协议。
- 不出现相机型号名称硬编码。

### 回归验证

- 运行新增 focused tests。
- 运行全部 `RunnerTests`，将结果与 2026-08-02 分支基线比较。
- 当前分支基线为 1092 tests、3 failures；既有失败均来自 `Info.plist` 后台定位声明测试，本任务不扩大该失败集合。
- 执行 iPhoneOS build，证明真机目标可编译。

## 实机验收

### GFX100RF

修复后清除 CamTransfer 和相机端旧配对，再重新配对：

1. 日志发现 `8B5ECF55`。
2. 名称/识别号后出现一次 `BLE_APP_INFO_WRITE_REQUEST payload=800101`。
3. 收到 write ACK 后才出现 `BLEHandshakeComplete` 和 AP 激活。
4. TCP 连接后，82 字节 PTP INIT 收到 68 字节 ACK。
5. OpenSession 成功并进入图库加载。

### 不暴露该特征的已验证相机

至少选择一台当前可正常连接的相机：

1. 不产生 `BLE_APP_INFO_WRITE_REQUEST`。
2. 原有 BLE → Wi-Fi → PTP 顺序保持成功。
3. 图库加载和下载主链路不回归。

## 完成标准

- 没有型号特判或第二套握手实现。
- 特征存在时写入并等待 `80 01 01` ACK；特征不存在时原流程不变。
- BLE 握手未完成不能启动 AP。
- focused tests 通过，完整 `RunnerTests` 不新增失败，iPhoneOS build 成功。
- GFX100RF 实机收到 68 字节 PTP INIT ACK 并完成 OpenSession；在此之前只能称为代码修复完成，不能称为故障已实机闭环。
