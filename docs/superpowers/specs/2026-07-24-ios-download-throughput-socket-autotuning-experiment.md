# iOS 下载吞吐量 Socket Autotuning 实验报告

## 1. 实验背景

- iOS CamTransfer 下载速度长期在 2.7-3.5 MiB/s
- 同一台手机的 XApp 可达 10-17 MiB/s  
- Android CamTransfer 也很快
- 历史上尝试过调整 SO_RCVBUF 大小（4 MiB 更慢）、D226、D235、chunk size 等，均无效

## 2. 根因发现

调用 `setsockopt(SO_RCVBUF)` 本身（无论值是多少）会关闭 Darwin/XNU 内核的 TCP receive autotuning 机制。

- 内核 autotuning 被禁用后：TCP 窗口和 ACK 策略固定不变
- 相机 WiFi 模块在固定窗口下进入 burst-pause 数据产出模式
- 产出 100-900ms 的数据空洞，导致吞吐降到 3 MiB/s

XApp 使用 NWConnection（Apple Network.framework），从不直接操作 socket options，内核全权管理 TCP 行为。

## 3. 实验矩阵与结果

### 3.1 Socket Buffer Profile 对比（同一天、同一设备、同一相机）

| Profile | SO_RCVBUF 值 | 稳定速度 | 首个 RAW |
|---------|-------------|----------|---------|
| production | 2 MiB (显式) | 2.7-3.5 MiB/s | 2.7-3.5 |
| xapp-window-match | 256 KiB (显式) | 2.7-3.2 MiB/s | 2.97 |
| kernel-autotuning | 不调用 setsockopt | **7-11 MiB/s** | **6.5-7.5** |

### 3.2 TCP_NODELAY 实验

| 配置 | 结果 |
|------|------|
| TCP_NODELAY=enabled (保留) | 7-11 MiB/s ✅ |
| TCP_NODELAY=disabled | 5-6.5 MiB/s ❌ 更差 |

结论：TCP_NODELAY 应保留。PTP 是命令/响应协议，需要低延迟命令发送。

### 3.3 SO_RCVTIMEO 实验

| 配置 | 结果 |
|------|------|
| 不设 SO_RCVTIMEO (用 poll) | 7-11 MiB/s ✅ |
| 设 SO_RCVTIMEO (去掉 poll) | 首批快(10+)，后续掉到 4.7 ❌ |

结论：连接后对 socket 调用任何 setsockopt 都可能干扰内核 TCP autotuning。

### 3.4 QoS 提升实验

在 readExactlyToFile 的 recv 循环中提升线程到 QOS_CLASS_USER_INTERACTIVE。

| 配置 | 结果 |
|------|------|
| .userInitiated (原始) | 7-8 MiB/s |
| QOS_CLASS_USER_INTERACTIVE | 7-11 MiB/s，峰值更容易达到 |

## 4. 最终生产配置

```swift
// 连接前设置（safe）
TCP_NODELAY = 1

// 不调用（关键！）
// setsockopt(SO_RCVBUF) — 会关闭 TCP autotuning
// setsockopt(SO_SNDBUF) — 同上
// setsockopt(SO_RCVTIMEO) — 连接后调用会干扰 autotuning

// recv 线程 QoS
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
```

## 5. 当前验证结果（4 轮 fresh session）

| 轮次 | 文件数 | 速度范围 | 平均 |
|------|--------|----------|------|
| 1 | 11 | 6.48-10.42 | 8.4 MiB/s ✅ |
| 2 | 4 | 3.63-4.02 | 3.8 MiB/s ❌ (相机 epoch) |
| 3 | 5 | 6.35-8.20 | 7.6 MiB/s ✅ |
| 4 | 4 | 7.54-11.35 | 10.2 MiB/s ✅ |

4 轮中 3 轮稳定快速（7-11 MiB/s），1 轮出现相机 producer epoch 退化。

## 6. 未解决的问题

1. **相机 producer epoch 退化**：4 轮中仍有 1 轮回到 3.8 MiB/s，这不是 socket 配置问题，是相机固件侧的动态状态。需要通过分支 A/B（PTP 命令序列实验）进一步定位。

2. **前台 vs 后台差异**：后台下载可达 11-13 MiB/s，前台稳定在 7-9 MiB/s。差距可能来自 iOS 系统级 WiFi 省电策略或 UI 渲染对 CPU 调度的影响。

3. **与 XApp 的剩余差距**：XApp 稳定 10-17 MiB/s，当前最优前台 7-11 MiB/s。完全弥合可能需要迁移到 NWConnection（Apple Network.framework）。

## 7. 核心洞察

**对 PTP socket 的黄金规则：connect() 之后不要调用任何 setsockopt。**

Darwin 内核的 TCP autotuning 机制会根据链路 RTT 和吞吐动态调整窗口大小和 ACK 策略。一旦 userspace 调用 setsockopt（无论是 SO_RCVBUF、SO_SNDBUF 还是 SO_RCVTIMEO），内核认为 "userspace 想自己管理"，于是关闭动态调优，TCP 行为固定化。

在相机 WiFi 这种特殊环境下（嵌入式固件 TCP 实现、直连无路由器、<1ms RTT），内核的动态调优算法比任何固定值都更能适应相机的数据产出节奏。

## 8. Debug 参数参考

```
# 回退到旧的 2 MiB buffer（用于对照）
--camtransfer-debug-socket-buffer=production

# 256 KiB buffer（模拟 XApp 窗口，已证无效）
--camtransfer-debug-socket-buffer=xapp-window-match

# 64 KiB 极小 buffer
--camtransfer-debug-socket-buffer=minimal

# 禁用 TCP_NODELAY（已证更差）
--camtransfer-debug-tcp-nodelay=disabled
```

## 9. 后续优化方向

| 优先级 | 方向 | 预期效果 |
|--------|------|----------|
| 1 | 下载时暂停 BLE connection | 释放 2.4GHz 射频时隙给 WiFi |
| 2 | 减少下载间 Gallery PTP 命令 | 避免 producer epoch 退化 |
| 3 | 迁移到 NWConnection | 完全匹配 XApp 的网络栈行为 |
