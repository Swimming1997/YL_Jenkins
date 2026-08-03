# 项目接入手册

## 接入前门禁

- 明确仓库、受信任分支、只读凭据和固定 SHA 规则。
- 记录语言、锁文件、测试命令、报告路径、资源上限和 cleanup 行为。
- 明确是否访问数据库、浏览器、外部服务或部署环境；未获精确授权的一律禁止。
- 项目 Pipeline 复用自身构建和测试入口，Jenkins 不复制业务 Planner、Runner 或覆盖格式。

## Agent 和权限

- 普通 CI 优先使用无 Docker CLI、无宿主机 Socket、无生产凭据的 Build Agent。
- 需要容器测试时使用隔离 Regression Agent 和专用 TLS DIND。
- 不可信 Fork/PR 不得获得 SCM 写凭据、发布凭据、生产凭据或高权限 Docker 环境。
- Controller executor 保持为 0，Job 必须绑定明确标签。

## Pipeline 最低要求

- 将分支解析为完整 SHA，并固定检出该 SHA。
- 限制并发和超时，失败/超时/中断状态准确。
- 归档直接业务证据，而不是只依赖绿色构建。
- `post`中按唯一 runId 或精确项目名清理 Workspace、缓存和测试资源。
- 配置明确的构建与 Artifact 保留数量。

## 接入验收

运行平台静态与运行时验证、权限边界、Agent smoke、项目成功/失败路径和资源清理测试。只有直接证据全部通过且 cleanup 成功后，才能把项目标记为已接入。

