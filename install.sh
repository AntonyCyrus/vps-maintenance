#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 VPS 自动维护安装器。
# 可以重复运行；覆盖前会备份本项目可能修改的现有文件。

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly BACKUP_ROOT="/root/vps-maintenance-backup-${TIMESTAMP}"
readonly LOCK_FILE="/run/lock/vps-maintenance.lock"

readonly SCRIPT_NAMES=(
    maintenance-daily-security
    maintenance-weekly-packages
    maintenance-fortnightly-full-upgrade
    maintenance-monthly-cleanup
    maintenance-reboot-if-needed
)

readonly TIMER_NAMES=(
    vps-daily-security.timer
    vps-weekly-packages.timer
    vps-fortnightly-full-upgrade.timer
    vps-reboot-if-needed.timer
    vps-monthly-cleanup.timer
)

log() {
    printf '[install] %s\n' "$*"
}

die() {
    printf '[install] 错误: %s\n' "$*" >&2
    exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 sudo bash install.sh 运行。"
fi

[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] || \
    die "本项目仅支持 Debian 13，当前系统为 ${PRETTY_NAME:-未知}。"

[[ -d /run/systemd/system ]] || die "当前系统没有运行 systemd。"

if systemd-detect-virt --quiet --container; then
    die "检测到容器环境。共享宿主机内核的容器不能使用本项目的内核重启策略。"
fi

for name in "${SCRIPT_NAMES[@]}"; do
    [[ -f "${PROJECT_DIR}/scripts/${name}" ]] || die "缺少 scripts/${name}。"
    bash -n "${PROJECT_DIR}/scripts/${name}" || die "${name} 语法检查失败。"
done

[[ -f "${PROJECT_DIR}/README.md" ]] || die "缺少 README.md。"

if ! command -v flock >/dev/null 2>&1; then
    log "正在安装文件锁工具。"
    apt-get -o Acquire::Retries=3 update
    DEBIAN_FRONTEND=noninteractive apt-get -y install util-linux
fi

exec 9>"$LOCK_FILE"
flock --wait 21600 9 || die "等待维护锁超时。"

backup_file() {
    local source_path="$1"
    local target_path
    [[ -e "$source_path" || -L "$source_path" ]] || return 0
    target_path="${BACKUP_ROOT}${source_path}"
    mkdir -p -- "$(dirname -- "$target_path")"
    cp -a -- "$source_path" "$target_path"
}

FILES_TO_BACKUP=(
    /etc/apt/apt.conf.d/52vps-maintenance-periodic
    /etc/apt/apt.conf.d/52vps-maintenance-unattended-upgrades
    /etc/apt/apt.conf.d/52vps-maintenance-kernels
    /etc/needrestart/conf.d/52vps-maintenance.conf
    /etc/systemd/journald.conf.d/99-vps-maintenance.conf
    /etc/systemd/system/vps-maintenance@.service
    /etc/systemd/system/vps-reboot-if-needed.service
)

for name in "${SCRIPT_NAMES[@]}"; do
    FILES_TO_BACKUP+=("/usr/local/sbin/${name}")
done
for name in "${TIMER_NAMES[@]}"; do
    FILES_TO_BACKUP+=("/etc/systemd/system/${name}")
done

for path in "${FILES_TO_BACKUP[@]}"; do
    backup_file "$path"
done

mkdir -p -- "$BACKUP_ROOT"
log "现有相关文件已备份到 ${BACKUP_ROOT}。"

log "停用可能已经存在的旧版维护定时器。"
systemctl disable --now "${TIMER_NAMES[@]}" >/dev/null 2>&1 || true

log "停用 Debian 自带 APT 周期定时器，避免重复更新。"
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

log "安装维护所需软件包。"
apt-get -o Acquire::Retries=3 update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -y install unattended-upgrades needrestart util-linux

log "安装维护脚本。"
for name in "${SCRIPT_NAMES[@]}"; do
    install -o root -g root -m 0755 \
        "${PROJECT_DIR}/scripts/${name}" "/usr/local/sbin/${name}"
done

install -d -o root -g root -m 0755 /usr/local/share/doc/vps-maintenance
install -o root -g root -m 0644 \
    "${PROJECT_DIR}/README.md" /usr/local/share/doc/vps-maintenance/README.md

log "写入 APT、needrestart 和 journald 配置。"
install -d -o root -g root -m 0755 /etc/needrestart/conf.d
install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d

printf '%s\n' \
    '// 关闭 APT 自带周期任务；更新由本项目的 systemd timer 负责。' \
    'APT::Periodic::Enable "0";' \
    > /etc/apt/apt.conf.d/52vps-maintenance-periodic

printf '%s\n' \
    '// 每日任务只允许 Debian 13 官方安全仓库。' \
    '#clear Unattended-Upgrade::Origins-Pattern;' \
    '#clear Unattended-Upgrade::Allowed-Origins;' \
    'Unattended-Upgrade::Origins-Pattern {' \
    '    "origin=Debian,codename=trixie-security,label=Debian-Security";' \
    '};' \
    'Unattended-Upgrade::Automatic-Reboot "false";' \
    'Unattended-Upgrade::Remove-Unused-Dependencies "false";' \
    'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";' \
    'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";' \
    > /etc/apt/apt.conf.d/52vps-maintenance-unattended-upgrades

printf '%s\n' \
    '// 保护正在运行的内核，并至少保留最近三份内核。' \
    'APT::Protect-Kernels "true";' \
    'APT::NeverAutoRemove::KernelCount "3";' \
    > /etc/apt/apt.conf.d/52vps-maintenance-kernels

printf '%s\n' \
    '# 默认只列出待重启服务；维护脚本在 APT 完成后统一自动重启一次。' \
    '$nrconf{restart} = '\''l'\'';' \
    > /etc/needrestart/conf.d/52vps-maintenance.conf

printf '%s\n' \
    '[Journal]' \
    'SystemMaxUse=500M' \
    'MaxRetentionSec=30day' \
    > /etc/systemd/journald.conf.d/99-vps-maintenance.conf

log "安装 systemd 服务和定时器。"
install -o root -g root -m 0644 \
    "${PROJECT_DIR}/systemd/vps-maintenance@.service" \
    /etc/systemd/system/vps-maintenance@.service
install -o root -g root -m 0644 \
    "${PROJECT_DIR}/systemd/vps-reboot-if-needed.service" \
    /etc/systemd/system/vps-reboot-if-needed.service

for name in "${TIMER_NAMES[@]}"; do
    install -o root -g root -m 0644 \
        "${PROJECT_DIR}/systemd/${name}" "/etc/systemd/system/${name}"
done

log "检查 APT 和 systemd 配置。"
apt-config dump >/dev/null
systemctl daemon-reload
systemd-analyze verify \
    vps-maintenance@daily-security.service \
    vps-maintenance@weekly-packages.service \
    vps-maintenance@fortnightly-full-upgrade.service \
    vps-maintenance@monthly-cleanup.service \
    vps-reboot-if-needed.service \
    "${TIMER_NAMES[@]}"

systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true

log "启用固定日期维护定时器。"
systemctl enable --now "${TIMER_NAMES[@]}"

log "安装完成。以下是下一次执行时间："
systemctl list-timers --all 'vps-*' --no-pager

