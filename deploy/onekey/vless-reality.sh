#!/bin/bash
# ============================================================
# 3X-UI 一键搭建: VLESS+REALITY
# 协议: VLESS | 传输: TCP | 安全: REALITY | 端口: 443
# 特点: 无需域名和证书，开箱即用，抗审查最强
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

# 检测公网 IP
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

# 获取面板登录凭据和 API Token
get_credentials() {
    # 从 install-result.env 读取
    if [[ -f /etc/x-ui/install-result.env ]]; then
        source /etc/x-ui/install-result.env
        PANEL_USER="${XUI_USERNAME}"
        PANEL_PASS="${XUI_PASSWORD}"
        PANEL_PORT="${XUI_PANEL_PORT}"
        PANEL_PATH="${XUI_WEB_BASE_PATH}"
        API_TOKEN="${XUI_API_TOKEN}"
    fi
    
    # 如果没读到，尝试从 x-ui 二进制获取
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
        LOGE "无法获取面板凭据，请手动检查面板状态"
        exit 1
    fi
}

# 通过 API 登录获取 session cookie
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
    
    # 尝试使用 API Token
    if [[ -n "$API_TOKEN" ]]; then
        LOGI "使用 API Token 认证..."
        return 0
    fi
    
    LOGE "面板登录失败，请检查凭据"
    exit 1
}

# 生成 UUID
gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
    (date +%s%N | md5sum | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
}

# 生成 REALITY 密钥对
gen_reality_keys() {
    local keys=$(/usr/local/x-ui/bin/xray-linux-${ARCH} x25519 2>/dev/null)
    if [[ $? -ne 0 || -z "$keys" ]]; then
        # 如果 xray 不可用，尝试其他路径
        keys=$(/usr/local/x-ui/xray x25519 2>/dev/null) || true
    fi
    if [[ -z "$keys" ]]; then
        LOGE "无法生成 REALITY 密钥对，请确保 xray 已安装"
        exit 1
    fi
    PRIVATE_KEY=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$keys" | grep "Public key:" | awk '{print $3}')
    LOGI "REALITY 密钥对已生成"
}

# 获取最佳目标网站 (shortid 用)
get_dest() {
    # 常用的 REALITY 目标网站 - 返回一个随机的
    local sites=(
        "www.microsoft.com:443"
        "www.apple.com:443"
        "www.cloudflare.com:443"
        "www.amazon.com:443"
        "www.google.com:443"
        "www.bing.com:443"
        "www.github.com:443"
        "www.stackoverflow.com:443"
    )
    echo "${sites[$RANDOM % ${#sites[@]}]}"
}

# 生成随机 shortId
gen_shortid() {
    openssl rand -hex 8
}

# 添加 VLESS+REALITY 入站
add_inbound() {
    local uuid=$(gen_uuid)
    local dest=$(get_dest)
    local shortid=$(gen_shortid)
    local remark="VLESS-REALITY-${SERVER_IP}"
    local port="443"
    
    read -rp "请输入入站端口 [默认 443]: " input_port
    port="${input_port:-$port}"
    
    read -rp "请输入备注 [默认 ${remark}]: " input_remark
    remark="${input_remark:-$remark}"
    
    # 生成 REALITY 密钥
    gen_reality_keys
    
    # 构建入站 JSON
    local settings='{
        "clients": [{
            "id": "'"${uuid}"'",
            "flow": "xtls-rprx-vision",
            "email": "reality@'"${SERVER_IP}"'",
            "enable": true
        }],
        "decryption": "none"
    }'
    
    local stream_settings='{
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "dest": "'"${dest}"'",
            "xver": 0,
            "serverNames": ["'"${SERVER_IP}"'", "'"$(echo ${dest} | cut -d: -f1)"'"],
            "privateKey": "'"${PRIVATE_KEY}"'",
            "shortIds": ["'"${shortid}"'"]
        }
    }'
    
    local sniffing='{
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }'
    
    local tag="in-${port}-reality"
    
    # 构建完整请求体
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
        # 尝试获取 obj 中的 id
        local inbound_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('obj',{}).get('id',''))" 2>/dev/null)
        if [[ -n "$inbound_id" ]]; then
            LOGI "入站添加成功！ID: ${inbound_id}"
        else
            LOGE "入站添加失败: $(echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp")"
            exit 1
        fi
    fi
    
    # 重启 Xray 以应用配置
    LOGI "正在重启 Xray 以应用配置..."
    /usr/bin/x-ui restart-xray 2>/dev/null || /usr/local/x-ui/x-ui restart-xray 2>/dev/null || true
    sleep 2
    
    # 输出连接信息
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}          VLESS+REALITY 配置完成！${PLAIN}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
    echo ""
    echo -e " ${BLUE}协议:${PLAIN} VLESS + REALITY"
    echo -e " ${BLUE}地址:${PLAIN} ${SERVER_IP}"
    echo -e " ${BLUE}端口:${PLAIN} ${port}"
    echo -e " ${BLUE}UUID:${PLAIN} ${uuid}"
    echo -e " ${BLUE}Flow:${PLAIN} xtls-rprx-vision"
    echo -e " ${BLUE}目标网站:${PLAIN} ${dest}"
    echo -e " ${BLUE}PublicKey:${PLAIN} ${PUBLIC_KEY}"
    echo -e " ${BLUE}ShortId:${PLAIN} ${shortid}"
    echo ""
    echo -e " ${YELLOW}分享链接 (v2rayN/Nekobox/Shadowrocket):${PLAIN}"
    local encoded_uuid=$(echo -n "${uuid}" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "${uuid}")
    local encoded_server=$(echo -n "${SERVER_IP}" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "${SERVER_IP}")
    local encoded_remark=$(echo -n "${remark}" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "${remark}")
    local share_link="vless://${encoded_uuid}@${SERVER_IP}:${port}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${dest%:*}&sid=${shortid}&flow=xtls-rprx-vision#${encoded_remark}"
    echo -e " ${GREEN}${share_link}${PLAIN}"
    echo ""
    echo -e " ${YELLOW}客户端配置参数:${PLAIN}"
    echo -e "  地址 (Address): ${SERVER_IP}"
    echo -e "  端口 (Port): ${port}"
    echo -e "  用户ID (UUID): ${uuid}"
    echo -e "  流控 (Flow): xtls-rprx-vision"
    echo -e "  传输 (Network): tcp"
    echo -e "  安全 (Security): reality"
    echo -e "  目标 (ServerName): ${dest%:*}"
    echo -e "  指纹 (Fingerprint): chrome"
    echo -e "  PublicKey: ${PUBLIC_KEY}"
    echo -e "  ShortId: ${shortid}"
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${PLAIN}"
}

# 主流程
main() {
    LOGI "=============================================="
    LOGI "  3X-UI 一键搭建: VLESS+REALITY"
    LOGI "=============================================="
    echo ""
    
    if ! check_installed; then
        LOGW "3X-UI 面板未安装，正在自动安装..."
        install_panel
    else
        LOGI "3X-UI 面板已安装"
    fi
    
    # 确保面板在运行
    systemctl start x-ui 2>/dev/null || true
    sleep 2
    
    get_credentials
    login_panel
    add_inbound
    
    # 删除临时文件
    rm -f /tmp/xui_cookie.txt 2>/dev/null
}

main "$@"