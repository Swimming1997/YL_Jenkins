# Jenkins Platform

本仓库提供可重建的 Jenkins 平台。当前实现范围为 G0～P3A：在本地 Docker Desktop 中运行 Jenkins Controller、隔离 Build/Regression Agent 和专用 Docker-in-Docker，并通过 JCasC、Role Strategy 和 Job DSL 自动恢复平台配置；XHSMedium 已接入手工只读 CI 试点。

## 当前基线

- Jenkins LTS：`2.568.1-jdk21`
- 官方镜像 digest：`sha256:f4f65e6cd1405cd889b7f5ac33f9d5cdc2a099de6b87fe8a3933b9c5d53d1d02`
- 容器端口：`8080`，仅绑定宿主机 `127.0.0.1`
- 数据目录：Docker named volume `jenkins_platform_home`
- Agent：Linux Build Agent 与隔离 Regression Agent
- 平台 Git 远端：`https://github.com/Swimming1997/YL_Jenkins.git`
- 全局 Shared Library：`jenkins-platform-library`，默认版本 `main`

插件及其依赖全部使用明确版本，记录在 `plugins/plugins.txt`。

## 前置条件

- Docker Desktop，使用 Linux Container 模式
- Docker Compose v2 或兼容的 `docker compose` 命令
- PowerShell 7（用于仓库自带脚本）

Jenkins、Java、Node.js 和数据库均不需要安装到宿主机。

XHSMedium 私有仓库接入还要求 `.secrets/xhsmedium_scm_token` 存在，其中保存仅授权 `MuFannnn/xhsmedium`、权限为 `Contents: Read-only` 的 GitHub Fine-grained PAT。该文件已被 Git 忽略，禁止提交或复制到日志。

## 启动

```powershell
Set-Location C:\Users\Administrator\Desktop\Jenkins\jenkins-platform
.\scripts\bootstrap.ps1
```

首次启动会从 `.env.example`创建被 Git 忽略的 `.env`，并在 `.secrets/`生成随机的本地管理员和审计账户密码。脚本随后构建锁定版本的 Controller 镜像并等待 JCasC 加载和健康检查通过。访问：

```text
http://127.0.0.1:8080
```

本地账户为 `admin`和 `audit`。密码仅保存在 Git 忽略的 Secret 文件中，按需在本机读取：

```powershell
Get-Content .\.secrets\jenkins_admin_password
```

不要把密码复制到仓库、聊天、日志或构建产物中。`audit`只能查看平台和 Job，不能修改系统配置。

## 验证

静态和运行时验证：

```powershell
.\scripts\validate.ps1 -Runtime
.\scripts\test-authorization.ps1 -RunLibrarySmoke
.\scripts\test-shared-library.ps1
.\scripts\test-agents.ps1
.\scripts\test-xhsmedium-ci.ps1 -Branch dev
.\scripts\test-xhsmedium-watcher.ps1
```

验证数据卷在容器重建后仍然保留数据：

```powershell
.\scripts\test-persistence.ps1
```

该脚本只创建一个随机探针文件，重建 Controller 后验证它仍存在，最后删除探针。

## 日常操作

```powershell
docker compose ps
docker compose logs --follow controller
docker compose stop
docker compose start
docker compose down
```

`docker compose down`不会删除 named volume。除非明确要清空本地 Jenkins 数据，否则不要使用 `docker compose down --volumes`。

## 备份与恢复

```powershell
.\scripts\backup.ps1
.\scripts\restore.ps1 -BackupFile .\backups\jenkins-home-<timestamp>.tar.gz -TargetVolume jenkins_restore_test
```

恢复脚本拒绝覆盖已有卷。完整演练流程和清理要求见 `docs/backup-and-recovery.md`。

## 在其他 Docker 主机复现

1. 克隆本仓库。
2. 确认目标主机能访问 Docker Hub 和 Jenkins 插件更新站点。
3. 复制 `.env.example`为 `.env`并调整本机端口或卷名。
4. 执行 `scripts/bootstrap.ps1`，或执行等价的 `docker compose up --detach --build controller`。
5. 执行运行时验证。

云服务器部署前还必须补齐 HTTPS、企业身份认证、正式备份目标、防火墙和监控。本地账户和 localhost HTTP 配置不能直接作为生产配置使用。

## 安全边界

- 不把 Docker Socket 挂载到 Controller。
- 不把宿主机 Docker Socket 挂载到任何 Agent；Regression Agent 仅连接专用 TLS DIND。
- 不向不可信 PR 提供发布、生产或高权限 Docker 凭据。
- 不在仓库保存真实密码、Token、Cookie 或连接串。
- 当前不调用 FTP、飞书、生产数据库或其他真实外部系统。
- XHSMedium 仍处于安全冻结状态，不推送、不发布、不部署。

## 文档

- `docs/decisions/0001-local-container-baseline.md`：G0 技术决策与未决门禁
- `docs/xhsmedium-onboarding-audit.md`：XHSMedium 只读接入勘察
- `docs/configuration-as-code.md`：JCasC、Job DSL 与 Shared Library
- `docs/authorization.md`：本地账户和角色权限
- `docs/backup-and-recovery.md`：备份、恢复和演练
- `docs/agents.md`：Agent 标签、连接和验证
- `docs/docker-isolation.md`：专用 DIND 与清理边界
- `docs/xhsmedium-ci.md`：XHSMedium 手工只读 CI、证据和安全边界
- `docs/xhsmedium-scm-polling.md`：每小时检查 dev 拉新并按新 SHA 触发 CI
- `docs/xhsmedium-regression.md`：偶数整点 sealed 回归与受控离线依赖缓存
