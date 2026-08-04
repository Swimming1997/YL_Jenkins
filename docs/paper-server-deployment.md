# paper-server 测试部署

paper-server 是共享的 Ubuntu Docker 主机。Jenkins 平台固定部署在 `/opt/jenkins-platform`，只用于受控 CI、回归、Release 和非生产部署验收，不构成生产发布环境。

## 资源与常驻服务

服务器基线为 4 vCPU、约 15 GiB 内存。`compose.paper-server.yaml` 只让以下服务常驻：

| 服务 | CPU 上限 | 内存上限 |
|---|---:|---:|
| Controller | 1.0 | 1280 MiB |
| Build Agent | 1.5 | 2 GiB |
| Registry | 0.25 | 512 MiB |

Regression、Release、dev Deploy 和 test Deploy 的 Agent/DIND 均放在 profile 中。任何时刻只允许一个重型 profile 执行任务，不得并行运行回归、制品构建和两个环境部署。

## 初始化

仓库、`.env` 和 `.secrets/` 必须位于 `/opt/jenkins-platform`。`xhsmedium_scm_token` 需要预先放入 `.secrets/`；引导脚本会在服务器生成其他独立密码和 Agent 密钥，不覆盖已有 Secret。

```bash
cd /opt/jenkins-platform
./scripts/bootstrap-paper-server.sh
```

脚本校验合并后的 Compose 配置，然后构建并启动 Controller、Build Agent 和 Registry。宿主机只运行 Git、Docker、OpenSSL 和 SSH 密钥工具；Jenkins、Agent、Registry、数据库和测试服务全部运行在 Docker 中。

## 构建网络例外

paper-server 的默认 Docker 构建网络访问国际 Debian 软件源时可能持续阻塞。受信任的平台 Dockerfile 在镜像构建阶段使用 host 网络；该例外不改变任何容器运行网络，也不会在构建阶段注入 SCM、Registry 或部署 Secret。

Build Agent 在 paper-server 上使用独立的阿里云 Debian 与 Debian Security 镜像参数，并对 apt 设置 20 秒下载超时和 5 次重试。Dockerfile 的镜像参数默认留空，因此其他环境仍使用基础镜像原有软件源。

XHSMedium P3 CI 继续使用官方 npm registry。针对 paper-server 上已观测到的下载连接重置，Shared Library 只对明确的瞬时网络错误有界重试 `npm ci`；不会重试测试或构建，也不会切换第三方 npm 供应链。

## 访问边界

Jenkins 和 Registry 只绑定服务器 localhost：

```text
127.0.0.1:8080  Jenkins
127.0.0.1:5000  Registry
```

本地访问 Jenkins：

```powershell
ssh -L 8080:127.0.0.1:8080 paper-server
```

浏览器随后访问 `http://127.0.0.1:8080`。管理员密码只在服务器 `/opt/jenkins-platform/.secrets/jenkins_admin_password` 中保存，禁止复制到聊天、Git、控制台日志或 Artifact。

## 串行 profile 操作

所有命令都在 `/opt/jenkins-platform` 中执行，并同时指定基础与服务器覆盖文件。

```bash
# Regression
docker compose -f compose.yaml -f compose.paper-server.yaml --profile regression up -d --build regression-docker regression-agent
docker compose -f compose.yaml -f compose.paper-server.yaml stop regression-agent regression-docker

# Release
docker compose -f compose.yaml -f compose.paper-server.yaml --profile release up -d --build release-docker release-agent
docker compose -f compose.yaml -f compose.paper-server.yaml stop release-agent release-docker

# dev Deploy
docker compose -f compose.yaml -f compose.paper-server.yaml --profile deploy-dev up -d --build deploy-dev-docker deploy-dev-agent
docker compose -f compose.yaml -f compose.paper-server.yaml stop deploy-dev-agent deploy-dev-docker

# test Deploy
docker compose -f compose.yaml -f compose.paper-server.yaml --profile deploy-test up -d --build deploy-test-docker deploy-test-agent
docker compose -f compose.yaml -f compose.paper-server.yaml stop deploy-test-agent deploy-test-docker
```

启动下一个 profile 前，必须确认上一个 Agent/DIND 已停止且 Jenkins 队列为空。禁止使用无范围的 `docker system prune`，也不得对共享主机执行 `docker compose down --volumes`。

## 验证与水位

基线检查：

```bash
docker compose -f compose.yaml -f compose.paper-server.yaml ps
docker stats --no-stream jenkins-platform-controller-1 jenkins-platform-build-agent-1 jenkins-platform-registry-1
ss -lnt | grep -E ':(8080|5000)\b'
```

最低要求：

- 三个基线服务均为 `healthy`。
- Built-In Node executor 为 0，Build Agent 在线。
- 8080 和 5000 只监听 `127.0.0.1`。
- Registry 匿名请求返回 HTTP 401。
- Agent 和 Controller 不挂载 `/var/run/docker.sock`。
- Jenkins 队列为空，Job Workspace 无业务文件残留。
- 主机至少保留 4 GiB available 内存和 20 GiB 可用磁盘；低于水位时停止新的重型任务。

首次云端基线验收中，`Platform/Validation/build-agent-smoke` 构建 1 为 `SUCCESS`，控制台包含 `BUILD_AGENT_OK`，Workspace 无业务文件残留。

## Secret 与恢复

`.secrets/` 和 `.env` 均被 Git 忽略。服务器 Secret 不回传本地，不复用本地管理员、Registry 或环境密码。只读 XHSMedium SCM Token 是唯一需要预先提供的外部接入 Secret。

Controller 使用 `jenkins_platform_home` named volume，Registry 使用独立 named volume。备份、恢复和磁盘清理必须沿用仓库的精确范围脚本与 `docs/backup-and-recovery.md`，不得影响 paper-server 上的 Langfuse、New API 或其他 Compose 项目。
