#!/bin/bash
# ============================================================
# 3X-UI 一键搭建: VLESS+XHTTP
# 协议: VLESS | 传输: XHTTP | 安全: TLS | 端口: 8443
# 特点: 新一代 HTTP 多路复用传输，低延迟高并发
# 注意: 需要 Xray 内核 v1.8.0+ 支持 XHTTP
# ============================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

LOGI() { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
LOGW() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }
LOGE() { echo -e "${RED}[ERROR] $*${PLAIN}"; }

# 检查 root
[[ $EUID -ne 0 ]] && LOGE "请使用 root 权限运行此脚本" && exit 1

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7|armv7l) ARCH="armv7" ;;
    *) LOGE "不支持的架构: $ARCH" && exit 1 ;;
esac
LOGI "系统架构: $ARCH"

# 获取公网 IP
get_ip() {
    local URL_LIST=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local ip=""
    for url in "${URL_LIST[@]}"; do
        ip=$(curl -s --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]"')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

SERVER_IP=$(get_ip)
if [[ -z "$SERVER_IP" ]]; then
    read -rp "请输入服务器公网 IPv4 地址: " SERVER_IP
fi
LOGI "服务器 IP: $SERVER_IP"

# 检查 3x-ui 是否已安装
check_installed() {
    if [[ -f /usr/local/x-ui/x-ui ]] || [[ -f /usr/bin/x-ui ]]; then
        return 0
    fi
    return 1
}

# 安装 3x-ui
install_panel() {
    LOGI "正在安装 3X-UI 面板..."
    export XUI_NONINTERACTIVE=1
    bash <(curl -Ls https://raw.githubusercontent.com/ifwqu/3x-ui/main/install.sh)
    if [[ $? -ne 0 ]]; then
        LOGE "3X-UI 安装失败"
        exit 1
    fi
    LOGI "3X-UI 面板安装完成"
}

# 检查 Xray 内核版本（XHTTP 需要 v1.8.0+）
check_xray_version() {
    local xray_bin=""
    for p in /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/xray; do
        if [[ -f "$p" ]]; then
            xray_bin="$p"
            break
        fi
    done
    
    if [[ -z "$xray_bin" ]]; then
        LOGW "未找到 Xray 二进制文件，将在安装后检查"
        return 0
    fi
    
    local version=$("$xray_bin" version 2>/dev/null | grep -oP 'Xray\s+\K[\d]+\.[\d]+\.[\d]+' | head -1)
    if [[ -z "$version" ]]; then
        version=$("$xray_bin" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
    fi
    if [[ -z "$version" ]]; then
        LOGW "无法获取 Xray 版本，将尝试更新至最新版"
        return 0
    fi
    
    local major=$(echo "$version" | cut -d. -f1)
    local minor=$(echo "$version" | cut -d. -f2)
    
    if [[ "$major" -lt 1 || ("$major" -eq 1 && "$minor" -lt 8) ]]; then
        LOGW "当前 Xray 版本 ($version) 不支持 XHTTP（需要 v1.8.0+）"
        read -rp "是否自动更新 Xray 至最新版？[Y/n]: " choice
        choice="${choice:-Y}"
        case "$choice" in
            Y|y|yes|Yes) 
                update_xray
                ;;
            *)
                LOGE "XHTTP 需要 Xray v1.8.0+，无法继续"
                exit 1
                ;;
        esac
    else
        LOGI "Xray 版本 ($version) 支持 XHTTP ✓"
    fi
}

# 更新 Xray 内核
update_xray() {
    LOGI "正在更新 Xray 至最新版本..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [[ $? -eq 0 ]]; then
        LOGI "Xray 更新成功"
    else
        LOGE "Xray 更新失败"
        exit 1
    fi
}

# 获取面板凭据
get_credentials() {
    if [[ -f /etc/x-ui/install-result.env ]]; then
        source /etc/x-ui/install-result.env
        PANEL_USER="${XUI_USERNAME}"
        PANEL_PASS="${XUI_PASSWORD}"
        PANEL_PORT="${XUI_PANEL_PORT}"
        PANEL_PATH="${XUI_WEB_BASE_PATH}"
        API_TOKEN="${XUI_API_TOKEN}"
    fi
    if [[ -z "$PANEL_USER" ]]; then
        local info=$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null)
        PANEL_USER=$(echo "$info" | grep -Eo 'username: .+' | awk '{print $2}')
        PANEL_PASS=$(echo "$info" | grep -Eo 'password: .+' | awk '{print $2}')
        PANEL_PORT=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
        PANEL_PATH=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    fi
    if [[ -z "$API_TOKEN" ]]; then
        API_TOKEN=$(/usr/local/x-ui/x-ui setting -getApiToken true 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}')
    fi
    if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
        LOGE "无法获取面板凭据"
        exit 1
    fi
}

login_panel() {
    local login_url="http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}login"
    local resp=$(curl -s -c /tmp/xui_cookie.txt \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}" \
        "${login_url}")
    if echo "$resp" | grep -q '"success":\s*true'; then
        LOGI "面板登录成功"
        return 0
    fi
    if [[ -n "$API_TOKEN" ]]; then
        LOGI "使用 API Token 认证..."
        return 0
    fi
    LOGE "面板登录失败"
    exit 1
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
    (date +%s%N | md5sum | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
}

gen_random() {
    local length="$1"
    openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# 申请 SSL 证书
setup_ssl() {
    local domain="$1"
    LOGI "正在为域名 ${domain} 申请 SSL 证书..."
    
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        curl -s https://get.acme.sh | sh
    fi
    
    systemctl stop x-ui 2>/dev/null || true
    sleep 1
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force 2>/dev/null
    ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 --force
    
    if [[ $? -ne 0 ]]; then
        LOGW "SSL 证书签发失败，请确保域名 ${domain} 已指向本机 IP ${SERVER_IP} 且端口 80 开放"
        systemctl start x-ui 2>/dev/null || true
        return 1
    fi
    
    local cert_path="/root/cert/${domain}"
    mkdir -p "$cert_path"
    
    ~/.acme.sh/acme.sh --installcert -d "${domain}" \
        --key-file "${cert_path}/privkey.pem" \
        --fullchain-file "${cert_path}/fullchain.pem" \
        --reloadcmd "systemctl restart x-ui" 2>/dev/null
    
    chmod 600 "${cert_path}/privkey.pem"
    chmod 644 "${cert_path}/fullchain.pem"
    
    /usr/local/x-ui/x-ui cert -webCert "${cert_path}/fullchain.pem" -webCertKey "${cert_path}/privkey.pem" 2>/dev/null || true
    
    systemctl start x-ui 2>/dev/null || true
    sleep 2
    LOGI "SSL 证书配置完成！"
    return 0
}

# 添加 VLESS+XHTTP 入站
add_inbound() {
    local uuid=$(gen_uuid)
    local xhttp_path="/$(gen_random 8)"
    local remark="VLESS-XHTTP-${SERVER_IP}"
    local port="8443"
    
    local domain=""
    read -rp "请输入您的域名 (需已指向本机): " domain
    while [[ -z "$domain" ]]; do
        LOGE "域名不能为空"
        read -rp "请输入您的域名: " domain
    done
    
    read -rp "请输入入站端口 [默认 8443]: " input_port
    port="${input_port:-$port}"
    
    read -rp "请输入 XHTTP 路径 [默认 ${xhttp_path}]: " input_path
    xhttp_path="${input_path:-$xhttp_path}"
    [[ "$xhttp_path" != /* ]] && xhttp_path="/${xhttp_path}"
    
    read -rp "请输入备注 [默认 ${remark}]: " input_remark
    remark="${input_remark:-$remark}"
    
    # 申请 SSL 证书
    if ! setup_ssl "$domain"; then
        LOGE "SSL 证书配置失败，无法继续"
        exit 1
    fi
    
    # 构建入站 JSON
    local settings='{
        "clients": [{
            "id": "'"${uuid}"'",
            "flow": "",
            "email": "xhttp@'"${SERVER_IP}"'",
            "enable": true
        }],
        "decryption": "none"
    }'
    
    local stream_settings='{
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
            "path": "'"${xhttp_path}"'",
            "mode": "auto",
            "extra": []
        },
        "tlsSettings": {
            "serverName": "'"${domain}"'",
            "minVersion": "1.2",
            "maxVersion": "1.3",
            "cipherSuites": "",
            "rejectUnknownSni": false,
            "certificates": [{
                "certificateFile": "/root/cert/'"${domain}"'/fullchain.pem",
                "keyFile": "/root/cert/'"${domain}"'/privkey.pem"
            }]
        }
    }'
    
    local sniffing='{
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }'
    
    local tag="in-${port}-xhttp"
    
    local payload=$(cat <<EOF | tr -d '\n'
{
    "port": ${port},
    "protocol": "vless",
    "settings": ${settings},
    "streamSettings": ${stream_settings},
    "sniffing": ${sniffing},
    "remark": "${remark}",
    "tag": "${tag}",
    "enable": true,
    "total": 0,
    "expiryTime": 0
}
EOF
)
    
    # 调用 API 添加入站
    local api_url="http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}panel/api/inbounds/add"
    local resp
    
    if [[ -n "$API_TOKEN" ]]; then
        resp=$(curl -s -X POST "${api_url}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${payload}")
    else
        resp=$(curl -s -X POST "${api_url}" \
            -b /tmp/xui_cookie.txt \
            -H "Content-Type: application/json" \
            -d "${payload}")
    fi
    
    if echo "$resp" | grep -q '"success":\s*true'; then
        LOGI "入站添加成功！"
    else
        local inbound_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('obj',{}).get('id',''))" 2>/dev/null)
        if [[ -n "$inbound_id" ]]; then
            LOGI "入站添加成功！ID: ${inbound_id}"
        else
            LOGE "入站添加失败: $(echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp")"
            exit 1
        fi
    fi
    
    # 重启 Xray
    LOGI "正在重启 Xray..."
    /usr/bin/x-ui restart-xray 2>/dev/null || /usr/local/x-ui/x-ui restart-xray 2>/dev/null || true
    sleep 2
    
    # 输出连接信息
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}          VLESS+XHTTP 配置完成！${PLAIN}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
    echo ""
    echo -e " ${BLUE}协议:${PLAIN} VLESS + XHTTP + TLS"
    echo -e " ${BLUE}地址:${PLAIN} ${domain}"
    echo -e " ${BLUE}端口:${PLAIN} ${port}"
    echo -e " ${BLUE}UUID:${PLAIN} ${uuid}"
    echo -e " ${BLUE}XHTTP 路径:${PLAIN} ${xhttp_path}"
    echo -e " ${BLUE}传输模式:${PLAIN} auto"
    echo -e " ${BLUE}备注:${PLAIN} ${remark}"
    echo ""
    echo -e " ${YELLOW}分享链接:${PLAIN}"
    local encoded_uuid=$(echo -n "${uuid}" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "${uuid}")
    local encoded_remark=$(echo -n "${remark}" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "${remark}")
    local share_link="vless://${encoded_uuid}@${domain}:${port}?type=xhttp&security=tls&path=${xhttp_path}&host=${domain}&sni=${domain}&mode=auto#${encoded_remark}"
    echo -e " ${GREEN}${share_link}${PLAIN}"
    echo ""
    echo -e " ${YELLOW}客户端配置参数:${PLAIN}"
    echo -e "  地址 (Address): ${domain}"
    echo -e "  端口 (Port): ${port}"
    echo -e "  用户ID (UUID): ${uuid}"
    echo -e "  传输 (Network): xhttp"
    echo -e "  安全 (Security): tls"
    echo -e "  XHTTP 路径 (Path): ${xhttp_path}"
    echo -e "  传输模式 (Mode): auto"
    echo -e "  SNI (ServerName): ${domain}"
    echo ""
    echo -e " ${YELLOW}注意:${PLAIN} XHTTP 是 Xray 1.8.0+ 的新传输协议，"
    echo -e " 兼容性可参考 https://xtls.github.io/"
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
}

# 主流程
main() {
    LOGI "=============================================="
    LOGI "  3X-UI 一键搭建: VLESS+XHTTP"
    LOGI "=============================================="
    echo ""
    LOGI "XHTTP 是 Xray 1.8.0+ 的新一代 HTTP 多路复用传输协议"
    echo ""
    
    if ! check_installed; then
        LOGW "3X-UI 面板未安装，正在自动安装..."
        install_panel
    else
        LOGI "3X-UI 面板已安装"
    fi
    
    check_xray_version
    
    systemctl start x-ui 2>/dev/null || true
    sleep 2
    
    get_credentials
    login_panel
    add_inbound
    
    rm -f /tmp/xui_cookie.txt 2>/dev/null
}

main "$@"