# 故障响应手册

## 首要原则

先保存首个有效失败和 Jenkins Build URL，再判断故障属于应用、测试定义、基础设施、外部网络、超时或人工中断。不要为了得到绿色结果修改历史证据，也不要使用全局清理命令。

## Controller 不可用

1. 执行 `docker compose ps`和 `docker compose logs --tail 200 controller`。
2. 检查 Jenkins Home 容量；达到 90% 时停止新任务并按 Job 保留策略处理，不执行全局 prune。
3. Controller 数据损坏时，从 Git 重建配置并将备份恢复到全新卷，禁止覆盖原卷。
4. 恢复后执行 `validate.ps1 -Runtime`和权限测试。

## Agent 离线

1. 确认队列中的 Job 标签和离线节点，不把排队记为测试失败。
2. 检查 `build-agent`、`regression-agent`和 `regression-docker`健康状态。
3. 仅重启对应 Agent；Regression Agent 必须继续只连接 TLS DIND。
4. 运行 `test-agents.ps1`，要求 Jenkins 明确观察到离线与重新连接。

## 回归失败或中断

1. 查看 `summary.json`和 `first-failure.json`，确认 Requirement 状态。
2. 按精确 `com.docker.compose.project`标签检查容器、卷和网络。
3. 检查 Workspace、npm cache 和 `.platform-compat`辅助文件。
4. cleanup 未成功时保持失败状态，不执行跨项目删除。

## 磁盘增长或运行残留

1. 停止新的重型任务，记录 `df`、Docker、专用 DIND、Jenkins Home 和最大 Artifact 占用。
2. 按[`runtime-residue-management.md`](runtime-residue-management.md)区分零残留对象、有界证据/缓存和禁止日常删除的持久数据。
3. 先处理精确 run 镜像；再使用对应 `Platform/Maintenance/dind-*`执行 `AUDIT`，审核候选后以明确确认运行 `APPLY`，处理旧 SHA 缓存和专用 DIND BuildKit cache；每步重新测量可用空间。
4. 过期 trace、Artifact 和 Jenkins Build 只能按 RRM-D4 的记录级保留策略处理，不得由 DIND Maintenance Job 删除。
5. 保留当前 SHA、唯一成功基线、首个失败、结构化 JSON、日志和截图；禁止宿主全局 prune。
6. 清理后确认重型 profile 已停止、Jenkins 队列为空、基线服务健康，并记录 `RESIDUE_CLEANUP_EVIDENCE`。

## 凭据或权限异常

立即停止相关 Job，保留脱敏日志，运行 `test-authorization.ps1`。不得把 Token、密码、Cookie 或连接串复制到聊天、工单或 Artifact；疑似泄漏时由凭据所有者撤销并重新生成。
