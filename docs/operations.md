# 平台运维手册

## 日常检查

```powershell
docker compose ps
.\scripts\validate.ps1 -Runtime
.\scripts\test-retention.ps1 -RegressionBuild 19
```

正常状态要求 Controller、Build Agent、Regression Agent 和隔离 DIND 均为 `healthy`，Jenkins 队列无异常积压，Jenkins Home 与 DIND 文件系统使用率低于 90%，已完成的 scheduled project、Workspace 和兼容辅助文件无残留。

## 运行残留治理

运行资源、DIND 镜像、依赖缓存、Artifact、trace 和持久数据的分类、保留上限、磁盘水位、清理顺序与证据格式统一遵循[`runtime-residue-management.md`](runtime-residue-management.md)。日常检查不能只验证容器和 Workspace；还必须检查专用 DIND 的历史 run 镜像、BuildKit cache 与 Jenkins 大型 Artifact。低于 25 GiB进入预警，低于 20 GiB时禁止启动新的重型任务。

专用 DIND 维护使用 `Platform/Maintenance/dind-{regression,release,deploy-dev,deploy-test}`。`AUDIT`为默认只读模式；`APPLY`必须输入 `APPLY_DEDICATED_DIND_MAINTENANCE`。Regression 还必须提供当前和上一已验证完整 SHA，Job 会使用只读 Jenkins API 凭据核对最近成功回归的不同 SHA 顺序。执行前只启动目标 profile，确认队列为空；执行后停止 profile并保存 `DIND_MAINTENANCE_EVIDENCE`。

Maintenance 只能对固定 Agent 所连接的专用 TLS DIND执行。AUDIT 可以只读报告运行容器；APPLY 遇到目标运行容器或其他 Jenkins executor 活跃时必须拒绝。镜像命名越界、protected image 丢失或 APPLY 后 cache 仍超过 4 GiB时，Job 必须失败。不得从宿主执行等价的无范围 prune。

## 启停和重建

```powershell
docker compose stop
docker compose start
docker compose up -d --force-recreate controller
```

Controller executor 必须保持为 0。Agent SSH 端口和 DIND 端口不得映射到宿主机；任何重建后都运行 `validate.ps1 -Runtime`。禁止使用 `docker compose down --volumes`清空平台数据，禁止执行 `docker system prune`或 `docker volume prune`。

## 备份和恢复

日常备份使用 `scripts/backup.ps1`。本地完整恢复演练使用：

```powershell
.\scripts\test-backup-restore.ps1 -ExpectedRegressionBuild 19
```

演练仅恢复到新卷和随机 localhost 端口，验证后精确删除演练容器、卷和敏感备份。云端备份必须另行配置加密介质、异地副本、访问审计和失败告警。

## 变更验收

平台代码修改先运行静态检查和相关聚焦测试，再执行 `test-hardening.ps1`。失败报告必须保留首个有效失败；中断、超时、cleanup 失败或覆盖缺口不得改写为通过。
