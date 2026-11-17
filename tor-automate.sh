#!/usr/bin/env bash
# Tor Automate Engine V5.0 (Sanaei 3x-ui Edition)
# Tor exit-node routing per country, wired into Sanaei 3x-ui (v3.x) through its REST API.

TA_VERSION="5.0-3xui"

# ================= COLORS =================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ================= CONFIG =================
# Everything this tool owns lives in these dedicated directories (override with TA_* env for testing).
TA_HOME="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"        # /opt/tor-automate
CONF_DIR="${TA_CONF_DIR:-/etc/tor-automate}"                       # settings, Tor node configs, backups
BASE_DIR="$CONF_DIR/nodes"                                         # one torrc per location
DATA_DIR="${TA_DATA_DIR:-/var/lib/tor-automate}"                   # Tor data directories (owned by debian-tor)
BACKUP_DIR="$CONF_DIR/backups"
export XUI_STATE_DIR="$CONF_DIR/private"                           # panel cookie jar (mode 700)
PANEL_CONF="$CONF_DIR/panel.conf"                                  # panel connection (mode 600)
TOR_MARKER="$CONF_DIR/.tor-installed-by-tor-automate"

# shellcheck source=lib/xui.sh
if [ -r "$TA_HOME/lib/xui.sh" ]; then source "$TA_HOME/lib/xui.sh"
else echo "tor-automate: missing $TA_HOME/lib/xui.sh (re-run the installer)" >&2; exit 1; fi

declare -A NODES=(
    [01]="DE:Germany:9080" [02]="TR:Turkey:9081" [03]="US:United States:9082"
    [04]="FR:France:9083" [05]="AT:Austria:9084" [06]="BE:Belgium:9085"
    [07]="RO:Romania:9086" [08]="CA:Canada:9087" [09]="SG:Singapore:9088"
    [10]="JP:Japan:9089" [11]="IE:Ireland:9090" [12]="FI:Finland:9091"
    [13]="ES:Spain:9092" [14]="PL:Poland:9093" [15]="NL:Netherlands:9094"
    [16]="IT:Italy:9095" [17]="CH:Switzerland:9096" [18]="SE:Sweden:9097"
    [19]="NO:Norway:9098" [20]="DK:Denmark:9099" [21]="IS:Iceland:9100"
    [22]="AU:Australia:9101" [23]="IN:India:9102" [24]="HK:Hong Kong:9103"
    [25]="UA:Ukraine:9104" [26]="CZ:Czech Republic:9105" [27]="KR:South Korea:9106"
    [28]="ZA:South Africa:9107" [29]="MX:Mexico:9108" [30]="MY:Malaysia:9109"
    [31]="AZ:Azerbaijan:9110" [32]="CY:Cyprus:9111" [33]="GR:Greece:9112"
    [34]="PT:Portugal:9113" [35]="HU:Hungary:9114" [36]="LU:Luxembourg:9115"
    [37]="GB:United Kingdom:9116" [38]="AR:Argentina:9117" [39]="TW:Taiwan:9118"
    [40]="BG:Bulgaria:9119" [41]="IL:Israel:9120" [42]="MD:Moldova:9121"
    [43]="RU:Russia:9122" [44]="CL:Chile:9123" [45]="CR:Costa Rica:9124"
    [46]="VN:Vietnam:9125" [47]="ID:Indonesia:9126" [48]="SC:Seychelles:9127"
    [49]="HR:Croatia:9128" [50]="TN:Tunisia:9129"
)

declare -A EMOJIS=(
    [DE]="🇩🇪" [TR]="🇹🇷" [US]="🇺🇸" [FR]="🇫🇷" [AT]="🇦🇹" [BE]="🇧🇪"
    [RO]="🇷🇴" [CA]="🇨🇦" [SG]="🇸🇬" [JP]="🇯🇵" [IE]="🇮🇪" [FI]="🇫🇮"
    [ES]="🇪🇸" [PL]="🇵🇱" [NL]="🇳🇱" [IT]="🇮🇹" [CH]="🇨🇭" [SE]="🇸🇪"
    [NO]="🇳🇴" [DK]="🇩🇰" [IS]="🇮🇸" [AU]="🇦🇺" [IN]="🇮🇳" [HK]="🇭🇰"
    [UA]="🇺🇦" [CZ]="🇨🇿" [KR]="🇰🇷" [ZA]="🇿🇦" [MX]="🇲🇽" [MY]="🇲🇾"
    [AZ]="🇦🇿" [CY]="🇨🇾" [GR]="🇬🇷" [PT]="🇵🇹" [HU]="🇭🇺" [LU]="🇱🇺"
    [GB]="🇬🇧" [AR]="🇦🇷" [TW]="🇹🇼" [BG]="🇧🇬" [IL]="🇮🇱" [MD]="🇲🇩"
    [RU]="🇷🇺" [CL]="🇨🇱" [CR]="🇨🇷" [VN]="🇻🇳" [ID]="🇮🇩" [SC]="🇸🇨"
    [HR]="🇭🇷" [TN]="🇹🇳"
)

ORDER=({01..50})


# ================= CORE FUNCTIONS =================

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}[!] Error: Please run as root (sudo).${NC}"
        exit 1
    fi
}


# Start one Tor instance as the unprivileged debian-tor user (runuser ships with util-linux; sudo is not required).
run_tor() { ( cd / && runuser -u debian-tor -- tor -f "$1" >/dev/null 2>&1 ) & }

# ================= BACKGROUND CRON JOB =================
background_auto_heal() {
    for idx in "${ORDER[@]}"; do
        local details="${NODES[$idx]}"
        IFS=':' read -r code name out_port <<< "$details"
        
        local conf_file="$BASE_DIR/node_${code}_${out_port}.conf"
        local ip_file="$DATA_DIR/${code}_${out_port}/last_ip.txt"
        
        if [ -f "$conf_file" ]; then
            local is_dead=0
            
            if ! pgrep -f "$BASE_DIR/node_${code}_${out_port}.conf" > /dev/null; then
                is_dead=1
            else
                local test_ip=$(curl -s --socks5-hostname 127.0.0.1:$out_port https://api.ipify.org --max-time 15 || true)
                if [[ ! "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    is_dead=1
                else
                    echo "$test_ip" > "$ip_file"
                fi
            fi
            
            if [ $is_dead -eq 1 ]; then
                pkill -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
                rm -f "$ip_file"
                run_tor "$conf_file"
                
                (
                    sleep 15
                    local new_ip=$(curl -s --socks5-hostname 127.0.0.1:$out_port https://api.ipify.org --max-time 15 || true)
                    if [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo "$new_ip" > "$ip_file"
                    fi
                ) &
            fi
        fi
    done
    exit 0
}

if [ "$1" == "--auto-heal" ]; then
    background_auto_heal
fi

# ================= UI FUNCTIONS =================

draw_header() {
    clear
    echo -e "${MAGENTA} ╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA} ║${CYAN}  ████████╗ ██████╗ ██████╗                               ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${CYAN}  ╚══██╔══╝██╔═══██╗██╔══██╗                              ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${CYAN}     ██║   ██║   ██║██████╔╝                              ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${CYAN}     ██║   ██║   ██║██╔══██╗                              ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${CYAN}     ██║   ╚██████╔╝██║  ██║                              ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${CYAN}     ╚═╝    ╚═════╝ ╚═╝  ╚═╝                              ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ║${YELLOW}      A U T O M A T E   V5.0  ·  3 X - U I           ${MAGENTA}║${NC}"
    echo -e "${MAGENTA} ╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

draw_progress() {
    local text=$1
    for ((i=1; i<=20; i++)); do
        local percent=$((i * 5))
        printf "\r${CYAN}[*] %-40s ${MAGENTA}[${GREEN}" "$text"
        for ((j=1; j<=i; j++)); do printf "█"; done
        for ((j=i+1; j<=20; j++)); do printf " "; done
        printf "${MAGENTA}] ${YELLOW}%3d%%${NC}" "$percent"
        sleep 0.05
    done
    echo ""
}

deploy_node() {
    local code=$1; local name=$2; local out_port=$3
    local conf_file="$BASE_DIR/node_${code}_${out_port}.conf"
    local inst_data_dir="$DATA_DIR/${code}_${out_port}"
    local ip_file="$inst_data_dir/last_ip.txt"

    mkdir -p "$BASE_DIR"
    mkdir -p "$inst_data_dir"
    chown -R debian-tor:debian-tor "$inst_data_dir" 2>/dev/null || true

    cat <<EOF > "$conf_file"
SocksPort 127.0.0.1:$out_port
DataDirectory $inst_data_dir
ExitNodes {$code}
StrictNodes 1
RunAsDaemon 1
Log notice file $inst_data_dir/notices.log
EOF
    chmod 644 "$conf_file" 2>/dev/null || true

    if pgrep -f "$BASE_DIR/node_${code}_${out_port}.conf" > /dev/null; then
        pkill -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
    fi

    echo -e "${CYAN}[*] Routing ${WHITE}$code - $name ${CYAN}➔ Tor Port: ${MAGENTA}$out_port${CYAN}. Please wait...${NC}"
    run_tor "$conf_file"
    draw_progress "Bootstrapping Tor connection"

    local connect_attempts=0
    local max_connect_attempts=20
    
    # New Check Variables
    local clean_attempts=0
    local max_clean_attempts=3

    while [ $connect_attempts -lt $max_connect_attempts ]; do
        # Effort to get IP from Tor
        local public_ip=$(curl -s --socks5-hostname 127.0.0.1:$out_port https://api.ipify.org --max-time 10 | tr -d '\0' || true)
        
        if [ ! -z "$public_ip" ] && [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            
            # --- START OF IP API CHECK ---
            echo -e "${CYAN}[*] Checking IP Reputation for ${MAGENTA}$public_ip${CYAN}...${NC}"
            local api_resp=$(curl -s "https://api.ipapi.is/?q=$public_ip" --max-time 10 || true)
            
            local is_bad=0
            local abuser_line=$(echo "$api_resp" | grep -i '"abuser_score"')
            
            # If the line contains "High" (this covers High and Very High)
            if echo "$abuser_line" | grep -iq "High"; then
                is_bad=1
            fi
            
            if [ $is_bad -eq 0 ] || [ $clean_attempts -ge $max_clean_attempts ]; then
                if [ $is_bad -eq 1 ]; then
                    echo -e "${YELLOW}[!] Max retries reached (3/3). Forcing acceptance of IP: $public_ip${NC}"
                else
                    echo -e "${GREEN}[+] IP is Clean (Low/Elevated)!${NC}"
                fi
                
                # Accept IP
                echo "$public_ip" > "$ip_file"
                echo -e "${GREEN}[+] Online -> ${WHITE}$code - $name ${GREEN}($public_ip)${NC}\n"
                return 0
            else
                clean_attempts=$((clean_attempts+1))
                echo -e "${RED}[-] IP $public_ip is High Risk! Requesting new IP from Tor ($clean_attempts/$max_clean_attempts)...${NC}"
                
                # Restart the specific Tor instance to force a new circuit and IP
                pkill -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
                sleep 2
                run_tor "$conf_file"
                sleep 5 
                
                # Reset connection attempts to give Tor time to connect again
                connect_attempts=0
            fi
            # --- END OF IP API CHECK ---
            
        else
            echo -e "${CYAN}[*] Waiting for Tor connection (Attempt $((connect_attempts+1))/$max_connect_attempts)...${NC}"
            connect_attempts=$((connect_attempts+1))
            sleep 3
        fi
    done
    
    echo -e "${RED}[-] Setup failed or Country restricted for $code - $name (Could not connect to Tor)${NC}\n"
}

# ================= CORE MENUS =================

# Idempotent: safe to run repeatedly. Touches only our own directories, cron entry and (if WE installed it) Tor.
install_engine_core() {
    check_root
    local had_tor=0
    command -v tor >/dev/null 2>&1 && had_tor=1
    echo -e "${YELLOW}[*] Updating package lists...${NC}"
    apt-get update -qq
    echo -e "${YELLOW}[*] Installing prerequisites (Tor, curl, jq, openssl, cron, iproute2)...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y tor tor-geoipdb curl jq openssl cron iproute2 ca-certificates util-linux procps || {
        echo -e "${RED}[!] Package installation failed.${NC}"; return 1; }

    mkdir -p "$BASE_DIR" "$DATA_DIR" "$BACKUP_DIR" "$XUI_STATE_DIR"
    chmod 755 "$CONF_DIR" "$BASE_DIR" "$DATA_DIR"          # debian-tor must be able to traverse to its torrc
    chmod 700 "$XUI_STATE_DIR" "$BACKUP_DIR"

    # The distro's default Tor instance is useless to us (we run one tor per country). Only switch it off
    # when WE installed Tor; a Tor that was already there is somebody else's and is left untouched.
    if [ $had_tor -eq 0 ] && [ ! -f "$TOR_MARKER" ]; then
        : > "$TOR_MARKER"
        systemctl disable --now tor@default 2>/dev/null || true
        systemctl disable --now tor 2>/dev/null || true
    fi

    # Auto-heal: every 30 min (as before) and once after boot so nodes come back after a reboot.
    cat > /etc/cron.d/tor-automate <<CRON
*/30 * * * * root /usr/local/bin/tor-automate --auto-heal > /dev/null 2>&1
@reboot root sleep 45; /usr/local/bin/tor-automate --auto-heal > /dev/null 2>&1
CRON
    chmod 644 /etc/cron.d/tor-automate
    cat > /etc/logrotate.d/tor-automate <<LR
$DATA_DIR/*/notices.log {
    weekly
    rotate 4
    missingok
    notifempty
    copytruncate
    compress
}
LR
    systemctl enable --now cron 2>/dev/null || true
    echo -e "${GREEN}[+] Engine & core tools installed. Background Auto-Heal is active.${NC}"
}

install_engine() {
    draw_header
    install_engine_core
    sleep 3
}

uninstall_engine() {
    check_root
    draw_header
    echo -e "${RED}[!] WARNING: This removes every Tor node created by Tor Automate and all its configuration.${NC}"
    echo -e "${YELLOW}    Directories removed: $CONF_DIR, $DATA_DIR, $TA_HOME${NC}"
    echo -e "${YELLOW}    Your 3x-ui installation is NOT touched. Inbounds/outbounds that this tool added to the panel stay there${NC}"
    echo -e "${YELLOW}    (use Panel menu -> Remove locations first if you want them gone).${NC}"
    if [ -f "$TOR_MARKER" ]; then echo -e "${YELLOW}    The 'tor' package will be purged (Tor Automate installed it).${NC}"
    else echo -e "${YELLOW}    The 'tor' package will be kept (it was installed before Tor Automate).${NC}"; fi
    read -r -p "❓ Are you sure? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi
    pkill -f "$BASE_DIR/node_" 2>/dev/null || true
    sleep 1
    local purge=0; [ -f "$TOR_MARKER" ] && purge=1
    rm -f /etc/cron.d/tor-automate /etc/logrotate.d/tor-automate
    for d in "$CONF_DIR" "$DATA_DIR"; do
        case "$d" in ""|"/"|"/etc"|"/var"|"/var/lib"|"/usr"|"/opt") echo -e "${RED}[!] Refusing to delete '$d'${NC}" ;; *) rm -rf "$d" ;; esac
    done
    if [ $purge -eq 1 ]; then
        apt-get remove --purge -y tor tor-geoipdb
        apt-get autoremove -y
    fi
    rm -f /usr/local/bin/tor-automate
    echo -e "${GREEN}[+] Uninstallation complete.${NC}"
    [ "$TA_HOME" = "/opt/tor-automate" ] && ( sleep 1; rm -rf /opt/tor-automate ) >/dev/null 2>&1 &
    exit 0
}

list_locations() {
    echo -e "${YELLOW}Available Locations:${NC}\n"
    
    local C_CYAN='\033[1;36m'
    local C_GREEN='\033[1;32m'
    local C_WHITE='\033[1;37m'
    local NC='\033[0m'
    
    local CIRCLE_ON="${C_GREEN}●${NC}"
    local CIRCLE_OFF="${C_WHITE}○${NC}"
    
    for ((i=1; i<=25; i++)); do
        local idx1=$(printf "%02d" $i)
        local idx2=$(printf "%02d" $((i+25)))
        
        IFS=':' read -r code1 name1 port1 <<< "${NODES[$idx1]}"
        local stat1="$CIRCLE_OFF"
        if [ -f "$BASE_DIR/node_${code1}_${port1}.conf" ]; then
            stat1="$CIRCLE_ON"
        fi
        
        local col2_str=""
        if [[ -n "${NODES[$idx2]}" ]]; then
            IFS=':' read -r code2 name2 port2 <<< "${NODES[$idx2]}"
            local stat2="$CIRCLE_OFF"
            if [ -f "$BASE_DIR/node_${code2}_${port2}.conf" ]; then
                stat2="$CIRCLE_ON"
            fi
            col2_str=$(printf "${C_CYAN}[%s]${NC} %b %-16s" "$idx2" "$stat2" "$name2")
        fi
        
        printf "  ${C_CYAN}[%s]${NC} %b %-16s    %b\n" "$idx1" "$stat1" "$name1" "$col2_str"
    done
    
    echo -e "\n  ${RED}00${NC} - ${WHITE}Back to main menu${NC}\n"
}

add_single_node() {
    check_root
    draw_header
    echo -e "${CYAN}» Option 4 - Add Location Node${NC}\n"
    list_locations
    read -p "$(echo -e ${MAGENTA}"Select location index: "${NC})" loc_idx
    if [[ "$loc_idx" == "00" ]]; then return; fi
    p_idx=$(printf "%02d" "$loc_idx")
    if [[ -n "${NODES[$p_idx]}" ]]; then
        IFS=':' read -r code name out_port <<< "${NODES[$p_idx]}"
        
        if [ -f "$BASE_DIR/node_${code}_${out_port}.conf" ]; then
            echo -e "\n${YELLOW}[!] Node $code - $name is already active. You cannot install it again.${NC}"
            sleep 2
        else
            deploy_node "$code" "$name" "$out_port"
            read -p "$(echo -e ${WHITE}"Press Enter to return..."${NC})"
        fi
    fi
}

bulk_add_nodes() {
    check_root
    draw_header
    echo -e "${CYAN}» Option 5 - Bulk Add Nodes${NC}\n"
    echo -e "  ${GREEN}[1]${NC} Deploy All Supported Locations (Full World)"
    echo -e "  ${GREEN}[2]${NC} Custom Batch Deployment (Comma separated selection)"
    echo -e "  ${GREEN}[3]${NC} Deploy Main Countries (TR, US, FR, FI, ES, NL, GB, CA, LU, CH)"
    echo -e "  ${RED}[0]${NC} Go Back\n"
    
    read -p "$(echo -e ${CYAN}"Select deployment mode [0-3]: "${NC})" bulk_opt
    
    if [ "$bulk_opt" == "1" ]; then
        echo -e "${YELLOW}[!] Initiating deployment for ALL uninstalled nodes...${NC}"
        for idx in "${ORDER[@]}"; do
            IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
            
            if [ -f "$BASE_DIR/node_${code}_${out_port}.conf" ]; then
                continue
            fi
            
            echo -e "\n${CYAN}[*] Processing ${WHITE}$code - $name${CYAN}...${NC}"
            deploy_node "$code" "$name" "$out_port"
            sleep 1 
        done
        echo -e "\n${GREEN}[+] Full deployment sequence complete!${NC}"
        read -p "$(echo -e ${WHITE}"Press Enter to return to main menu..."${NC})"
        
    elif [ "$bulk_opt" == "2" ]; then
        list_locations
        echo -e "${YELLOW}Example format: 1, 4, 15, 22${NC}"
        read -p "$(echo -e ${CYAN}"Enter indices separated by comma: "${NC})" custom_list
        
        if [ -z "$custom_list" ] || [ "$custom_list" == "00" ] || [ "$custom_list" == "0" ]; then return; fi
        
        IFS=',' read -ra ADDR <<< "$custom_list"
        for i in "${ADDR[@]}"; do
            local clean_i=$(echo "$i" | sed 's/^0*//' | tr -d ' ')
            if [ -n "$clean_i" ]; then
                local p_idx=$(printf "%02d" "$clean_i")
                if [[ -n "${NODES[$p_idx]}" ]]; then
                    IFS=':' read -r code name out_port <<< "${NODES[$p_idx]}"
                    
                    if [ -f "$BASE_DIR/node_${code}_${out_port}.conf" ]; then
                        echo -e "${YELLOW}[!] $code - $name is already active. Skipping...${NC}"
                    else
                        echo -e "\n${CYAN}[*] Processing ${WHITE}$code - $name${CYAN}...${NC}"
                        deploy_node "$code" "$name" "$out_port"
                        sleep 1
                    fi
                fi
            fi
        done
        echo -e "\n${GREEN}[+] Custom batch deployment sequence complete!${NC}"
        read -p "$(echo -e ${WHITE}"Press Enter to return to main menu..."${NC})"

    elif [ "$bulk_opt" == "3" ]; then
        echo -e "${YELLOW}[!] Initiating deployment for Main Countries...${NC}"
        local main_list=("02" "03" "04" "08" "12" "13" "15" "17" "36" "37")
        for p_idx in "${main_list[@]}"; do
            IFS=':' read -r code name out_port <<< "${NODES[$p_idx]}"
            
            if [ -f "$BASE_DIR/node_${code}_${out_port}.conf" ]; then
                echo -e "${YELLOW}[!] $code - $name is already active. Skipping...${NC}"
                continue
            fi
            
            echo -e "\n${CYAN}[*] Processing ${WHITE}$code - $name${CYAN}...${NC}"
            deploy_node "$code" "$name" "$out_port"
            sleep 1 
        done
        echo -e "\n${GREEN}[+] Main Countries deployment sequence complete!${NC}"
        read -p "$(echo -e ${WHITE}"Press Enter to return to main menu..."${NC})"
    fi
}

view_active_nodes() {
    while true; do
        draw_header
        echo -e "${CYAN}» Option 6 - Active Nodes Monitor (Instant View Mode)${NC}"
        echo -e "${YELLOW}[*] Live monitoring... Fetching data directly from cache without active API checks.${NC}\n"
        
        echo -e "${BLUE}┌──────┬──────┬──────────────────────┬─────────────┬──────────────┬──────────────────┐${NC}"
        echo -e "${BLUE}│${WHITE} ID   ${BLUE}│${WHITE} CC   ${BLUE}│${WHITE} Location             ${BLUE}│${WHITE} Tor Port    ${BLUE}│${WHITE} Status       ${BLUE}│${WHITE} Live IP          ${BLUE}│${NC}"
        echo -e "${BLUE}├──────┼──────┼──────────────────────┼─────────────┼──────────────┼──────────────────┤${NC}"
        
        local found=0
        for idx in "${ORDER[@]}"; do
            local details="${NODES[$idx]}"
            IFS=':' read -r code name out_port <<< "$details"
            
            local conf_file="$BASE_DIR/node_${code}_${out_port}.conf"
            local ip_file="$DATA_DIR/${code}_${out_port}/last_ip.txt"
            
            if [ -f "$conf_file" ]; then
                found=1
                
                local display_ip="Waiting..."
                if [ -f "$ip_file" ] && [ -s "$ip_file" ]; then
                    display_ip=$(cat "$ip_file")
                fi
                
                if pgrep -f "$BASE_DIR/node_${code}_${out_port}.conf" > /dev/null; then
                    printf "${BLUE}│ ${CYAN}%-4s ${BLUE}│ ${WHITE}%-4s ${BLUE}│ ${WHITE}%-20s ${BLUE}│ ${MAGENTA}%-11s ${BLUE}│ ${GREEN}%-12s ${BLUE}│ ${GREEN}%-16s ${BLUE}│${NC}\n" "$idx" "$code" "$name" "$out_port" "ONLINE" "$display_ip"
                else
                    rm -f "$ip_file"
                    run_tor "$conf_file"
                    
                    printf "${BLUE}│ ${CYAN}%-4s ${BLUE}│ ${WHITE}%-4s ${BLUE}│ ${WHITE}%-20s ${BLUE}│ ${MAGENTA}%-11s ${BLUE}│ ${YELLOW}%-12s ${BLUE}│ ${YELLOW}%-16s ${BLUE}│${NC}\n" "$idx" "$code" "$name" "$out_port" "HEALING..." "Restarting..."
                    
                    (
                        while true; do
                            sleep 8
                            local new_ip=$(curl -s --socks5-hostname 127.0.0.1:$out_port https://api.ipify.org --max-time 15 || true)
                            if [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                                echo "$new_ip" > "$ip_file"
                                break
                            fi
                            pkill -HUP -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
                        done
                    ) &
                fi
            fi
        done
        
        if [ $found -eq 0 ]; then
            printf "${BLUE}│ ${YELLOW}%-82s ${BLUE}│${NC}\n" "No active nodes found in the system."
        fi
        echo -e "${BLUE}└──────┴──────┴──────────────────────┴─────────────┴──────────────┴──────────────────┘${NC}\n"
        
        echo -e "${MAGENTA}[ Live Monitoring Active ]${NC} Screen refreshes every 3 seconds."
        echo -e "${WHITE}Press any key (or Enter) to stop monitoring and return to main menu...${NC}"
        
        if read -t 3 -n 1 -s key; then
            break
        fi
    done
}

edit_delete_nodes() {
    draw_header
    echo -e "📌 ${MAGENTA}[ DELETE ACTIVE NODE ]${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────${NC}"
    local active_nodes=()
    for idx in "${ORDER[@]}"; do
        IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
        if pgrep -f "$BASE_DIR/node_${code}_${out_port}.conf" > /dev/null; then
            active_nodes+=("$idx")
            local emoji="${EMOJIS[$code]}"
            printf "  ${CYAN}[%s]${NC} %s %-18s \tTorPort:${MAGENTA}%s${NC}\n" "$idx" "$emoji" "$name" "$out_port"
        fi
    done
    if [ ${#active_nodes[@]} -eq 0 ]; then
        echo -e "  ${RED}No active nodes to delete.${NC}"; sleep 2; return
    fi
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${RED}[99] DELETE ALL ACTIVE NODES (Clear All)${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────${NC}"
    
    read -p "$(echo -e ${CYAN}"Select ID to stop/delete (or 0 to cancel): "${NC})" del_sel
    
    if [[ "$del_sel" == "0" || -z "$del_sel" ]]; then return; fi
    
    if [[ "$del_sel" == "99" ]]; then
        echo -e "\n${YELLOW}[!] Deleting ALL active nodes... Please wait.${NC}"
        for idx in "${active_nodes[@]}"; do
            IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
            pkill -9 -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
        done
        sleep 1.5
        for idx in "${active_nodes[@]}"; do
            IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
            rm -f "$BASE_DIR/node_${code}_${out_port}.conf"
            rm -rf "$DATA_DIR/${code}_${out_port}" 2>/dev/null || true
        done
        echo -e "${GREEN}[+] All nodes removed successfully.${NC}"; sleep 2
        return
    fi

    del_sel=$(printf "%02d" $((10#$del_sel)) 2>/dev/null || echo "")
    if [[ -n "${NODES[$del_sel]}" ]]; then
        IFS=':' read -r code name out_port <<< "${NODES[$del_sel]}"
        pkill -9 -f "$BASE_DIR/node_${code}_${out_port}.conf" 2>/dev/null || true
        sleep 1
        rm -f "$BASE_DIR/node_${code}_${out_port}.conf"
        rm -rf "$DATA_DIR/${code}_${out_port}" 2>/dev/null || true
        echo -e "${GREEN}[+] Node removed.${NC}"; sleep 2
    fi
}


# ================= SANAEI 3X-UI PANEL INTEGRATION =================
# Strategy (what replaces PasarGuard "core config + hosts"):
#   - pick an existing inbound as the template and clone it once per Tor location (new port, new tag,
#     remark "<flag> <country>"; clients are shared so every user's subscription gains the new locations)
#   - add a socks outbound -> 127.0.0.1:<tor port> and a routing rule  inboundTag -> that outbound
#     to the Xray template (the 3x-ui equivalent of PasarGuard's core config)
#   - clone the template inbound's Host entry (address/SNI/fingerprint...) for subscription links
# Order is leak-safe: inbounds are created DISABLED, routing is written, and only then are they enabled.

MANAGED_IN_RE='^[A-Z]{2}-.+-IN-[0-9]+$'
MANAGED_OUT_RE='^[A-Z]{2}-.+-OUT-[0-9]+$'
CLONEABLE_PROTOCOLS='["vless","vmess","trojan","shadowsocks"]'   # TCP based; the Tor SOCKS outbound cannot carry UDP-only protocols

TA_TMP=""
ta_init_tmp() {
    if [ -z "$TA_TMP" ] || [ ! -d "$TA_TMP" ]; then TA_TMP=$(mktemp -d /tmp/tor-automate.XXXXXX); chmod 700 "$TA_TMP"; fi
}
trap '[ -n "$TA_TMP" ] && rm -rf "$TA_TMP"' EXIT

pause() { read -r -p "$(echo -e "${WHITE}Press [Enter] to continue...${NC}")" _; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}f=(i==1)?"%d %s":"%.1f %s";printf f,b,u[i]}'
}

panel_fail() { echo -e "${RED}[!] $1${NC}"; local e; e=$(xui_err); [ -n "$e" ] && echo -e "${RED}    $e${NC}"; }

# ---------------------------------------------------------------- connection

panel_setup_connection() {
    local ans p_url="" p_resolve="" p_insecure=0 mode tfa=""
    echo -e "${YELLOW}[~] Detecting the local Sanaei 3x-ui installation...${NC}"
    if xui_detect_local; then
        echo -e "  ${GREEN}Detected:${NC} ${WHITE}$DET_URL${NC}"
        [ -n "$DET_NOTE" ] && echo -e "  ${YELLOW}Note: $DET_NOTE${NC}"
        read -r -p "  Use the detected address? (Y/n): " ans
        if [[ -z "$ans" || "${ans,,}" == "y" ]]; then p_url="$DET_URL"; p_resolve="$DET_RESOLVE"; fi
    else
        echo -e "  ${YELLOW}Auto-detection unavailable: $DET_NOTE${NC}"
    fi
    if [ -z "$p_url" ]; then
        read -r -p "  Panel URL with port and base path (e.g. https://panel.example.com:2053/mypath): " p_url
        p_url="${p_url%/}"
        if [[ ! "$p_url" =~ ^https?://[^/[:space:]]+ ]]; then echo -e "${RED}[!] Invalid URL.${NC}"; return 1; fi
        p_resolve=""
    fi
    if [[ "$p_url" == https://* ]]; then
        read -r -p "  Verify the TLS certificate? (Y/n) [n = accept self-signed]: " ans
        [[ "${ans,,}" == "n" ]] && p_insecure=1
    fi

    echo -e "\n  ${CYAN}[1]${NC} Username & password ${WHITE}(session login, renewed automatically)${NC}"
    echo -e "  ${CYAN}[2]${NC} API token ${WHITE}(panel Settings -> API Tokens; best if 2FA is enabled)${NC}"
    read -r -p "  Authentication method [1]: " mode
    PANEL_URL="$p_url"; PANEL_RESOLVE="$p_resolve"; PANEL_INSECURE="$p_insecure"
    PANEL_USER=""; PANEL_PASS=""; API_TOKEN=""
    if [ "$mode" == "2" ]; then
        AUTH_MODE="token"
        read -r -s -p "  API token: " API_TOKEN; echo ""
    else
        AUTH_MODE="session"
        read -r -p "  Admin username: " PANEL_USER
        read -r -s -p "  Admin password: " PANEL_PASS; echo ""
        read -r -p "  Two-factor code (leave empty if 2FA is off): " tfa
    fi

    echo -e "${YELLOW}[~] Logging in...${NC}"
    if xui_login "$tfa"; then
        xui_save_conf
        echo -e "${GREEN}🟢 Login successful! Connection saved to $PANEL_CONF (root only).${NC}"
        [ -n "$tfa" ] && echo -e "${YELLOW}[i] 2FA codes expire, so a session that expires later cannot be renewed automatically. An API token avoids this.${NC}"
        sleep 1; return 0
    fi
    panel_fail "Login failed."
    sleep 2; return 1
}

panel_login() {
    check_root; ta_init_tmp; draw_header
    echo -e "⏳ ${CYAN}Connecting to Sanaei 3x-ui panel...${NC}"
    local use_saved tfa
    if xui_load_conf; then
        echo -e "\n${GREEN}[+] Saved connection found:${NC} ${WHITE}$PANEL_URL${NC} (${AUTH_MODE})"
        read -r -p "$(echo -e ${CYAN}"❓ Use the saved connection? (Y/n): "${NC})" use_saved
        if [[ -z "$use_saved" || "${use_saved,,}" == "y" ]]; then
            echo -e "${YELLOW}[~] Logging in...${NC}"
            local login_ok=0
            if xui_login; then
                login_ok=1
            elif [ "$AUTH_MODE" == "session" ] && grep -qi "two-factor" <<<"$(xui_err)"; then
                read -r -p "  Two-factor code (leave empty if 2FA is off): " tfa
                [ -n "$tfa" ] && xui_login "$tfa" && login_ok=1
            fi
            if [ $login_ok -eq 1 ]; then echo -e "${GREEN}🟢 Login resumed successfully!${NC}"; sleep 1; panel_menu; return; fi
            panel_fail "Saved connection failed."
            read -r -p "  Enter new connection details? (Y/n): " use_saved
            [[ "${use_saved,,}" == "n" ]] && return
        fi
    fi
    panel_setup_connection && panel_menu
}

panel_menu() {
    ta_init_tmp
    while true; do
        draw_header
        echo -e "📌 ${MAGENTA}[ SANAEI 3X-UI CONTROL PANEL ]${NC}   ${WHITE}$PANEL_URL${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo -e "  ${GREEN}[1]${NC} Auto-Extract Panel Configurations (add Tor locations)"
        echo -e "  ${RED}[2]${NC} Logout (forget saved panel connection)"
        echo -e "  ${CYAN}[3]${NC} Status, traffic & online clients"
        echo -e "  ${YELLOW}[4]${NC} Remove Tor locations from the panel"
        echo -e "  ${YELLOW}[0]${NC} Return to Main Menu"
        echo -e "${BLUE}=============================================${NC}\n"
        read -r -p "$(echo -e ${CYAN}"Selected option: "${NC})" panel_opt
        case "$panel_opt" in
            0) break ;;
            1) panel_batch_create ;;
            2) rm -f "$PANEL_CONF" "$XUI_STATE_DIR"/session.jar "$XUI_STATE_DIR"/csrf.token; echo -e "${GREEN}[+] Logged out, saved connection removed.${NC}"; sleep 1; break ;;
            3) panel_status ;;
            4) panel_remove_locations ;;
        esac
    done
}

# ---------------------------------------------------------------- jq builders

# Port picking: avoids every inbound port in the panel, Xray-template inbounds and anything listening locally.
declare -A USED_PORTS
load_used_ports() {   # $1 = inbounds json, $2 = template file
    USED_PORTS=(); local p
    while read -r p; do [ -n "$p" ] && USED_PORTS[$p]=1; done < <(
        { jq -r '.[].port' <<<"$1"; jq -r '.inbounds[]? | .port // empty' "$2" 2>/dev/null
          ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); print a[n]}'; } )
}
PICKED_PORT=""
pick_port() {
    local p tries=0
    while [ $tries -lt 1000 ]; do
        p=$(( RANDOM % 6000 + 3000 ))
        if [ -z "${USED_PORTS[$p]}" ]; then USED_PORTS[$p]=1; PICKED_PORT=$p; return 0; fi
        tries=$((tries+1))
    done
    return 1
}

# Clone of an inbound: new remark/tag/port, DISABLED, identity/traffic fields reset. $5: share|none
build_clone_inbound() {   # src_json remark tag port client_mode
    jq -c --arg remark "$2" --arg tag "$3" --argjson port "$4" --arg cm "$5" '
      . as $s | {
        remark: $remark, enable: false, listen: ($s.listen // ""), port: $port, protocol: $s.protocol, tag: $tag,
        total: 0, up: 0, down: 0, expiryTime: 0,
        trafficReset: ($s.trafficReset // "never"), trafficResetDay: ($s.trafficResetDay // 1),
        subSortIndex: ($s.subSortIndex // 1), excludeFromSub: false,
        shareAddrStrategy: ($s.shareAddrStrategy // "node"), shareAddr: ($s.shareAddr // ""),
        disableFlow: ($s.disableFlow // false),
        settings: ( ($s.settings // {})
                    | (if has("fallbacks") then .fallbacks = [] else . end)
                    | (if $cm == "none" and has("clients") then .clients = [] else . end) | tojson ),
        streamSettings: ( ($s.streamSettings // {})
                    | (if has("externalProxy") then .externalProxy = [] else . end) | tojson ),
        sniffing: ( ($s.sniffing // {}) | tojson )
      }' <<<"$1"
}

build_clone_host() {   # host_group_json remark port inbound_id
    jq -c --arg remark "$2" --argjson port "$3" --argjson id "$4" '
      def stripport:
        if startswith("[") then (sub("\\]:[0-9]+$"; "]") | ltrimstr("[") | rtrimstr("]"))
        elif test("^[^:]+:[0-9]+$") then sub(":[0-9]+$"; "")
        else . end;
      del(.groupId, .createdAt, .updatedAt)
      | .inboundIds = [$id] | .remark = $remark | .port = $port
      | .hosts = ((.hosts // []) | map(stripport) | unique)' <<<"$1"
}

# Add outbound + routing rule to a template file (in place). Existing items with the same tags are replaced.
# The rule is placed after the leading api/blocked rules so panel-defined catch-all rules cannot shadow it.
tpl_add_route() {   # file in_tag out_tag tor_port
    jq --arg it "$2" --arg ot "$3" --argjson p "$4" '
      {type:"field", inboundTag:[$it], outboundTag:$ot} as $rule
      | .outbounds = ((.outbounds // []) | map(select(.tag != $ot))
            + [{tag:$ot, protocol:"socks", settings:{servers:[{address:"127.0.0.1", port:$p}]}}])
      | .routing = (.routing // {})
      | .routing.rules = ((.routing.rules // []) | map(select(((.inboundTag // []) | index($it)) | not)))
      | (.routing.rules | map(.outboundTag // "") | to_entries
           | map(select(.value != "api" and .value != "blocked")) | (.[0].key // null)) as $pos
      | .routing.rules = (if $pos == null then .routing.rules + [$rule]
                          else .routing.rules[:$pos] + [$rule] + .routing.rules[$pos:] end)' "$1" > "$1.new" && mv "$1.new" "$1"
}

tpl_remove_route() {   # file in_tag   (also drops the managed outbound the rule pointed to)
    jq --arg it "$2" --arg re "$MANAGED_OUT_RE" '
      ([.routing.rules[]? | select((.inboundTag // []) | index($it)) | .outboundTag] | .[0] // "") as $ot
      | .routing.rules = ((.routing.rules // []) | map(select(((.inboundTag // []) | index($it)) | not)))
      | .outbounds = ((.outbounds // []) | map(select(.tag != $ot or ($ot | test($re) | not))))' "$1" > "$1.new" && mv "$1.new" "$1"
}

backup_template() {   # file -> prints backup path
    local f="$BACKUP_DIR/xray-template-$(date +%Y%m%d-%H%M%S).json"
    ( umask 077; cp "$1" "$f" )
    ls -1t "$BACKUP_DIR"/xray-template-*.json 2>/dev/null | tail -n +21 | xargs -r rm -f
    echo "$f"
}

# ---------------------------------------------------------------- add Tor locations

panel_batch_create() {
    xui_load_conf || { echo -e "${RED}[!] No saved panel connection.${NC}"; sleep 2; return; }
    ta_init_tmp

    local installed=() idx code name out_port emoji
    for idx in "${ORDER[@]}"; do
        IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
        [ -f "$BASE_DIR/node_${code}_${out_port}.conf" ] && installed+=("$idx")
    done
    if [ ${#installed[@]} -eq 0 ]; then
        echo -e "\n${RED}[!] No installed Tor nodes found. Please install nodes first.${NC}"; sleep 2; return
    fi

    echo -e "\n📌 ${MAGENTA}[ INSTALLED NODES TO ADD ]${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────${NC}"
    for idx in "${installed[@]}"; do
        IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
        printf "  ${CYAN}[%s]${NC} %s %-18s \tTorPort:${MAGENTA}%s${NC}\n" "$idx" "${EMOJIS[$code]}" "$name" "$out_port"
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────${NC}"

    local selected_nodes=() user_selection
    read -r -p "$(echo -e ${CYAN}"Select Node IDs to add to Panel (e.g. 01,05) or type 'all' [Default: all]: "${NC})" user_selection
    if [[ -z "$user_selection" || "${user_selection,,}" == "all" ]]; then
        selected_nodes=("${installed[@]}")
    else
        local s clean_s p_idx n ok dup
        IFS=',' read -ra SEL_ADDR <<< "$user_selection"
        for s in "${SEL_ADDR[@]}"; do
            clean_s=$(echo "$s" | sed 's/^0*//' | tr -d ' ')
            [ -z "$clean_s" ] && continue
            [[ "$clean_s" =~ ^[0-9]+$ ]] || { echo -e "${YELLOW}[!] '$s' is not a node ID. Skipping...${NC}"; continue; }
            p_idx=$(printf "%02d" "$clean_s")
            ok=0; for n in "${installed[@]}"; do [[ "$n" == "$p_idx" ]] && ok=1 && break; done
            if [ $ok -eq 0 ]; then echo -e "${YELLOW}[!] Node ID $p_idx is not installed or invalid. Skipping...${NC}"; continue; fi
            dup=0; for n in "${selected_nodes[@]}"; do [[ "$n" == "$p_idx" ]] && dup=1 && break; done
            [ $dup -eq 0 ] && selected_nodes+=("$p_idx")
        done
    fi
    if [ ${#selected_nodes[@]} -eq 0 ]; then echo -e "\n${RED}[!] No valid nodes selected. Returning to menu...${NC}"; sleep 2; return; fi

    # ---- read the panel
    echo -e "\n${YELLOW}[~] 🤖 Reading inbounds and Xray configuration from 3x-ui...${NC}"
    local inb_all tpl="$TA_TMP/template.json"
    inb_all=$(xui_inbounds) || { panel_fail "Could not read inbounds."; pause; return; }
    xui_template_get "$tpl" || { panel_fail "Could not read the Xray configuration."; pause; return; }
    local cand
    cand=$(jq -c --argjson ok "$CLONEABLE_PROTOCOLS" --arg re "$MANAGED_IN_RE" \
        '[.[] | select(.protocol as $p | $ok | index($p)) | select(.tag | test($re) | not)]' <<<"$inb_all")
    local n_cand; n_cand=$(jq 'length' <<<"$cand")
    if [ "$n_cand" -eq 0 ]; then
        echo -e "${RED}[!] No suitable inbound to clone (need a VLESS/VMess/Trojan/Shadowsocks inbound on this server).${NC}"
        echo -e "${YELLOW}    Create one in the 3x-ui panel first, then run this again.${NC}"; pause; return
    fi

    echo -e "\n📌 ${MAGENTA}[ SELECT INBOUND TO CLONE FROM ]${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}#    Port    Protocol   Network   Security  Users  On   Remark${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
    local i row
    for ((i=0; i<n_cand; i++)); do
        row=$(jq -r ".[$i] | [.port, .protocol, (.streamSettings.network // \"tcp\"), (.streamSettings.security // \"none\"),
             ((.settings.clients // []) | length), (if .enable then \"yes\" else \"no\" end), .remark] | @tsv" <<<"$cand")
        IFS=$'\t' read -r f_port f_proto f_net f_sec f_cl f_en f_rem <<<"$row"
        printf "  ${CYAN}[%d]${NC}  %-7s %-10s %-9s %-9s %-6s %-4s %s\n" "$((i+1))" "$f_port" "$f_proto" "$f_net" "$f_sec" "$f_cl" "$f_en" "$f_rem"
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${RED}[0] Go Back${NC}"
    local inb_sel
    read -r -p "$(echo -e ${CYAN}"Select inbound to clone (e.g. 1): "${NC})" inb_sel
    if [[ ! "$inb_sel" =~ ^[0-9]+$ ]] || [ "$inb_sel" -eq 0 ] || [ "$inb_sel" -gt "$n_cand" ]; then return; fi
    local src src_id src_remark
    src=$(jq -c ".[$((inb_sel-1))]" <<<"$cand")
    src_id=$(jq -r .id <<<"$src"); src_remark=$(jq -r .remark <<<"$src")

    local src_listen; src_listen=$(jq -r '.listen // ""' <<<"$src")
    case "$src_listen" in ""|0.0.0.0|::) ;; *) echo -e "${YELLOW}[!] This inbound listens on '$src_listen' only; clones will too (usually unreachable from outside).${NC}" ;; esac

    # ---- clients
    local nosub client_mode="share"
    nosub=$(jq '[(.settings.clients // [])[] | select((.subId // "") == "")] | length' <<<"$src")
    echo -e "\n📌 ${MAGENTA}[ USERS ON THE NEW LOCATIONS ]${NC}"
    echo -e "  ${CYAN}[1]${NC} Share the existing users ${WHITE}(same accounts & subscription links get every location)${NC}"
    echo -e "  ${CYAN}[2]${NC} No users ${WHITE}(add users to the new inbounds in the panel yourself)${NC}"
    local cm_default=1
    if [ "$nosub" -gt 0 ]; then
        echo -e "  ${YELLOW}[!] $nosub user(s) have no Subscription ID; 3x-ui refuses to reuse such users across inbounds."
        echo -e "      Set a Sub ID for them in the panel to use option 1. Defaulting to 2.${NC}"; cm_default=2
    fi
    local cm_sel; read -r -p "$(echo -e ${CYAN}"Choice [$cm_default]: "${NC})" cm_sel
    cm_sel="${cm_sel:-$cm_default}"; [ "$cm_sel" == "2" ] && client_mode="none"

    # ---- host (address / SNI for subscription links)
    local hosts_src host_json="" h_count
    hosts_src=$(xui_hosts_by_inbound "$src_id") || hosts_src="[]"
    h_count=$(jq 'length' <<<"$hosts_src" 2>/dev/null || echo 0)
    echo -e "\n📌 ${MAGENTA}[ SELECT HOST TO CLONE FROM ]${NC}"
    if [ "${h_count:-0}" -gt 0 ]; then
        echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${WHITE}#   Remark                         Address                       SNI${NC}"
        for ((i=0; i<h_count; i++)); do
            row=$(jq -r ".[$i] | [(.remark // \"\"), ((.hosts // [])[0] // \"(inbound default)\"), (.sni // \"\")] | @tsv" <<<"$hosts_src")
            IFS=$'\t' read -r f_rem f_addr f_sni <<<"$row"
            printf "  ${CYAN}[%-2d]${NC} %-30s %-29s %s\n" "$((i+1))" "$f_rem" "$f_addr" "$f_sni"
        done
        echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}[0] Do not create hosts (links use the panel's default address)${NC}"
        local host_sel; read -r -p "$(echo -e ${CYAN}"Enter host # to clone address/SNI from [1]: "${NC})" host_sel
        host_sel="${host_sel:-1}"
        if [[ "$host_sel" =~ ^[0-9]+$ ]] && [ "$host_sel" -ge 1 ] && [ "$host_sel" -le "$h_count" ]; then
            host_json=$(jq -c ".[$((host_sel-1))]" <<<"$hosts_src")
        fi
    else
        echo -e "  ${YELLOW}No Host entries on this inbound: subscription links will use the panel's default address.${NC}"
    fi

    # ---- plan
    echo -e "\n⚡ ${YELLOW}Preparing locations...${NC}"
    load_used_ports "$inb_all" "$tpl"
    local tpl_backup; tpl_backup=$(backup_template "$tpl")
    echo -e "  ${CYAN}Backup of current Xray config:${NC} $tpl_backup"

    local created_ids=() created_in=() created_out=() created_port=() created_remark=() skipped=0 failed=0
    local safe_name new_remark rand_port in_tag out_tag payload resp real_tag new_id
    for idx in "${selected_nodes[@]}"; do
        IFS=':' read -r code name out_port <<< "${NODES[$idx]}"
        emoji="${EMOJIS[$code]}"
        safe_name=$(echo "$name" | tr -d ' ' | tr -cd 'a-zA-Z0-9-')
        new_remark="$emoji $name"

        if jq -e --arg r "$new_remark" --arg re "$MANAGED_IN_RE" '.[] | select(.remark == $r and (.tag | test($re)))' <<<"$inb_all" >/dev/null 2>&1 \
           || jq -e --arg re "^${code}-.*-OUT-${out_port}\$" '.outbounds[]? | select(.tag | test($re))' "$tpl" >/dev/null 2>&1; then
            echo -e "  ⚠️  ${YELLOW}$emoji $name is already configured in the panel. Skipping to prevent duplicate...${NC}"
            skipped=$((skipped+1)); continue
        fi
        if ! pick_port; then echo -e "  ❌ ${RED}$name: no free port found.${NC}"; failed=$((failed+1)); continue; fi
        rand_port=$PICKED_PORT
        in_tag="${code}-${safe_name}-IN-${rand_port}"
        out_tag="${code}-${safe_name}-OUT-${out_port}"

        payload="$TA_TMP/inbound_${code}.json"
        build_clone_inbound "$src" "$new_remark" "$in_tag" "$rand_port" "$client_mode" > "$payload"
        if ! resp=$(xui_inbound_add "$payload"); then
            echo -e "  ❌ ${RED}$emoji $name: panel refused the inbound: $(xui_err)${NC}"; failed=$((failed+1)); continue
        fi
        new_id=$(jq -r '.id' <<<"$resp"); real_tag=$(jq -r '.tag' <<<"$resp")
        [ "$real_tag" != "$in_tag" ] && echo -e "  ${YELLOW}(panel assigned tag $real_tag)${NC}"
        created_ids+=("$new_id"); created_in+=("$real_tag"); created_out+=("$out_tag")
        created_port+=("$out_port"); created_remark+=("$new_remark")
        echo -e "  ⚙️  $emoji $name | In:$rand_port ➔ Out:$out_port Prepared (inbound #$new_id, disabled)."
    done

    if [ ${#created_ids[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}[!] Nothing was added.${NC} (skipped: $skipped, failed: $failed)"; pause; return
    fi

    # ---- upload routing, then enable
    echo -e "\n🚀 ${MAGENTA}[ UPLOADING DIRECTLY TO PANEL VIA API ]${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    local k
    for k in "${!created_ids[@]}"; do tpl_add_route "$tpl" "${created_in[$k]}" "${created_out[$k]}" "${created_port[$k]}"; done
    draw_progress "Uploading Core Configuration"
    if ! xui_template_put "$tpl"; then
        panel_fail "Panel rejected the Xray configuration - rolling back."
        for k in "${!created_ids[@]}"; do xui_inbound_del "${created_ids[$k]}"; done
        echo -e "${YELLOW}[i] The new inbounds were removed again; nothing changed in routing. Backup: $tpl_backup${NC}"; pause; return
    fi
    echo -e "${GREEN}[+] Outbounds & routing rules saved (applied live by 3x-ui).${NC}"

    echo -e "${YELLOW}[~] Enabling inbounds...${NC}"
    local enabled=0
    for k in "${!created_ids[@]}"; do
        if xui_inbound_enable "${created_ids[$k]}" true; then enabled=$((enabled+1))
        else echo -e " ❌ ${RED}Could not enable ${created_remark[$k]}: $(xui_err)${NC}"; fi
    done

    # ---- hosts
    if [ -n "$host_json" ]; then
        echo -e "${YELLOW}[~] Pushing Hosts to Panel...${NC}"
        draw_progress "Injecting Hosts"
        local hf="$TA_TMP/host.json" rport
        for k in "${!created_ids[@]}"; do
            rport=$(jq -r '.port' <<<"$(xui_inbounds | jq -c --argjson id "${created_ids[$k]}" '.[] | select(.id == $id)')" 2>/dev/null)
            build_clone_host "$host_json" "${created_remark[$k]}" "${rport:-0}" "${created_ids[$k]}" > "$hf"
            if xui_host_add "$hf"; then echo -e " ✅ ${GREEN}Host ${created_remark[$k]} Injected Successfully!${NC}"
            else echo -e " ❌ ${RED}Failed to inject host ${created_remark[$k]}: $(xui_err)${NC}"; fi
        done
    fi

    # ---- verify
    echo -e "\n${YELLOW}[~] Verifying...${NC}"
    local vt="$TA_TMP/verify.json" state bad=0
    if xui_template_get "$vt"; then
        for k in "${!created_ids[@]}"; do
            if ! jq -e --arg it "${created_in[$k]}" --arg ot "${created_out[$k]}" \
                 '[.routing.rules[]? | select((.inboundTag // []) | index($it)) | select(.outboundTag == $ot)] | length > 0' "$vt" >/dev/null; then
                echo -e " ❌ ${RED}Routing rule for ${created_remark[$k]} is missing in the panel.${NC}"; bad=1
            fi
        done
    else bad=1; fi
    sleep 2
    state=$(xui_xray_state)
    if [ "$state" != "running" ]; then
        bad=1; echo -e " ❌ ${RED}Xray state: $state $(xui_xray_error)${NC}"
        read -r -p "$(echo -e ${YELLOW}"Restore the previous Xray configuration from the backup? (Y/n): "${NC})" rs
        if [[ -z "$rs" || "${rs,,}" == "y" ]]; then
            for k in "${!created_ids[@]}"; do xui_inbound_enable "${created_ids[$k]}" false; done
            jq . "$tpl_backup" > "$TA_TMP/restore.json" && xui_template_put "$TA_TMP/restore.json" && echo -e "${GREEN}[+] Previous configuration restored (new inbounds left disabled).${NC}"
        fi
    else
        echo -e " ✅ ${GREEN}Xray is running; $enabled/${#created_ids[@]} inbound(s) enabled.${NC}"
    fi

    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    echo -e "🎉 ${GREEN}Process finished! Added: ${#created_ids[@]}, skipped: $skipped, failed: $failed.${NC}"
    [ $bad -eq 0 ] && echo -e "💡 ${CYAN}Changes are already live - no panel restart is needed. Users get the new locations on their next subscription refresh.${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}\n"
    pause
}

# ---------------------------------------------------------------- status

tor_port_state() {   # tor port -> ONLINE / DOWN
    if pgrep -f "$BASE_DIR/node_[A-Z]{2}_${1}\.conf" >/dev/null 2>&1; then echo ONLINE; else echo DOWN; fi
}

panel_status() {
    ta_init_tmp
    echo -e "\n${YELLOW}[~] Reading panel status...${NC}"
    local inb tpl="$TA_TMP/status_tpl.json" tr onl st
    inb=$(xui_inbounds) || { panel_fail "Could not read inbounds."; pause; return; }
    xui_template_get "$tpl" || { panel_fail "Could not read Xray configuration."; pause; return; }
    tr=$(xui_outbound_traffic 2>/dev/null) || tr="[]"
    onl=$(xui_onlines 2>/dev/null) || onl="[]"
    st=$(xui_call GET /panel/api/server/status 2>/dev/null)
    draw_header
    echo -e "📊 ${MAGENTA}[ PANEL STATUS ]${NC}  ${WHITE}$PANEL_URL${NC}"
    echo -e "  Xray: ${GREEN}$(jq -r '.obj.xray.state // "unknown"' <<<"$st")${NC} v$(jq -r '.obj.xray.version // "?"' <<<"$st")   Online clients (panel-wide): ${GREEN}$(jq 'length' <<<"$onl")${NC}"
    echo -e "  ${YELLOW}(3x-ui reports online users globally, not per inbound; per-location load is shown as traffic below)${NC}\n"
    echo -e "${BLUE}┌──────────────────────┬─────────┬─────┬──────────┬────────┬────────────┬────────────┬────────────┬────────────┐${NC}"
    printf "${BLUE}│${WHITE} %-20s ${BLUE}│${WHITE} %-7s ${BLUE}│${WHITE} %-3s ${BLUE}│${WHITE} %-8s ${BLUE}│${WHITE} %-6s ${BLUE}│${WHITE} %-10s ${BLUE}│${WHITE} %-10s ${BLUE}│${WHITE} %-10s ${BLUE}│${WHITE} %-10s ${BLUE}│${NC}\n" \
        "Location" "In Port" "On" "Tor Port" "Tor" "In Up" "In Down" "Tor Up" "Tor Down"
    echo -e "${BLUE}├──────────────────────┼─────────┼─────┼──────────┼────────┼────────────┼────────────┼────────────┼────────────┤${NC}"
    local rows; rows=$(jq -r --argjson tpl "$(cat "$tpl")" --argjson tr "$tr" --arg re "$MANAGED_IN_RE" '
        .[] | select(.tag | test($re)) as $i
        | ([$tpl.routing.rules[]? | select((.inboundTag // []) | index($i.tag)) | .outboundTag] | .[0] // "") as $ot
        | ([$tpl.outbounds[]? | select(.tag == $ot) | .settings.servers[0].port] | .[0] // 0) as $tp
        | ([$tr[]? | select(.tag == $ot)] | .[0] // {}) as $t
        | [$i.remark, $i.port, (if $i.enable then "yes" else "no" end), $tp, ($i.up // 0), ($i.down // 0), ($t.up // 0), ($t.down // 0)] | @tsv' <<<"$inb")
    local f_rem f_port f_en f_tp f_iu f_id f_tu f_td cnt=0 ts
    while IFS=$'\t' read -r f_rem f_port f_en f_tp f_iu f_id f_tu f_td; do
        [ -z "$f_rem" ] && continue; cnt=$((cnt+1))
        ts=$(tor_port_state "$f_tp")
        printf "${BLUE}│${NC} %-20s ${BLUE}│${NC} %-7s ${BLUE}│${NC} %-3s ${BLUE}│${NC} %-8s ${BLUE}│${NC} %-6s ${BLUE}│${NC} %-10s ${BLUE}│${NC} %-10s ${BLUE}│${NC} %-10s ${BLUE}│${NC} %-10s ${BLUE}│${NC}\n" \
            "$f_rem" "$f_port" "$f_en" "$f_tp" "$ts" "$(human_bytes "$f_iu")" "$(human_bytes "$f_id")" "$(human_bytes "$f_tu")" "$(human_bytes "$f_td")"
    done <<<"$rows"
    [ $cnt -eq 0 ] && printf "${BLUE}│${YELLOW} %-117s ${BLUE}│${NC}\n" "No Tor locations are configured in the panel yet."
    echo -e "${BLUE}└──────────────────────┴─────────┴─────┴──────────┴────────┴────────────┴────────────┴────────────┴────────────┘${NC}\n"
    pause
}

# ---------------------------------------------------------------- remove

panel_remove_locations() {
    ta_init_tmp
    local inb tpl="$TA_TMP/remove_tpl.json"
    inb=$(xui_inbounds) || { panel_fail "Could not read inbounds."; pause; return; }
    xui_template_get "$tpl" || { panel_fail "Could not read Xray configuration."; pause; return; }
    local managed n; managed=$(jq -c --arg re "$MANAGED_IN_RE" '[.[] | select(.tag | test($re))]' <<<"$inb"); n=$(jq 'length' <<<"$managed")
    if [ "$n" -eq 0 ]; then echo -e "\n${YELLOW}[!] No Tor locations found in the panel.${NC}"; sleep 2; return; fi
    echo -e "\n📌 ${MAGENTA}[ TOR LOCATIONS IN PANEL ]${NC}"
    local i row
    for ((i=0; i<n; i++)); do
        row=$(jq -r ".[$i] | [.remark, .port, .tag] | @tsv" <<<"$managed"); IFS=$'\t' read -r a b c <<<"$row"
        printf "  ${CYAN}[%d]${NC} %-22s port %-6s %s\n" "$((i+1))" "$a" "$b" "$c"
    done
    echo -e "  ${RED}[99] REMOVE ALL${NC}   ${YELLOW}[0] Cancel${NC}"
    local sel; read -r -p "$(echo -e ${CYAN}"Select (comma separated, e.g. 1,3): "${NC})" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    local pick=()
    if [ "$sel" == "99" ]; then for ((i=0; i<n; i++)); do pick+=("$i"); done
    else
        local s; IFS=',' read -ra SA <<< "$sel"
        for s in "${SA[@]}"; do s=$(tr -d ' ' <<<"$s"); [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "$n" ] && pick+=("$((s-1))"); done
    fi
    [ ${#pick[@]} -eq 0 ] && { echo -e "${RED}[!] Nothing selected.${NC}"; sleep 1; return; }
    read -r -p "$(echo -e ${YELLOW}"Remove ${#pick[@]} location(s) from the panel? Users lose these locations. (y/N): "${NC})" c
    [[ "${c,,}" == "y" ]] || return
    local bk; bk=$(backup_template "$tpl"); local id tag
    for i in "${pick[@]}"; do
        id=$(jq -r ".[$i].id" <<<"$managed"); tag=$(jq -r ".[$i].tag" <<<"$managed")
        # inbound first, routing afterwards: traffic can never bypass Tor while the inbound exists
        if xui_inbound_del "$id"; then tpl_remove_route "$tpl" "$tag"; echo -e " ✅ ${GREEN}Removed $(jq -r ".[$i].remark" <<<"$managed")${NC}"
        else echo -e " ❌ ${RED}Could not remove $tag: $(xui_err)${NC}"; fi
    done
    if xui_template_put "$tpl"; then echo -e "${GREEN}[+] Xray configuration updated (backup: $bk).${NC}"
    else panel_fail "Could not update the Xray configuration."; fi
    pause
}


# ================= MENU LOOP =================
case "$1" in
    --install-engine) install_engine_core; exit $? ;;
    --version|-v)     echo "tor-automate $TA_VERSION"; exit 0 ;;
esac
check_root

while true; do
    draw_header
    if command -v tor &> /dev/null && command -v jq &> /dev/null; then
        echo -e "   ${WHITE}System Status:${NC} ${GREEN}Engine Ready${NC}"
    else
        echo -e "   ${WHITE}System Status:${NC} ${RED}Not Ready${NC}"
    fi
    echo -e "${BLUE} ────────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC} ${WHITE}»${NC} Install Engine & Core Tools"
    echo -e "  ${CYAN}[2]${NC} ${WHITE}»${NC} Update System"
    echo -e "  ${CYAN}[3]${NC} ${WHITE}»${NC} Uninstall System"
    echo -e "${BLUE} ────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}[4]${NC} ${WHITE}»${NC} Add Location Node (Single)"
    echo -e "  ${GREEN}[5]${NC} ${WHITE}»${NC} Bulk Add Nodes (Multiple/All)"
    echo -e "  ${GREEN}[6]${NC} ${WHITE}»${NC} View Active Nodes"
    echo -e "  ${GREEN}[7]${NC} ${WHITE}»${NC} Edit or Delete Nodes"
    echo -e "  ${CYAN}[8]${NC} ${WHITE}»${NC} Advanced Port Settings"
    echo -e "${BLUE} ────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}[9]${NC} ${WHITE}»${NC} Panel Sanaei 3x-ui Integration"
    echo -e "${BLUE} ────────────────────────────────────────────────────────${NC}"
    echo -e "  ${RED}[0]${NC} ${WHITE}»${NC} Exit Program"
    echo -e "${BLUE} ────────────────────────────────────────────────────────${NC}\n"

    read -r -p "$(echo -e ${MAGENTA}"Enter choice [0-9]: "${NC})" main_choice

    case $main_choice in
        1) install_engine ;;
        2|8) echo -e "${YELLOW}[!] This feature is currently locked for this tier.${NC}"; sleep 2 ;;
        3) uninstall_engine ;;
        4) add_single_node ;;
        5) bulk_add_nodes ;;
        6) view_active_nodes ;;
        7) edit_delete_nodes ;;
        9) panel_login ;;
        0) clear; exit 0 ;;
        *) ;;
    esac
done
