#!/bin/bash
# 
# VPS OPtimizer Bash Script
# Author: github.com/opiran-club
#
# For more information and updates, visit github.com/opiran-club and @opiranclub on telegram.
#
# Running this script starts the step-by-step optimizer automatically (no main menu).

CYAN="\e[96m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
BLUE="\e[94m"
MAGENTA="\e[95m"
WHITE="\e[97m"
NC="\e[0m"

export TERM="${TERM:-xterm}"
export DEBIAN_FRONTEND=noninteractive
# Never stop on config-file prompts during apt upgrades/installs
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [ "$EUID" -ne 0 ]; then
    echo && echo -e "\n ${RED}This script must be run as root.${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create FILE.bak once (never overwrite an existing backup with an already-modified file)
backup_file() {
    local f="$1"
    if [ -f "$f" ] && [ ! -f "${f}.bak" ]; then
        cp -p "$f" "${f}.bak"
    fi
}

press_enter() {
    echo -e "\n ${MAGENTA}Press Enter to continue... ${NC}"
    read -r
}

ask_reboot() {
    echo && echo -e "\n ${YELLOW}Reboot now? (Recommended) ${GREEN}[y/n]${NC}"
    read -r reboot
    case "$reboot" in
        [Yy]*)
            systemctl reboot
            ;;
        *)
            return
            ;;
    esac
    exit
}

logo1="     ______    _______    __      _______        __      _____  ___   "
logo2="    /      \  |   __  \  |  \    /       \      /  \     \    \|   \  "
logo3="   /  ____  \ (  |__)  ) |   |  |         |    /    \    |.\   \    | "
logo4="  /  /    )  )|   ____/  |   |  |_____/   )   /' /\  \   |: \   \   | "
logo5=" (  (____/  / (   /      |.  |   //      /   //  __'  \  |.  \    \.| "
logo6="  \        / /    \      /\  |\ |:  __   \  /   /  \\   \ |    \    \| "
logo7="   \_____/ (_______)    (__\_|_)|__|  \___)(___/    \___)\___|\____\) "

logo() {
echo -e "${BLUE}${logo1:0:24}${RED}${logo1:24:19}${WHITE}${logo1:43:14}${GREEN}${logo1:57}${NC}"
echo -e "${BLUE}${logo2:0:24}${RED}${logo2:24:19}${WHITE}${logo2:43:14}${GREEN}${logo2:57}${NC}"
echo -e "${BLUE}${logo3:0:24}${RED}${logo3:24:19}${WHITE}${logo3:43:14}${GREEN}${logo3:57}${NC}"
echo -e "${BLUE}${logo4:0:24}${RED}${logo4:24:19}${WHITE}${logo4:43:14}${GREEN}${logo4:57}${NC}"
echo -e "${BLUE}${logo5:0:24}${RED}${logo5:24:19}${WHITE}${logo5:43:14}${GREEN}${logo5:57}${NC}"
echo -e "${BLUE}${logo6:0:24}${RED}${logo6:24:19}${WHITE}${logo6:43:14}${GREEN}${logo6:57}${NC}"
echo -e "${BLUE}${logo7:0:24}${RED}${logo7:24:19}${WHITE}${logo7:43:14}${GREEN}${logo7:57}${NC}"
}

# ---------------------------------------------------------------------------
# Step 1: apt sources
# ---------------------------------------------------------------------------

sourcelist() {
    clear
    title="Source List Adjustment to Official Repositories"
    logo
    echo ""
    echo -e "${MAGENTA}$title${NC}"
    echo ""
    echo -e "\e[93m+-------------------------------------+\e[0m"
    echo ""

    if [ ! -f /etc/os-release ]; then
        echo && echo -e "${RED}Unable to detect OS. No changes made.${NC}"
        press_enter
        return 1
    fi

    local ID="" VERSION_CODENAME=""
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        ubuntu|debian) ;;
        *)
            echo && echo -e "${RED}Unsupported OS. No changes made.${NC}"
            press_enter
            return 1
            ;;
    esac

    # VERSION_CODENAME is always available; lsb_release may not be installed yet on minimal images
    local release="$VERSION_CODENAME"
    if [ -z "$release" ] && command -v lsb_release >/dev/null 2>&1; then
        release=$(lsb_release -cs)
    fi
    if [ -z "$release" ]; then
        echo && echo -e "${RED}Cannot determine release codename. No changes made.${NC}"
        press_enter
        return 1
    fi

    local tool
    for tool in curl jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo && echo -e "${YELLOW}$tool not found, attempting to install...${NC}"
            apt-get update -qq >/dev/null 2>&1
            if ! apt-get install -y "${APT_OPTS[@]}" "$tool"; then
                echo && echo -e "${RED}Error installing $tool. Aborting.${NC}"
                press_enter
                return 1
            fi
        fi
    done

    # Newer releases (Ubuntu 24.04+, Debian 13+) keep their sources in deb822 files.
    # If we write a classic sources.list, move those aside so entries are not duplicated.
    disable_deb822_sources() {
        local f
        for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/debian.sources; do
            if [ -f "$f" ]; then
                [ -f "${f}.bak" ] || cp -p "$f" "${f}.bak"
                mv -f "$f" "${f}.disabled"
            fi
        done
    }

    write_sources_list() {
        local content="$1" temp_file
        temp_file=$(mktemp) || return 1
        printf '%s\n' "$content" > "$temp_file"
        chmod 644 "$temp_file"
        if ! mv -f "$temp_file" /etc/apt/sources.list; then
            echo && echo -e "${RED}Error writing to sources.list. Changes not saved.${NC}"
            rm -f "$temp_file"
            return 1
        fi
        disable_deb822_sources
    }

    update_ubuntu_sources() {
        local mirror_url
        if [ "$1" = "iran" ]; then
            mirror_url="http://mirror.arvancloud.ir/ubuntu"
        else
            mirror_url="http://archive.ubuntu.com/ubuntu"
        fi
        write_sources_list "deb $mirror_url $release main restricted
deb $mirror_url $release-updates main restricted
deb $mirror_url $release universe
deb $mirror_url $release-updates universe
deb $mirror_url $release multiverse
deb $mirror_url $release-updates multiverse
deb $mirror_url $release-backports main restricted universe multiverse
deb $mirror_url $release-security main restricted
deb $mirror_url $release-security universe
deb $mirror_url $release-security multiverse"
    }

    update_debian_sources() {
        local mirror_url security_mirror_url
        if [ "$1" = "iran" ]; then
            mirror_url="http://mirror.arvancloud.ir/debian"
            security_mirror_url="http://mirror.arvancloud.ir/debian-security"
        else
            mirror_url="http://deb.debian.org/debian"
            security_mirror_url="http://security.debian.org/debian-security"
        fi
        write_sources_list "deb $mirror_url $release main
deb $mirror_url $release-updates main
deb $mirror_url $release-backports main
deb $security_mirror_url $release-security main"
    }

    local location_info location="Unknown" update_choice region
    location_info=$(curl -s --max-time 10 "http://ipwho.is" 2>/dev/null)
    if [[ -n "$location_info" ]]; then
        location=$(echo "$location_info" | jq -r '.country' 2>/dev/null)
    fi
    if [[ -z "$location_info" || -z "$location" || "$location" == "null" ]]; then
        echo && echo -e "${RED}Error fetching location information. Using default mirrors.${NC}"
        location="Unknown"
    fi

    if [[ "$location" == "Iran" ]]; then
        region="iran"
        echo && echo -ne "${YELLOW}Location detected as ${GREEN}Iran${YELLOW}. Update sources list to Iranian mirrors? ${GREEN}[SUGGESTED Y] ${YELLOW}[y/n]: ${NC}"
    else
        region="non-iran"
        echo && echo -ne "${YELLOW}Location detected as ${GREEN}$location${YELLOW}. Update sources list to default mirrors? ${GREEN}[SUGGESTED Y] ${YELLOW}[y/n]: ${NC}"
    fi
    read -r update_choice

    case $update_choice in
        [Yy]*)
            backup_file /etc/apt/sources.list
            case "$ID" in
                ubuntu)
                    if update_ubuntu_sources "$region"; then
                        echo && echo -e "${GREEN}Ubuntu sources list updated.${NC}"
                    fi
                    ;;
                debian)
                    if update_debian_sources "$region"; then
                        echo && echo -e "${GREEN}Debian sources list updated.${NC}"
                    fi
                    ;;
            esac
            ;;
        [Nn]*)
            echo && echo -e "${YELLOW}Skipping sources list update.${NC}"
            ;;
        *)
            echo && echo -e "${RED}Invalid input. No changes made.${NC}"
            ;;
    esac
    press_enter
}

# ---------------------------------------------------------------------------
# Step 2: system update
# ---------------------------------------------------------------------------

complete_update() {
    clear
    title="Update and upgrade packages"
    logo
    echo && echo -e "${CYAN}$title ${NC}"
    echo && printf "\e[93m+-------------------------------------+\e[0m\n" 
    echo && echo -e "${RED}Please wait, it might take a couple of minutes${NC}" && echo
    apt-get update
    apt-get upgrade -y "${APT_OPTS[@]}"
    apt-get autoremove -y
    apt-get clean
    echo && echo -e "${GREEN}System update & upgrade completed.${NC}"
    sleep 1
    press_enter
}

# ---------------------------------------------------------------------------
# Step 3: useful packages
# ---------------------------------------------------------------------------

installations() {
    clear
    title="Install necessary packages"
    logo
    echo && echo -e "${MAGENTA}$title ${NC}"
    echo && printf "\e[93m+-------------------------------------+\e[0m\n"
    echo && echo -e "${YELLOW}Please wait, it might take a while${NC}"

    local packages=(jq nload nethogs autossh ssh iperf software-properties-common apt-transport-https
                    lsb-release ca-certificates gnupg2 bash-completion curl git unzip
                    zip wget locales nano python3 net-tools haveged htop dnsutils iputils-ping)

    if ! apt-get install -y "${APT_OPTS[@]}" "${packages[@]}"; then
        # One unavailable package makes apt reject the whole list, so retry one by one
        echo && echo -e "${YELLOW}Bulk install failed, retrying package by package...${NC}"
        local pkg failed=()
        for pkg in "${packages[@]}"; do
            apt-get install -y "${APT_OPTS[@]}" "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
        done
        if [ "${#failed[@]}" -gt 0 ]; then
            echo && echo -e "${RED}Could not install: ${failed[*]}${NC}"
        fi
    fi
    echo && echo -e "${GREEN}Installation of useful and necessary packages completed.${NC}"
    sleep 1
    press_enter
}

# ---------------------------------------------------------------------------
# Step 4: timezone detection
# ---------------------------------------------------------------------------

set_timezone() {
    clear
    title="Timezone Adjustment"
    logo 
    echo && printf "${MAGENTA}%s ${NC}\n" "$title"
    echo && printf "\e[93m+-------------------------------------+\e[0m\n"
    local current_timezone
    current_timezone=$(timedatectl 2>/dev/null | awk '/Time zone/ {print $3}')
    echo && printf "${YELLOW}Your current timezone is ${GREEN}%s${NC}\n" "$current_timezone"
    local tool
    for tool in curl jq; do
        if ! command -v "$tool" &> /dev/null; then
            echo && printf "${RED}Error: %s is not installed. Please install it to proceed.${NC}\n" "$tool"
            press_enter
            return 1
        fi
    done

    local public_ip="" location="" timezone="" content source v
    local sources=("http://ipwho.is" "http://ip-api.com/json")
    for source in "${sources[@]}"; do
        public_ip="" location="" timezone=""
        content=$(curl -s --max-time 10 "$source" 2>/dev/null) || continue
        case "$source" in
            "http://ipwho.is")
                public_ip=$(echo "$content" | jq -r '.ip' 2>/dev/null)
                location=$(echo "$content" | jq -r '.city' 2>/dev/null)
                timezone=$(echo "$content" | jq -r '.timezone.id' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
            "http://ip-api.com/json")
                public_ip=$(echo "$content" | jq -r '.query' 2>/dev/null)
                location=$(echo "$content" | jq -r '.city' 2>/dev/null)
                timezone=$(echo "$content" | jq -r '.timezone' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
        esac
        # jq prints the string "null" for missing fields
        for v in public_ip location timezone; do
            [[ "${!v}" == "null" ]] && printf -v "$v" '%s' ""
        done
        if [[ -n "$location" && -n "$timezone" && -n "$public_ip" ]]; then
            break
        fi
    done

    if [[ -n "$location" && -n "$timezone" && -n "$public_ip" ]]; then
        printf "${YELLOW}Your public IP is ${GREEN}%s${NC}\n" "$public_ip"
        printf "${YELLOW}Your location is ${GREEN}%s${NC}\n" "$location"
        printf "${YELLOW}Your detected timezone is ${GREEN}%s${NC}\n" "$timezone"
        local date_time
        date_time=$(TZ="$timezone" date "+%Y-%m-%d %H:%M:%S")
        echo && printf "${YELLOW}The current date and time in your detected timezone is ${GREEN}%s${NC}\n" "$date_time"
    else
        echo && printf "${RED}Error: Failed to fetch location and timezone information from all sources.${NC}\n"
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# Step 5: sysctl / limits
# ---------------------------------------------------------------------------

remove_old_sysctl() {
    clear
    title=" Network Optimizing "
    logo
    echo && echo -e "${MAGENTA}$title${NC}"
    echo && echo -e "\e[93m+-------------------------------------+\e[0m"
    [ -f /etc/profile ] && sed -i '/1000000/d' /etc/profile
    backup_file /etc/sysctl.conf
    mkdir -p /etc/security
    backup_file /etc/security/limits.conf
cat <<EOL > /etc/sysctl.conf
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

cat <<EOL > /etc/security/limits.conf
* soft nproc 655350
* hard nproc 655350
* soft nofile 655350
* hard nofile 655350
root soft nproc 655350
root hard nproc 655350
root soft nofile 655350
root hard nofile 655350
EOL
    if sysctl -p >/dev/null; then
        echo && echo -e "${GREEN}Sysctl configuration and optimization complete.${NC}"
    else
        echo && echo -e "${YELLOW}Sysctl configuration written, but some keys could not be applied (normal on containers / older kernels).${NC}"
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# Step 6: SSH
# ---------------------------------------------------------------------------

optimize_ssh_configuration() {
    clear
    local SSH_PATH="/etc/ssh/sshd_config"
    title="Improve SSH Configuration and Optimize SSHD"
    logo
    echo && echo -e "${MAGENTA}$title${NC}\n"
    echo && echo -e "\e[93m+-------------------------------------+\e[0m\n"
    if [ ! -f "$SSH_PATH" ]; then
        echo && echo -e "${RED}Error: SSH configuration file not found at ${SSH_PATH}.${NC}"
        press_enter
        return 1
    fi
    backup_file "$SSH_PATH"
    echo && echo -e "${YELLOW}Backup of the original SSH configuration is at ${SSH_PATH}.bak${NC}"

    # Keep the settings that decide whether you can still log in
    local before ssh_port root_login pass_auth
    before=$(mktemp)
    cp -p "$SSH_PATH" "$before"
    sshd_value() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'; }
    ssh_port=$(sshd_value port);                 ssh_port=${ssh_port:-22}
    root_login=$(sshd_value permitrootlogin);    root_login=${root_login:-prohibit-password}
    pass_auth=$(sshd_value passwordauthentication); pass_auth=${pass_auth:-yes}

cat <<EOL > "$SSH_PATH"
# Optimized SSH configuration for improved security and performance

Port $ssh_port
PermitRootLogin $root_login
PasswordAuthentication $pass_auth
PubkeyAuthentication yes
UsePAM yes
HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256,hmac-sha2-512
KexAlgorithms curve25519-sha256,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256
UseDNS no
MaxSessions 10
Compression no
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 3
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
Banner /etc/ssh/banner
X11Forwarding no
PrintMotd no
PrintLastLog yes
MaxAuthTries 3
LoginGraceTime 1m
MaxStartups 10:30:60
Subsystem sftp internal-sftp
EOL
    echo "WARNING: Unauthorized access to this system is prohibited." > /etc/ssh/banner

    # Never restart sshd with a config it rejects
    if command -v sshd >/dev/null 2>&1 && ! sshd -t; then
        echo && echo -e "${RED}New SSH configuration is invalid. Restoring previous configuration.${NC}"
        cp -p "$before" "$SSH_PATH"
        rm -f "$before"
        press_enter
        return 1
    fi
    rm -f "$before"

    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null; then
        echo && echo -e "${GREEN}SSH and SSHD configuration and optimization complete.${NC}"
    else
        echo && echo -e "${RED}Failed to restart SSH service. Please check the configuration.${NC}"
        press_enter
        return 1
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# Final screen
# ---------------------------------------------------------------------------

final() {
    clear
    logo
    echo && echo -e "    ${MAGENTA} Your server fully optimized successfully${NC}"
    printf "\e[93m+-------------------------------------+\e[0m\n" 
    echo && echo -e "${MAGENTA}Please reboot the system to take effect, by running the following command: ${GREEN}reboot${NC}"
    echo && echo -e "${MAGENTA}Please visit me at: ${GREEN}https://t.me/OPIranCluB ${NC}"
    echo && printf "\e[93m+-------------------------------------+\e[0m\n" 
    echo && ask_reboot
}

# ---------------------------------------------------------------------------
# Main: run the step-by-step optimizer automatically
# ---------------------------------------------------------------------------

main() {
    sourcelist
    complete_update
    installations
    set_timezone
    remove_old_sysctl
    optimize_ssh_configuration
    final
}

main
