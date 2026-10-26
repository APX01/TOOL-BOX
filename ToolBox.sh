#!/bin/bash

#===========================================
# Toolbox - Advanced Server Management Script
# Compatible with Ubuntu 22.04/24.04
# Author: Advanced Network Tools
# Version: 1.1
#===========================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
NFTABLES_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-toolbox.conf"
NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="/root/toolbox_backups"
BLOCKLIST_URL="https://raw.githubusercontent.com/APX01/TOOL-BOX/main/Ips.txt"

# Set to "true" by init_nftables when it had to create/repair something
NFT_CHANGED="false"

#===========================================
# Utility Functions
#===========================================

# Check if script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${BOLD}Error: This script must be run as root!${NC}"
        echo -e "${YELLOW}Please run with: sudo bash $0${NC}"
        exit 1
    fi
}

# Create backup directory
init_backup_dir() {
    mkdir -p "$BACKUP_DIR"
}

# Print header
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                        TOOLBOX v1.1                        ║"
    echo "║           Advanced Server Management & Security            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Print status bar
print_status() {
    local title="$1"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}$title${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Success message
success_msg() {
    echo -e "${GREEN}${BOLD}✓ $1${NC}"
}

# Error message
error_msg() {
    echo -e "${RED}${BOLD}✗ $1${NC}"
}

# Warning message
warning_msg() {
    echo -e "${YELLOW}${BOLD}⚠ $1${NC}"
}

# Info message
info_msg() {
    echo -e "${CYAN}${BOLD}ℹ $1${NC}"
}

# Pause function
pause() {
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Validate an IPv4 address (each octet 0-255)
is_valid_ipv4() {
    local ip="$1"
    local o1 o2 o3 o4 octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"; o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

#===========================================
# System Detection Functions
#===========================================

# Detect SSH service name (ssh or sshd)
detect_ssh_service() {
    if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
        echo "ssh"
    elif systemctl list-unit-files sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
        echo "sshd"
    else
        echo ""
    fi
}

# Get all SSH ports in effect (space separated)
get_ssh_ports() {
    local ports=""

    # 1) Ports sshd is really listening on
    ports=$(ss -H -tlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')

    # 2) Socket-activated ssh (Ubuntu 22.10+/24.04)
    if [[ -z "${ports// /}" ]] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
        ports=$(systemctl show ssh.socket -p Listen --value 2>/dev/null | awk '/Stream/ {n=split($1,a,":"); print a[n]}' | sort -un | tr '\n' ' ')
    fi

    # 3) Effective sshd configuration
    if [[ -z "${ports// /}" ]] && command -v sshd &>/dev/null; then
        ports=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un | tr '\n' ' ')
    fi

    # 4) Raw config file
    if [[ -z "${ports// /}" ]] && [[ -f /etc/ssh/sshd_config ]]; then
        ports=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | sort -un | tr '\n' ' ')
    fi

    # 5) Default
    if [[ -z "${ports// /}" ]]; then
        ports="22 "
    fi

    echo "${ports% }"
}

# Get first (main) SSH port
get_ssh_port() {
    get_ssh_ports | awk '{print $1}'
}

# Check if IPv6 is enabled
check_ipv6_status() {
    local ipv6_disable
    ipv6_disable=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [[ "$ipv6_disable" == "1" ]]; then
        echo "disabled"
    else
        echo "enabled"
    fi
}

# Check ICMP status
check_icmp_status() {
    local chain
    chain=$(nft list chain inet filter input 2>/dev/null) || { echo "allowed"; return; }

    if grep -q "echo-request drop" <<< "$chain"; then
        echo "blocked"
    elif grep -q "icmp type echo-request accept" <<< "$chain"; then
        echo "allowed"
    elif grep -q "policy drop" <<< "$chain"; then
        echo "blocked"
    else
        echo "allowed"
    fi
}

# Check if IP blocklist is active
check_blocklist_status() {
    local set_out count
    set_out=$(nft list set inet filter blocklist 2>/dev/null) || { echo "inactive"; return; }

    count=$(grep -oE '[0-9]+(\.[0-9]+){3}(/[0-9]+)?(-[0-9]+(\.[0-9]+){3})?' <<< "$set_out" | wc -l)

    if [[ "$count" -gt 0 ]] && nft list chain inet filter output 2>/dev/null | grep -q '@blocklist'; then
        echo "active ($count ranges)"
    else
        echo "inactive"
    fi
}

# Get current DNS servers
get_dns_servers() {
    local dns_list=""

    if systemctl is-active --quiet systemd-resolved; then
        dns_list=$(resolvectl status 2>/dev/null | grep -m1 -E '^[[:space:]]*DNS Servers:' | sed 's/^.*DNS Servers:[[:space:]]*//')

        # If empty, check the config file
        if [[ -z "$dns_list" ]] && [[ -f /etc/systemd/resolved.conf.d/dns.conf ]]; then
            dns_list=$(grep "^DNS=" /etc/systemd/resolved.conf.d/dns.conf | cut -d= -f2)
        fi
    fi

    # Fallback to resolv.conf
    if [[ -z "$dns_list" ]]; then
        dns_list=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -2 | tr '\n' ' ')
    fi

    if [[ -z "$dns_list" ]]; then
        echo "Not configured"
    else
        echo "$dns_list"
    fi
}

#===========================================
# Display Status Dashboard
#===========================================

display_status_dashboard() {
    echo ""
    print_status "📊 System Status Dashboard"
    echo ""

    # SSH Status
    local ssh_service ssh_ports
    ssh_service=$(detect_ssh_service)
    ssh_ports=$(get_ssh_ports)
    if [[ -n "$ssh_service" ]] && { systemctl is-active --quiet "$ssh_service" || systemctl is-active --quiet ssh.socket 2>/dev/null; }; then
        echo -e "${GREEN}●${NC} SSH Service: ${GREEN}Active${NC} (Port: ${CYAN}$ssh_ports${NC})"
    else
        echo -e "${RED}●${NC} SSH Service: ${RED}Inactive${NC}"
    fi

    # NFTables Status
    if systemctl is-active --quiet nftables; then
        echo -e "${GREEN}●${NC} NFTables: ${GREEN}Active${NC}"
    else
        echo -e "${RED}●${NC} NFTables: ${RED}Inactive${NC}"
    fi

    # IPv6 Status
    local ipv6_status
    ipv6_status=$(check_ipv6_status)
    if [[ "$ipv6_status" == "enabled" ]]; then
        echo -e "${GREEN}●${NC} IPv6: ${GREEN}Enabled${NC}"
    else
        echo -e "${YELLOW}●${NC} IPv6: ${YELLOW}Disabled${NC}"
    fi

    # ICMP Status
    local icmp_status
    icmp_status=$(check_icmp_status)
    if [[ "$icmp_status" == "blocked" ]]; then
        echo -e "${YELLOW}●${NC} ICMP (Ping): ${YELLOW}Blocked${NC}"
    else
        echo -e "${GREEN}●${NC} ICMP (Ping): ${GREEN}Allowed${NC}"
    fi

    # IP Blocklist
    local blocklist_status
    blocklist_status=$(check_blocklist_status)
    if [[ "$blocklist_status" != "inactive" ]]; then
        echo -e "${GREEN}●${NC} IP Blocklist: ${GREEN}$blocklist_status${NC}"
    else
        echo -e "${YELLOW}●${NC} IP Blocklist: ${YELLOW}Inactive${NC}"
    fi

    # DNS Servers
    local dns_servers
    dns_servers=$(get_dns_servers)
    echo -e "${CYAN}●${NC} DNS Servers: ${CYAN}$dns_servers${NC}"

    echo ""
}

#===========================================
# NFTables Management
#===========================================

# Add a rule to the input chain only if it is not already there.
# Usage: ensure_input_rule "<text as printed by nft list>" <rule words...>
ensure_input_rule() {
    local pattern="$1"
    shift
    if ! nft list chain inet filter input 2>/dev/null | grep -qE "^[[:space:]]*${pattern}"; then
        if nft add rule inet filter input "$@"; then
            NFT_CHANGED="true"
        fi
    fi
}

# Initialize nftables (idempotent: only changes what is missing)
init_nftables() {
    NFT_CHANGED="false"

    # Install nftables if not present
    if ! command -v nft &> /dev/null; then
        info_msg "Installing nftables..."
        apt-get update -qq
        apt-get install -y nftables
    fi

    # Table
    if ! nft list table inet filter &>/dev/null; then
        nft add table inet filter
        NFT_CHANGED="true"
    fi

    # Chains (created with accept policy first, so nothing breaks while rules are added)
    if ! nft list chain inet filter input &>/dev/null; then
        nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
        NFT_CHANGED="true"
    fi
    if ! nft list chain inet filter output &>/dev/null; then
        nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
        NFT_CHANGED="true"
    fi
    if ! nft list chain inet filter forward &>/dev/null; then
        nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
        NFT_CHANGED="true"
    elif nft list chain inet filter forward 2>/dev/null | grep -q "policy drop"; then
        # A drop policy here breaks Docker / routed traffic
        nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
        NFT_CHANGED="true"
    fi

    # Base input rules
    local p
    ensure_input_rule 'ct state established,related accept' ct state established,related accept
    ensure_input_rule 'iif "lo" accept' iif lo accept
    for p in $(get_ssh_ports); do
        ensure_input_rule "tcp dport ${p} accept" tcp dport "$p" accept
    done
    ensure_input_rule 'udp dport 53 accept' udp dport 53 accept
    ensure_input_rule 'tcp dport 53 accept' tcp dport 53 accept
    # IPv6 neighbour discovery / router advertisements need ICMPv6
    ensure_input_rule 'meta l4proto ipv6-icmp accept' meta l4proto ipv6-icmp accept
    # DHCP replies
    ensure_input_rule 'udp sport 67 udp dport 68 accept' udp sport 67 udp dport 68 accept

    # Only now (SSH is already allowed) switch the input policy to drop
    if ! nft list chain inet filter input 2>/dev/null | grep -q "policy drop"; then
        nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
        NFT_CHANGED="true"
    fi

    if [[ "$NFT_CHANGED" == "true" ]]; then
        save_nftables
        success_msg "NFTables base rules are ready"
    fi
}

# Save nftables rules permanently (only our own table, so Docker's rules are untouched)
save_nftables() {
    local tmp="${NFTABLES_CONF}.toolbox.tmp"

    {
        echo "#!/usr/sbin/nft -f"
        echo ""
        echo "# Managed by Toolbox"
        echo "table inet filter"
        echo "delete table inet filter"
        nft list table inet filter
    } > "$tmp" 2>/dev/null

    if nft -c -f "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$NFTABLES_CONF"
        systemctl enable --now nftables >/dev/null 2>&1
    else
        rm -f "$tmp"
        warning_msg "Could not validate rules file; permanent save skipped"
    fi
}

# Backup current nftables rules
backup_nftables() {
    local backup_file="$BACKUP_DIR/nftables_$(date +%Y%m%d_%H%M%S).conf"
    nft list table inet filter > "$backup_file" 2>/dev/null
    echo "$backup_file"
}

# Print the rule handles in a chain matching a grep -E pattern
nft_rule_handles() {
    local chain="$1"
    local pattern="$2"
    nft -a list chain inet filter "$chain" 2>/dev/null | grep -E "$pattern" | grep -oP 'handle \K[0-9]+'
}

# Delete every rule in a chain matching a grep -E pattern
nft_delete_rules() {
    local chain="$1"
    local pattern="$2"
    local handle
    for handle in $(nft_rule_handles "$chain" "$pattern"); do
        nft delete rule inet filter "$chain" handle "$handle" 2>/dev/null
    done
}

#===========================================
# 1. SSH Port Management
#===========================================

# Restore the SSH configuration saved in a backup directory
restore_ssh_backup() {
    local dir="$1"
    local ssh_service="$2"

    cp -a "$dir/sshd_config" /etc/ssh/sshd_config
    if [[ -d "$dir/sshd_config.d" ]]; then
        rm -rf /etc/ssh/sshd_config.d
        cp -a "$dir/sshd_config.d" /etc/ssh/sshd_config.d
    fi
    rm -f /etc/systemd/system/ssh.socket.d/toolbox.conf
    rmdir /etc/systemd/system/ssh.socket.d 2>/dev/null
    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    fi
    systemctl restart "$ssh_service"
}

change_ssh_port() {
    print_header
    print_status "🔐 SSH Port Configuration"
    echo ""

    local ssh_service
    ssh_service=$(detect_ssh_service)
    if [[ -z "$ssh_service" ]]; then
        error_msg "SSH service not found!"
        pause
        return
    fi

    local current_port
    current_port=$(get_ssh_port)
    info_msg "Current SSH Port: $current_port"
    info_msg "Detected SSH Service: $ssh_service"
    echo ""

    echo -e "${YELLOW}Enter new SSH port (1024-65535, Enter to cancel):${NC}"
    local new_port
    read -r new_port

    if [[ -z "$new_port" ]]; then
        return
    fi

    # Validate port number
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        error_msg "Invalid port number!"
        pause
        return
    fi

    if [[ "$new_port" == "$current_port" ]]; then
        error_msg "Port $new_port is already the SSH port!"
        pause
        return
    fi

    # Check if port is already in use
    if ss -H -tuln | awk '{print $5}' | grep -Eq "[:.]${new_port}$"; then
        error_msg "Port $new_port is already in use!"
        pause
        return
    fi

    echo ""
    info_msg "Changing SSH port from $current_port to $new_port"

    # Backup SSH configuration
    local ssh_config="/etc/ssh/sshd_config"
    local backup_sub="$BACKUP_DIR/ssh_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_sub"
    cp -a "$ssh_config" "$backup_sub/sshd_config"
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d "$backup_sub/sshd_config.d"
    fi

    # Firewall first: open the new port while the old one stays open
    init_nftables
    ensure_input_rule "tcp dport ${new_port} accept" tcp dport "$new_port" accept

    # Update SSH config: remove old Port lines (also in drop-ins), put new one on top
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$f"
    done
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$ssh_config"
    sed -i "1i Port $new_port" "$ssh_config"

    # Socket-activated SSH (Ubuntu 24.04) ignores "Port", it needs a socket drop-in
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/toolbox.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$new_port
ListenStream=[::]:$new_port
EOF
        systemctl daemon-reload
    fi

    # Validate configuration before restarting
    if command -v sshd &>/dev/null && ! sshd -t 2>/dev/null; then
        error_msg "New SSH configuration is invalid! Reverting..."
        restore_ssh_backup "$backup_sub" "$ssh_service"
        nft_delete_rules input "tcp dport ${new_port} accept"
        save_nftables
        error_msg "Changes reverted"
        pause
        return
    fi

    info_msg "Restarting SSH service..."
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    fi
    systemctl restart "$ssh_service"
    sleep 1

    # Verify sshd really listens on the new port
    if ss -H -tln | awk '{print $4}' | grep -Eq "[:.]${new_port}$"; then
        # Success: close the old SSH port
        nft_delete_rules input "^[[:space:]]*tcp dport ${current_port} accept"
        save_nftables

        success_msg "SSH port changed to $new_port"
        success_msg "Firewall updated (old port $current_port closed)"
        echo ""
        warning_msg "Use the new port from now on!"
        warning_msg "Example: ssh -p $new_port user@server"
    else
        error_msg "SSH is not listening on port $new_port! Reverting..."
        restore_ssh_backup "$backup_sub" "$ssh_service"
        nft_delete_rules input "tcp dport ${new_port} accept"
        ensure_input_rule "tcp dport ${current_port} accept" tcp dport "$current_port" accept
        save_nftables
        error_msg "Changes reverted due to error"
    fi

    pause
}

#===========================================
# 2. Port Management (Toggle System)
#===========================================

manage_ports_menu() {
    print_header
    print_status "🔌 Port Management"
    echo ""

    init_nftables

    # SSH ports must never be closed
    local ssh_ports
    ssh_ports=$(get_ssh_ports)

    info_msg "Current Open Ports (excluding SSH and DNS):"
    echo ""

    local chain_dump tcp_ports udp_ports
    chain_dump=$(nft list chain inet filter input 2>/dev/null)

    tcp_ports=$(grep -oP '^\s*tcp dport \K[0-9]+(?= accept)' <<< "$chain_dump" | awk -v ex=" 53 $ssh_ports " 'index(ex, " " $1 " ") == 0' | sort -un | tr '\n' ' ')
    udp_ports=$(grep -oP '^\s*udp dport \K[0-9]+(?= accept)' <<< "$chain_dump" | awk -v ex=" 53 " 'index(ex, " " $1 " ") == 0' | sort -un | tr '\n' ' ')

    if [[ -n "$tcp_ports" ]]; then
        echo -e "${GREEN}  TCP:${NC} $tcp_ports"
    else
        echo -e "${YELLOW}  TCP: No additional ports${NC}"
    fi

    if [[ -n "$udp_ports" ]]; then
        echo -e "${GREEN}  UDP:${NC} $udp_ports"
    else
        echo -e "${YELLOW}  UDP: No additional ports${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Enter port(s) to toggle (open if closed, close if open):${NC}"
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  ${WHITE}8443${NC}              - Toggle single port"
    echo -e "  ${WHITE}80,443,2082,8080${NC}  - Toggle multiple ports"
    echo -e "  ${WHITE}[Enter]${NC}           - Return to main menu"
    echo ""
    echo -n "Ports: "
    local port_input
    read -r port_input

    # If empty, return to main menu
    if [[ -z "$port_input" ]]; then
        return
    fi

    # Split ports by comma
    local -a PORTS
    IFS=',' read -ra PORTS <<< "$port_input"

    local opened_count=0
    local closed_count=0
    local fail_count=0
    local port

    echo ""
    info_msg "Processing ports..."
    echo ""

    for port in "${PORTS[@]}"; do
        # Trim whitespace
        port=$(echo "$port" | xargs)

        # Validate port
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            error_msg "Invalid port: $port (skipping)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Prevent closing SSH ports
        if [[ " $ssh_ports " == *" $port "* ]]; then
            error_msg "Cannot toggle SSH port $port (skipping)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Prevent closing DNS port
        if [[ "$port" == "53" ]]; then
            warning_msg "DNS port 53 is protected (skipping)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Check if port is already open (TCP or UDP)
        if nft list chain inet filter input 2>/dev/null | grep -qP "^\s*(tcp|udp) dport $port accept"; then
            # Port is open, close it (all TCP/UDP rules for it)
            nft_delete_rules input "^[[:space:]]*(tcp|udp) dport $port accept"

            success_msg "Port $port closed (TCP/UDP)"
            closed_count=$((closed_count + 1))
        else
            # Port is closed, open it
            nft add rule inet filter input tcp dport "$port" accept
            nft add rule inet filter input udp dport "$port" accept

            success_msg "Port $port opened (TCP/UDP)"
            opened_count=$((opened_count + 1))
        fi
    done

    # Save rules
    save_nftables

    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Operation Summary:${NC}"
    echo -e "  ${GREEN}✓ Opened:${NC} $opened_count"
    echo -e "  ${YELLOW}✓ Closed:${NC} $closed_count"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "  ${RED}✗ Failed/Skipped:${NC} $fail_count"
    fi
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    pause
}

#===========================================
# 3. IP Blocklist Management
#===========================================

# Convert a raw list (IPs / CIDRs, junk allowed) into a clean, normalized,
# non-overlapping CIDR list. Usage: normalize_ip_list <input> <output>
normalize_ip_list() {
    local in_file="$1"
    local out_file="$2"

    tr -d '\r' < "$in_file" | sed 's/[[:space:]]//g' | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {
            split($0, a, "/")
            m = (a[2] == "") ? 32 : a[2] + 0
            if (m > 32) next
            split(a[1], o, ".")
            if (o[1] + 0 > 255 || o[2] + 0 > 255 || o[3] + 0 > 255 || o[4] + 0 > 255) next
            ip = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
            size = 2 ^ (32 - m)
            start = int(ip / size) * size
            printf "%.0f %.0f\n", start, start + size - 1
        }' | sort -k1,1n -k2,2nr | awk '
        BEGIN { maxend = -1 }
        {
            # sorted by start asc / end desc; CIDRs either nest or are disjoint
            if ($1 + 0 > maxend) {
                s = $1 + 0
                size = $2 - $1 + 1
                m = 32
                t = size
                while (t > 1) { t = t / 2; m-- }
                a = int(s / 16777216); r = s - a * 16777216
                b = int(r / 65536);    r = r - b * 65536
                c = int(r / 256);      d = r - c * 256
                if (m == 32) printf "%d.%d.%d.%d\n", a, b, c, d
                else         printf "%d.%d.%d.%d/%d\n", a, b, c, d, m
                maxend = $2 + 0
            }
        }' > "$out_file"
}

block_ips_from_url() {
    print_header
    print_status "🚫 IP Blocklist Management"
    echo ""

    if ! command -v curl &> /dev/null; then
        info_msg "Installing curl..."
        apt-get update -qq
        apt-get install -y curl
    fi

    local work_dir
    work_dir=$(mktemp -d /tmp/toolbox_blocklist.XXXXXX)
    local raw_file="$work_dir/raw.txt"
    local clean_file="$work_dir/clean.txt"
    local nft_file="$work_dir/blocklist.nft"

    info_msg "Downloading IP list..."
    info_msg "$BLOCKLIST_URL"
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 "$BLOCKLIST_URL" -o "$raw_file"; then
        error_msg "Failed to download the IP list!"
        rm -rf "$work_dir"
        pause
        return
    fi

    normalize_ip_list "$raw_file" "$clean_file"

    local valid_count
    valid_count=$(wc -l < "$clean_file")
    if [[ "$valid_count" -eq 0 ]]; then
        error_msg "No valid IP entries found in the downloaded file!"
        rm -rf "$work_dir"
        pause
        return
    fi
    info_msg "Downloaded list parsed: $valid_count unique ranges"
    echo ""

    init_nftables

    # Create the set if it does not exist yet
    if ! nft list set inet filter blocklist &>/dev/null; then
        nft add set inet filter blocklist '{ type ipv4_addr; flags interval; auto-merge; }'
    fi

    # Build one atomic transaction: flush old content + load new elements
    {
        echo "flush set inet filter blocklist"
        awk -v chunk=500 '
            {
                if ((NR - 1) % chunk == 0) {
                    if (NR > 1) print " }"
                    printf "add element inet filter blocklist { %s", $0
                } else {
                    printf ", %s", $0
                }
            }
            END { if (NR > 0) print " }" }' "$clean_file"
    } > "$nft_file"

    info_msg "Loading IP blocklist..."
    if ! nft -f "$nft_file"; then
        error_msg "Failed to load the blocklist into nftables!"
        rm -rf "$work_dir"
        pause
        return
    fi

    # Remove the old-style inbound rule (earlier versions matched source addresses)
    nft_delete_rules input '@blocklist'

    # Drop traffic TO the listed ranges (outgoing from this host and forwarded user traffic).
    # Loopback and Docker bridge traffic are exempt so local container networking keeps working.
    if ! nft list chain inet filter output 2>/dev/null | grep -q '@blocklist'; then
        nft -f - <<'EOF'
insert rule inet filter output ip daddr @blocklist oifname != "lo" oifname != "docker0" oifname != "br-*" drop
EOF
    fi
    if ! nft list chain inet filter forward 2>/dev/null | grep -q '@blocklist'; then
        nft -f - <<'EOF'
insert rule inet filter forward ip daddr @blocklist oifname != "docker0" oifname != "br-*" drop
EOF
    fi

    save_nftables
    rm -rf "$work_dir"

    echo ""
    success_msg "IP blocklist activated: $valid_count ranges blocked"
    info_msg "Outgoing and forwarded traffic to these ranges is dropped"
    pause
}

#===========================================
# 4. ICMP Control
#===========================================

manage_icmp() {
    while true; do
        print_header
        print_status "🏓 ICMP (Ping) Control"
        echo ""

        local icmp_status
        icmp_status=$(check_icmp_status)
        if [[ "$icmp_status" == "blocked" ]]; then
            echo -e "${YELLOW}●${NC} Current Status: ${YELLOW}ICMP Blocked${NC}"
        else
            echo -e "${GREEN}●${NC} Current Status: ${GREEN}ICMP Allowed${NC}"
        fi

        echo ""
        echo -e "${CYAN}${BOLD}1)${NC} Block ICMP (Disable Ping)"
        echo -e "${CYAN}${BOLD}2)${NC} Allow ICMP (Enable Ping)"
        echo -e "${CYAN}${BOLD}0)${NC} Back to Main Menu"
        echo ""
        echo -e "${YELLOW}Enter your choice:${NC}"
        local choice
        read -r choice

        case $choice in
            1) block_icmp ;;
            2) allow_icmp ;;
            0) break ;;
            *) error_msg "Invalid option!" ; pause ;;
        esac
    done
}

block_icmp() {
    init_nftables

    # Delete all existing echo-request rules
    nft_delete_rules input 'echo-request'

    # IPv4 ping: drop. IPv6 ping: drop too, inserted before the generic ICMPv6 accept
    nft add rule inet filter input icmp type echo-request drop
    nft insert rule inet filter input icmpv6 type echo-request drop

    save_nftables

    success_msg "ICMP (Ping) has been blocked"
    pause
}

allow_icmp() {
    init_nftables

    # Delete all existing echo-request rules
    nft_delete_rules input 'echo-request'

    # Add accept rule (IPv6 ping is already covered by the ICMPv6 accept rule)
    nft add rule inet filter input icmp type echo-request accept

    save_nftables

    success_msg "ICMP (Ping) has been allowed"
    pause
}

#===========================================
# 5. Clear NFTables Rules
#===========================================

clear_nftables() {
    print_header
    print_status "🗑️  Clear NFTables Rules"
    echo ""

    # Backup current rules
    local backup_file
    backup_file=$(backup_nftables)
    info_msg "Current rules backed up to: $backup_file"

    # Remove only our own table (other tables, e.g. Docker's, stay untouched)
    nft delete table inet filter 2>/dev/null

    # Recreate basic structure with SSH access
    init_nftables

    success_msg "All nftables rules cleared"
    success_msg "Basic rules with SSH access restored"
    pause
}

#===========================================
# 6. IPv6 Management
#===========================================

manage_ipv6() {
    while true; do
        print_header
        print_status "🌐 IPv6 Management"
        echo ""

        local ipv6_status
        ipv6_status=$(check_ipv6_status)
        if [[ "$ipv6_status" == "enabled" ]]; then
            echo -e "${GREEN}●${NC} Current Status: ${GREEN}IPv6 Enabled${NC}"
        else
            echo -e "${YELLOW}●${NC} Current Status: ${YELLOW}IPv6 Disabled${NC}"
        fi

        echo ""
        echo -e "${CYAN}${BOLD}1)${NC} Enable IPv6"
        echo -e "${CYAN}${BOLD}2)${NC} Disable IPv6"
        echo -e "${CYAN}${BOLD}0)${NC} Back to Main Menu"
        echo ""
        echo -e "${YELLOW}Enter your choice:${NC}"
        local choice
        read -r choice

        case $choice in
            1) enable_ipv6 ;;
            2) disable_ipv6 ;;
            0) break ;;
            *) error_msg "Invalid option!" ; pause ;;
        esac
    done
}

enable_ipv6() {
    info_msg "Enabling IPv6..."

    cat > "$SYSCTL_CONF" <<EOF
# IPv6 Configuration
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF

    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1

    success_msg "IPv6 enabled permanently"
    info_msg "If the server does not get its IPv6 address back, a reboot may be needed"
    pause
}

disable_ipv6() {
    info_msg "Disabling IPv6..."

    cat > "$SYSCTL_CONF" <<EOF
# IPv6 Configuration - Disabled
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 0
EOF

    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1

    success_msg "IPv6 disabled permanently"
    pause
}

#===========================================
# 7. DNS Management
#===========================================

manage_dns() {
    while true; do
        print_header
        print_status "🌍 DNS Management"
        echo ""

        local current_dns
        current_dns=$(get_dns_servers)
        info_msg "Current DNS: $current_dns"

        echo ""
        echo -e "${CYAN}${BOLD}1)${NC} Google DNS (8.8.8.8, 8.8.4.4)"
        echo -e "${CYAN}${BOLD}2)${NC} Cloudflare DNS (1.1.1.1, 1.0.0.1)"
        echo -e "${CYAN}${BOLD}3)${NC} Quad9 DNS (9.9.9.9, 149.112.112.112)"
        echo -e "${CYAN}${BOLD}4)${NC} Manual DNS Configuration"
        echo -e "${CYAN}${BOLD}0)${NC} Back to Main Menu"
        echo ""
        echo -e "${YELLOW}Enter your choice:${NC}"
        local choice
        read -r choice

        case $choice in
            1) set_dns "8.8.8.8" "8.8.4.4" "Google DNS" ;;
            2) set_dns "1.1.1.1" "1.0.0.1" "Cloudflare DNS" ;;
            3) set_dns "9.9.9.9" "149.112.112.112" "Quad9 DNS" ;;
            4) set_manual_dns ;;
            0) break ;;
            *) error_msg "Invalid option!" ; pause ;;
        esac
    done
}

set_dns() {
    local dns1="$1"
    local dns2="$2"
    local name="$3"
    local dns_list="$dns1"

    if [[ -n "$dns2" ]]; then
        dns_list="$dns1 $dns2"
    fi

    info_msg "Setting DNS to $name..."
    echo ""

    if systemctl is-active --quiet systemd-resolved; then
        # systemd-resolved (Ubuntu 22/24 default)
        info_msg "Configuring via systemd-resolved..."

        if [[ -f /etc/systemd/resolved.conf ]]; then
            cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf_$(date +%Y%m%d_%H%M%S).bak"
        fi

        mkdir -p /etc/systemd/resolved.conf.d/

        cat > /etc/systemd/resolved.conf.d/dns.conf <<EOF
[Resolve]
DNS=$dns_list
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=no
DNSStubListener=yes
EOF

        systemctl restart systemd-resolved
        sleep 2

        # Make sure resolv.conf points to resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

        success_msg "DNS configured via systemd-resolved"
    elif [[ ! -L /etc/resolv.conf ]]; then
        # Plain resolv.conf
        info_msg "Configuring via resolv.conf..."
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf_$(date +%Y%m%d_%H%M%S).bak"

        {
            echo "# DNS Configuration by Toolbox"
            echo "nameserver $dns1"
            if [[ -n "$dns2" ]]; then
                echo "nameserver $dns2"
            fi
        } > /etc/resolv.conf

        success_msg "DNS configured in resolv.conf"
    else
        warning_msg "resolv.conf is managed by another tool; DNS was not changed"
    fi

    # Netplan note
    if [[ -d "$NETPLAN_DIR" ]] && ls "$NETPLAN_DIR"/*.yaml >/dev/null 2>&1; then
        local netplan_file
        netplan_file=$(ls "$NETPLAN_DIR"/*.yaml 2>/dev/null | head -1)
        if [[ -n "$netplan_file" ]] && grep -q "nameservers:" "$netplan_file"; then
            cp "$netplan_file" "$BACKUP_DIR/netplan_$(date +%Y%m%d_%H%M%S).yaml"

            info_msg "Netplan configuration detected"
            warning_msg "For persistent DNS in netplan, you may need to manually edit:"
            echo -e "${CYAN}  $netplan_file${NC}"
            echo ""
        fi
    fi

    # Verify DNS is actually set
    sleep 1
    echo ""
    info_msg "Verifying DNS configuration..."

    local actual_dns
    actual_dns=$(get_dns_servers)

    echo ""
    success_msg "DNS changed to $name"
    echo -e "${GREEN}  Primary DNS:${NC}   $dns1"
    if [[ -n "$dns2" ]]; then
        echo -e "${GREEN}  Secondary DNS:${NC} $dns2"
    fi

    echo ""
    info_msg "Active DNS servers: $actual_dns"

    if getent hosts github.com >/dev/null 2>&1; then
        success_msg "Name resolution test passed"
    else
        warning_msg "Name resolution test failed (check the DNS addresses / firewall)"
    fi

    pause
}

set_manual_dns() {
    echo ""
    echo -e "${YELLOW}Enter primary DNS server:${NC}"
    local dns1 dns2
    read -r dns1

    echo -e "${YELLOW}Enter secondary DNS server (optional):${NC}"
    read -r dns2

    # Validate DNS format
    if ! is_valid_ipv4 "$dns1"; then
        error_msg "Invalid DNS format!"
        pause
        return
    fi

    if [[ -n "$dns2" ]] && ! is_valid_ipv4 "$dns2"; then
        error_msg "Invalid secondary DNS format!"
        pause
        return
    fi

    set_dns "$dns1" "$dns2" "Custom DNS"
}

#===========================================
# Main Menu
#===========================================

main_menu() {
    while true; do
        print_header
        display_status_dashboard

        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}${BOLD}Main Menu${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${CYAN}${BOLD} 1)${NC} Change SSH Port"
        echo -e "${CYAN}${BOLD} 2)${NC} Manage Ports (Toggle Open/Close)"
        echo -e "${CYAN}${BOLD} 3)${NC} Block IPs from GitHub List (Anti-Abuse)"
        echo -e "${CYAN}${BOLD} 4)${NC} ICMP Control (Ping)"
        echo -e "${CYAN}${BOLD} 5)${NC} Clear All NFTables Rules"
        echo -e "${CYAN}${BOLD} 6)${NC} IPv6 Management"
        echo -e "${CYAN}${BOLD} 7)${NC} DNS Management"
        echo ""
        echo -e "${RED}${BOLD} 0)${NC} Exit"
        echo ""
        echo -e "${YELLOW}Enter your choice:${NC}"
        local choice
        read -r choice

        case $choice in
            1) change_ssh_port ;;
            2) manage_ports_menu ;;
            3) block_ips_from_url ;;
            4) manage_icmp ;;
            5) clear_nftables ;;
            6) manage_ipv6 ;;
            7) manage_dns ;;
            0)
                echo ""
                success_msg "Thank you for using Toolbox!"
                exit 0
                ;;
            *)
                error_msg "Invalid option!"
                pause
                ;;
        esac
    done
}

#===========================================
# Main Execution
#===========================================

# Check root
check_root

# Initialize backup directory
init_backup_dir

# Check if nftables is installed, if not install it
if ! command -v nft &> /dev/null; then
    print_header
    info_msg "NFTables not found. Installing..."
    apt-get update -qq
    apt-get install -y nftables
    success_msg "NFTables installed successfully"
    sleep 2
fi

# Start main menu
main_menu
