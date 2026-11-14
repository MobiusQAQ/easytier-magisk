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
ui_print "终端状态查看命令（su 执行）："
ui_print "  easytier-cli peer  : 查看所有实例加入的 peer 状态"
ui_print "  easytier status    : 查看各实例运行概要与连接统计"
ui_print "  action.sh peer     : 免重启现场诊断与 peer 查询"
ui_print "----------------------------------"
ui_print "修改配置后无需重启设备，在 Magisk 中禁用 EasyTier 模块，等待 10 秒后重新启用即可让新配置生效"
ui_print "点击 Magisk 中模块左下角的“操作”按钮可以禁用或激活热点子网转发，使用该功能前需要在配置中提前配置好 cidr 参数"
ui_print "模块安装完成，重启设备生效"