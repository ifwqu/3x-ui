#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# 端口 helpers: detect listener and owning process (best effort)
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Simple helpers for domain/IP validation
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# acme.sh's standalone server binds IPv4 by default; --listen-v6 makes it
# v6-only, which breaks HTTP-01 validation when the domain's A record points
# at this host's IPv4 (#4994). Only force IPv6 when the host has no global
# IPv4 address at all.
acme_listen_flag() {
    if ip -4 addr show scope global 2> /dev/null | grep -q "inet "; then
        echo ""
    else
        echo "--listen-v6"
    fi
}

# check root
[[ $EUID -ne 0 ]] && LOGE "ERROR: You must be root to run this script! \n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "无法检测系统类型，请联系作者！" >&2
    exit 1
fi
echo "系统发行版为： $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

运行中_in_docker="false"
if [[ -f /.dockerenv ]] || [[ "${XUI_IN_DOCKER}" == "true" ]]; then
    运行中_in_docker="true"
fi

# Declare Variables
if [[ "${运行中_in_docker}" == "true" ]]; then
    xui_folder="${XUI_MAIN_FOLDER:=/app}"
else
    xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
fi
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "重启 the panel, Attention: 重启ing the panel will also restart xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此操作将更新所有 x-ui 组件到最新版本，数据不会丢失。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新面板 is complete, 面板 has automatically restarted "
        before_show_menu
    fi
}

update_dev() {
    confirm "这将更新 x-ui 到最新的 DEV 提交（dev-latest 滚动构建，非稳定版）。您的数据会被保留。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    # XUI_UPDATE_TAG tells update.sh to install the dev-latest pre-release
    # instead of the latest stable tag.
    XUI_UPDATE_TAG="dev-latest" bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "Dev 更新完成，面板已自动重启 "
        before_show_menu
    fi
}

replace_xui_script() {
    local url="$1"
    local use_if_modified_since="$2"
    local temp_file="/usr/bin/x-ui-temp.$$"

    rm -f "$temp_file"
    if [[ "$use_if_modified_since" == "true" ]]; then
        curl -fLRo "$temp_file" -z /usr/bin/x-ui "$url"
    else
        curl -fLRo "$temp_file" "$url"
    fi
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        # -z above means "not modified since /usr/bin/x-ui" rather than a
        # real failure, so an empty download here is success, not an error.
        [[ "$use_if_modified_since" == "true" ]] && return 0
        return 1
    fi

    mv -f "$temp_file" /usr/bin/x-ui
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    # The move already landed the new script; a transient chmod failure here
    # shouldn't make callers think the whole replace failed.
    chmod +x /usr/bin/x-ui
    return 0
}

update_menu() {
    echo -e "${yellow}Updating Menu${plain}"
    confirm "This function will update the menu to the latest changes." "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    if replace_xui_script "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh" "false"; then
        chmod +x ${xui_folder}/x-ui.sh
        echo -e "${green}更新面板 successful. The panel has automatically restarted.${plain}"
        exit 0
    else
        echo -e "${red}菜单更新失败。${plain}"
        return 1
    fi
}

legacy_version() {
    echo -n "请输入面板版本号（如 2.4.0）："
    read -r tag_version

    if [ -z "$tag_version" ]; then
        echo "面板 version cannot be empty. Exiting."
        exit 1
    fi
    # Use the entered panel version in the download link
    install_command="bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/v$tag_version/install.sh") v$tag_version"

    echo "正在下载并安装面板版本 $tag_version..."
    eval $install_command
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
}

xui_env_file_path() {
    case "${release}" in
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

uninstall() {
    confirm "确定要卸载面板吗？ xray will also un已安装!" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    local panel_used_postgres="false"
    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        panel_used_postgres="true"
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf
    rm -f "$db_env_file"

    if [[ "$panel_used_postgres" == "true" ]] && postgresql_已安装; then
        purge_postgresql
    fi

    echo ""
    echo -e "卸载面板ed Successfully.\n"
    echo "如需重新安装面板，可使用以下命令："
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)${plain}"
    echo ""
    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "Are you sure to reset the username and password of the panel?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    read -rp "请设置登录用户名 [默认为随机用户名]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "请设置登录密码 [默认为随机密码]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "是否禁用已配置的双因素认证？(y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor=true > /dev/null 2>&1
        echo -e "Two factor authentication has been disabled."
    fi

    echo -e "面板 login username has been reset to: ${green} ${config_account} ${plain}"
    echo -e "面板 login password has been reset to: ${green} ${config_password} ${plain}"
    echo -e "${green} Please use the new login username and password to access the X-UI panel. Also remember them! ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}Resetting Web 基础路径${plain}"

    read -rp "确定要重置 Web 基础路径吗？(y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}Operation canceled.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Apply the new web base path setting
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    echo -e "Web 基础路径已重置 to: ${green}${config_webBasePath}${plain}"
    echo -e "${green}Please use the new web base path to access the panel.${plain}"
    restart
}

reset_config() {
    confirm "Are you sure you want to reset all panel settings, Account data will not be lost, 用户名 and password will not change" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "All panel settings have been reset to default."
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "get current settings error, please check logs"
        show_menu
        return
    fi
    LOGI "${info}"

    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        local dsn
        dsn="$(grep -E '^XUI_DB_DSN=' "$db_env_file" | head -1 | cut -d= -f2-)"
        local dsn_safe
        dsn_safe="$(echo "$dsn" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|')"
        echo -e "${green}Database: PostgreSQL — ${dsn_safe}${plain}"
    else
        echo -e "${green}Database: SQLite (/etc/x-ui/x-ui.db)${plain}"
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}Could not auto-detect server IP from any provider.${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公网 IPv4 地址： " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}Invalid IPv4 address. Please try again.${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")
        # The cert folder name is only the certificate's first domain. A
        # multidomain (SAN) certificate may be served under any name it covers,
        # so read the real names from the certificate itself (#5070).
        local cert_sans=""
        if [[ -f "$existing_cert" ]] && command -v openssl > /dev/null 2>&1; then
            cert_sans=$(openssl x509 -in "$existing_cert" -noout -ext subjectAltName 2> /dev/null \
                | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2)
            if [[ -n "$cert_sans" ]] && ! echo "$cert_sans" | grep -qx "$domain"; then
                domain=$(echo "$cert_sans" | head -n1)
            fi
        fi

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问地址： https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问地址： https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
        if [[ -n "$cert_sans" && $(echo "$cert_sans" | wc -l) -gt 1 ]]; then
            echo -e "${yellow}The certificate also covers:${plain} $(echo "$cert_sans" | grep -vx "$domain" | tr '\n' ' ')"
        fi
    else
        echo -e "${red}⚠ WARNING: No SSL certificate configured!${plain}"
        echo -e "${yellow}You can get a Let's Encrypt certificate for your IP address (valid ~6 天, auto-renews).${plain}"
        read -rp "现在为 IP 生成 SSL 证书？[y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop 0 > /dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}访问地址： https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                # ssl_cert_issue_for_ip already restarts the panel, but ensure it's 运行中
                start 0 > /dev/null 2>&1
            else
                LOGE "IP certificate setup failed."
                echo -e "${yellow}You can try again via main menu option 20 (SSL 证书管理).${plain}"
                start 0 > /dev/null 2>&1
            fi
        else
            echo -e "${yellow}访问地址： http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}For security, please configure SSL certificate using main menu option 20 (SSL 证书管理)${plain}"
        fi
    fi
}

set_port() {
    echo -n "Enter port number[1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "已取消"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "The port is set, Please restart the panel now, and use the new port ${green}${port}${plain} to access web panel"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板 is 运行中, No need to start again, If you need to restart, please select restart"
    else
        if [[ "${运行中_in_docker}" == "true" ]]; then
            LOGE "面板 process is not 运行中 inside this container."
            LOGI "In Docker the panel is the container's main process. 重启 the container to bring it back up:"
            LOGI "  docker restart <container_name>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui 启动ed Successfully"
        else
            LOGE "panel Failed to start, Probably because it takes longer than two seconds to start, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板 stopped, No need to stop again!"
    else
        if [[ "${运行中_in_docker}" == "true" ]]; then
            LOGI "In Docker the panel runs as the container's main process."
            LOGI "To stop it, stop the container from the host:"
            LOGI "  docker stop <container_name>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui and xray stopped successfully"
        else
            LOGE "面板 stop failed, Probably because the stop time exceeds two seconds, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        if signal_xui HUP; then
            sleep 1
            signal_xui USR1
            LOGI "重启 signal sent to the panel and xray-core."
        else
            LOGE "Could not find the 运行中 panel process to signal."
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui and xray 重启ed successfully"
        else
            LOGE "面板 restart failed, Please check the log information later"
        fi
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui and xray 重启ed successfully"
    else
        LOGE "面板 restart failed, Probably because it takes longer than two seconds to start, Please check the log information later"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        if signal_xui USR1; then
            LOGI "xray-core 重启 signal sent successfully, Please check the log information to confirm whether xray restarted successfully"
        else
            LOGE "Could not find the 运行中 panel process to signal."
        fi
        sleep 2
        show_xray_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui reload
    else
        systemctl reload x-ui
    fi
    LOGI "xray-core 重启 signal sent successfully, Please check the log information to confirm whether xray restarted successfully"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        show_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        LOGI "Autostart is controlled by the Docker restart policy (e.g. 'restart: unless-stopped' in docker-compose.yml)."
        LOGI "There is no service to enable inside the container."
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Set to boot automatically on startup successfully"
    else
        LOGE "x-ui Failed to set Autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        LOGI "Autostart is controlled by the Docker restart policy (e.g. 'restart: unless-stopped' in docker-compose.yml)."
        LOGI "Set 'restart: no' for the container on the host to disable autostart."
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Autostart 已取消 successfully"
    else
        LOGE "x-ui Failed to cancel autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "请选择: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t2.${plain} Clear All logs"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "请选择: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "All Logs cleared."
                restart
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} 启用 BBR"
    echo -e "${green}\t2.${plain} Disable BBR"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${yellow}BBR is not currently enabled.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        # sysctl -w already restores the live values, so no `sysctl --system`
        # afterwards — it would re-apply every sysctl file on the host and
        # surface unrelated errors from the distro's own defaults (see issue #5160)
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
    else
        # Replace BBR with CUBIC configurations
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR has been replaced with CUBIC successfully.${plain}"
    else
        echo -e "${red}Failed to replace BBR with CUBIC. Please check your system configuration.${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR is already enabled!${plain}"
        before_show_menu
    fi

    # 启用 BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Backup old settings from sysctl.conf, if any
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        # Apply only our config file; `sysctl --system` would re-apply every
        # sysctl file on the host and surface unrelated errors from the distro's
        # own defaults (see issue #5160)
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Verify that BBR is enabled
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR has been enabled successfully.${plain}"
    else
        echo -e "${red}Failed to enable BBR. Please check your system configuration.${plain}"
    fi
}

update_shell() {
    if replace_xui_script "https://github.com/MHSanaei/3x-ui/raw/main/x-ui.sh" "true"; then
        LOGI "Upgrade script succeeded, Please rerun the script"
        before_show_menu
    else
        echo ""
        LOGE "Failed to download script, Please check whether the machine can connect Github"
        before_show_menu
    fi
}

xui_pid() {
    ps -ef 2> /dev/null | grep -F "${xui_folder}/x-ui" | grep -v grep | awk 'NR==1 {print $1}'
}

signal_xui() {
    local sig="$1" pid
    pid="$(xui_pid)"
    if [[ -z "${pid}" ]]; then
        return 1
    fi
    kill -"${sig}" "${pid}" 2> /dev/null
}

# 0: 运行中, 1: not 运行中, 2: not 已安装
check_status() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        if [[ ! -x "${xui_folder}/x-ui" ]]; then
            return 2
        fi
        if [[ -n "$(xui_pid)" ]]; then
            return 0
        else
            return 1
        fi
    fi
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "运行中" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板 已安装, Please do not reinstall"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "Please install the panel first"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "面板 state: ${green}Running${plain}"
            show_enable_status
            ;;
        1)
            echo -e "面板 state: ${yellow}Not Running${plain}"
            show_enable_status
            ;;
        2)
            echo -e "面板 state: ${red}Not 安装面板ed${plain}"
            ;;
    esac
    show_xray_status
    show_mtproto_status
}

show_enable_status() {
    if [[ "${运行中_in_docker}" == "true" ]]; then
        echo -e "启动 automatically: ${green}Managed by Docker${plain}"
        return
    fi
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "启动 automatically: ${green}Yes${plain}"
    else
        echo -e "启动 automatically: ${red}No${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray state: ${green}Running${plain}"
    else
        echo -e "xray state: ${red}Not Running${plain}"
    fi
}

# show_mtproto_status reports each mtproto inbound's mtg sidecar (one process per
# inbound, run outside xray). Silent when no mtproto inbound is configured.
show_mtproto_status() {
    local cfg_dir="${xui_folder}/bin/mtproto"
    local cfgs=()
    if [[ -d "${cfg_dir}" ]]; then
        for f in "${cfg_dir}"/mtg-*.toml; do
            [[ -e "$f" ]] && cfgs+=("$f")
        done
    fi
    [[ ${#cfgs[@]} -eq 0 ]] && return

    local 运行中
    运行中=$(ps -ef | grep "mtg-linux" | grep -v "grep" | grep -oE 'mtg-[0-9]+\.toml')
    for f in "${cfgs[@]}"; do
        local name id bind
        name=$(basename "$f")
        id=$(echo "${name}" | sed -E 's/mtg-([0-9]+)\.toml/\1/')
        bind=$(grep -E '^[[:space:]]*bind-to' "$f" | head -1 | cut -d'"' -f2)
        if echo "${运行中}" | grep -qx "${name}"; then
            echo -e "mtproto inbound ${id} (${bind}): ${green}Running${plain}"
        else
            echo -e "mtproto inbound ${id} (${bind}): ${red}Not Running${plain}"
        fi
    done
}

firewall_menu() {
    echo -e "${green}\t1.${plain} ${green}安装面板${plain} Firewall"
    echo -e "${green}\t2.${plain} 端口 List [numbered]"
    echo -e "${green}\t3.${plain} ${green}Open${plain} 端口"
    echo -e "${green}\t4.${plain} ${red}Delete${plain} 端口 from List"
    echo -e "${green}\t5.${plain} ${green}Enable${plain} Firewall"
    echo -e "${green}\t6.${plain} ${red}Disable${plain} Firewall"
    echo -e "${green}\t7.${plain} Firewall Status"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "ufw firewall is not 已安装. 安装面板ing now..."
        apt-get update
        apt-get install -y ufw
    else
        echo "ufw firewall is already 已安装"
    fi

    # Check if the firewall is inactive
    if ufw status | grep -q "Status: active"; then
        echo "Firewall is already active"
    else
        echo "Activating firewall..."
        # Open the necessary ports
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #web端口
        ufw allow 2096/tcp #subport

        # Enable the firewall
        ufw --force enable
    fi
}

open_ports() {
    # Prompt the user to enter the ports they want to open
    read -rp "请输入要开放的端口（如 80,443,2053 或范围 400-500）: " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "错误：输入无效. 请输入以逗号分隔的端口列表或端口范围 (e.g. 80,443,2053 or 400-500)." >&2
        exit 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Open the port range
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "Opened the specified ports:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Display current rules with numbers
    echo "Current UFW rules:"
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "Do you want to delete rules by:"
    echo "1) 规则编号"
    echo "2) 端口"
    read -rp "请输入您的选择（1 或 2）: " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "请输入要删除的规则编号（如 1, 2 等）: " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "错误：输入无效. Please enter a comma-separated list of rule numbers." >&2
            exit 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "Failed to delete rule number $rule_number"
        done

        echo "Selected rules have been deleted."

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "请输入要删除的端口（如 80,443,2053 或范围 400-500）: " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "错误：输入无效. 请输入以逗号分隔的端口列表或端口范围 (e.g. 80,443,2053 or 400-500)." >&2
            exit 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Delete the port range
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "Deleted the specified ports:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}Error:${plain} Invalid choice. Please enter 1 or 2." >&2
        exit 1
    fi
}

update_all_geofiles() {
    local failed=0
    update_geofiles "main" || failed=1
    update_geofiles "IR" || failed=1
    update_geofiles "RU" || failed=1
    return $failed
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
        *)
            echo -e "${red}update_geofiles: unknown dataset '${1}'${plain}"
            return 1
            ;;
    esac
    local failed=0 http_code
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        local dest="${xui_folder}/bin/${dat}.dat"
        local temp_file="${dest}.tmp.$$"
        rm -f "$temp_file"
        # -z (against the live file, not the temp file) skips the download
        # (server answers 304) when the local copy is already current.
        http_code=$(curl -sSfLRo "$temp_file" -z "$dest" -w '%{http_code}' \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat)
        if [[ $? -ne 0 ]]; then
            echo -e "${red}${dat}.dat: download failed${plain}"
            rm -f "$temp_file"
            failed=1
        elif [[ "$http_code" == "304" ]]; then
            echo -e "${dat}.dat: already up to date"
            rm -f "$temp_file"
        elif [[ ! -s "$temp_file" ]]; then
            echo -e "${red}${dat}.dat: downloaded file is empty${plain}"
            rm -f "$temp_file"
            failed=1
        else
            mv -f "$temp_file" "$dest"
            if [[ $? -ne 0 ]]; then
                echo -e "${red}${dat}.dat: failed to install${plain}"
                rm -f "$temp_file"
                failed=1
            else
                echo -e "${green}${dat}.dat: updated${plain}"
                geo_updated=1
            fi
        fi
    done
    return $failed
}

run_geo_update() {
    local name="$1"
    shift
    geo_updated=0
    "$@"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Some ${name} could not be updated. Check the errors above.${plain}"
    elif [[ $geo_updated -eq 1 ]]; then
        echo -e "${green}${name} have been updated successfully!${plain}"
        restart
    else
        echo -e "${green}${name} are already up to date, restart is not needed.${plain}"
    fi
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} All"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            run_geo_update "Loyalsoldier datasets" update_geofiles "main"
            ;;
        2)
            run_geo_update "chocolate4u datasets" update_geofiles "IR"
            ;;
        3)
            run_geo_update "runetfreedom datasets" update_geofiles "RU"
            ;;
        4)
            run_geo_update "geo files" update_all_geofiles
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

install_acme() {
    # Check if acme.sh is already 已安装
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh is already 已安装."
        return 0
    fi

    LOGI "安装面板ing acme.sh..."
    cd ~ || return 1 # Ensure you can change to the home directory

    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "安装面板ation of acme.sh failed."
        return 1
    else
        LOGI "安装面板ation of acme.sh succeeded."
    fi

    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} Get SSL (Domain)"
    echo -e "${green}\t2.${plain} Revoke & Remove"
    echo -e "${green}\t3.${plain} Force Renew"
    echo -e "${green}\t4.${plain} Show Existing Domains"
    echo -e "${green}\t5.${plain} Set Cert paths for the panel"
    echo -e "${green}\t6.${plain} Get SSL for IP Address (6-day cert, auto-renews)"
    echo -e "${green}\t0.${plain} Back to Main Menu"

    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            ssl_cert_issue
            ssl_cert_issue_main
            ;;
        2)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "No certificates found to revoke."
            else
                echo "Existing domains:"
                echo "$domains"
                read -rp "请从列表中选择域名以撤销并移除证书: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    # The IP-cert flow (option 6) stores files under /root/cert/ip, but acme.sh
                    # tracks the cert under the actual IP address(es). Resolve those so renewal
                    # state is torn down too; otherwise the acme.sh cron re-creates the deleted cert.
                    local acme_ids="${domain}"
                    if [[ "${domain}" == "ip" ]]; then
                        acme_ids=$(~/.acme.sh/acme.sh --list 2> /dev/null | awk 'NR>1 {print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:')
                    fi
                    for id in ${acme_ids}; do
                        # Best-effort revoke at the CA, then drop acme.sh renewal tracking.
                        ~/.acme.sh/acme.sh --revoke -d "${id}" 2> /dev/null
                        ~/.acme.sh/acme.sh --remove -d "${id}" 2> /dev/null
                        # --remove leaves the cert files on disk, so delete the state dirs (RSA + ECC).
                        rm -rf ~/.acme.sh/"${id}" ~/.acme.sh/"${id}_ecc"
                    done
                    # Delete the local certificate files for this domain.
                    rm -rf "/root/cert/${domain}"
                    LOGI "Certificate revoked and removed for domain: ${domain}"

                    # If the panel currently serves this domain's cert, clear the stored paths
                    # so it stops loading the now-deleted files, then restart.
                    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
                    if [[ "${existing_cert}" == "/root/cert/${domain}/"* ]]; then
                        ${xui_folder}/x-ui cert -reset
                        LOGI "Cleared panel certificate paths referencing ${domain}; restarting panel."
                        restart
                    fi
                else
                    echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        3)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "No certificates found to renew."
            else
                echo "Existing domains:"
                echo "$domains"
                read -rp "请从列表中选择域名以续期 SSL 证书: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --renew -d ${domain} --force
                    LOGI "Certificate forcefully renewed for domain: $domain"
                else
                    echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        4)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "No certificates found under /root/cert."
            else
                echo "Existing domains and their paths:"
                for domain in $domains; do
                    local cert_path="/root/cert/${domain}/fullchain.pem"
                    local key_path="/root/cert/${domain}/privkey.pem"
                    if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                        echo -e "Domain: ${domain}"
                        echo -e "\tCertificate Path: ${cert_path}"
                        echo -e "\tPrivate Key Path: ${key_path}"
                    else
                        echo -e "Domain: ${domain} - Certificate or Key missing."
                    fi
                done
            fi
            # The panel's configured certificate may live outside /root/cert
            # (e.g. certbot under /etc/letsencrypt) — show it too (#5070).
            local panel_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
            if [[ -n "${panel_cert}" && "${panel_cert}" != /root/cert/* ]]; then
                echo -e "面板 certificate (custom path): ${panel_cert}"
                if [[ -f "${panel_cert}" ]] && command -v openssl > /dev/null 2>&1; then
                    local panel_sans=$(openssl x509 -in "${panel_cert}" -noout -ext subjectAltName 2> /dev/null \
                        | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2 | tr '\n' ' ')
                    [[ -n "${panel_sans}" ]] && echo -e "\tCovers: ${panel_sans}"
                fi
            fi
            ssl_cert_issue_main
            ;;
        5)
            echo -e "${green}\t1.${plain} Use a certificate from /root/cert"
            echo -e "${green}\t2.${plain} Enter custom certificate file paths (e.g. certbot, /etc/letsencrypt/...)"
            read -rp "请选择: " pathChoice
            if [[ "$pathChoice" == "2" ]]; then
                read -rp "Certificate file path (fullchain): " webCertFile
                read -rp "Private key file path: " webKeyFile
                if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                    ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    echo "面板 certificate paths set:"
                    echo "  - 证书文件： $webCertFile"
                    echo "  - Private Key File: $webKeyFile"
                    restart
                else
                    echo "Certificate or private key file not found."
                fi
                ssl_cert_issue_main
                return
            fi
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "No certificates found."
            else
                echo "Available domains:"
                echo "$domains"
                read -rp "Please choose a domain to set the panel paths: " domain

                if echo "$domains" | grep -qw "$domain"; then
                    local webCertFile="/root/cert/${domain}/fullchain.pem"
                    local webKeyFile="/root/cert/${domain}/privkey.pem"

                    if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                        echo "面板 paths set for domain: $domain"
                        echo "  - 证书文件： $webCertFile"
                        echo "  - Private Key File: $webKeyFile"
                        # Register the acme.sh install-cert hook so auto-renewal copies the
                        # renewed cert to these paths and reloads the panel. Without it acme.sh
                        # renews but never updates /root/cert, silently serving a stale cert.
                        if command -v ~/.acme.sh/acme.sh &> /dev/null && ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
                            ~/.acme.sh/acme.sh --installcert --force -d "${domain}" \
                                --key-file "${webKeyFile}" \
                                --fullchain-file "${webCertFile}" \
                                --reloadcmd "x-ui restart" 2>&1 || true
                            echo "Registered acme.sh auto-renewal hook for ${domain}."
                        fi
                        restart
                    else
                        echo "Certificate or private key not found for domain: $domain."
                    fi
                else
                    echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        6)
            echo -e "${yellow}Let's Encrypt SSL Certificate for IP Address${plain}"
            echo -e "This will obtain a certificate for your server's IP using the shortlived profile."
            echo -e "${yellow}证书有效期约 6 天，通过 acme.sh 定时任务自动续期。${plain}"
            echo -e "${yellow}端口 80 must be open and accessible from the internet.${plain}"
            confirm "Do you want to proceed?" "y"
            if [[ $? == 0 ]]; then
                ssl_cert_issue_for_ip
            fi
            ssl_cert_issue_main
            ;;

        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            ssl_cert_issue_main
            ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "启动ing automatic SSL certificate generation for server IP..."
    LOGI "Using Let's Encrypt shortlived profile (~6 天 validity, auto-renews)"

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

    # Get server IP
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -n "$server_ip" ]]; then
        LOGI "Server IP detected: ${server_ip}"
        if ! confirm "是否为 ${server_ip} 正确的服务器公网 IPv4 地址？" "y"; then
            server_ip=""
        fi
    else
        LOGI "Could not auto-detect server IP from any provider."
    fi

    while [[ -z "$server_ip" ]]; do
        read -rp "请输入服务器的公网 IPv4 地址： " server_ip
        server_ip="${server_ip// /}"
        if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            LOGE "Invalid IPv4 address. Please try again."
            server_ip=""
        fi
    done

    LOGI "是否为suing certificate for server IP: ${server_ip}"

    # Ask for optional IPv6
    local ipv6_addr=""
    read -rp "Do you have an IPv6 address to include? (leave empty to skip): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Trim whitespace

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh not found, installing..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "acme.sh 安装失败"
            return 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum makecache -y > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac

    # Create certificate directory
    certPath="/root/cert/ip"
    mkdir -p "$certPath"

    # Build domain arguments
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "Including IPv6 address: ${ipv6_addr}"
    fi

    # 选择 port for HTTP-01 listener (default 80, allow override)
    local Web端口=""
    read -rp "端口 to use for ACME HTTP-01 listener (default 80): " Web端口
    Web端口="${Web端口:-80}"
    if ! [[ "${Web端口}" =~ ^[0-9]+$ ]] || ((Web端口 < 1 || Web端口 > 65535)); then
        LOGE "提供的端口无效，将回退到 80。"
        Web端口=80
    fi
    LOGI "使用端口 ${Web端口} to issue certificate for IP: ${server_ip}"
    if [[ "${Web端口}" -ne 80 ]]; then
        LOGI "Reminder: Let's Encrypt still reaches port 80; forward external port 80 to ${Web端口} for validation."
    fi

    while true; do
        if is_port_in_use "${Web端口}"; then
            LOGI "端口 ${Web端口} is currently in use."

            local alt_port=""
            read -rp "请输入 acme.sh 独立监听器的其他端口 (留空则取消): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "端口 ${Web端口} is busy; 无法继续 with issuance."
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "提供的端口无效."
                return 1
            fi
            Web端口="${alt_port}"
            continue
        else
            LOGI "端口 ${Web端口} 端口空闲，可用于独立验证."
            break
        fi
    done

    # Reload command - restarts panel after renewal
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"

    # issue the certificate for IP with shortlived profile
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --天 6 \
        --httpport ${Web端口} \
        --force

    if [ $? -ne 0 ]; then
        LOGE "证书签发失败： IP: ${server_ip}"
        LOGE "Make sure port ${Web端口} is open and the server is accessible from the internet"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    else
        LOGI "Certificate issued successfully for IP: ${server_ip}"
    fi

    # 安装面板 the certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still 已安装. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert --force -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "未找到证书文件 after installation"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    fi

    LOGI "证书文件安装成功"

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Prompt user to set panel paths after successful certificate installation
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"

    read -rp "是否将此证书设置为面板使用? (y/n): " set面板
    if [[ "$set面板" == "y" || "$set面板" == "Y" ]]; then
        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "面板 paths set for IP: $server_ip"
            LOGI "  - 证书文件： $webCertFile"
            LOGI "  - Private Key File: $webKeyFile"
            LOGI "  - Validity: ~6 天 (auto-renews via acme.sh cron)"
            echo -e "${green}访问地址： https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            LOGI "面板将重启以应用 SSL 证书..."
            restart
        else
            LOGE "Error: Certificate or private key file not found for IP: $server_ip."
            return 1
        fi
    else
        LOGI "Skipping panel path setting."
    fi

    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "acme.sh could not be found. we will install it"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "install acme failed, please check logs"
            exit 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum makecache -y > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac
    if [ $? -ne 0 ]; then
        LOGE "install socat failed, please check logs"
        exit 1
    else
        LOGI "install socat succeed..."
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "请输入您的域名： " domain
        domain="${domain// /}" # Trim whitespace

        if [[ -z "$domain" ]]; then
            LOGE "域名不能为空，请重新输入。"
            continue
        fi

        if ! is_domain "$domain"; then
            LOGE "Invalid domain format: ${domain}. Please enter a valid domain name."
            continue
        fi

        break
    done
    LOGD "您的域名为： ${domain}, checking it..."
    SSL_ISSUED_DOMAIN="${domain}"

    # detect existing certificate and reuse it only if its files are actually
    # present and non-empty. acme.sh stores ECC certs under ${domain}_ecc and RSA
    # certs under ${domain}; a failed issuance can leave a domain entry in --list
    # with no usable cert files, which must not be reused (it produces a 0-byte
    # fullchain.pem). Broken partial state is cleaned up so issuance can proceed.
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        local acmeCertDir=""
        if [[ -s ~/.acme.sh/${domain}_ecc/fullchain.cer && -s ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}_ecc
        elif [[ -s ~/.acme.sh/${domain}/fullchain.cer && -s ~/.acme.sh/${domain}/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}
        fi
        if [[ -n "${acmeCertDir}" ]]; then
            cert_exists=1
            local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
            LOGI "已找到现有证书： ${domain}, 将复用该证书."
            [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
        else
            LOGW "发现 acme.sh 不完整状态： ${domain} (无有效证书文件); cleaning it up and re-issuing."
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
    fi
    if [[ ${cert_exists} -eq 0 ]]; then
        LOGI "您的域名已准备好签发证书..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local Web端口=80
    read -rp "Please choose which port to use (default is 80): " Web端口
    if [[ -z ${Web端口} ]]; then
        Web端口=80
    elif [[ ! ${Web端口} =~ ^[1-9][0-9]*$ || ${Web端口} -gt 65535 ]]; then
        LOGE "您输入的 ${Web端口} 无效，将使用默认端口 80."
        Web端口=80
    fi
    LOGI "将使用端口： ${Web端口} 签发证书，请确保该端口开放。"

    if [[ ${cert_exists} -eq 0 ]]; then
        # issue the certificate
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${Web端口} --force
        if [ $? -ne 0 ]; then
            LOGE "证书签发失败，请检查日志。"
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
            exit 1
        else
            LOGE "证书签发成功，正在安装证书..."
        fi
    else
        LOGI "使用现有证书，正在安装证书..."
    fi

    reloadCmd="x-ui restart"

    LOGI "ACME 默认 --reloadcmd 为： ${yellow}x-ui restart"
    LOGI "每次签发和续期证书时都会执行此命令。"
    read -rp "是否修改 ACME 的 --reloadcmd? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Preset: systemctl reload nginx ; x-ui restart"
        echo -e "${green}\t2.${plain} Input your own command"
        echo -e "${green}\t0.${plain} 保持默认 reloadcmd"
        read -rp "请选择: " choice
        case "$choice" in
            1)
                LOGI "Reloadcmd 为： systemctl reload nginx ; x-ui restart"
                reloadCmd="systemctl reload nginx ; x-ui restart"
                ;;
            2)
                LOGD "建议将 x-ui restart 放在最后, so it won't raise an error if other services fails"
                read -rp "Please enter your reloadcmd (example: systemctl reload nginx ; x-ui restart): " reloadCmd
                LOGI "Your reloadcmd is: ${reloadCmd}"
                ;;
            *)
                LOGI "保持默认 reloadcmd"
                ;;
        esac
    fi

    # install the certificate
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "安装面板ing key to:" && echo "${installOutput}" | grep -q "安装面板ing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        LOGI "证书安装成功，正在启用自动续期..."
    else
        LOGE "证书安装失败，退出。"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
        exit 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "Auto renew failed, certificate details:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        LOGI "自动续期成功，证书详情："
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Prompt user to set panel paths after successful certificate installation
    read -rp "是否将此证书设置为面板使用? (y/n): " set面板
    if [[ "$set面板" == "y" || "$set面板" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "面板 paths set for domain: $domain"
            LOGI "  - 证书文件： $webCertFile"
            LOGI "  - Private Key File: $webKeyFile"
            echo -e "${green}访问地址： https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "Error: Certificate or private key file not found for domain: $domain."
        fi
    else
        LOGI "Skipping panel path setting."
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** Instructions for Use ******"
    LOGI "Follow the steps below to complete the process:"
    LOGI "1. A Cloudflare API Token (recommended, scoped to Zone:DNS:Edit) or the Global API Key + registered email."
    LOGI "2. The Domain Name."
    LOGI "3. Once the certificate is issued, you will be prompted to set the certificate for the panel (optional)."
    LOGI "4. The script also supports automatic renewal of the SSL certificate after installation."

    confirm "Do you confirm the information and wish to proceed? [y/n]" "y"

    if [ $? -eq 0 ]; then
        # Check for acme.sh first
        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            echo "acme.sh could not be found. We will install it."
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "安装面板 acme failed, please check logs."
                exit 1
            fi
        fi

        CF_Domain=""

        LOGD "Please set a domain name:"
        read -rp "Input your domain here: " CF_Domain
        LOGD "Your domain name is set to: ${CF_Domain}"

        # Cloudflare API credentials: an API Token (recommended, scoped to a
        # single zone) or the account-wide Global API Key. acme.sh reads
        # CF_Token for tokens, or CF_Key + CF_Email for the Global Key.
        CF_KeyType=""
        read -rp "Are you using a Cloudflare API Token or Global API Key? (t/g) [Default t]: " CF_KeyType
        CF_KeyType=${CF_KeyType:-t}

        if [[ "$CF_KeyType" == "g" || "$CF_KeyType" == "G" ]]; then
            CF_GlobalKey=""
            CF_AccountEmail=""
            LOGD "Please set the Global API Key:"
            read -rp "Input your key here: " CF_GlobalKey
            LOGD "Please set up the registered email:"
            read -rp "Input your email here: " CF_AccountEmail
            export CF_Key="${CF_GlobalKey}"
            export CF_Email="${CF_AccountEmail}"
        else
            CF_ApiToken=""
            LOGD "Please set the API Token:"
            read -rp "Input your token here: " CF_ApiToken
            export CF_Token="${CF_ApiToken}"
        fi

        # Set the default CA to Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            LOGE "Default CA, Let'sEncrypt fail, script exiting..."
            exit 1
        fi

        # 是否为sue the certificate using Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -ne 0 ]; then
            LOGE "Certificate issuance failed, script exiting..."
            exit 1
        else
            LOGI "Certificate issued successfully, 安装面板ing..."
        fi

        # 安装面板 the certificate
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            LOGE "Failed to create directory: ${certPath}"
            exit 1
        fi

        reloadCmd="x-ui restart"

        LOGI "ACME 默认 --reloadcmd 为： ${yellow}x-ui restart"
        LOGI "每次签发和续期证书时都会执行此命令。"
        read -rp "是否修改 ACME 的 --reloadcmd? (y/n): " setReloadcmd
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            echo -e "\n${green}\t1.${plain} Preset: systemctl reload nginx ; x-ui restart"
            echo -e "${green}\t2.${plain} Input your own command"
            echo -e "${green}\t0.${plain} 保持默认 reloadcmd"
            read -rp "请选择: " choice
            case "$choice" in
                1)
                    LOGI "Reloadcmd 为： systemctl reload nginx ; x-ui restart"
                    reloadCmd="systemctl reload nginx ; x-ui restart"
                    ;;
                2)
                    LOGD "建议将 x-ui restart 放在最后, so it won't raise an error if other services fails"
                    read -rp "Please enter your reloadcmd (example: systemctl reload nginx ; x-ui restart): " reloadCmd
                    LOGI "Your reloadcmd is: ${reloadCmd}"
                    ;;
                *)
                    LOGI "保持默认 reloadcmd"
                    ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert --force -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"

        if [ $? -ne 0 ]; then
            LOGE "Certificate installation failed, script exiting..."
            exit 1
        else
            LOGI "Certificate 已安装 successfully, Turning on automatic updates..."
        fi

        # Enable auto-update
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "Auto update setup failed, script exiting..."
            exit 1
        else
            LOGI "The certificate is 已安装 and auto-renewal is turned on. Specific information is as follows:"
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Prompt user to set panel paths after successful certificate installation
        read -rp "是否将此证书设置为面板使用? (y/n): " set面板
        if [[ "$set面板" == "y" || "$set面板" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "面板 paths set for domain: $CF_Domain"
                LOGI "  - 证书文件： $webCertFile"
                LOGI "  - Private Key File: $webKeyFile"
                echo -e "${green}访问地址： https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                restart
            else
                LOGE "Error: Certificate or private key file not found for domain: $CF_Domain."
            fi
        else
            LOGI "Skipping panel path setting."
        fi
    else
        show_menu
    fi
}

run_speedtest() {
    # Check if Speedtest is already 已安装
    if ! command -v speedtest &> /dev/null; then
        # If not 已安装, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "安装面板ing Speedtest using snap..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "Error: Package manager not found. You may need to install Speedtest manually."
                return 1
            else
                echo "安装面板ing Speedtest using $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} 安装面板 Fail2ban and configure IP Limit"
    echo -e "${green}\t2.${plain} Change Ban Duration"
    echo -e "${green}\t3.${plain} Unban Everyone"
    echo -e "${green}\t4.${plain} Ban Logs"
    echo -e "${green}\t5.${plain} Ban an IP Address"
    echo -e "${green}\t6.${plain} Unban an IP Address"
    echo -e "${green}\t7.${plain} Real-Time Logs"
    echo -e "${green}\t8.${plain} Service Status"
    echo -e "${green}\t9.${plain} Service 重启"
    echo -e "${green}\t10.${plain} 卸载面板 Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            confirm "Proceed with installation of Fail2ban & IP Limit?" "y"
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            read -rp "Please enter new Ban Duration in Minutes [default 30]: " NUM
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                echo -e "${red}${NUM} is not a number! Please, try again.${plain}"
            fi
            iplimit_main
            ;;
        3)
            confirm "Proceed with Unbanning everyone from IP Limit jail?" "y"
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                echo -e "${green}All users Unbanned successfully.${plain}"
                iplimit_main
            else
                echo -e "${yellow}已取消.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            read -rp "Enter the IP address you want to ban: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                echo -e "${green}IP Address ${ban_ip} has been banned successfully.${plain}"
            else
                echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        6)
            read -rp "Enter the IP address you want to unban: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                echo -e "${green}IP Address ${unban_ip} has been unbanned successfully.${plain}"
            else
                echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            iplimit_main
            ;;
    esac
}

setup_fail2ban_iplimit() {
    # Honor the same toggle the panel uses (isFail2BanEnabled): enabled when the
    # var is unset or exactly "true"; any other explicit value means the operator
    # opted out, so do nothing rather than install a fail2ban the panel ignores.
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}, skipping Fail2ban setup.${plain}\n"
        return 0
    fi

    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}Fail2ban is not 已安装. 安装面板ing now...!${plain}\n"

        # 安装面板 fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 2400 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                if [[ "${release}" != "fedora" ]] && ! dnf repolist enabled 2> /dev/null | grep -qiw epel; then
                    dnf install -y epel-release \
                        || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" \
                        || echo -e "${yellow}Could not enable the EPEL repository; fail2ban is only available from EPEL on this distro.${plain}"
                fi
                dnf makecache -y && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum makecache -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf makecache -y && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Sy --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}Unsupported operating system. Please check the script and install the necessary packages manually.${plain}\n"
                return 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban installation failed.${plain}\n"
            return 1
        fi

        echo -e "${green}Fail2ban 已安装 successfully!${plain}\n"
    else
        echo -e "${yellow}Fail2ban is already 已安装.${plain}\n"
    fi

    echo -e "${green}Configuring IP Limit...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP Limit 已安装 and configured successfully!${plain}\n"
    return 0
}

# install_iplimit is the interactive (menu) entry point: it runs the shared
# setup and then returns to the menu. The non-interactive installer path uses
# setup_fail2ban_iplimit directly via `x-ui setup-fail2ban`.
install_iplimit() {
    setup_fail2ban_iplimit
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} Only remove IP Limit configurations"
    echo -e "${green}\t2.${plain} 卸载面板 Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}Unsupported operating system. Please uninstall Fail2ban manually.${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban and IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Checking ban logs...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban service is not 运行中!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban service is not 运行中!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Recent system ban activities from fail2ban.log:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}No recent system ban activities found${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL ban log entries:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}No ban entries found${plain}"
        else
            echo -e "${yellow}Ban log file is empty${plain}"
        fi
    else
        echo -e "${red}Ban log file not found at: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Current jail status:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Unable to get jail status${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ and Ubuntu 22.04+ fail2ban's default backend should be changed to systemd
    if [[ ( "${release}" == "debian" && ${os_version} -ge 12 ) || ( "${release}" == "ubuntu" && ${os_version} -ge 2200 ) ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=1
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # 端口 to exempt from the ban so an over-limit proxy client can never lock
    # the administrator out of SSH or the panel. The ban still covers every other
    # TCP and UDP port (including all Xray inbounds, e.g. UDP-based Hysteria2), so
    # IP-limit keeps working for inbounds added later without regenerating these files.
    local ssh_ports
    ssh_ports=$(grep -oP '^[[:space:]]*端口[[:space:]]+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | paste -sd, -)
    [[ -z "${ssh_ports}" ]] && ssh_ports="22"
    local panel_port
    panel_port=$(${xui_folder}/x-ui setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    local exempt_ports="${ssh_ports}"
    [[ -n "${panel_port}" ]] && exempt_ports="${exempt_ports},${panel_port}"

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
chain = INPUT
exemptports = ${exempt_ports}
EOF

    echo -e "${green}Ip Limit jail files created with a bantime of ${bantime} minutes.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Removing conflicts of [3x-ipl] in jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}Could not auto-detect server IP from any provider.${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公网 IPv4 地址： " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}Invalid IPv4 address. Please try again.${plain}"
                server_ip=""
            fi
        done
    fi

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}面板 is secure with SSL.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}Warning: No Cert and Key found! The panel is not secure.${plain}"
        echo "Please obtain a certificate or set up SSH port forwarding."
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}Current SSH 端口 Forwarding Configuration:${plain}"
        echo -e "Standard SSH command:"
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nIf using SSH key:"
        echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nAfter connecting, access the panel at:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\n请选择:"
    echo -e "${green}1.${plain} Set listen IP"
    echo -e "${green}2.${plain} Clear listen IP"
    echo -e "${green}0.${plain} Back to Main Menu"
    read -rp "请选择: " num

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                echo -e "\nNo listenIP configured. 请选择:"
                echo -e "1. 使用默认 IP (127.0.0.1)"
                echo -e "2. Set a custom IP"
                read -rp "Select an option (1 or 2): " listen_choice

                config_listenIP="127.0.0.1"
                [[ "$listen_choice" == "2" ]] && read -rp "Enter custom IP to listen on: " config_listenIP

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                echo -e "${green}listen IP has been set to ${config_listenIP}.${plain}"
                echo -e "\n${green}SSH 端口 Forwarding Configuration:${plain}"
                echo -e "Standard SSH command:"
                echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nIf using SSH key:"
                echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nAfter connecting, access the panel at:"
                echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                restart
            else
                config_listenIP="${existing_listenIP}"
                echo -e "${green}Current listen IP is already set to ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            echo -e "${green}Listen IP has been cleared.${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

# PostgreSQL service management (for panels configured with XUI_DB_TYPE=postgres).

postgresql_已安装() {
    command -v pg_lsclusters > /dev/null 2>&1 || command -v psql > /dev/null 2>&1 || command -v postgres > /dev/null 2>&1
}

# Prints "VER CLUSTER" of the first configured cluster on Debian-style installs (e.g. "16 main").
pg_cluster_info() {
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters 2> /dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2; exit}'
    fi
}

# Resolves the systemd unit used to manage the PostgreSQL server.
pg_systemd_unit() {
    local info ver cluster
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        echo "postgresql@${ver}-${cluster}"
    else
        echo "postgresql"
    fi
}

postgresql_status() {
    if ! postgresql_已安装; then
        LOGE "PostgreSQL does not appear to be 已安装 on this system."
        return 1
    fi
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters
    else
        systemctl status "$(pg_systemd_unit)" --no-pager
    fi
    echo ""
    if command -v ss > /dev/null 2>&1; then
        local listening
        listening=$(ss -ltnp 2> /dev/null | grep ':5432')
        if [[ -n "$listening" ]]; then
            echo -e "${green}PostgreSQL is listening on port 5432:${plain}"
            echo "$listening"
        else
            echo -e "${red}Nothing is listening on port 5432 - the database is not 运行中.${plain}"
        fi
    fi
}

postgresql_start() {
    pg_require_已安装 || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql start
    else
        systemctl start "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_stop() {
    pg_require_已安装 || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop
    else
        systemctl stop "$(pg_systemd_unit)"
    fi
    LOGI "PostgreSQL stop signal sent."
}

postgresql_restart() {
    pg_require_已安装 || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql restart
    else
        systemctl restart "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_enable() {
    pg_require_已安装 || return 1
    if [[ $release == "alpine" ]]; then
        rc-update add postgresql default
    else
        systemctl enable "$(pg_systemd_unit)"
    fi
    if [[ $? == 0 ]]; then
        LOGI "PostgreSQL set to start automatically on boot."
    else
        LOGE "Failed to enable PostgreSQL autostart."
    fi
}

postgresql_log() {
    pg_require_已安装 || return 1
    local info ver cluster logfile
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        logfile="/var/log/postgresql/postgresql-${ver}-${cluster}.log"
    fi
    if [[ -n "$logfile" && -f "$logfile" ]]; then
        tail -n 40 "$logfile"
    elif command -v journalctl > /dev/null 2>&1; then
        journalctl -u "$(pg_systemd_unit)" -n 40 --no-pager
    else
        LOGE "No PostgreSQL log found."
    fi
}

pg_require_已安装() {
    if ! postgresql_已安装; then
        LOGE "PostgreSQL is not 已安装. Use option 1 (安装面板 PostgreSQL) in this menu first."
        return 1
    fi
}

# Completely removes the PostgreSQL server and ALL of its databases from the system.
# Gated behind an explicit confirmation because this is system-wide and irreversible:
# any other application sharing this PostgreSQL instance loses its data too. Mirrors the
# package names used by pg_install_local() so the right packages are removed per distro.
purge_postgresql() {
    echo ""
    echo -e "${yellow}This panel was using PostgreSQL.${plain}"
    echo -e "${red}WARNING:${plain} purging removes the PostgreSQL server and ${red}ALL${plain} of its databases on"
    echo -e "this machine, including any used by other applications. This cannot be undone."
    confirm "Also purge PostgreSQL and delete all of its data?" "n"
    if [[ $? != 0 ]]; then
        LOGI "Left PostgreSQL 已安装; its data was not removed."
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop 2> /dev/null
        rc-update del postgresql 2> /dev/null
    else
        systemctl stop "$(pg_systemd_unit)" 2> /dev/null
        systemctl disable "$(pg_systemd_unit)" 2> /dev/null
    fi

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get -y --purge remove 'postgresql*'
            apt-get -y autoremove --purge
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf remove -y postgresql postgresql-server postgresql-contrib
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum remove -y postgresql postgresql-server postgresql-contrib
            else
                dnf remove -y postgresql postgresql-server postgresql-contrib
            fi
            ;;
        arch | manjaro | parch)
            pacman -Rns --noconfirm postgresql
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q remove -y postgresql postgresql-server postgresql-contrib
            ;;
        alpine)
            apk del postgresql postgresql-contrib postgresql-client
            ;;
        *)
            LOGE "Unsupported distro for automatic PostgreSQL purge: ${release}. Remove it manually."
            return 1
            ;;
    esac

    rm -rf /var/lib/postgresql /var/lib/pgsql /var/lib/postgres /etc/postgresql
    LOGI "PostgreSQL has been purged."
}

# RHEL-family initdb writes pg_hba.conf host rules with ident auth, which
# compares the OS username against the Postgres role and always rejects the
# randomly generated panel role over TCP (#5806). Prepend password-auth rules
# scoped to the panel database; first match wins, and md5 also accepts
# scram-sha-256-stored verifiers, so this works on every supported distro.
# Mirrors pg_ensure_hba_password_auth() from install.sh.
pg_ensure_hba_password_auth() {
    local pg_db="$1"
    local hba_file
    hba_file=$(sudo -u postgres psql -tAc 'SHOW hba_file' 2> /dev/null | tr -d '[:space:]')
    [[ -n "${hba_file}" && -f "${hba_file}" ]] || return 0
    grep -Eq "^host[[:space:]]+${pg_db}[[:space:]]" "${hba_file}" && return 0
    local tmp
    tmp=$(mktemp) || return 1
    {
        echo "# 由 3x-ui 添加：允许面板数据库的密码登录。"
        echo "host    ${pg_db}    all    127.0.0.1/32    md5"
        echo "host    ${pg_db}    all    ::1/128         md5"
        cat "${hba_file}"
    } > "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    cat "${tmp}" > "${hba_file}" || {
        rm -f "${tmp}"
        return 1
    }
    rm -f "${tmp}"
    sudo -u postgres psql -tAc 'SELECT pg_reload_conf()' > /dev/null 2>&1 || true
}

# 安装面板s a local PostgreSQL server and creates a dedicated xui user/database.
# Progress goes to stderr; on success the connection DSN is printed to stdout so
# callers can capture it. Mirrors install_postgres_local() from install.sh, so the
# panel can be set up without re-运行中 the remote install script.
pg_install_local() {
    local pg_user pg_pass pg_db pg_host pg_port
    pg_pass=$(gen_random_string 24)
    pg_db="xui"
    pg_host="127.0.0.1"
    pg_port="5432"

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}不支持自动安装 PostgreSQL 的发行版: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    local existing_owner=""
    existing_owner=$(sudo -u postgres psql -tAc \
        "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | tr -d '[:space:]')
    if [[ -n "${existing_owner}" && "${existing_owner}" != "postgres" ]]; then
        pg_user="${existing_owner}"
    else
        pg_user=$(gen_random_string 8)
    fi

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    pg_ensure_hba_password_auth "${pg_db}" \
        || echo -e "${yellow}警告：无法更新 pg_hba.conf; PostgreSQL may reject the panel's TCP login (ident auth).${plain}" >&2

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

# 安装面板s the PostgreSQL client tools (pg_dump/pg_restore) used by in-panel backup.
pg_ensure_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}安装面板ing PostgreSQL client tools (pg_dump/pg_restore)...${plain}" >&2
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql-client >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql >&2 || return 1
            else
                dnf install -y -q postgresql >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql >&2 || return 1
            ;;
        alpine)
            apk add --no-cache postgresql-client >&2 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1
}

# Prints the major version of the 已安装 pg_restore, or nothing when absent.
pg_client_major() {
    command -v pg_restore > /dev/null 2>&1 || return 1
    pg_restore --version 2> /dev/null | grep -oE '[0-9]+' | head -n 1
}

# 安装面板s or upgrades the PostgreSQL client tools (pg_dump/pg_restore) so their
# major version is at least $1 (e.g. 17); with no argument any 已安装 version
# is accepted. Falls back to the official PostgreSQL package repository when the
# distribution one is too old. Restoring a panel backup made by a newer pg_dump
# needs this:   x-ui pgclient <major>
pg_upgrade_client() {
    local want="$1" have
    if [[ -n "$want" && ! "$want" =~ ^[0-9]+$ ]]; then
        LOGE "Invalid PostgreSQL major version '${want}' (expected a number like 17)."
        return 1
    fi
    have=$(pg_client_major)
    if [[ -n "$have" ]]; then
        if [[ -z "$want" || "$have" -ge "$want" ]]; then
            LOGI "PostgreSQL client tools are already 已安装 (version ${have})."
            return 0
        fi
        LOGI "安装面板ed PostgreSQL client tools are version ${have}; version ${want} or newer is required."
    fi
    if [[ "${运行中_in_docker}" == "true" ]]; then
        LOGI "Note: packages 已安装 inside the container are lost when the container is recreated."
    fi
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 || return 1
            if [[ -z "$want" ]]; then
                apt-get install -y -q postgresql-client >&2 || return 1
            elif ! apt-get install -y -q "postgresql-client-${want}" >&2; then
                LOGI "postgresql-client-${want} is not in the distribution repositories; adding the official PostgreSQL apt repository..."
                apt-get install -y -q postgresql-common ca-certificates >&2 || return 1
                /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >&2 || return 1
                apt-get install -y -q "postgresql-client-${want}" >&2 || return 1
            fi
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol | centos)
            local pkg_mgr="dnf"
            command -v dnf > /dev/null 2>&1 || pkg_mgr="yum"
            if [[ -z "$want" ]]; then
                "$pkg_mgr" install -y -q postgresql >&2 || return 1
            elif ! "$pkg_mgr" install -y -q "postgresql${want}" >&2; then
                local elver
                elver=$(rpm -E %rhel 2> /dev/null)
                if [[ ! "$elver" =~ ^[0-9]+$ ]]; then
                    LOGE "Could not determine the Enterprise Linux release; install the PostgreSQL ${want} client tools manually."
                    return 1
                fi
                LOGI "postgresql${want} is not in the enabled repositories; adding the official PostgreSQL yum repository..."
                "$pkg_mgr" install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${elver}-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" >&2 || return 1
                if [[ "$pkg_mgr" == "dnf" ]]; then
                    dnf -qy module disable postgresql >&2 || true
                fi
                "$pkg_mgr" install -y -q "postgresql${want}" >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            if [[ -z "$want" ]] || ! zypper -q install -y "postgresql${want}" >&2; then
                zypper -q install -y postgresql >&2 || return 1
            fi
            ;;
        alpine)
            if [[ -z "$want" ]] || ! apk add --no-cache "postgresql${want}-client" >&2; then
                apk add --no-cache postgresql-client >&2 || return 1
            fi
            ;;
        *)
            LOGE "Unsupported OS '${release}'; install the PostgreSQL client tools manually."
            return 1
            ;;
    esac
    hash -r 2> /dev/null
    have=$(pg_client_major)
    if [[ -n "$want" && ( -z "$have" || "$have" -lt "$want" ) && -x "/usr/pgsql-${want}/bin/pg_restore" ]]; then
        ln -sf "/usr/pgsql-${want}/bin/pg_dump" /usr/local/bin/pg_dump
        ln -sf "/usr/pgsql-${want}/bin/pg_restore" /usr/local/bin/pg_restore
        hash -r 2> /dev/null
        have=$(pg_client_major)
    fi
    if [[ -z "$have" ]]; then
        LOGE "pg_dump/pg_restore are still unavailable after installation."
        return 1
    fi
    if [[ -n "$want" && "$have" -lt "$want" ]]; then
        LOGE "PostgreSQL client tools are version ${have} after installation but ${want} or newer is required; install them manually."
        return 1
    fi
    LOGI "PostgreSQL client tools are ready (version ${have})."
    return 0
}

# Writes XUI_DB_TYPE/XUI_DB_DSN into the service env file, preserving other entries.
pg_write_env() {
    local dsn="$1" envfile
    envfile="$(xui_env_file_path)"
    install -d -m 755 "$(dirname "$envfile")"
    touch "$envfile"
    sed -i '/^XUI_DB_TYPE=/d; /^XUI_DB_DSN=/d' "$envfile"
    {
        echo "XUI_DB_TYPE=postgres"
        echo "XUI_DB_DSN=${dsn}"
    } >> "$envfile"
    chmod 600 "$envfile"
}

pg_install_server_action() {
    if postgresql_已安装; then
        LOGI "PostgreSQL already appears to be 已安装 on this system."
        confirm "Run setup anyway (ensures the xui database/user exist)?" "n" || return 0
    fi
    LOGI "安装面板ing PostgreSQL server and creating a dedicated user/database..."
    local dsn
    dsn=$(pg_install_local)
    if [[ $? -ne 0 || -z "$dsn" ]]; then
        LOGE "PostgreSQL installation failed."
        return 1
    fi
    PG_LAST_DSN="$dsn"
    pg_ensure_client || LOGE "Could not install pg_dump/pg_restore (panel DB backup may be unavailable)."
    echo ""
    LOGI "PostgreSQL is 已安装 and ready."
    echo -e "${green}Connection DSN:${plain} ${dsn}"
    echo -e "${yellow}Use option 2 to migrate your SQLite data and switch the panel to PostgreSQL.${plain}"
}

# Copies the current SQLite data into PostgreSQL, then switches the panel over.
migrate_to_postgres() {
    if [[ ! -x "${xui_folder}/x-ui" ]]; then
        LOGE "x-ui is not 已安装."
        return 1
    fi
    echo ""
    echo -e "${yellow}This copies your current SQLite data into a PostgreSQL database,${plain}"
    echo -e "${yellow}then switches the panel to PostgreSQL and restarts it.${plain}"
    echo -e "${red}Any existing panel tables in the destination will be cleared and overwritten.${plain}"
    confirm "Continue?" "n" || return 0

    local dsn="" pg_mode
    if [[ -n "$PG_LAST_DSN" ]]; then
        echo -e "A PostgreSQL database was created in this session:"
        echo -e "  ${green}${PG_LAST_DSN}${plain}"
        confirm "Migrate into this database?" "y" && dsn="$PG_LAST_DSN"
    fi

    if [[ -z "$dsn" ]]; then
        echo ""
        echo -e "${green}\t1.${plain} 本地安装 PostgreSQL 并创建专用用户/数据库（推荐）"
        echo -e "${green}\t2.${plain} 使用已有的 PostgreSQL 服务器（输入 DSN）"
        read -rp "选择 [1]: " pg_mode
        pg_mode="${pg_mode:-1}"
        if [[ "$pg_mode" == "2" ]]; then
            while [[ -z "$dsn" ]]; do
                read -rp "Enter PostgreSQL DSN (postgres://user:pass@host:port/dbname?sslmode=disable): " dsn
                dsn="${dsn// /}"
            done
        else
            LOGI "正在本地安装 PostgreSQL (this may take a moment)..."
            dsn=$(pg_install_local)
            if [[ $? -ne 0 || -z "$dsn" ]]; then
                LOGE "PostgreSQL installation failed. Aborting migration."
                return 1
            fi
            PG_LAST_DSN="$dsn"
        fi
    fi

    pg_ensure_client || LOGE "Could not install pg_dump/pg_restore (in-panel DB backup/restore may be unavailable)."

    LOGI "停止ping panel to take a consistent snapshot..."
    stop 0 > /dev/null 2>&1

    echo ""
    LOGI "Migrating data into PostgreSQL..."
    if ! ${xui_folder}/x-ui migrate-db --dsn "$dsn"; then
        LOGE "Migration failed. The panel was NOT switched to PostgreSQL."
        start 0 > /dev/null 2>&1
        return 1
    fi

    pg_write_env "$dsn"
    LOGI "Wrote database settings to $(xui_env_file_path) (XUI_DB_TYPE=postgres)."
    LOGI "重启ing panel on PostgreSQL..."
    restart 0
    sleep 1
    if check_status; then
        LOGI "Migration complete. The panel is now 运行中 on PostgreSQL."
    else
        LOGE "面板 did not come up. Check logs (main menu option 17). Your SQLite data is left intact."
    fi
}

postgresql_menu() {
    echo -e "${green}\t1.${plain} ${green}安装面板${plain} PostgreSQL (server + client + xui db)"
    echo -e "${green}\t2.${plain} Migrate SQLite ${green}->${plain} PostgreSQL"
    echo -e "${green}\t3.${plain} 状态（集群和端口 5432）"
    echo -e "${green}\t4.${plain} ${green}启动${plain} PostgreSQL"
    echo -e "${green}\t5.${plain} ${red}停止${plain} PostgreSQL"
    echo -e "${green}\t6.${plain} 重启 PostgreSQL"
    echo -e "${green}\t7.${plain} ${green}Enable${plain} Autostart on boot"
    echo -e "${green}\t8.${plain} View PostgreSQL Log"
    echo -e "${green}\t9.${plain} Convert SQLite ${green}.db <-> .dump${plain}"
    echo -e "${green}\t10.${plain} 安装面板/Upgrade client tools (pg_dump/pg_restore)"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            pg_install_server_action
            postgresql_menu
            ;;
        2)
            migrate_to_postgres
            postgresql_menu
            ;;
        3)
            postgresql_status
            postgresql_menu
            ;;
        4)
            postgresql_start
            postgresql_menu
            ;;
        5)
            postgresql_stop
            postgresql_menu
            ;;
        6)
            postgresql_restart
            postgresql_menu
            ;;
        7)
            postgresql_enable
            postgresql_menu
            ;;
        8)
            postgresql_log
            postgresql_menu
            ;;
        9)
            migrate_db_prompt
            postgresql_menu
            ;;
        10)
            read -rp "Required PostgreSQL major version (empty = any): " pg_client_ver
            pg_upgrade_client "$pg_client_ver"
            postgresql_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            postgresql_menu
            ;;
    esac
}

# Convert between the panel's SQLite database and a portable .dump (SQL text)
# file using the bundled x-ui binary. With no arguments it dumps the 已安装
# panel database; an optional second argument overrides the output path.
#   x-ui migrateDB [file.db|file.dump] [output]
migrate_db() {
    local input="$1" output="$2"
    local default_db="/etc/x-ui/x-ui.db"
    local bin="${xui_folder}/x-ui"

    [[ -z "$input" ]] && input="$default_db"

    if [[ ! -x "$bin" ]]; then
        LOGE "x-ui binary not found at ${bin}. 是否为 the panel 已安装?"
        return 1
    fi

    if ! "$bin" migrate-db -h 2>&1 | grep -q -- '-dump'; then
        LOGE "This x-ui build does not support .db <-> .dump conversion yet."
        LOGE "更新面板 the panel first (x-ui update) to a version with 'migrate-db --dump/--restore'."
        return 1
    fi

    if [[ ! -f "$input" ]]; then
        LOGE "Input file not found: ${input}"
        echo -e "Usage: ${green}x-ui migrateDB [file.db|file.dump] [output]${plain}"
        return 1
    fi

    local mode
    case "$input" in
        *.db | *.sqlite | *.sqlite3)
            mode="dump"
            ;;
        *.dump | *.sql)
            mode="restore"
            ;;
        *)
            if head -c 16 "$input" | grep -q "SQLite format 3"; then
                mode="dump"
            else
                mode="restore"
            fi
            ;;
    esac

    if [[ "$mode" == "dump" ]]; then
        [[ -z "$output" ]] && output="${input%.*}.dump"
        if [[ -f "$output" ]]; then
            confirm "Output ${output} already exists and will be overwritten. Continue?" "n" || return 0
        fi
        LOGI "Dumping SQLite database to SQL text:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --src "$input" --dump "$output"; then
            LOGI "Done. Wrote ${output}."
        else
            LOGE "Dump failed."
            return 1
        fi
    else
        [[ -z "$output" ]] && output="${input%.*}.db"
        if [[ "$output" == "$default_db" ]] && check_status > /dev/null 2>&1; then
            LOGE "Refusing to restore into the live database (${default_db}) while x-ui is 运行中."
            LOGE "停止 the panel first (x-ui stop) or choose a different output path."
            return 1
        fi
        if [[ -f "$output" ]]; then
            confirm "Output ${output} already exists and will be overwritten. Continue?" "n" || return 0
            rm -f "$output"
        fi
        LOGI "Rebuilding SQLite database from SQL text:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --restore "$input" --out "$output"; then
            LOGI "Done. Created ${output}."
        else
            LOGE "Restore failed."
            rm -f "$output"
            return 1
        fi
    fi
}

# Interactive wrapper around migrate_db for the menu: prompts for the paths and
# lets migrate_db auto-detect the direction.
migrate_db_prompt() {
    local default_db="/etc/x-ui/x-ui.db"
    local input output
    echo -e "Convert between a SQLite ${green}.db${plain} and a portable ${green}.dump${plain} (direction auto-detected)."
    read -rp "Input file [${default_db}]: " input
    input="${input:-$default_db}"
    read -rp "Output file (leave empty to auto-name next to input): " output
    migrate_db "$input" "$output"
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}                       │
│                                                                │
│  ${blue}x-ui${plain}                       - Admin Management Script          │
│  ${blue}x-ui start${plain}                 - 启动                            │
│  ${blue}x-ui stop${plain}                  - 停止                             │
│  ${blue}x-ui restart${plain}               - 重启                          │
|  ${blue}x-ui restart-xray${plain}          - 重启 Xray                     │
│  ${blue}x-ui status${plain}                - Current Status                   │
│  ${blue}x-ui settings${plain}              - Current Settings                 │
│  ${blue}x-ui enable${plain}                - 启用开机自启 on OS 启动up   │
│  ${blue}x-ui disable${plain}               - 禁用开机自启 on OS 启动up  │
│  ${blue}x-ui log${plain}                   - Check logs                       │
│  ${blue}x-ui banlog${plain}                - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}                - 更新面板                           │
│  ${blue}x-ui update-dev${plain}            - 更新面板 to Dev channel (latest)   │
│  ${blue}x-ui update-all-geofiles${plain}   - 更新面板 all geo files             │
│  ${blue}x-ui migrateDB [file]${plain}      - Convert .db <-> .dump (SQLite)   │
│  ${blue}x-ui pgclient [ver]${plain}        - Upgrade pg_dump/pg_restore tools │
│  ${blue}x-ui legacy${plain}                - Legacy version                   │
│  ${blue}x-ui install${plain}               - 安装面板                          │
│  ${blue}x-ui uninstall${plain}             - 卸载面板                        │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│  ${green}3X-UI 面板管理脚本${plain}                │
│  ${green}0.${plain} 退出脚本                               │
│────────────────────────────────────────────────│
│  ${green}1.${plain} 安装面板                                   │
│  ${green}2.${plain} 更新面板                                    │
│  ${green}3.${plain} 更新面板 to Dev Channel (latest commit)     │
│  ${green}4.${plain} 更新面板 Menu                               │
│  ${green}5.${plain} 旧版本安装                            │
│  ${green}6.${plain} 卸载面板                                 │
│────────────────────────────────────────────────│
│  ${green}7.${plain} 重置用户名与密码                 │
│  ${green}8.${plain} 重置 Web 基础路径                       │
│  ${green}9.${plain} 重置设置                            │
│  ${green}10.${plain} 修改端口                              │
│  ${green}11.${plain} 查看当前设置                    │
│────────────────────────────────────────────────│
│  ${green}12.${plain} 启动                                    │
│  ${green}13.${plain} 停止                                     │
│  ${green}14.${plain} 重启                                  │
|  ${green}15.${plain} 重启 Xray                             │
│  ${green}16.${plain} 查看状态                             │
│  ${green}17.${plain} 日志管理                          │
│────────────────────────────────────────────────│
│  ${green}18.${plain} 启用开机自启                         │
│  ${green}19.${plain} 禁用开机自启                        │
│────────────────────────────────────────────────│
│  ${green}20.${plain} SSL 证书管理               │
│  ${green}21.${plain} Cloudflare SSL 证书               │
│  ${green}22.${plain} IP 限制管理                      │
│  ${green}23.${plain} 防火墙管理                      │
│  ${green}24.${plain} SSH 端口转发管理           │
│  ${green}25.${plain} PostgreSQL 管理                    │
│────────────────────────────────────────────────│
│  ${green}26.${plain} 启用 BBR                               │
│  ${green}27.${plain} 更新面板 Geo Files                         │
│  ${green}28.${plain} Speedtest 网速测试                       │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "请输入您的选择 [0-28]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_dev
            ;;
        4)
            check_install && update_menu
            ;;
        5)
            check_install && legacy_version
            ;;
        6)
            check_install && uninstall
            ;;
        7)
            check_install && reset_user
            ;;
        8)
            check_install && reset_webbasepath
            ;;
        9)
            check_install && reset_config
            ;;
        10)
            check_install && set_port
            ;;
        11)
            check_install && check_config
            ;;
        12)
            check_install && start
            ;;
        13)
            check_install && stop
            ;;
        14)
            check_install && restart
            ;;
        15)
            check_install && restart_xray
            ;;
        16)
            check_install && status
            ;;
        17)
            check_install && show_log
            ;;
        18)
            check_install && enable
            ;;
        19)
            check_install && disable
            ;;
        20)
            ssl_cert_issue_main
            ;;
        21)
            ssl_cert_issue_CF
            ;;
        22)
            iplimit_main
            ;;
        23)
            firewall_menu
            ;;
        24)
            SSH_port_forwarding
            ;;
        25)
            postgresql_menu
            ;;
        26)
            bbr_menu
            ;;
        27)
            update_geo
            ;;
        28)
            run_speedtest
            ;;
        *)
            LOGE "Please enter the correct number [0-28]"
            ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "setup-fail2ban")
            setup_fail2ban_iplimit
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "update-dev")
            check_install 0 && update_dev 0
            ;;
        "legacy")
            check_install 0 && legacy_version 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            check_install 0 && uninstall 0
            ;;
        "update-all-geofiles")
            geo_updated=0
            if check_install 0 && update_all_geofiles 0; then
                [[ $geo_updated -eq 0 ]] || restart 0
            fi
            ;;
        "migrateDB")
            migrate_db "$2" "$3"
            ;;
        "pgclient")
            pg_upgrade_client "$2"
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
