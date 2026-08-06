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

首次验收只有一份合法 approved release，因此故障注入恢复的是同一 digest 的上一成功运行状态，验证的是状态捕获、失败门禁和恢复机制。P6.1-D1增加双Approval验收工具；该工具已在 paper-server 使用两份 SHA、backend digest和frontend digest均不同的合法 Approval 完成 dev/test 真实跨版本验收，跨版本回滚缺口已关闭。

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

## P6.1-D1 跨版本回滚验收

`scripts/test-xhsmedium-deploy-cross-version.ps1`要求两份成功的Release Approval，并验证两个manifest的SHA及backend/frontend digest均不同。每个环境按固定顺序执行：

1. 部署基线Approval A并核对两个A digest。
2. 对候选Approval B注入健康失败，要求Jenkins构建保持`FAILURE`且没有`P6_DEPLOY_OK`。
3. 核对`rollback-evidence.json`中的`failedApprovalBuild=B`、`restoredApprovalBuild=A`、A的Git SHA和两个A digest，并确认环境健康。
4. 再次正常部署B，核对最终运行两个B digest且环境健康。

本地完整拓扑可一次验收两个环境：

```powershell
.\scripts\test-xhsmedium-deploy-cross-version.ps1 `
  -BaselineApprovedReleaseBuild <approval-a> `
  -CandidateApprovedReleaseBuild <approval-b>
```

也可以通过`-Environment dev`或`-Environment test`单独运行一个环境，以满足资源受限环境的严格串行要求。复核历史证据时，某个环境的`Existing*BaselineBuild`、`Existing*RollbackBuild`和`Existing*CandidateBuild`必须三个同时提供且构建号严格递增；脚本仍核对最终环境运行候选B，不接受不完整或顺序不成立的历史构建组合。

P6.1-D1工具的本地静态与参数契约验证不等于真实跨digest通过。最终状态必须以两份合法Approval、两个环境的Jenkins构建、归档JSON、运行容器digest、Secret脱敏、队列和Workspace零残留证据为准。

### P6.1-D1 完成证据（2026-08-06）

- Jenkins Platform 修复提交：`e9a688147b9ed959fe9c24dc5ffe03aed611af82`。Deploy Pipeline 在加载`previous-deployment.env`前独立保存当前失败 Approval，JSON 和`P6_DEPLOY_ROLLED_BACK` marker不再被上一部署环境覆盖。
- Approval A：构建 3，Git SHA `b48c1e8f98df9a085452d8746cba024d8e263fea`；backend digest `sha256:a1b8df408088cc3410f9f929adfcec6dff63ccd4c16121835c3be09621ee59fa`，frontend digest `sha256:ccb095b2e60953e3f2b6e961c8730719a471e87239145bdc0513f0b3b196063b`。
- Approval B：构建 4，Git SHA `7021db362cdebf141c74a1034c04844fb349a83c`；backend digest `sha256:bf70768fdfae9eaf2aa59699a21188daaed14f800b882e555daec29205f743bd`，frontend digest `sha256:94de66ca3750a15fed2761ec0b4ca11aabdb663cab7cca36594b4ffd52a979c0`。

| 环境 | 基线 A | B 故障并回滚 A | 最终 B | 结果 |
|---|---:|---:|---:|---|
| dev | 5 `SUCCESS` | 6 `FAILURE` | 7 `SUCCESS` | 回滚证据为失败 4、恢复 3，最终运行 B 双 digest |
| test | 2 `SUCCESS` | 3 `FAILURE` | 4 `SUCCESS` | 回滚证据为失败 4、恢复 3，最终运行 B 双 digest |

两个故障构建均没有`P6_DEPLOY_OK`，`rollback-evidence.json`均记录`healthy=true`、A SHA和两个A digest。两个最终构建均记录B SHA和两个B digest；控制台不含测试 Secret，Deploy Workspace无残留，Jenkins队列和active executor均为零。dev停止后才启动test，验收结束后四个重型profile全部停止。

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
