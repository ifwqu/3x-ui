# 一键搭建脚本 (One-Click Setup Scripts)

本目录包含多个一键搭建脚本，用于在 3X-UI 面板上快速创建特定协议组合的入站配置。

## 使用方法

```bash
# 以 root 身份运行任意脚本
bash <(curl -Ls https://raw.githubusercontent.com/ifwqu/3x-ui/main/deploy/onekey/vless-reality.sh)
```

## 脚本列表

| 脚本 | 协议 | 传输 | 安全 | 端口 | 说明 |
|------|------|------|------|------|------|
| `vless-reality.sh` | VLESS | TCP | REALITY | 443 | 无需证书，抗审查最强 |
| `vless-ws-tls-arm.sh` | VLESS | WebSocket | TLS | 443 | ARM 架构优化，兼容 CDN |
| `vless-xhttp.sh` | VLESS | XHTTP | TLS | 8443 | 新一代 HTTP 多路复用传输 |
| `trojan-tls.sh` | Trojan | TCP | TLS | 443 | 经典 Trojan 协议 |

## 前置条件

- 一台 Linux 服务器（root 权限）
- 对于 TLS 类脚本：需要域名并将 DNS A/AAAA 记录指向服务器 IP
- 端口 80 对外开放（用于 Let's Encrypt 证书签发）

## 输出

每个脚本执行完毕后会输出：
- 面板访问地址（首次安装时）
- 节点连接信息（分享链接、二维码等）
- 客户端配置参数

## 注意事项

- **VLESS+REALITY**：不需要域名和证书，开箱即用，推荐优先使用
- **VLESS+WS+TLS**：需要域名，WebSocket 可套 CDN（Cloudflare 等）
- **VLESS+XHTTP**：新一代传输协议，需要较新的 Xray 内核支持
- **TROJAN+TLS**：兼容性好，支持回落（Fallback）配置