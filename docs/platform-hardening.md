# P4.5 首期加固验收

P4.5 使用本地 Docker 隔离环境完成自动验证、故障注入、恢复和三轮加速稳定性模拟。该模拟用于替代本项目的 1～2 周等待期，但不等价于真实生产运行时长；云端上线前仍需重新确认监控、备份介质、RPO/RTO 和维护责任人。

## 一键验收

```powershell
.\scripts\test-hardening.ps1 `
  -Cycles 3 `
  -RegressionBuild 19 `
  -FailureBuild 9 `
  -TimeoutBuild 10 `
  -InterruptionBuild 12
```

每次运行使用唯一 runId，并将详细日志和 `summary.json`写入 Git 忽略的 `artifacts/platform-hardening/<runId>/`。summary 明确记录 `mode=accelerated-simulation`、模拟轮数、步骤状态、首个失败和总耗时。

## 完成证据

成功运行 `p45-20260803-082714-2045acd5`共执行 25 个步骤，25 个 `PASSED`、0 个 `FAILED`，总耗时 605488 ms，`firstFailure=null`。覆盖：

- JCasC、Job DSL、Shared Library、Agent 镜像与运行时配置
- 匿名、审计账号、Script Console、Credentials 和 Job Build 权限
- Build Agent 无 Docker CLI、无宿主机 Socket、无 Controller Secret、无法解析隔离 DIND
- 两个 Agent 被 Jenkins 明确观察为离线，随后恢复并通过 reconnect Job
- Controller 重建后的 Jenkins Home 持久性
- 32 MiB 隔离 Jenkins Home 的明确磁盘不足失败，实例未被误报健康
- Jenkins Home 备份、SHA-256、全新卷恢复、随机本地端口启动、管理员认证、构建 19 历史和即时 RPO 探针
- 构建 19 真实成功，以及构建 9、10、12 的失败、超时和人工中断证据
- Job 保留数量、回归 Artifact、磁盘阈值、精确资源和 Workspace 清理
- 三轮运行时、权限、Agent、SCM watcher 和清理重复验证

首次模拟 `p45-20260803-081517-d82a81ab`在 watcher 步骤保留为 `FAILED`。首个失败不是平台故障：watcher 从旧基线 `1ac17fb...`首次追平当前 `b846dcd...`，正确触发了只读 CI 构建 18；原测试错误地只接受 `SCM_NO_CHANGE`。测试随后改为允许一次明确收敛，再要求连续两次 `SCM_NO_CHANGE`。下游 CI 构建 18 为 `SUCCESS`并输出 `READ_ONLY_CI_OK`。

## 完成边界

- 以上结果只证明本地隔离基线和加速故障模拟通过。
- 未连接生产或共享数据库、真实浏览器 Profile、FTP、飞书、OSS 或部署环境。
- 未执行发布、部署、全局 Docker prune 或宿主机 Docker Socket 挂载。
- P5 仍以解除 XHSMedium 安全冻结和提供私有镜像仓库为前置门禁。

