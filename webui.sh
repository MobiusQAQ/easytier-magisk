#!/system/bin/sh

MODDIR=$(CDPATH= cd "${0%/*}" 2>/dev/null && pwd -P) || {
    echo "Failed to resolve module directory" >&2
    exit 1
}
CONFIG_FILE="${MODDIR}/config/config.toml"
COMMAND_ARGS="${MODDIR}/config/command_args"
NETWORKS_DIR="${MODDIR}/config/networks"
HOTSPOT_INSTANCE_FILE="${MODDIR}/config/hotspot_instance"
EASYTIER="${MODDIR}/easytier-core"

# 多实例模式：config/networks/ 里存在 .toml 时，单实例的 config.toml 不生效。
# WebUI 编辑的是"热点出口实例"那份配置（或第一个），而不是 config.toml，
# 否则改了也不会有任何效果。
in_networks_mode() {
    [ -d "${NETWORKS_DIR}" ] || return 1
    ls -1 "${NETWORKS_DIR}"/*.toml >/dev/null 2>&1
}

# 多实例模式下当前被编辑的配置文件
active_config() {
    if in_networks_mode; then
        H=$(head -n1 "${HOTSPOT_INSTANCE_FILE}" 2>/dev/null | tr -d ' \t\r\n')
        if [ -n "$H" ] && [ -f "${NETWORKS_DIR}/${H}.toml" ]; then
            printf '%s' "${NETWORKS_DIR}/${H}.toml"
            return
        fi
        ls -1 "${NETWORKS_DIR}"/*.toml 2>/dev/null | head -n1
        return
    fi
    printf '%s' "${CONFIG_FILE}"
}

fail() {
    echo "$1" >&2
    exit 1
}

running_pids() {
    for process_dir in /proc/[0-9]*; do
        [ "$(readlink "${process_dir}/exe" 2>/dev/null)" = "${EASYTIER}" ] || continue
        printf '%s\n' "${process_dir#/proc/}"
    done
}

is_running() {
    [ -n "$(running_pids)" ]
}

case "$1" in
    status)
        if is_running; then
            echo "running"
        else
            echo "stopped"
        fi
        ;;
    config-mode)
        if [ -f "${COMMAND_ARGS}" ]; then
            echo "command-args"
        elif in_networks_mode; then
            echo "networks"
        else
            echo "toml"
        fi
        ;;
    list-configs)
        if in_networks_mode; then
            for f in "${NETWORKS_DIR}"/*.toml; do
                [ -f "$f" ] || continue
                basename "$f" .toml
            done
        fi
        ;;
    active-config-name)
        if in_networks_mode; then
            basename "$(active_config)" .toml
        fi
        ;;
    read-config)
        TARGET=$(active_config)
        [ -n "$TARGET" ] || fail "Configuration file not found: ${CONFIG_FILE}"
        [ -f "$TARGET" ] || fail "Configuration file not found: ${TARGET}"
        cat "$TARGET"
        ;;
    save-and-restart)
        [ -f "${COMMAND_ARGS}" ] && fail "command_args is active; config.toml would be ignored"
        [ -n "$2" ] || fail "Missing base64-encoded configuration"
        [ -x "${EASYTIER}" ] || fail "easytier-core is not executable"

        TARGET=$(active_config)
        [ -n "$TARGET" ] || fail "Cannot determine target configuration file"
        TEMP_FILE="${TARGET}.webui.$$"
        trap 'rm -f "${TEMP_FILE}"' EXIT HUP INT TERM
        umask 077

        printf '%s' "$2" | base64 -d > "${TEMP_FILE}" \
            || fail "Failed to decode configuration"

        VALIDATION_OUTPUT=$("${EASYTIER}" --check-config -c "${TEMP_FILE}" 2>&1)
        if [ $? -ne 0 ]; then
            fail "${VALIDATION_OUTPUT:-Configuration validation failed}"
        fi

        chmod 0644 "${TEMP_FILE}"
        mv -f "${TEMP_FILE}" "${TARGET}" \
            || fail "Failed to replace configuration"
        trap - EXIT HUP INT TERM

        # 只重启"刚刚被修改的那个实例"，不要株连其它实例。
        # 多实例下把所有 easytier-core 都杀掉会让其它网络一起断掉。
        KILLED=0
        TARGET_REAL=$(readlink -f "${TARGET}" 2>/dev/null || printf '%s' "${TARGET}")
        for process_dir in /proc/[0-9]*; do
            [ -r "${process_dir}/cmdline" ] || continue
            CMDLINE=$(tr '\000' ' ' < "${process_dir}/cmdline" 2>/dev/null)
            case "$CMDLINE" in
                *easytier-core*) ;;
                *) continue ;;
            esac
            case "$CMDLINE" in
                *"-c ${TARGET} "*|*"-c ${TARGET_REAL} "*|*"-c ${TARGET}"|*"-c ${TARGET_REAL}")
                    kill "${process_dir#/proc/}" 2>/dev/null && KILLED=1
                    ;;
            esac
        done
        if [ "$KILLED" = "0" ] && ! in_networks_mode; then
            # 单实例兼容：拿不到精确匹配时回退到原来的全杀逻辑
            RUNNING_PIDS=$(running_pids)
            for pid in ${RUNNING_PIDS}; do
                kill "${pid}" || fail "Failed to restart EasyTier"
            done
        fi
        echo "saved"
        ;;
    *)
        fail "Usage: $0 {status|config-mode|list-configs|active-config-name|read-config|save-and-restart BASE64}"
        ;;
esac
