# 故障排查：hs1 实测断网问题（已修复）

## 现象

刷入 `v2.7.0-hs1` 后，手机状态栏显示有网，但 EasyTier 一个 peer 都连不上，
`log.log` 里持续刷屏（5 分钟 864 条）：

```
tun device ready dev="tun0"
connect to peer error dst="tcp://225284.xyz:11010"
    context: "contextual hickory lookup_ip failed, host: 225284.xyz"
    kind: Io(Os { code: 101, kind: NetworkUnreachable })
connect to peer error dst="tcp://et.sumnight.top:11010"   ... 同上
connect to peer error dst="tcp://et1.fuis.top:11010"      ... 同上
```

注意关键点：失败发生在 **DNS 解析阶段**（`lookup_ip failed`），三个 peer 域名全军覆没，
而 tun 设备、监听端口（tcp/udp 11010、wg 11011）都正常建立了。
说明**不是** TPROXY 冲突，也**不是**热点规则问题，而是 easytier 自身的 socket 出不去。

## 根因

`hs1` 的 `coexist.sh` 无条件给 easytier-core 加了 `--socket-mark 20052`，
然后加规则：

```sh
ip rule add pref 80 fwmark 20052 lookup main     # ← 错在这里
```

**Android 的 `main` 路由表通常是空的。** 默认路由由 netd 放在以网卡名命名的表里
（`wlan0` / `rmnet_data0` / `ccmni0` …），而 netd 的路由规则全都匹配
`fwmark 0x0/0xffff`——**只对未打标记的包生效**。

于是带 `SO_MARK=20052` 的包走的是：

```
pref 80    : fwmark 0x4e54 lookup main      → 命中，但 main 表没有路由
pref 16000 : from all fwmark 0x0/0xffff lookup wlan0   → 不匹配（包有标记）
pref 32000 : from all unreachable           → 命中 = ENETUNREACH(101)
```

连 UDP DNS 查询都被这一条打死，所以 `hickory lookup_ip` 全部失败。

### 本地复现（netns 模拟 Android 路由结构）

```
[A] 未打标记 route get          : 通
[B] 标记 20052，无规则          : Network is unreachable
[C] pref80 fwmark 20052 lookup 1001（hs2 做法）: 8.8.8.8 via 192.168.1.1 dev wlan0 table 1001
[D] pref80 fwmark 20052 lookup main（hs1 做法）: Network is unreachable   ← 与真机日志一致
[E] 再加 netd 兜底 32000 unreachable           : Network is unreachable   ← 完整复刻
```

## 修复（v2.7.0-hs2）

### 1. fwmark 规则指向"确实有默认路由的物理表"

`route_table_for_mark()` 三级降级探测：
1. `ip route get 8.8.8.8` 拿到真实出口网卡，再看 `ip route show table <网卡名>` 有无 `default`
2. 扫所有表找带默认路由且 dev 是物理网卡的那张（部分 ROM 用数字表 1001/1002）
3. 最后才回退 `main`（桌面 Linux）

### 2. 加完规则立刻实测，通不过就撤销（最关键）

```sh
ip route get 8.8.8.8 mark 20052     # 返回 unreachable 就判定失败
```

- `apply_rules()`：加规则 → 立刻 verify → 失败就 `flush_mark_rules` 并放弃共存
- `build_extra_args()`：**启动 easytier 之前**再 verify 一次，
  不通过就**不带 `--socket-mark`** 启动

即：宁可放弃 TPROXY 共存，也绝不让手机断网。

### 3. 默认关闭，需显式开启

`config/coexist.conf` 里新增 `COEXIST_ENABLE=0`。
只填 `ET_SOCKET_MARK` 不会生效，必须同时设 `COEXIST_ENABLE=1`。

### 4. 升级自愈

`apply_rules()` 一进来就 `flush_mark_rules`（按 hex mark 扫所有 `ip rule`），
所以从 hs1 升级上来时，那句有害的 `fwmark 0x4e54 lookup main` 会被自动清掉，
不需要手动执行任何命令。

### 5. 附带修复

- `log.log` 不再被 core 输出冲掉：core 改写到 `core.log`，超过 1MB 自动清空。
  之前 `> "${LOG_FILE}"` 每次启动都截断，导致 `[ET-NAT]`/`[ET-COEXIST]` 记录全丢。
- `hotspot_iprule.sh del` 现在会连 `POSTROUTING -j ET_NAT` / `FORWARD -j ET_FWD`
  钩子一起删（`clean_rules()`），不再留空链占位。
- 未开启 `enable_IP_rule` 时不再往 `POSTROUTING`/`FORWARD` 插钩子。
- `uninstall.sh` 卸载时主动清干净 iptables 链和 fwmark 规则。

## 验证记录

| 项目 | 结果 |
|---|---|
| 静态语法（9 个脚本 + update-binary） | 全部通过 `sh -n` |
| `coexist.sh table` 在模拟 Android 表结构下 | 正确返回 `1001` |
| `apply` 后 `ip route get mark` | 通（`via 192.168.1.1 dev wlan0 table 1001`） |
| `apply` 连跑 3 次 | `ip rule` 恒 1 条，PREROUTING/OUTPUT 跳转各恒 1 条 |
| hs1 残留 `lookup main` 规则被 apply 清理 | 通过，且不新建规则（COEXIST_ENABLE=0） |
| 热点 `add_once` + 连跑 3 次 | `ET_NAT` 恒 1 条，`ET_FWD` 恒 2 条 |
| 热点关闭时不建 NAT 但 `ip_forward` 仍被置 1 | 通过（证明 `ensure_sysctls` 在 `return` 之前） |
| `hotspot_iprule.sh del` | `ET_NAT`/`ET_FWD` 链与钩子全部消失 |

> 仍未在真实 Android 设备上跑端到端。上机后先看 `core.log`：
> - 若仍有 `NetworkUnreachable`，说明该 ROM 的表结构与探测逻辑不符，
>   把 `ip rule show` 和 `ip route show table all` 的输出发出来即可定位；
> - 若看到 `[ET-COEXIST] ... 路由校验未通过`，说明共存已被自动降级，
>   网络本身不受影响，TPROXY 共存需按该 ROM 的实际表名调整。
