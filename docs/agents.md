# Jenkins Agent

P2 使用两个静态 Linux SSH Agent。Controller executor 保持为 0，业务命令只能由匹配标签的 Agent 执行。

| Agent | 标签 | 工具 | Docker权限 |
|---|---|---|---|
| Build Agent | `linux node20 xhsmedium-build` | Java 21、Git、Node 20、npm 10、Python 3、make、g++ | 无 Docker CLI、无 Docker Socket |
| Regression Agent | `linux node20 docker-isolated xhsmedium-regression` | Java 21、Git、Node 20、npm 10、Python 3、make、g++、Playwright 1.59.1、Docker 29.3.1、Compose 5.1.1 | 只访问专用 TLS DIND |
| Release Agent | `linux docker-isolated xhsmedium-release` | Java 21、Git、curl、Python 3、Docker 29.3.1、Buildx | 只访问专用 TLS Release DIND 和认证 Registry |
| Dev Deploy Agent | `linux docker-isolated xhsmedium-deploy-dev` | Java 21、curl、Python 3、Docker 29.3.1、Compose 5.1.1 | 只访问专用 TLS Dev DIND 和认证 Registry |
| Test Deploy Agent | `linux docker-isolated xhsmedium-deploy-test` | Java 21、curl、Python 3、Docker 29.3.1、Compose 5.1.1 | 只访问专用 TLS Test DIND 和认证 Registry |

Build Agent 的容器内存上限为 2 GiB，`/home/jenkins/agent` 是 2 GiB tmpfs。该挂载显式启用 `exec`，因为 Jenkins Git 凭据包装和 `node_modules/.bin` 必须在 Workspace 中执行；同时保留 `nosuid`、`nodev`、容器 `no-new-privileges`、能力裁剪、无 Docker CLI、无宿主机端口及构建后 Workspace 清理。云服务器部署时必须为该 Agent 预留至少 2 GiB 内存。

Python 3、make 和 g++ 仅安装在 Build Agent 镜像内，用于 `node-gyp` 在缺少匹配预编译包时构建锁定的 native Node.js 依赖；宿主机不安装这些运行依赖。

三个 Agent 使用不同的 RSA PEM SSH 凭据。私钥只挂载到 Controller，公钥只挂载到对应 Agent。密钥文件位于 Git 忽略的 `.secrets/`，由 `scripts/generate-agent-keys.ps1`创建。

P5 增加第三套独立 Release Agent SSH 凭据。Registry 用户名和密码只挂载到 Controller 与一次性 auth 初始化容器；Release Agent 文件系统不挂载 Registry Secret，Pipeline 仅在认证 Stage 中注入并使用 Workspace 内临时 `DOCKER_CONFIG`，随后 logout 和删除。

P6 增加相互独立的 Dev/Test Deploy Agent SSH 凭据和 TLS DIND。每个 Deploy Agent 只能控制自己的模拟目标；环境级 MySQL、JWT 和草稿加密 Secret 只在对应 Job 的部署 Stage 注入，Agent 容器环境和文件系统不持久挂载这些 Secret。

Agent SSH 端口只存在于 Docker `control`网络，不映射到宿主机。P2 本地环境使用 non-verifying host-key 策略，以允许容器重建后自动重连；该策略只能用于不对外开放的本地 control 网络。云端必须改为固定 known_hosts 或受控短生命周期 Agent。

Agent Workspace 使用逻辑容量 2 GiB 的 tmpfs，以高于 Jenkins 默认磁盘阈值；tmpfs 不预分配内存，实际使用仍受每个 Agent 的 1 GiB 容器内存上限约束。

RRM-D3.1 为四个专用 DIND 各生成一个 `Platform/Maintenance/dind-*` Job。Job 固定运行在对应 Agent，通过已有 TLS `DOCKER_HOST`维护该 Agent 唯一可见的 DIND；只读 Jenkins API 凭据仅在空闲门禁 Stage 注入，用于检查队列、executor 和 Regression 成功 SHA 窗口，随后不持久保存。Maintenance 不获得宿主 Docker Socket、管理员凭据、Registry Secret 或部署环境 Secret。

## 验证

```powershell
.\scripts\test-agents.ps1
```

验证脚本运行 Build/Regression smoke、Workspace cleanup、预期 timeout cleanup 和 Agent reconnect，并检查精确 Docker 网络残留。
