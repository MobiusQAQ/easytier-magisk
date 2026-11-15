SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=true
LATESTARTSERVICE=true

set_perm_recursive $MODPATH 0 0 0777 0777

ui_print "系统架构为：$ARCH"
ui_print "系统 SDK 版本：$API"
ui_print "EasyTier 安装位置：/data/adb/modules/easytier_magisk"
ui_print "配置文件位置：/data/adb/modules/easytier_magisk/config/config.toml"
ui_print "多网络：把多个 .toml 放进 config/networks/ 即可并行运行多个网络实例"
ui_print "  示例见 config/networks/README.md（.toml.example 不会自动启用）"
ui_print "  用 config/hotspot_instance 指定哪个实例做热点出口"
ui_print "如需使用启动参数模式，请将 /data/adb/modules/easytier_magisk/config/command_args_sample 重命名为 command_args，并修改其中的内容"
ui_print "config 目录中存在 command_args 文件时，模块会自动忽略 config.toml 文件"
ui_print "支持模块 WebUI 的管理器可直接打开配置界面；Magisk 用户可配合 KsuWebUI 使用"
ui_print "----------------------------------"
ui_print "注意！启动参数文件中不能存在 \" 和 '，配置文件则没有这个限制"
ui_print "----------------------------------"

# 安装终端命令包装器与软链接（支持 Termux / KernelSU / APatch / Magisk）
install_cli_entrypoints() {
    local target_src="$MODPATH/system/bin/easytier-cli"
    [ -f "$target_src" ] || return 0

    # 1. Termux 环境支持
    local termux_bin="/data/data/com.termux/files/usr/bin"
    if [ -d "$termux_bin" ]; then
        ui_print "- 正在为 Termux 安装 easytier-cli & easytier 终端命令..."
        cp -f "$target_src" "${termux_bin}/easytier-cli" 2>/dev/null || true
        cp -f "$target_src" "${termux_bin}/easytier" 2>/dev/null || true
        chmod 755 "${termux_bin}/easytier-cli" "${termux_bin}/easytier" 2>/dev/null || true
        local t_owner
        t_owner=$(stat -c '%u:%g' "$termux_bin" 2>/dev/null || true)
        [ -n "$t_owner" ] && chown "$t_owner" "${termux_bin}/easytier-cli" "${termux_bin}/easytier" 2>/dev/null || true
    fi

    # 2. KernelSU 环境支持
    local ksu_bin="/data/adb/ksu/bin"
    if [ -d "$ksu_bin" ]; then
        ui_print "- 正在为 KernelSU 注册 easytier-cli & easytier 终端命令..."
        cp -f "$target_src" "${ksu_bin}/easytier-cli" 2>/dev/null || true
        ln -sf "easytier-cli" "${ksu_bin}/easytier" 2>/dev/null || cp -f "$target_src" "${ksu_bin}/easytier" 2>/dev/null || true
        chmod 755 "${ksu_bin}/easytier-cli" "${ksu_bin}/easytier" 2>/dev/null || true
    fi

    # 3. APatch 环境支持
    local ap_bin="/data/adb/ap/bin"
    if [ -d "$ap_bin" ]; then
        ui_print "- 正在为 APatch 注册 easytier-cli & easytier 终端命令..."
        cp -f "$target_src" "${ap_bin}/easytier-cli" 2>/dev/null || true
        ln -sf "easytier-cli" "${ap_bin}/easytier" 2>/dev/null || cp -f "$target_src" "${ap_bin}/easytier" 2>/dev/null || true
        chmod 755 "${ap_bin}/easytier-cli" "${ap_bin}/easytier" 2>/dev/null || true
    fi
}

install_cli_entrypoints

ui_print "终端状态查看命令（Termux / 终端直接执行）："
ui_print "  easytier-cli peer  : 查看所有实例加入的 peer 状态"
ui_print "  easytier status    : 查看各实例运行概要与连接统计"
ui_print "  action.sh peer     : 免重启现场诊断与 peer 查询"
ui_print "----------------------------------"
ui_print "修改配置后无需重启设备，在 Magisk 中禁用 EasyTier 模块，等待 10 秒后重新启用即可让新配置生效"
ui_print "点击 Magisk 中模块左下角的“操作”按钮可以禁用或激活热点子网转发，使用该功能前需要在配置中提前配置好 cidr 参数"
ui_print "模块安装完成，重启设备生效"