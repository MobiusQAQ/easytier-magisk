# EasyTier Magisk 改造版（多网络并行 + 热点共享内网 + TPROXY 共存）

基于官方 `EasyTier/EasyTier` 的 `easytier-contrib/easytier-magisk` v2.7.0 改造。
核心二进制未做任何改动，只补脚本层缺失的能力。

> ## 💻 v2.7.0-hs7：终端 peer 状态一键查看与全局 CLI 工具
>
> 解决终端中无法直接执行 `easytier-cli peer` 或多网络实例下端口需手动指定的痛点：
>
> 1. **系统全局终端命令 (`/system/bin/easytier-cli` & `easytier`)**：
>    - 模块自动挂载到 `/system/bin`，任何终端（Termux、MT 管理器终端、ADB Shell）执行 `su` 后可直接运行 `easytier-cli` 或 `easytier`。
> 2. **智能多实例聚合展示**：
>    - 运行 `easytier-cli peer`（或快捷别名 `easytier peer`），自动识别所有并行运行的网络实例，逐一展示各实例网卡、虚拟 IP、RPC 端口及对应加入了的 Peer 节点表格（类似原版单机输出）。
>    - 支持通过 `-i <实例名>` 仅查看某个特定实例（如 `easytier peer -i work`）。
> 3. **实例运行概览总览**：
>    - 运行 `easytier status`，一行表格直观显示所有网络实例的网卡、虚拟 IP、RPC 端口、PID 和在线 Peer 连接数。
> 4. **免重启现场查看**：
>    - 支持直接执行 `/data/adb/modules/easytier_magisk/action.sh peer` 现场查看。
>
> ## 🔧 v2.7.0-hs6：蜂窝日志根因修复 + 诊断排查套件 (Debug 版)
>
> 结合现场日志快照全面修复以下问题，并提供一键诊断套件：
>
> 1. **修复域名 peer 解析超时（DNS Resolve Timeout）**：
>    - **根因**：原 `ensure_dns_rules` 依赖 `unbound_can_route` 探测，而 Android netd 默认给 root 的 `iif lo` 开放了具名表回退，导致脚本误判未绑定 socket 可以出网，跳过了 DNS 放行规则。结果 `easytier-core` 内部 `hickory-dns` 发送的 UDP 报文落入 netd unreachable，域名 peer 频繁报 `resolve timeout after 2s`。
>    - **修复**：去除误判前置条件，并重写 `route_table_for_egress`，精准提取出口网卡（排除 `dummy0`）绑定的具名路由表号，稳定添加 `ip rule pref 79 to <dns>/32 lookup <表号>`。
>
> 2. **修复高通 DBS / 新版 Android 热点网卡识别失效**：
>    - **根因**：在双 WiFi / DBS 机型（如 Redmi K60 等）上，热点 AP 网卡为 `wlan2` 或 `wlan1`，原正则仅匹配 `swlan*/softap*/ap*`，导致热点网卡匹配为空，未能开启 NAT 转发与 `rp_filter=2`。
>    - **修复**：优先从 Android netd 自身的策略路由（`from all iif <dev> lookup <tbl>`）智能逆向提取真实热点网卡，备选正则扩展支持 `wlan[1-9]*`。
>
> 3. **多实例守护性能重构（切网重启从 3 分钟缩短至 2 秒）**：
>    - **根因**：原 `pids_for_config` 在每轮检查中遍历 `/proc/[0-9]*/cmdline` 派生数千个 `tr` 子进程，造成巨大 CPU 负载与 20 秒/实例的启动延迟。
>    - **修复**：引入 `.pid-*` 快速校验，命中即 O(1) 返回，消除进程扫描卡顿。
>
> 4. **后台防杀与防冻结保护**：
>    - 为每个 `easytier-core` 进程写入 `oom_score_adj = -1000` 并加入前台 `cpuset`，防止在 MIUI/HyperOS（millet_kernel）等激进后台策略下被挂起或杀死。
>
> 5. **SELinux 审计风暴静音**：
>    - 在 `service.sh` 中对 `ioctl(SIOCGIFINDEX)` 注入 `dontaudit`，彻底解决内核日志中数千万条 audit 溢出与系统卡顿问题。
>
> 6. **现场诊断与 Debug 版本**：
>    - 运行 `dump_debug.sh`（或执行 `action.sh dump`）一键抓取网络、路由、iptables、进程与日志，脱敏后自动打包至 `/sdcard/easytier_debug.tar.gz`；
>    - 支持 `action.sh debug` 动态切换调试日志（注入 `RUST_LOG=debug,easytier=trace`）；
>    - `./build.sh` 现已支持一键编译 Release 版与内置 Debug 开关的 Debug 版。

> ## 🔧 v2.7.0-hs5：修复「peer 连上了但 ping 不通 10.10.0.x」
>
> 新增一条策略路由规则，让 App 能访问 mesh 虚拟网段：
>
> ```
> ip rule add pref 1000 to <mesh-cidr> lookup main
> ```
>
> **为什么需要**：Android netd 的规则普遍带 `uidrange 0-0` 或 `iif lo` 限定，
> 而普通 App（Termux、浏览器）发出的包带 netId fwmark（如 `0x10064`），
> 既不是 uid 0、也不带 oif，匹配不到任何具名表规则，
> 一路落到 `32000: from all unreachable`。所以 `ping 10.10.0.2` 直接
> `Network is unreachable`，`et0` 的 TX 计数器几乎不增长（包根本没进 tun）。
>
> 实测判据（内核路由查找最准）：
>
> ```
> ip route get 10.10.0.1              -> 10.10.0.1 dev etC src 10.10.0.3 uid 0
> ip route get 10.10.0.1 mark 0x10064 -> Network is unreachable   ← App 的真实遭遇
> # 加规则后
> ip route get 10.10.0.1 mark 0x10064 -> 10.10.0.1 dev etC src 10.10.0.3
> ping 10.10.0.1 -> 3 received, 0% packet loss
> ```
>
> **安全约束**：只有该网段在 main 表里确实指向 `et*` 设备时才加规则。
> 物理内网恰好与 mesh 同段（例如都是 `10.10.0.0/24`）时会**跳过**，
> 避免把真实内网流量导进隧道。
>
> 关闭开关：`touch disable_mesh_route`。
>
> 同版还修了两处：
> - `bind_device` 改为**默认开启**（原来只在启动时探测，启动时网络好就不加了，
>   结果切网后所有 peer 掉线再也连不回来）；
> - 新增**默认出口网卡变化检测**，WiFi ↔ 移动数据切换时自动重启实例；
> - `ET-NAT` 日志去重，不再被 30 条 `Custom chains flushed` 刷屏。

> ## 🔧 v2.7.0-hs4：修复"本机有网但 easytier 连不上任何 peer"
>
> 如果你的 `core-*.log` 里刷着这样的内容，而手机上网完全正常：
>
> ```
> hickory dns lookup_ip failed, host: xxx.xyz
> Os { code: 101, message: "Network unreachable" }
> ```
>
> 根因是 Android netd 的路由规则形如
> `19000: from all iif lo oif wlan0 uidrange 0-0 lookup wlan0`，
> 带 **`oif <物理网卡>`**，只匹配**已绑定该网卡**的 socket。
> easytier 的 `--bind-device` 只覆盖隧道 socket，**DNS 解析用的 socket 没被绑定**，
> 于是 DNS 查询落到 `32000: from all unreachable` → `ENETUNREACH(101)`。
> 用域名做 peer 时，一个都连不上；用 IP 做 peer 则正常。
>
> hs4 的修复（自动化，无需配置）：
> 1. 检测「未绑定 socket 能否出网」，不能则自动加 `--bind-device true`；
> 2. 给配置里的 DNS 服务器加 `ip rule pref 79 to <dns>/32 lookup <物理表>`，
>    只放行 DNS，其它流量不受影响；
> 3. 网络正常时**完全不动**系统路由表（已实测：无任何多余规则）。
>
> 手动关闭：`touch disable_bind_device` / `touch disable_dns_rule`。
>
> 同一版还修了一个更危险的隐患：`ET_SOCKET_MARK` 若为空/0/非数字，
> 旧版 `mark_hex` 会退化成 `0x0`，`flush_mark_rules` 就会误删 netd 的
> `16000: from all fwmark 0x0/0x10000 lookup main` —— 那是 Android 的基础路由，
> 删掉等于整机断网。现在 mark 非法时直接不启用共存，且拒绝删除带
> `uidrange`/`iif`/`oif` 特征的规则。

> ## 🆕 v2.7.0-hs3：同时跑多份配置（多个网络并行）
>
> 把多个 `.toml` 放进 `config/networks/`，**每个文件一个独立网络实例**，
> 各自独立进程、独立 tun、独立日志、独立崩溃重启。
>
> ```bash
> cd /data/adb/modules/easytier_magisk/config/networks
> cp example-main.toml.example main.toml   # 家里网
> cp example-work.toml.example work.toml   # 公司网
> vi main.toml work.toml                   # 填 network_name/secret/peer
> echo main > ../hotspot_instance          # 指定 main 做热点出口
> ```
>
> 详见 [多网络并行](#多网络并行v270-hs3-新增) 与
> [`config/networks/README.md`](./config/networks/README.md)。
>
> **向后兼容**：`config/networks/` 里没有 `.toml` 时，自动回退到单实例
> `config/config.toml`，行为与 hs2 完全一致。升级不会改变你现有配置。

> ## ⚠️ v2.7.0-hs2 紧急修复（如果你刷过 hs1，请务必升级）
>
> **hs1 会导致整机断网**：easytier 一个 peer 都连不上，`log.log` 里刷屏
> `lookup_ip failed ... NetworkUnreachable code 101`。
>
> 根因：hs1 无条件给 easytier 加 `--socket-mark`，并把它路由到 `main` 表。
> 但 **Android 的 main 表通常是空的**，默认路由在 netd 以网卡名命名的表里，
> 且 netd 规则只匹配 `fwmark 0x0/0xffff`（未打标记的包）。于是带标记的包
> 一路落到 netd 的 `32000: from all unreachable` => `ENETUNREACH(101)`，
> 连 DNS 都发不出去。
>
> hs2 的修复：fwmark 规则改指向"确实有默认路由的物理表"，且**加完规则立刻
> 用 `ip route get 8.8.8.8 mark <n>` 实测，通不过就撤销并让 easytier
> 以不带 mark 的方式启动**。共存功能同时改为默认关闭（`COEXIST_ENABLE=0`）。
> 详细复盘见 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)。
>
> 从 hs1 升级时无需手动清理，`coexist.sh` 启动时会自动清掉历史遗留的
> `fwmark ... lookup main` 规则。

## 本次补齐的三件事

官方模块有两个缺口，导致"开热点让其它设备连内网"实际不可用：

### 1. 内核转发开关从未被设置

官方 `hotspot_iprule.sh` 只加 iptables 规则，**从没执行过 `ip_forward=1`**。
Android 上 `ip_forward` 默认可能为 0，此时热点设备的包到手机就被内核丢弃，
后面 MASQUERADE/FORWARD 写得再对也没用。

本版新增 `ensure_sysctls()`：

```sh
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 2 > /proc/sys/net/ipv4/conf/<iface>/rp_filter   # loose 模式
echo 1 > /proc/sys/net/ipv4/conf/<iface>/forwarding
```

⚠️ 关键修复点：`ensure_sysctls()` 被移到 `set_nat_rules()` 的**最前面**。
若留在 `return 1`（热点未开）之后，热点后开时 sysctl 永远不会执行。

`rp_filter` 用 `2`（loose）而非 `1`（strict）：tun 是点对点设备，回程路由不对称，
strict 模式会丢弃来自 tun 的回包。

### 2. 热点网段没有导出进 mesh

`--proxy-networks` 决定哪些本地网段能被 mesh 里其它节点访问。官方要求手动在
`config.toml` 写死 cidr，热点网段（各家 ROM 不同：192.168.43.x / 192.168.1.x /
192.168.232.x）一变就失效。

本版自动探测并合并：

- `probe_cidrs()` 探测 `ap*/swlan*/softap*/p2p-wlan*` 与 `usb*/rndis*/eth*` 接口网段，
  写入 `.hotspot_cidr`。
- `build_extra_args()` 启动时把探测到的网段 + 用户自己写的 `proxy_networks`
  **合并**后通过 `--proxy-networks` 传入。注意 CLI 参数会整体覆盖配置文件，
  所以必须合并，不能只传热点网段。
- 热点开关导致网段变化时写 `.restart_easytier`，让守护循环以新参数重启主程序。
  效果：开热点后免手动改配置、免重启手机。

### 3. 规则不幂等（会累积）

官方 `set_nat_rules()` 每被调用一次就 `-A` 追加一条 MASQUERADE。
热点反复开关（`ip monitor link` 每次触发）会累积出成百条重复规则。

本版在追加前先 `-F ET_NAT` / `-F ET_FWD`（仅自定义链，安全），保证幂等。
实测三轮刷新，每轮规则数恒为 1。

## 多网络并行（v2.7.0-hs3 新增）

### 目录结构

```
config/
├── networks/                     ← 每个 *.toml 一个独立网络实例
│   ├── main.toml                 （家里网）
│   ├── work.toml                 （公司网）
│   └── README.md
├── hotspot_instance              ← 哪份配置做热点出口（写实例名）
├── config.toml                   ← 单实例兼容（networks/ 为空时才用）
└── coexist.conf
```

只有 `.toml` 结尾的文件会被加载。仓库自带的 `*.toml.example` 只是模板，不会被启用。

### 实现方式：多进程

每份配置拉起一个**独立的 `easytier-core` 进程**（不是 `--config-dir` 单进程多实例）。

选择多进程而非 `--config-dir` 的原因，来自实测：

| | 多进程（本版采用） | `--config-dir` 单进程 |
|---|---|---|
| 热点网段自动注入 | ✅ 每个实例可独立传 `--proxy-networks` | ❌ **全局 CLI 参数被完全忽略** |
| 崩溃隔离 | ✅ 一个挂了不影响其它 | ❌ 一份坏配置中断整个加载循环 |
| 日志 | ✅ `core-<实例名>.log` 各自独立 | ❌ 混在一起 |
| 内存 | 约 56 MB × 实例数 | 共享，更省 |

`--config-dir` 模式下 `--socket-mark`、`--proxy-networks` 等 CLI 参数**全部失效**，
只能写死在文件里，这与"开热点后自动注入网段、免改配置免重启"的核心特性冲突，
因此排除。

### 模块自动补全的字段

写不写都行；不写时模块在**启动参数**里注入（**不会修改你的 toml 文件**）：

| 字段 | 缺省时自动取值 |
|---|---|
| `dev_name` | `et0`、`et1`…（自动避开已被占用的名字） |
| `instance_name` | 文件名（去掉 `.toml`） |
| `rpc_portal` | `127.0.0.1:1588<序号>` |
| `hostname` | 设备型号 |

### 必须自己保证不冲突的字段

这几项模块**不会**替你改（改了会破坏你的意图），冲突会导致实例起不来：

| 字段 | 冲突后果 |
|---|---|
| `listeners` 端口 | 后者 `failed to listen` |
| `ipv4` 网段 | 路由冲突 |
| 手写的 `dev_name` | `Resource busy (os error 16)` |
| 手写的 `instance_name` | 后者**静默失败**，无报错 |
| 手写的 `rpc_portal` | 后者的 RPC 不可用 |

### 热点出口只走一个实例

`config/hotspot_instance` 里写实例名：

```bash
echo main > /data/adb/modules/easytier_magisk/config/hotspot_instance
```

只有这个实例会被注入热点网段（`--proxy-networks`），其它实例不参与热点转发。
留空则默认取文件名排序第一的实例。

这样一个热点只有一条确定的出口路径，避免多出口造成路由歧义。

### 状态查看（终端命令行）

现在可在任何终端（Termux / MT 管理器 / ADB Shell）获得类似原版 `easytier-cli` 的完整体验：

```bash
# 1. 查看所有实例加入的 Peer 节点状态（自动聚合多网络实例）
easytier-cli peer
# 或快捷别名：
easytier peer

# 2. 仅查看指定实例的 Peer 状态
easytier peer -i default
easytier peer -i work

# 3. 查看模块所有网络实例运行总览表（网卡、虚拟 IP、RPC 端口、PID、Peer 数量）
easytier status

# 4. 查看所有实例的路由表与本地节点信息
easytier-cli route
easytier-cli node

# 5. 免重启现场查看（如刚更新模块尚未重启手机）
/data/adb/modules/easytier_magisk/action.sh peer

# 6. 单实例精确查询或自定义 RPC 地址（完全兼容原生 CLI 参数）
easytier-cli -p 127.0.0.1:15880 peer
```

模块描述会实时显示 `运行中 N/M 个实例`。

## TPROXY 共存（可选，**默认关闭**）

`coexist.sh` + `config/coexist.conf`。原理基于 v2.7.0 二进制自带的参数：

- `--socket-mark <n>`：给 easytier 底层 socket 打 `SO_MARK`。
- `ip rule add pref 80 fwmark <n> lookup <物理网卡表>`：让带标记的包绕过代理 tun 直连。

同时给 mesh 网段、热点网段、easytier 监听端口在 mangle 链首放行，避免被代理劫持。

### 开启方式

编辑 `config/coexist.conf`：

```sh
COEXIST_ENABLE=1      # 改成 1 才真正启用
ET_SOCKET_MARK=20052
MAIN_RULE_PREF=80
```

然后重启模块（Magisk 里禁用 → 启用）。

### 为什么需要那层"路由实测护栏"

这是 hs2 最重要的改动。`coexist.sh` 在加完 fwmark 规则后会立刻执行：

```sh
ip route get 8.8.8.8 mark 20052
```

- 返回 `unreachable` → 说明这条规则指向的表出不去网，**立即撤销规则**并放弃共存；
- `easytier_core.sh` 在启动主程序前还会再验一次，不通过就**不带 `--socket-mark` 启动**。

**宁可放弃共存，也绝不让手机断网。** 这是 hs1 的教训。

`route_table_for_mark()` 的表探测是三级降级：
1. `ip route get 8.8.8.8` 拿真实出口网卡 → 查 `ip route show table <网卡名>` 有无 `default`
2. 扫所有表，找带默认路由且 dev 为物理网卡的表（部分 ROM 用数字表）
3. 最后才回退 `main`（桌面 Linux 行为）

关闭共存：把 `COEXIST_ENABLE` 改回 `0`，或临时 `touch disable_coexist`。

## 用法

### 单网络（沿用旧方式）

1. 刷入 zip，重启。
2. 编辑 `/data/adb/modules/easytier_magisk/config/config.toml`，填 network_name/secret/peers。
3. 在 Magisk 里点模块的「操作」按钮 => 生成 `enable_IP_rule`，启用热点转发。
4. 手机开热点，其它设备连上后即可访问 mesh 内网（如 `10.126.126.x`）。

### 多网络并行

1. 刷入 zip，重启。
2. `cp example-main.toml.example main.toml`（在 `config/networks/` 下），按需复制多份。
3. 每份填**不同的** `network_name`/`network_secret`/`peer`，注意**端口与 ipv4 网段不要重复**。
4. `echo main > config/hotspot_instance` 指定热点出口。
5. 点「操作」按钮启用热点转发；重启模块生效。

## 故障排查：有网但连不上 peer

### 症状

`core-<实例名>.log` 里反复出现：

```
hickory dns lookup_ip failed, host: 225284.xyz
Os { code: 101, message: "Network unreachable" }
connect to peer error dst="tcp://xxx.top:11010" ... code: 101
```

而手机浏览器、微信都正常。

### 判定方法

```bash
# 1) 未绑定网卡的 socket 能不能出网？
ip route get 8.8.8.8
#    "Network is unreachable" -> 就是这个问题
#    正常返回 "via ... dev wlan0" -> 不是这个问题

# 2) main 表有没有默认路由？
ip route show table main | grep '^default'
#    没有 -> Android 常态，默认路由在 netd 具名表里

# 3) 看 netd 规则是否带 oif
ip rule show | grep oif
#    有 "oif wlan0" 且带 uidrange -> 确认是 oif 匹配导致
```

### 为什么会这样

Android netd 把默认路由放在按网卡命名的表里，规则写成
`from all iif lo oif wlan0 uidrange 0-0 lookup wlan0`。

`oif wlan0` 这个条件要求 socket **已经绑定到 wlan0**（`SO_BINDTODEVICE`）。
未绑定的 socket 没有 oif，匹配不到任何具名表规则，一路落到
`32000: from all unreachable` → 内核直接返回 `ENETUNREACH(101)`。

`--bind-device` 只作用于 easytier 的**隧道** socket（TCP/UDP/QUIC/WS/WG），
DNS 解析（hickory resolver）用的 socket 不在其中，
所以「域名 peer 全挂、IP peer 正常」是典型特征。

### hs4 怎么修的

两个自动动作，都只在检测到"未绑定出不去"时才生效：

| 动作 | 作用 | 关闭开关 |
|---|---|---|
| `--bind-device true` | 隧道 socket 绑定物理网卡 | `touch disable_bind_device` |
| `ip rule pref 79 to <dns>/32 lookup <物理表>` | 放行 DNS 查询 | `touch disable_dns_rule` |

DNS 服务器地址从 `system/etc/resolv.conf` 和 `/etc/resolv.conf` 读取，
自动跳过 `127.x`（Android 上走 netd dnsproxy，本来就不受影响）。

⚠️ **往 main 表加主机路由没用**：`32000: from all unreachable` 排在
`32766: lookup main` 之前，先命中就断了。这一点实测确认过。

### 症状 2：peer 连上了，但 ping 不通 10.10.0.x

`core-*.log` 里能看到 `new peer added`，但：

```bash
ping 10.10.0.2
# connect: Network is unreachable
```

而 `ifconfig et0` 显示：

```
et0  RX packets:14  bytes:9520
     TX packets:1   bytes:48      ← TX 几乎不增长，包根本没进 tun
```

**判定**：

```bash
ip route get 10.10.0.2                 # 可能正常
ip route get 10.10.0.2 mark 0x10064    # App 的真实视角，多半是 unreachable
```

应用 socket 带 netId fwmark，匹配不到 netd 那些带 `uidrange 0-0` 的规则。

**修复**（hs5 自动做）：

```bash
ip rule add pref 1000 to 10.10.0.0/24 lookup main
```

只影响发往 mesh 网段的包，不动默认路由，不干扰 netd 的 fwmark 分流。

⚠️ 如果物理内网与 mesh 同段，模块会跳过这条规则以保护内网 ——
此时应改用不冲突的 mesh 网段（如 `10.99.0.0/24`）。

### 验证修复生效

```bash
# 应能看到 79 前缀的 DNS 放行规则
ip rule show | grep '^79:'

# log.log 里应有记录
grep "已放行" /data/adb/modules/easytier_magisk/log.log
grep "绑定物理网卡" /data/adb/modules/easytier_magisk/log.log
```

## 已知边界（务必阅读）

- **仅验证了脚本逻辑、配置解析与 iptables 幂等性**，未在真实 Android 设备上跑通
  端到端。本机测试环境被宿主已有的 EasyTier(`et0`/`et1`) + `xray-tun0` 污染，
  无法做干净的动态验证。上机后请先看 `log.log`。
- `ip_forward` 在部分 ROM 上会被系统服务周期性重置为 0。本版 `ensure_sysctls`
  在 `set_nat_rules` 触发时执行；若发现热点设备隔一段时间断流，
  把 `hotspot_iprule.sh` 的 `ip monitor link addr` 循环改成定时轮询即可。
- MASQUERADE 依赖 tun 接口名。若在 `config.toml` 里自定义了 `dev_name`，
  `get_et_iface()` 会读取它；否则回退到自动探测 `tun*`。
- `rp_filter=2` 会略微放宽反向路径校验。若 ROM 有额外安全要求，
  可只对 tun 与热点接口设 `2`，`all` 保持默认。
- **日志按实例分开**：`log.log` 是模块事件（`[ET-NAT]` / `[ET-COEXIST]` / 实例启停），
  只追加；`core-<实例名>.log` 是该实例 easytier-core 自身输出，超过 1MB 自动清空。
  单实例模式下名字是 `core-default.log`。
- **多实例内存**：每个实例约 56 MB RSS，`config/networks/` 里文件越多占用越高。
  低内存设备建议控制在 2～3 个。
- **多实例没有热加载**：往 `config/networks/` 里新增/删除 `.toml` 后需要重启模块
  （Magisk 里禁用→启用，或重启手机）。模块不会自动发现新文件。
- **TPROXY 共存仍未经真机验证**（hs1 那次真机运行恰恰暴露了它的致命 bug 并已修复，
  但修复后的版本尚未上机）。上机后若 `log.log` 出现
  `[ET-COEXIST] ... 路由校验未通过`，说明该 ROM 表结构与探测不符，
  此时网络不受影响，只需按实际表名调整。

## 与官方的差异清单

| 文件 | 改动 |
|---|---|
| `hotspot_iprule.sh` | 新增 `ensure_sysctls`/`probe_cidrs`；sysctl 提前；规则幂等；修 `awk` 的 `\:` 非法转义 |
| `easytier_core.sh` | **hs3 重写为多实例守护**：`config/networks/*.toml` 每文件一进程；自动分配 dev_name/rpc_portal；`/proc` 精确进程匹配；`core-<实例名>.log` |
| `coexist.sh` | 新增。TPROXY 共存；**hs2 加入表探测 + 路由实测护栏 + 历史规则自愈** |
| `config/coexist.conf` | 新增。hs2 增加 `COEXIST_ENABLE`（默认 0） |
| `uninstall.sh` | hs2 加入 iptables 链与 fwmark 规则清理 |
| `TROUBLESHOOTING.md` | 新增。hs1 断网问题的完整复盘与本地复现记录 |
| `config/networks/` | **hs3 新增**。多网络配置目录 + 示例 + 说明 |
| `config/hotspot_instance` | **hs3 新增**。指定热点出口实例 |
| `hotspot_iprule.sh` | hs3：`to_net_cidr` 把接口地址规范成网络地址；多实例感知 |
| `coexist.sh` | hs3：多 tun 网段聚合；`to_net_cidr` |
| `webui.sh` | hs3：多实例模式下编辑"热点出口实例"那份配置，只重启该实例 |
| `easytier_core.sh` | **hs5**：`bind_device` 默认开启；出口网卡变化自动重启；`ensure_dns_rules` + `ensure_mesh_rules` |
| `hotspot_iprule.sh` | **hs5**：日志去重，`ip monitor` 抖动不再刷屏 |
| `coexist.sh` | **hs4**：`mark_hex` 严格校验，`flush_mark_rules` 拒绝删除 netd 特征规则 |
| `uninstall.sh` | **hs4**：清理 DNS 放行规则 |
| `module.prop` | 版本改 `v2.7.0-hs5`，移除 `updateJson`（防官方更新覆盖改造） |

## 📦 模块打包与 GitHub Releases 自动发布

### 1. 本地打包构建

项目提供 [`build.sh`](file:///home/thtf/ws/easytier-magisk/build.sh) 快速打包 Magisk 模块 Zip：

```bash
# 同时编译标准发布包与调试包（生成至 dist/ 目录并自动计算 SHA256）
./build.sh all

# 仅编译标准发布包 (Easytier-Magisk-v<version>.zip)
./build.sh release

# 仅编译 Debug 调试包 (Easytier-Magisk-v<version>-debug.zip)
./build.sh debug
```

构建产物自动存放在 `dist/` 目录下，并生成 `dist/SHA256SUMS.txt` 校验和。

### 2. 一键发布到 GitHub Releases

本地通过 `gh` CLI 一键打 Tag 并发布到 GitHub Releases：

```bash
# 自动执行回归测试 -> 构建双版本 -> 生成校验和 -> 创建 Git Tag -> 上传 Release 资产
./build.sh publish
```

### 3. GitHub Actions 自动化 CI/CD

仓库配置了 [`.github/workflows/release.yml`](file:///home/thtf/ws/easytier-magisk/.github/workflows/release.yml)：
- 当向远程推送版本标签（如 `git push origin v2.7.0-hs6`）时，GitHub Actions 会自动触发；
- 自动化运行测试、打包标准版与 Debug 版、计算 SHA256 校验和；
- 自动创建并发布 GitHub Release，将模块资产挂载供用户直接在 Magisk / KernelSU / APatch 中刷入。

---

## WebUI / 手动配置（保留官方行为）

KernelSU 等支持模块 WebUI 的管理器可从模块详情页打开配置界面；
WebUI 用 EasyTier 自身配置模型校验，`save-and-restart` 时先 `--check-config`
再原子替换并重启进程。若存在 `config/command_args`，模块进入启动参数模式并
忽略 `config.toml`。
