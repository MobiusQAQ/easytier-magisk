# EasyTier Magisk 测试与验证脚本

本目录包含模块核心机制的本地端到端与模拟测试脚本：

- `coexist_hotspot_test.sh`: 端到端验证 TPROXY 共存 + 热点共享内网（网络命名空间与网桥模拟）
- `coexist_loopback_test.sh`: 回环机制验证（双实例走 127.0.0.1，对照「无共存」vs「有共存 socket-mark + mangle 放行 + fwmark main」）
- `coexist_verify.sh`: 基础共存机制验证（TPROXY 劫持出站 vs socket-mark 放行）
- `coexist_verify_fixed.sh`: 符合 TPROXY 语义的修正版验证（出向 mark -> 策略路由进 table 100，入向 TPROXY）
- `hotspot_gateway_test.sh`: 热点网关路由与 NAT 转发测试
- `coexist_flags_from_binary.txt`: 从 easytier-core 二进制提取的相关命令行标志与参数备忘
- `hotspot_gateway_result.txt`: 热点网关测试输出日志参考
