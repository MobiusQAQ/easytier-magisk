#!/data/adb/magisk/busybox sh
MODDIR=${0%/*}
# MODDIR="$(dirname $(readlink -f "$0"))"
chmod 755 ${MODDIR}/*
chmod -R 755 ${MODDIR}/system/bin 2>/dev/null

# 确保终端快捷命令在 Termux / KernelSU / APatch 就绪
sync_cli_entrypoints() {
    local target_src="${MODDIR}/system/bin/easytier-cli"
    [ -f "$target_src" ] || return 0

    local termux_bin="/data/data/com.termux/files/usr/bin"
    if [ -d "$termux_bin" ]; then
        if [ ! -f "${termux_bin}/easytier-cli" ] || [ ! -f "${termux_bin}/easytier" ]; then
            cp -f "$target_src" "${termux_bin}/easytier-cli" 2>/dev/null || true
            cp -f "$target_src" "${termux_bin}/easytier" 2>/dev/null || true
            chmod 755 "${termux_bin}/easytier-cli" "${termux_bin}/easytier" 2>/dev/null || true
            local t_owner
            t_owner=$(stat -c '%u:%g' "$termux_bin" 2>/dev/null || true)
            [ -n "$t_owner" ] && chown "$t_owner" "${termux_bin}/easytier-cli" "${termux_bin}/easytier" 2>/dev/null || true
        fi
    fi

    local ksu_bin="/data/adb/ksu/bin"
    if [ -d "$ksu_bin" ]; then
        if [ ! -f "${ksu_bin}/easytier-cli" ]; then
            cp -f "$target_src" "${ksu_bin}/easytier-cli" 2>/dev/null || true
            ln -sf "easytier-cli" "${ksu_bin}/easytier" 2>/dev/null || cp -f "$target_src" "${ksu_bin}/easytier" 2>/dev/null || true
            chmod 755 "${ksu_bin}/easytier-cli" "${ksu_bin}/easytier" 2>/dev/null || true
        fi
    fi

    local ap_bin="/data/adb/ap/bin"
    if [ -d "$ap_bin" ]; then
        if [ ! -f "${ap_bin}/easytier-cli" ]; then
            cp -f "$target_src" "${ap_bin}/easytier-cli" 2>/dev/null || true
            ln -sf "easytier-cli" "${ap_bin}/easytier" 2>/dev/null || cp -f "$target_src" "${ap_bin}/easytier" 2>/dev/null || true
            chmod 755 "${ap_bin}/easytier-cli" "${ap_bin}/easytier" 2>/dev/null || true
        fi
    fi
}
sync_cli_entrypoints

# 等待系统启动成功
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 5s
done

# 防止系统挂起
echo "PowerManagerService.noSuspend" > /sys/power/wake_lock

# 修复 SELinux ioctl(SIOCGIFINDEX) 产生的海量 AVC 拒绝审计日志（缓解 CPU 占用与日志刷屏）
if command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "allow { su ksu magisk } { su ksu magisk } unix_dgram_socket { ioctl read write }" 2>/dev/null
    magiskpolicy --live "dontaudit { su ksu magisk } { su ksu magisk } unix_dgram_socket ioctl" 2>/dev/null
elif command -v supolicy >/dev/null 2>&1; then
    supolicy --live "allow ksu ksu unix_dgram_socket ioctl" 2>/dev/null
    supolicy --live "dontaudit ksu ksu unix_dgram_socket ioctl" 2>/dev/null
fi

# 修改模块描述
sed -i 's/$(description=)$[^"]*/\1[状态]关闭中/' "$MODDIR/module.prop"

# 等待 3 秒
sleep 3s

# 启动前清理残留的历史守护脚本，避免多重循环累积与重复执行
for p in $(pgrep -f "${MODDIR}/easytier_core.sh" 2>/dev/null); do
    [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
done
for p in $(pgrep -f "${MODDIR}/hotspot_iprule.sh" 2>/dev/null); do
    [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
done

"${MODDIR}/easytier_core.sh" &
"${MODDIR}/hotspot_iprule.sh" add &

# easytier_core.sh 现在支持多网络实例：config/networks/*.toml
# 每个文件拉起一个独立 easytier-core 进程，由 easytier_core.sh 内部循环守护，
# hotspot_iprule.sh 也有内部循环守护，所以这里不需要再做守护了
