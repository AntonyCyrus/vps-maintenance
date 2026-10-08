#!/usr/bin/env bash
set -Eeuo pipefail

# 只撤销本项目安装的自动维护组件，不回滚已经完成的软件包升级。

if [[ "${EUID}" -ne 0 ]]; then
    printf '请使用 sudo bash uninstall.sh 运行。\n' >&2
    exit 1
fi

readonly TIMER_NAMES=(
    vps-daily-security.timer
    vps-weekly-packages.timer
    vps-fortnightly-full-upgrade.timer
    vps-reboot-if-needed.timer
    vps-monthly-cleanup.timer
)

systemctl disable --now "${TIMER_NAMES[@]}" >/dev/null 2>&1 || true

rm -f -- \
    /usr/local/sbin/maintenance-daily-security \
    /usr/local/sbin/maintenance-weekly-packages \
    /usr/local/sbin/maintenance-fortnightly-full-upgrade \
    /usr/local/sbin/maintenance-monthly-cleanup \
    /usr/local/sbin/maintenance-reboot-if-needed \
    /etc/systemd/system/vps-maintenance@.service \
    /etc/systemd/system/vps-reboot-if-needed.service \
    /etc/systemd/system/vps-daily-security.timer \
    /etc/systemd/system/vps-weekly-packages.timer \
    /etc/systemd/system/vps-fortnightly-full-upgrade.timer \
    /etc/systemd/system/vps-reboot-if-needed.timer \
    /etc/systemd/system/vps-monthly-cleanup.timer \
    /etc/apt/apt.conf.d/52vps-maintenance-periodic \
    /etc/apt/apt.conf.d/52vps-maintenance-unattended-upgrades \
    /etc/apt/apt.conf.d/52vps-maintenance-kernels \
    /etc/needrestart/conf.d/52vps-maintenance.conf \
    /etc/systemd/journald.conf.d/99-vps-maintenance.conf

systemctl daemon-reload
systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

printf '已移除 VPS 自动维护定时任务，并重新启用 Debian 自带 APT 定时器。\n'
printf '已完成的软件包升级不会被回滚。历史备份仍保留在 /root/vps-maintenance-backup-*。\n'

