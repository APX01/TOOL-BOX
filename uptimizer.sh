#!/bin/bash
#
# UPTIMIZER - one-shot VPS optimizer
# Runs everything automatically (no prompts, no Enter) and reboots at the end.
#

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
CYAN=$'\e[96m'
GREEN=$'\e[92m'
YELLOW=$'\e[93m'
RED=$'\e[91m'
BLUE=$'\e[94m'
MAGENTA=$'\e[95m'
WHITE=$'\e[97m'
DIM=$'\e[2m'
BOLD=$'\e[1m'
NC=$'\e[0m'

export TERM="${TERM:-xterm}"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # don't ask to restart services (Ubuntu 22.04+)
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFOLD=1

# Never stop on config-file prompts; wait for apt/dpkg locks instead of failing
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=120)

LOG="/var/log/uptimizer.log"
REBOOT_DELAY=10

if [ "$EUID" -ne 0 ]; then
    echo -e "\n ${RED}This script must be run as root.${NC}"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "\n ${RED}This script supports Debian/Ubuntu (apt) only.${NC}"
    exit 1
fi

: > "$LOG" 2>/dev/null || LOG="/tmp/uptimizer.log"
: > "$LOG"

trap 'echo -e "\n ${YELLOW}Cancelled.${NC}"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
LINE="${YELLOW}══════════════════════════════════════════════════════════════${NC}"

banner() {
    local colors=("$CYAN" "$CYAN" "$BLUE" "$BLUE" "$MAGENTA") i=0 row
    echo
    while IFS= read -r row; do
        printf '%s%s%s\n' "${colors[i]}" "$row" "$NC"
        i=$((i + 1))
    done <<'EOF'
 _   _  ____   _____  ___  __  __  ___  _____  _____  ____  
| | | ||  _ \ |_   _||_ _||  \/  ||_ _||__  /| ____||  _ \ 
| | | || |_) |  | |   | | | |\/| | | |   / / |  _|  | |_) |
| |_| ||  __/   | |   | | | |  | | | |  / /_ | |___ |  _ < 
 \___/ |_|      |_|  |___||_|  |_||___|/____||_____||_| \_\
EOF
    echo
    echo -e "$LINE"
    echo -e "  ${WHITE}${BOLD}Automatic VPS Optimizer${NC}  ${DIM}• fully unattended • auto reboot${NC}"
    echo -e "$LINE"
    echo
}

STEP_TOTAL=6
STEP_NUM=0
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# run_step "label" function [args...]
#   function exit code: 0 = ok, 2 = done with warnings, anything else = failed
run_step() {
    local label="$1"; shift
    local frames='|/-\' i=0 pid rc tag
    STEP_NUM=$((STEP_NUM + 1))
    tag="${DIM}[${STEP_NUM}/${STEP_TOTAL}]${NC}"

    echo "### [$STEP_NUM/$STEP_TOTAL] $label" >> "$LOG"
    "$@" >> "$LOG" 2>&1 < /dev/null &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K  %s %s[ %s ]%s %s' "$tag" "$CYAN" "${frames:$((i % 4)):1}" "$NC" "$label"
        i=$((i + 1))
        sleep 0.2
    done
    wait "$pid"
    rc=$?

    case "$rc" in
        0) printf '\r\033[K  %s %s[ ✔ ]%s %s\n' "$tag" "$GREEN" "$NC" "$label"; OK_COUNT=$((OK_COUNT + 1)) ;;
        2) printf '\r\033[K  %s %s[ ! ]%s %s %s(finished with warnings)%s\n' "$tag" "$YELLOW" "$NC" "$label" "$DIM" "$NC"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
        *) printf '\r\033[K  %s %s[ ✘ ]%s %s %s(failed, see log)%s\n' "$tag" "$RED" "$NC" "$label" "$DIM" "$NC"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

# Create FILE.bak once (never overwrite an existing backup with an already-modified file)
backup_file() {
    local f="$1"
    if [ -f "$f" ] && [ ! -f "${f}.bak" ]; then
        cp -p "$f" "${f}.bak"
    fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step_update() {
    apt-get "${APT_OPTS[@]}" update
}

step_upgrade() {
    apt-get -y "${APT_OPTS[@]}" upgrade
}

step_cleanup() {
    apt-get -y "${APT_OPTS[@]}" autoremove || return 1
    apt-get clean
}

step_packages() {
    local packages=(jq nload nethogs autossh ssh iperf software-properties-common apt-transport-https
                    lsb-release ca-certificates gnupg2 bash-completion curl git unzip
                    zip wget locales nano python3 net-tools haveged htop dnsutils iputils-ping)

    if apt-get install -y "${APT_OPTS[@]}" "${packages[@]}"; then
        return 0
    fi

    # One unavailable package makes apt reject the whole list, so retry one by one
    echo "Bulk install failed, retrying package by package..."
    local pkg failed=()
    for pkg in "${packages[@]}"; do
        apt-get install -y "${APT_OPTS[@]}" "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "Could not install: ${failed[*]}"
        # Everything failed -> real failure, otherwise just a warning
        [ "${#failed[@]}" -eq "${#packages[@]}" ] && return 1
        return 2
    fi
    return 0
}

step_network() {
    [ -f /etc/profile ] && sed -i '/1000000/d' /etc/profile
    backup_file /etc/sysctl.conf
    modprobe tcp_bbr 2>/dev/null || true

cat <<'EOL' > /etc/sysctl.conf
# System Configuration Settings for Improved Performance and Security

# File limits
fs.file-max = 67108864

# Network core settings
net.core.default_qdisc = fq_codel
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_max = 33554432
net.core.wmem_default = 1048576

# Memory Optimization
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# TCP settings
net.ipv4.tcp_rmem = 16384 1048576 33554432
net.ipv4.tcp_wmem = 16384 1048576 33554432
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = 65536 1048576 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1

# UDP settings
net.ipv4.udp_mem = 65536 1048576 33554432

# IPv6 settings
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

# Unix domain sockets
net.unix.max_dgram_qlen = 256

# VM settings
vm.min_free_kbytes = 65536
vm.swappiness = 10
vm.vfs_cache_pressure = 100

# Packet filtering
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# ARP settings
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2

# Kernel settings
kernel.printk = 4 4 1 7
kernel.panic = 1
vm.dirty_ratio = 15
EOL

    # Some keys may not exist in containers / older kernels: that is only a warning
    if sysctl -p /etc/sysctl.conf; then
        return 0
    fi
    return 2
}

step_limits() {
    mkdir -p /etc/security
    backup_file /etc/security/limits.conf
cat <<'EOL' > /etc/security/limits.conf
* soft nproc 655350
* hard nproc 655350
* soft nofile 655350
* hard nofile 655350
root soft nproc 655350
root hard nproc 655350
root soft nofile 655350
root hard nofile 655350
EOL
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

reboot_now() {
    systemctl reboot 2>/dev/null || reboot 2>/dev/null || shutdown -r now
}

main() {
    clear
    banner
    echo -e "  ${MAGENTA}${BOLD}Applying changes${NC}"
    echo

    run_step "Update package lists            (apt update)"      step_update
    run_step "Upgrade installed packages      (apt upgrade)"     step_upgrade
    run_step "Remove unused packages & clean cache"              step_cleanup
    run_step "Install essential tools         (curl, git, htop...)" step_packages
    run_step "Network optimization            (BBR + sysctl)"    step_network
    run_step "System limits optimization      (nofile / nproc)"  step_limits

    echo
    echo -e "$LINE"
    printf '  %s%s✔ %d done%s   %s! %d warnings%s   %s✘ %d failed%s\n' \
        "$GREEN" "$BOLD" "$OK_COUNT" "$NC" "$YELLOW" "$WARN_COUNT" "$NC" "$RED" "$FAIL_COUNT" "$NC"
    echo -e "  ${DIM}Log: ${LOG}${NC}"
    echo -e "$LINE"
    echo

    local s
    for ((s = REBOOT_DELAY; s > 0; s--)); do
        printf '\r\033[K  %sRebooting in %s%2d%s seconds...  %s(Ctrl+C to cancel)%s' \
            "$MAGENTA" "$GREEN" "$s" "$MAGENTA" "$DIM" "$NC"
        sleep 1
    done
    printf '\r\033[K  %sRebooting now...%s\n' "$GREEN" "$NC"
    sync
    reboot_now
}

main
