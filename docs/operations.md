# 平台运维手册

## 日常检查

```powershell
docker compose ps
.\scripts\validate.ps1 -Runtime
.\scripts\test-retention.ps1 -RegressionBuild 19
```

本地完整拓扑运行时要求Controller、Build Agent、Regression Agent和隔离DIND均为`healthy`。paper-server基线只要求Controller、Build Agent和Registry为`healthy`；Regression、Release与两个Deploy Agent/DIND在没有受控任务时应停止。两种形态都要求Jenkins队列无异常积压，Jenkins Home与DIND文件系统使用率低于90%，已完成的scheduled project、Workspace和兼容辅助文件无残留。

## 运行残留治理

运行资源、DIND 镜像、依赖缓存、Artifact、trace 和持久数据的分类、保留上限、磁盘水位、清理顺序与证据格式统一遵循[`runtime-residue-management.md`](runtime-residue-management.md)。日常检查不能只验证容器和 Workspace；还必须检查专用 DIND 的历史 run 镜像、BuildKit cache 与 Jenkins 大型 Artifact。30 GiB以下进入预警并要求串行，25 GiB以下自动拒绝新的 Regression、Release 和 Deploy，20 GiB以下进入紧急状态。

重型 Pipeline 的受信任 Shared Library读取 Controller容器内 `/var/jenkins_home`所在文件系统的可用字节，audit凭据只通过Jenkins API读取executor状态；两者形成 `RESOURCE_GATE_EVIDENCE`后才进入业务 Stage。Jenkins Home路径缺失或空间值无效时失败关闭，不得通过参数伪造可用空间。`Platform/Maintenance/dind-*`不调用该资源门禁，以保留低磁盘恢复路径，但仍必须满足其原有空闲和精确目标门禁。

业务和维护 Job 的普通构建记录上限为 20，完整 Artifact 上限为 5；Keep Forever构建豁免。Regression 在归档后输出 `TRACE_RETENTION_EVIDENCE`，非 pin 的 Playwright trace 只保留最近两个失败构建且最长 7 天，其他 JSON、日志和截图继续遵守 Artifact保留策略。

专用 DIND 维护使用 `Platform/Maintenance/dind-{regression,release,deploy-dev,deploy-test}`。`AUDIT`为默认只读模式；`APPLY`必须输入 `APPLY_DEDICATED_DIND_MAINTENANCE`。Regression 还必须提供当前和上一已验证完整 SHA，Job 会使用只读 Jenkins API 凭据核对最近成功回归的不同 SHA 顺序。执行前只启动目标 profile，确认队列为空；执行后停止 profile并保存 `DIND_MAINTENANCE_EVIDENCE`。

paper-server重型profile统一使用`bash scripts/paper-server-profile.sh <start|stop|status> <profile>`。`start`拒绝其他重型profile和目标半启动状态，等待Docker健康并恢复既有Jenkins节点；`stop`在队列或任一executor活跃时失败关闭，只停止目标Agent/DIND。成功必须保存`PROFILE_LIFECYCLE_EVIDENCE`；超时、中断或精确回滚失败不得手工改写为通过。

Maintenance 只能对固定 Agent 所连接的专用 TLS DIND执行。AUDIT 可以只读报告运行容器；APPLY 遇到目标运行容器或其他 Jenkins executor 活跃时必须拒绝。镜像命名越界、protected image 丢失或 APPLY 后 cache 仍超过 4 GiB时，Job 必须失败。不得从宿主执行等价的无范围 prune。

APPLY 先请求 Docker 将全部未使用 BuildKit cache 保持在 4 GiB以内。若内置 Docker driver 接受上限参数但复测仍超限，Job 会在同一专用 DIND内清空全部未使用 BuildKit cache，并以 `cache_fallback=1`记录；两种路径都必须再次验证 protected images，且不得删除任何镜像来满足 cache 上限。

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
