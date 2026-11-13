# networks/ —— 多网络实例目录

每个 `.toml` 文件 = **一个独立的 EasyTier 网络实例**（独立进程、独立 tun、独立日志）。
模块会自动为每个文件拉起一个 `easytier-core`。

## 快速上手

```bash
cd /data/adb/modules/easytier_magisk/config/networks

# 1) 复制示例并改名（文件名去掉 .toml 就是实例名）
cp example-main.toml.example main.toml
cp example-work.toml.example work.toml

# 2) 编辑，填 network_name / network_secret / peer
vi main.toml
vi work.toml

# 3) 指定哪个实例做热点出口（可选，不写则默认第一个）
echo main > ../hotspot_instance

# 4) 重启模块生效（Magisk 里禁用→启用，或重启手机）
```

只有 `.toml` 结尾的文件会被加载。`.toml.example` 只是模板，不会被启用。

## 多实例必须遵守的约束

| 项目 | 要求 | 重复会怎样 |
|---|---|---|
| `listeners` 端口 | **必须各不相同** | 后启动的实例起不来 |
| `ipv4` 网段 | **必须各不相同** | 路由冲突 |
| `network_name` | 不同网络自然不同 | — |
| `dev_name` | 可不写，模块自动分配 `et0/et1/...` | 手写重复会 `Resource busy` |
| `instance_name` | 可不写，模块用文件名 | 重复则第二个静默失败 |
| `rpc_portal` | 可不写，模块自动分配 `127.0.0.1:1588N` | 重复则后启动的实例 RPC 不可用 |

## 模块自动补全的字段

写在这些字段你就不用管；不写模块会自动填（**不会修改你的文件**，只在启动参数里注入）：

- `dev_name` → `et0`、`et1`…（自动避开已被占用的名字）
- `instance_name` → 文件名（去掉 `.toml`）
- `rpc_portal` → `127.0.0.1:1588<序号>`
- `hostname` → 设备型号

## 子网代理网段的正确写法

顶层 `proxy_networks = [...]` 会被 EasyTier 丢弃，必须用数组表：

```toml
[[proxy_network]]
cidr = "192.168.1.0/24"
```

（模块的自动收集逻辑两种写法都能识别，但内核只认后者。）

## 热点共享走哪个实例

`config/hotspot_instance` 里写实例名（文件名去掉 `.toml`）：

```bash
echo main > /data/adb/modules/easytier_magisk/config/hotspot_instance
```

只有这个实例会被自动注入热点网段（`--proxy-networks`）。
其它实例不会参与热点转发，从而避免多出口路由歧义。

留空或删除该文件 → 默认用文件名排序后的第一个实例。

## 查看运行状态

```bash
# 有几个实例在跑
pgrep -c -x easytier-core

# 每个实例的 tun 与配置的对应关系
cat /data/adb/modules/easytier_magisk/.instances
# 输出格式：实例名 <TAB> tun设备名 <TAB> 配置文件路径

# 每个实例独立的 core 日志
ls /data/adb/modules/easytier_magisk/core-*.log

# 用 cli 分别查询（需知道该实例的 rpc_portal）
/data/adb/modules/easytier_magisk/easytier-cli -p 127.0.0.1:15880 node
```

## 单实例兼容

如果 `networks/` 里没有任何 `.toml`，模块会回退使用旧的 `config/config.toml`（单实例），
行为与之前完全一致。所以升级上来不会立刻改变你的现有配置。
