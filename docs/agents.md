# Jenkins Agent

P2 使用两个静态 Linux SSH Agent。Controller executor 保持为 0，业务命令只能由匹配标签的 Agent 执行。

| Agent | 标签 | 工具 | Docker权限 |
|---|---|---|---|
| Build Agent | `linux node20 xhsmedium-build` | Java 21、Git、Node 20、npm 10 | 无 Docker CLI、无 Docker Socket |
| Regression Agent | `linux node20 docker-isolated xhsmedium-regression` | Java 21、Git、Node 20、npm 10、Playwright 1.59.1、Docker 29.3.1、Compose 5.1.1 | 只访问专用 TLS DIND |

两个 Agent 使用不同的 RSA PEM SSH 凭据。私钥只挂载到 Controller，公钥只挂载到对应 Agent。密钥文件位于 Git 忽略的 `.secrets/`，由 `scripts/generate-agent-keys.ps1`创建。

Agent SSH 端口只存在于 Docker `control`网络，不映射到宿主机。P2 本地环境使用 non-verifying host-key 策略，以允许容器重建后自动重连；该策略只能用于不对外开放的本地 control 网络。云端必须改为固定 known_hosts 或受控短生命周期 Agent。

## 验证

```powershell
.\scripts\test-agents.ps1
```

验证脚本运行 Build/Regression smoke、Workspace cleanup、预期 timeout cleanup 和 Agent reconnect，并检查精确 Docker 网络残留。
