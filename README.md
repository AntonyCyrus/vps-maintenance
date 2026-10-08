# Debian 13 VPS 自动维护

本项目用于 Debian 13 (trixie) 独立 VPS。它通过四个维护脚本和 systemd 日历定时器完成安全更新、常规更新、全面升级和定期清理，并在固定窗口按需重启以启用新内核。

所有脚本使用 UTF-8、LF 换行和普通 ASCII 命令字符。简体中文只用于注释和说明，不会混入命令参数。

## 固定日历

所有定时器均明确使用 `Asia/Shanghai`，不受 VPS 本地时区变化影响。这里的日期和时间始终按照东八区计算。

| 任务 | 东八区时间 | 说明 |
| --- | --- | --- |
| 每日安全更新 | 每天 02:00 | 仅安装 Debian Security 更新 |
| 常规软件包更新 | 每月 4、11、18、25 日 02:00 | 先明确安装安全更新，再更新所有已启用 APT 源中的软件包 |
| 全面升级 | 每月 8、22 日 02:00 | 先明确安装安全更新，再执行受保护的 `full-upgrade` |
| 每月清理 | 每月 28 日 03:30 | 清理无用依赖、旧内核、缓存和旧日志 |
| 按需重启检查 | 每天 05:00 | 仅在新内核或系统明确要求重启时重启 |

每月 4、8、11、18、22、25 日的每日安全任务会主动退出，由当天更全面的更新任务覆盖，避免重复启动三个独立任务。常规更新和全面升级脚本内部都会先单独执行 Debian Security 更新，因此不会遗漏安全补丁；所有升级完成后才统一运行一次 needrestart。28 日仍先执行安全更新，再于 03:30 执行清理。

按需重启只允许发生在东八区 05:00 至 05:30。若升级异常耗时、锁等待过久，或 Persistent 定时器在白天补跑，重启脚本只记录并退出，将重启顺延到第二天 05:00，避免在工作时间突然中断服务。

固定月日便于记忆，但它不是严格的每 7 天或每 14 天：跨月间隔会随月份长度变化。这是固定日期方案的正常结果。

## 项目内容

```text
vps-maintenance/
├── README.md
├── install.sh
├── uninstall.sh
├── scripts/
│   ├── maintenance-daily-security
│   ├── maintenance-weekly-packages
│   ├── maintenance-fortnightly-full-upgrade
│   ├── maintenance-monthly-cleanup
│   └── maintenance-reboot-if-needed
└── systemd/
    ├── vps-maintenance@.service
    ├── vps-daily-security.timer
    ├── vps-weekly-packages.timer
    ├── vps-fortnightly-full-upgrade.timer
    ├── vps-reboot-if-needed.service
    ├── vps-reboot-if-needed.timer
    └── vps-monthly-cleanup.timer
```

四个主要维护脚本共用 `/run/lock/vps-maintenance.lock`。按需重启检查也使用同一把锁，确保不会在 APT 或 dpkg 尚未结束时重启。

## 安装条件

- Debian 13 (trixie)。
- systemd 独立 VPS，例如 KVM、VMware 或物理机。
- 不适用于 LXC、OpenVZ、Docker 等共享宿主机内核的容器。
- 建议事先确认 VPS 提供商具有网页控制台、VNC 或救援模式。

## 上传到 GitHub

ZIP 文件本身不需要放入仓库。请先解压，然后把 `vps-maintenance` 文件夹中的内容上传到 GitHub 仓库根目录。仓库根目录应当直接看到 `install.sh` 和 `README.md`。

VPS 上克隆的是 Git 仓库地址，不是 `.zip` 地址：

```bash
git clone https://github.com/AntonyCyrus/vps-maintenance.git vps-maintenance
cd vps-maintenance
sudo bash install.sh
```

也可以直接将解压后的整个文件夹上传到 VPS，然后进入目录执行：

```bash
cd vps-maintenance
sudo bash install.sh
```

安装器可以重复运行。每次运行都会先把可能被覆盖的现有文件备份到：

```text
/root/vps-maintenance-backup-时间戳/
```

## 安装器会做什么

- 检查 Debian 13、systemd 和虚拟化环境。
- 安装 `unattended-upgrades`、`needrestart` 和 `util-linux`。
- 停用 APT 自带的周期定时器，避免与本项目重复执行。
- 安装脚本和 systemd 单元。
- 将 unattended-upgrades 限制到 Debian 13 官方安全仓库。
- 配置 needrestart 在每次 APT 事务结束后统一重启一次仍在使用旧共享库的后台服务，避免一次更新中反复重启。
- 配置 APT 至少保护最近三份内核。
- 配置 journald 最多保留 30 天且最多占用 500 MiB。
- 检查 Bash、systemd 和 APT 配置后启用定时器。

安装器不会立即全面升级，也不会在安装过程中重启 VPS。

## 更新范围

每日脚本只执行 Debian 13 官方 Security 更新，不会自动信任第三方仓库为安全来源。常规更新和全面升级任务也会先调用同一套 Security 更新机制，再继续处理普通软件包，因此它们完整包含每日安全更新的功能。

每月 4、11、18、25 日的常规更新会更新所有已经启用的 APT 仓库。因此，通过以下方式加入官方 APT 仓库安装的 sing-box 会被纳入常规更新：

```text
/etc/apt/sources.list.d/sagernet.sources
```

如果软件只是手动执行一次 `dpkg -i example.deb`，但没有对应 APT 仓库，APT 无法发现它将来的新版本，也就不能自动更新。

常规更新和全面升级均使用 `--no-remove`。如果新版本必须删除现有软件包才能解决依赖，任务会失败并保留现状，等待人工审查，而不会擅自删除服务。

## 服务和重启

软件包升级时，软件包自己的安装脚本可能立即 reload 或 restart 对应服务。例如 sing-box、Nginx、SSH、Docker 或数据库可能短暂中断。普通命令行程序通常在下一次启动时直接使用新版。

内核不会在安装后立即替换正在运行的内核。每天东八区 05:00 的检查脚本使用 `needrestart` 判断：

- 状态 1：内核已是最新，不重启。
- 状态 2 或 3：存在待启用内核，重启 VPS。
- 状态 0 或无法识别：不冒险重启，并让服务返回失败以便从日志发现。
- 如果系统明确创建 `/run/reboot-required`，也会执行重启。
- 如果取得维护锁时已超过东八区 05:30，则不再重启，顺延到第二天维护窗口。

APT 被配置为保护最近三份内核。新内核启动后，旧内核仍保留用于回退；每月 28 日仅清理超出保护数量且已成为自动依赖的更早内核。不要直接删除 `/boot` 中的文件。

## 验证安装

```bash
# 查看所有维护计时器及下次执行时间
systemctl list-timers --all 'vps-*'

# 检查是否存在失败的 systemd 服务
systemctl --failed

# 查看各项任务日志
journalctl -u vps-maintenance@daily-security.service -n 100 --no-pager
journalctl -u vps-maintenance@weekly-packages.service -n 100 --no-pager
journalctl -u vps-maintenance@fortnightly-full-upgrade.service -n 100 --no-pager
journalctl -u vps-maintenance@monthly-cleanup.service -n 100 --no-pager
journalctl -u vps-reboot-if-needed.service -n 100 --no-pager

# 检查当前内核和 needrestart 判断结果
uname -r
sudo needrestart -b -k

# 检查磁盘空间和已安装内核
df -h / /boot 2>/dev/null || df -h /
dpkg-query -W 'linux-image-*' 2>/dev/null
```

一次性服务执行结束后显示 `inactive (dead)` 是正常现象。应重点确认：

```text
status=0/SUCCESS
```

## 手动测试

以下命令会真实执行相应任务，不是模拟：

```bash
sudo systemctl start vps-maintenance@daily-security.service
sudo systemctl status vps-maintenance@daily-security.service --no-pager -l
```

在 4、8、11、18、22、25 日手动启动每日任务时，它会按照去重规则正常退出。若确实需要在这些日期手动执行安全更新，可以直接运行：

```bash
sudo unattended-upgrade --verbose
```

手动触发按需重启检查可能立即重启 VPS：

```bash
sudo systemctl start vps-reboot-if-needed.service
```

## 卸载定时任务

```bash
cd vps-maintenance
sudo bash uninstall.sh
```

卸载器会移除本项目安装的脚本、配置和 systemd 单元，并重新启用 Debian 自带 APT 定时器。它不会回滚已经安装的软件包，也不会自动恢复其他历史自定义配置；如有需要，请使用 `/root/vps-maintenance-backup-时间戳/` 中的备份。

## 代码和字体

GitHub README 无法强制指定网页字体。SSH 客户端应使用 UTF-8 编码，并选择支持简体中文的等宽字体或配置中文字体回退，例如：

- Windows Terminal：Cascadia Mono，并配置微软雅黑或更纱黑体作为中文回退。
- macOS Terminal：Menlo，并使用苹方中文回退。
- Linux：Noto Sans Mono CJK SC。

即使终端不支持中文，命令本身仍全部由 ASCII 字符组成，不会因为注释乱码而改变执行含义。

