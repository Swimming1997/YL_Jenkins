# XHSMedium 非生产部署

P6 在本地 Docker 中模拟未来两台独立的 dev/test 云服务器。每个环境由独立 Deploy Agent 控制自己的 TLS DIND；两个 Docker daemon、应用网络、MySQL 数据卷和镜像缓存互不共享，也不挂载宿主机 Docker Socket。

## 拓扑与边界

```text
Jenkins Controller
  ├─ Deploy Dev Agent  → TLS Deploy Dev DIND  → xhsmedium-dev
  └─ Deploy Test Agent → TLS Deploy Test DIND → xhsmedium-test

认证 Registry ──只向两个 Deploy DIND提供已批准的镜像 digest
```

`XHSMedium/Deploy/dev`和`XHSMedium/Deploy/test`只接受成功的 `XHSMedium/Release/approve`构建号，并要求显式设置 `CONFIRM_DEPLOY=true`。Pipeline 通过只读 Jenkins API下载 `approved-release-manifest.json`，验证 backend/frontend 引用属于固定 Registry 路径且以完整 SHA-256 digest 结尾，然后拉取并核对 OCI revision/source 标签。

Deploy Job 不检出 Git、不编译源码、不执行 Docker build、Push 或重新打标签。环境运行时只使用本地随机 Secret，并显式关闭爬虫开关；不配置 FTP、飞书、OSS、Redis 或任何真实外部系统。

## 部署内容

每个环境运行：

- 固定 digest 的 backend
- 固定 digest 的 frontend
- 固定 digest 的 MySQL 8.4
- 独立 MySQL 数据卷和 uploads 卷
- backend `/api`与 frontend `/`容器内健康检查

服务不向宿主机发布端口。Jenkins 通过对应 TLS Docker daemon执行容器内 HTTP 冒烟测试。本阶段只验证进程、数据库连接、根 HTTP 路径和制品身份；不初始化或加载真实业务数据，也不把根路径健康检查解释为全业务功能验收。

## 幂等和回滚

部署前，Pipeline 从当前 backend/frontend 容器标签捕获上一份成功的 digest、Git SHA 和 Approval Build。若当前健康容器已经运行目标 digest，Job 返回 `action=NOOP`，不执行 Compose up，也不重建容器。

新部署健康检查失败时：

1. Job 保持 `FAILURE`，不得输出成功部署标记。
2. 使用部署前捕获的两个镜像引用重新执行 Compose。
3. 核对恢复后的容器标签和 HTTP 健康状态。
4. 归档 `rollback-evidence.json`并输出 `P6_DEPLOY_ROLLED_BACK`。

首次验收只有一份合法 approved release，因此故障注入恢复的是同一 digest 的上一成功运行状态，验证的是状态捕获、失败门禁和恢复机制。第二份 approved release 产生后，应追加两个不同 digest 间的跨版本回滚验收。

## 本地验收证据

P6 使用 P5 Approval 构建 2：

| 环境 | 首次部署 | 幂等部署 | 故障与回滚 | 结果 |
|---|---:|---:|---:|---|
| dev | 1 | 2 | 3 | `SUCCESS` / `SUCCESS(NOOP)` / `FAILURE(已回滚)` |
| test | 1 | 2 | 3 | `SUCCESS` / `SUCCESS(NOOP)` / `FAILURE(已回滚)` |

两个环境最终均运行：

```text
backend  registry:5000/xhsmedium/backend@sha256:e4a0f2c302d9e2be3a758c865775d70f08b107371fd0d310e7b8ec6b2143f2c2
frontend registry:5000/xhsmedium/frontend@sha256:42b094476292029db5293a04b2ddf810594e234179cc8e677b239c5e04c3f1b3
```

复核既有构建且不创建新部署：

```powershell
.\scripts\test-xhsmedium-deploy.ps1 `
  -ExistingDevDeployBuild 1 -ExistingDevNoopBuild 2 -ExistingDevRollbackBuild 3 `
  -ExistingTestDeployBuild 1 -ExistingTestNoopBuild 2 -ExistingTestRollbackBuild 3
```

## 云服务器迁移

云端应把两个 DIND 模拟目标替换为两台独立 dev/test Docker 主机或受控短生命周期 Deploy Agent，并完成：

1. 安装 Docker Engine 与 Compose，禁止开放未认证的 2375。
2. 使用固定 `known_hosts`、VPN/云内网和 TLS；不得沿用本地 non-verifying SSH 策略。
3. Registry 必须使用可信 HTTPS，Deploy Credential 应改为真正的 pull-only 权限。
4. 为 dev/test 分配独立域名、证书、数据库、Secret、数据盘和备份策略。
5. 由反向代理发布所需端口，不直接暴露容器数据库或 Docker daemon。
6. 将 Compose 和部署状态保存到目标服务器受限目录，并在切换前备份数据卷。
7. 先在 dev 完成新 digest、幂等和回滚验证，再单独审批 test；不得自动晋级生产。

云端数据库迁移、真实业务 Secret、域名、证书、备份目标和业务级冒烟用例均需要新的精确授权。P6 本地证据不等价于生产部署授权。
