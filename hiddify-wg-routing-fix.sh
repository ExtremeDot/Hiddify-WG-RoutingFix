#!/usr/bin/env bash
set -euo pipefail

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

CONFIG_PATH="/usr/local/bin/config.json"
SERVICE_PATH="/etc/systemd/system/my-singbox.service"
CHECK_SCRIPT="/usr/local/bin/check_my_singbox.sh"
RULE_SCRIPT="/usr/local/bin/singbox-rule.sh"

REQUIRED_VERSION="1.11.15"
TARBALL="sing-box-${REQUIRED_VERSION}-linux-amd64.tar.gz"
RELEASE_DIR="sing-box-${REQUIRED_VERSION}-linux-amd64"

function ensure_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Error: this script must be run as root.${RESET}"
        exit 1
    fi
}

function pause() {
    read -rp "Press Enter to continue..."
}

function check_install_singbox() {
    echo -e "${CYAN}Checking sing-box installation...${RESET}"
    if command -v sing-box >/dev/null 2>&1; then
        installed=$(sing-box version 2>/dev/null || true)
        if echo "$installed" | grep -q "$REQUIRED_VERSION"; then
            echo -e "${GREEN}sing-box version ${REQUIRED_VERSION} is already installed.${RESET}"
            return
        else
            echo -e "${YELLOW}sing-box is installed but different version:${RESET}"
            echo "$installed"
        fi
    else
        echo -e "${YELLOW}sing-box not found.${RESET}"
    fi

    echo -e "${CYAN}Installing sing-box version ${REQUIRED_VERSION}...${RESET}"
    tmpdir=$(mktemp -d)
    pushd "$tmpdir" >/dev/null

    wget -q "https://github.com/SagerNet/sing-box/releases/download/v${REQUIRED_VERSION}/${TARBALL}"
    tar -xf "${TARBALL}"
    cd "${RELEASE_DIR}"
    install -m 755 sing-box /usr/local/bin/sing-box

    popd >/dev/null
    rm -rf "$tmpdir"

    echo -e "${GREEN}Installed sing-box ${REQUIRED_VERSION}.${RESET}"
    sing-box version || true
}

function ensure_config() {
    echo -e "${CYAN}Ensuring config file at ${CONFIG_PATH}...${RESET}"
    desired='{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "domain_strategy": "ipv4_only",
      "interface_name": "sing-tun",
      "address": "172.19.0.1/30",
      "mtu": 1420,
      "auto_route": true,
      "strict_route": true,
      "stack": "gvisor",
      "endpoint_independent_nat": true,
      "sniff": true,
      "sniff_override_destination": false
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "socks-out",
      "server": "127.0.0.1",
      "server_port": 12334
    }
  ],
  "route": {
    "final": "socks-out",
    "auto_detect_interface": false,
    "default_interface": "enp1s0"
  }
}'

    if [[ -f "$CONFIG_PATH" ]]; then
        if diff -q <(echo "$desired") "$CONFIG_PATH" >/dev/null 2>&1; then
            echo -e "${GREEN}Config already matches desired content.${RESET}"
        else
            echo -e "${YELLOW}Config exists but differs. Backing up and replacing...${RESET}"
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%s)"
            echo "$desired" >"$CONFIG_PATH"
        fi
    else
        echo "$desired" >"$CONFIG_PATH"
        echo -e "${GREEN}Created config.json.${RESET}"
    fi

    chmod 644 "$CONFIG_PATH"
    echo -e "${GREEN}Set permissions to 644 on config.json.${RESET}"
}

function ensure_service() {
    echo -e "${CYAN}Ensuring systemd service at ${SERVICE_PATH}...${RESET}"
    service_content='[Unit]
Description=My Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/sing-box run -c /usr/local/bin/config.json
#ExecStartPost=/usr/local/bin/singbox-rule.sh add
#ExecStopPost=/usr/local/bin/singbox-rule.sh del
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
'

    if [[ -f "$SERVICE_PATH" ]]; then
        if diff -q <(echo "$service_content") "$SERVICE_PATH" >/dev/null 2>&1; then
            echo -e "${GREEN}Service file already up to date.${RESET}"
        else
            echo -e "${YELLOW}Service file differs. Backing up and replacing...${RESET}"
            cp "$SERVICE_PATH" "${SERVICE_PATH}.bak.$(date +%s)"
            echo "$service_content" >"$SERVICE_PATH"
        fi
    else
        echo "$service_content" >"$SERVICE_PATH"
        echo -e "${GREEN}Created systemd service file.${RESET}"
    fi

    systemctl daemon-reload
    systemctl enable my-singbox.service
    echo -e "${GREEN}Enabled my-singbox.service.${RESET}"
}

function ensure_check_script() {
    echo -e "${CYAN}Ensuring check_my_singbox.sh...${RESET}"
    cat >"$CHECK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCKFILE="/var/run/check_my_singbox.lock"
MAX_RESTARTS=3
WINDOW=300

SERVICE="my-singbox.service"
TAG="check_my_singbox"
now=$(date +%s)

if [[ -f "$LOCKFILE" ]]; then
    awk -v now="$now" -v window="$WINDOW" '$1+0 >= now-window' "$LOCKFILE" > "${LOCKFILE}.tmp"
    mv "${LOCKFILE}.tmp" "$LOCKFILE"
else
    : > "$LOCKFILE"
fi

restart_count=$(wc -l < "$LOCKFILE" | tr -d ' ')

if ! /usr/bin/curl --silent --show-error --fail --max-time 5 --socks5 127.0.0.1:12334 https://myip.wtf/json >/dev/null 2>&1; then
    if (( restart_count >= MAX_RESTARTS )); then
        logger -t "$TAG" "curl failed, reached $restart_count restarts in last $WINDOW seconds; giving up for now"
        exit 1
    fi

    if systemctl is-active --quiet "$SERVICE"; then
        logger -t "$TAG" "curl failed but $SERVICE is active; skipping restart (attempt $((restart_count+1)))"
    else
        logger -t "$TAG" "curl failed, restarting $SERVICE (attempt $((restart_count+1)))"
        /usr/bin/systemctl restart "$SERVICE"
        echo "$now" >> "$LOCKFILE"
    fi
else
    logger -t "$TAG" "curl succeeded"
fi
EOF

    chmod 755 "$CHECK_SCRIPT"
    echo -e "${GREEN}check_my_singbox.sh created/updated and made executable.${RESET}"
}

function ensure_rule_script() {
    echo -e "${CYAN}Ensuring singbox-rule.sh...${RESET}"
    cat >"$RULE_SCRIPT" <<'EOF'
#!/bin/bash

case "$1" in
  add)
        if /sbin/ip rule show | grep "100:*" >/dev/null 2>&1; then
            echo "Exist, Skip it."
        else
            echo "Adding Rule"
            if /sbin/ip rule add from 10.90.0.0/24 lookup 2022 priority 100 ; then
                echo "Rule added"
            else
                echo "Failed to add rule"
            fi
        fi
    ;;
  del)
        if /sbin/ip rule show | grep "100:*" >/dev/null 2>&1; then
            echo "Exist, Deleting...."
            if /sbin/ip rule delete priority 100 ; then
                echo "Rule has been deleted"
            else
                echo "Failed to remove rule"
            fi
        else
            echo "No Rule detected"
        fi
    ;;
  *)
    echo "Usage: $0 {add|del}"
    ;;
esac
EOF

    chmod 755 "$RULE_SCRIPT"
    echo -e "${GREEN}singbox-rule.sh created/updated and made executable.${RESET}"
}

function ensure_cron() {
    echo -e "${CYAN}Ensuring cron entries...${RESET}"
    # current crontab for root
    crontab -l 2>/dev/null | { 
        grep -F "*/2 * * * * /usr/local/bin/check_my_singbox.sh" >/dev/null && echo -e "${GREEN}check_my_singbox cron exists.${RESET}" || {
            (crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/check_my_singbox.sh") | crontab -
            echo -e "${GREEN}Added check_my_singbox cron.${RESET}"
        }
    }

    crontab -l 2>/dev/null | {
        grep -F "*/5 * * * * /usr/local/bin/singbox-rule.sh add" >/dev/null && echo -e "${GREEN}singbox-rule cron exists.${RESET}" || {
            (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/singbox-rule.sh add") | crontab -
            echo -e "${GREEN}Added singbox-rule cron.${RESET}"
        }
    }
}

function show_menu() {
    clear
    echo -e "${CYAN}===== Sing-box Setup & Management =====${RESET}"
    echo -e "${YELLOW}1) Check/install sing-box${RESET}"
    echo -e "${YELLOW}2) View/edit config.json${RESET}"
    echo -e "${YELLOW}3) Setup/enabled systemd service${RESET}"
    echo -e "${YELLOW}4) Setup check and rule scripts + cron${RESET}"
    echo -e "${YELLOW}5) Service status${RESET}"
    echo -e "${YELLOW}6) Start/Restart service${RESET}"
    echo -e "${YELLOW}7) Enable/Reload cron (reload crontab)${RESET}"
    echo -e "${YELLOW}8) Exit${RESET}"
    echo
    read -rp "Choose an option: " opt
    case "$opt" in
        1)
            check_install_singbox
            pause
            ;;
        2)
            ensure_config
            echo -e "${CYAN}Opening editor for config.json (fallback to nano)...${RESET}"
            ${EDITOR:-nano} "$CONFIG_PATH"
            pause
            ;;
        3)
            ensure_service
            echo -e "${CYAN}You can run: systemctl start my-singbox.service${RESET}"
            pause
            ;;
        4)
            ensure_check_script
            ensure_rule_script
            ensure_cron
            pause
            ;;
        5)
            systemctl status my-singbox.service --no-pager || true
            pause
            ;;
        6)
            systemctl restart my-singbox.service
            echo -e "${GREEN}Service restarted.${RESET}"
            pause
            ;;
        7)
            ensure_cron
            pause
            ;;
        8)
            echo -e "${GREEN}Exiting.${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${RESET}"
            pause
            ;;
    esac
}

# main
ensure_root

while true; do
    show_menu
done
