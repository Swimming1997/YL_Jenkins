# 云服务器自建 Docker Registry

本文说明未来在云服务器自行部署 Registry 时需要完成的操作。它不执行 XHSMedium 业务部署，也不授权生产发布。

## 1. 推荐拓扑

Registry 使用独立域名，例如 `registry.example.com`，数据目录使用独立磁盘或云硬盘。Jenkins Release DIND 通过 HTTPS 访问 Registry；80/443 只对受信任办公网、VPN 或云内网开放，不直接暴露无认证的 5000 端口。

单台云服务器也可以同时运行 Registry 和业务容器，但必须使用不同 Compose project、网络、卷和备份策略。Registry 故障不能删除正在运行的业务容器，业务环境也不得挂载 Registry 数据卷。

## 2. 目录和 Secret

```bash
sudo install -d -m 0750 /opt/xhsmedium-registry/{auth,certs,data,backup}
cd /opt/xhsmedium-registry
```

生成独立 Registry 用户和 bcrypt htpasswd。密码不要写入 Shell 历史；以下命令中的环境变量应由交互式 Secret 管理或云密钥系统提供：

```bash
docker run --rm --entrypoint htpasswd \
  httpd:2.4-alpine@sha256:1b766f17b84026429b7cb243317b142921b24432336e798bc881c43f45ed9567 \
  -Bbn jenkins-release "$REGISTRY_PASSWORD" \
  | sudo tee /opt/xhsmedium-registry/auth/htpasswd >/dev/null
sudo chmod 0600 /opt/xhsmedium-registry/auth/htpasswd
```

为 `registry.example.com`准备可信 TLS 证书：

```text
/opt/xhsmedium-registry/certs/domain.crt
/opt/xhsmedium-registry/certs/domain.key
```

证书可以来自受信任 CA、企业 CA 或反向代理。不得在云端使用 `--insecure-registry`；使用私有 CA 时，把 CA 证书安装到 Release DIND 的 `/etc/docker/certs.d/registry.example.com/ca.crt`并重启 daemon。

## 3. Compose 配置

```yaml
services:
  registry:
    image: registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
    restart: unless-stopped
    environment:
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM: XHSMedium Registry
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
      REGISTRY_HTTP_TLS_CERTIFICATE: /certs/domain.crt
      REGISTRY_HTTP_TLS_KEY: /certs/domain.key
      REGISTRY_STORAGE_DELETE_ENABLED: "false"
      REGISTRY_HTTP_SECRET: ${REGISTRY_HTTP_SECRET:?required}
    ports:
      - "443:5000"
    volumes:
      - /opt/xhsmedium-registry/data:/var/lib/registry
      - /opt/xhsmedium-registry/auth:/auth:ro
      - /opt/xhsmedium-registry/certs:/certs:ro
    security_opt:
      - no-new-privileges:true
```

`REGISTRY_HTTP_SECRET`使用至少 32 字节随机值，通过 `.env`权限 0600、Docker Secret 或云密钥服务注入，不提交 Git。

启动并验证：

```bash
docker compose up -d
curl -I https://registry.example.com/v2/                    # 应返回 401
curl -u "jenkins-release:$REGISTRY_PASSWORD" \
  https://registry.example.com/v2/                          # 应返回 200
```

## 4. Jenkins 切换

1. 将 Jenkins 的 Registry 地址改为 `registry.example.com`。
2. 将云端 Push 账号写入 Jenkins `registry-xhsmedium-push` Credential；为 Deploy Job另建真正的 pull-only Credential。两者都禁止挂载到 Agent 文件系统。
3. 删除 Release DIND 的 `--insecure-registry=registry:5000`。
4. 安装 Registry CA，并验证 `docker login registry.example.com`。
5. 运行 Release Agent 和 Deploy Agent smoke，再执行一个新的、明确授权的候选构建及非生产部署。

正式 Jenkins 和 Registry 不在同一 Compose 网络时，只允许通过 HTTPS/VPN/云内网访问。防火墙不得开放 Docker daemon 2375；Release Agent 仍只连接自己的 TLS DIND 2376。

## 5. 备份与恢复

一致备份前暂停写入或停止 Registry：

```bash
docker compose stop registry
sudo tar -C /opt/xhsmedium-registry -czf \
  /opt/xhsmedium-registry/backup/registry-$(date -u +%Y%m%d-%H%M%S).tar.gz \
  data auth certs
docker compose start registry
sha256sum /opt/xhsmedium-registry/backup/registry-*.tar.gz
```

备份包含镜像层、manifest、认证文件和私钥，必须加密、限制读取并保存异地副本。恢复必须先写入新目录或新磁盘，验证 `/v2/`、完整 SHA 标签和 digest 后再切换，禁止直接覆盖唯一在线副本。

## 6. 保留、轮换和迁移

- 候选镜像以完整 Git SHA 标记，Release 和 Deploy 始终使用 digest。
- Registry 删除默认关闭。确需清理时先形成保留清单、备份并停止写入，再执行受控 garbage-collect；禁止定时全局清空。
- 轮换密码后同时更新 htpasswd 和 Jenkins Credential，并运行 smoke。
- 本地模拟镜像通常不迁移到正式仓库；正式云端启用后生成新的授权候选。
- 必须迁移既有 digest 时，使用受控 `skopeo copy --all`在两个已认证 Registry 间复制，并在目标端重新读取 `Docker-Content-Digest`，不得重新 Docker build。

## 7. 上线前检查

- 域名和 TLS 链可信，证书续期有告警。
- 5000、2375 和 Docker Socket 未暴露公网。
- Registry 数据、认证和证书均有可恢复备份。
- Jenkins Credential 最小权限且日志脱敏。
- 完整 SHA 标签无法静默覆盖，Release manifest 使用 digest。
- 磁盘容量、连续 401/5xx、Push 失败和证书过期均有监控。
