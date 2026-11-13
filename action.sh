#!/data/adb/magisk/busybox sh
MODDIR=${0%/*}
MODULE_PROP="${MODDIR}/module.prop"
IP_RULE_SCRIPT="${MODDIR}/hotspot_iprule.sh"
DUMP_SCRIPT="${MODDIR}/dump_debug.sh"
DEBUG_FLAG="${MODDIR}/enable_debug"
DEBUG_CONF="${MODDIR}/config/debug.conf"

ACTION="$1"

# 支持 action.sh dump 一键打包诊断信息
if [ "$ACTION" = "dump" ]; then
    chmod +x "$DUMP_SCRIPT" 2>/dev/null
    exec "$DUMP_SCRIPT"
fi

# 支持 action.sh debug 快速切换调试模式
if [ "$ACTION" = "debug" ]; then
    if [ -f "$DEBUG_FLAG" ]; then
        rm -f "$DEBUG_FLAG"
        [ -f "$DEBUG_CONF" ] && sed -i 's/^DEBUG=.*/DEBUG=0/' "$DEBUG_CONF"
        echo "[EasyTier] 调试模式已关闭"
    else
        touch "$DEBUG_FLAG"
        [ -f "$DEBUG_CONF" ] && sed -i 's/^DEBUG=.*/DEBUG=1/' "$DEBUG_CONF"
        echo "[EasyTier] 调试模式已激活 (RUST_LOG=debug,easytier=trace)"
    fi
    exit 0
fi

ET_STATUS=""
REDIR_STATUS=""
IS_RUNNING=false

# 确保辅助脚本有执行权限
chmod +x "${IP_RULE_SCRIPT}" 2>/dev/null

# 更新 module.prop 文件中的 description
update_module_description() {
    local status_message=$1
    # 检查 module.prop 文件存在且 description 发生变化了再写入
    if [ -f "${MODULE_PROP}" ]; then
        local current_desc=$(grep "^description=" "${MODULE_PROP}")
        local new_desc="description=[状态] ${status_message}"
        if [ "${current_desc}" != "${new_desc}" ]; then
            sed -i "s#^description=.*#${new_desc}#" "${MODULE_PROP}"
        fi
    fi
}

# 判断程序启动状态
if [ -f "${MODDIR}/disable" ]; then
    IS_RUNNING=false
    ET_STATUS="主程序已关闭"

elif pgrep -x easytier-core >/dev/null; then
    IS_RUNNING=true
    NCORE=$(pgrep -x easytier-core | wc -l | tr -d ' ')
    NCFG=$(ls -1 "${MODDIR}/config/networks"/*.toml 2>/dev/null | wc -l | tr -d ' ')
    if [ "$NCFG" -gt 0 ]; then
        ET_STATUS="运行中 ${NCORE}/${NCFG} 个实例"
    elif [ -f "${MODDIR}/config/command_args" ]; then
        ET_STATUS="主程序正在运行（启动参数模式）"
    else
        ET_STATUS="主程序正在运行（配置文件模式）"
    fi
    
elif [ -z "$ET_STATUS" ]; then
    # 既没 disable 也没运行，说明是异常停止或未启动
    ET_STATUS="主程序启动失败或未运行"
fi

# 无论主程序是否运行，都允许切换“开关文件”的状态，以便下次生效
if [ -f "${MODDIR}/enable_IP_rule" ]; then
    rm -f "${MODDIR}/enable_IP_rule"
    
    "${IP_RULE_SCRIPT}" del >/dev/null 2>&1
    
    REDIR_STATUS="转发已禁用"
    echo "热点子网转发已禁用"
    echo "[ET-NAT] Action: IP rule disabled." >> "${MODDIR}/log.log"
else
    touch "${MODDIR}/enable_IP_rule"

    if [ "$IS_RUNNING" = true ]; then
        "${IP_RULE_SCRIPT}" del >/dev/null 2>&1
        "${IP_RULE_SCRIPT}" add_once
        echo "转发规则将立即生效，无需重启"
    else
        echo "主程序未运行，转发规则将在下次启动时生效"
    fi
    
    REDIR_STATUS="转发已激活"
    echo "----------------------------------"
    echo "热点子网转发已激活"
    echo "热点开启后将自动将热点加入转发网络"
    echo "需要在配置中提前配置好 cidr 参数"
    echo "----------------------------------"
    echo "[ET-NAT] Action: IP rule enabled." >> "${MODDIR}/log.log"
fi

sync
update_module_description "${ET_STATUS}| ${REDIR_STATUS}"