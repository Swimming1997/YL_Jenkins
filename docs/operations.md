# 平台运维手册

## 日常检查

```powershell
docker compose ps
.\scripts\validate.ps1 -Runtime
.\scripts\test-retention.ps1 -RegressionBuild 19
```

正常状态要求 Controller、Build Agent、Regression Agent 和隔离 DIND 均为 `healthy`，Jenkins 队列无异常积压，Jenkins Home 与 DIND 文件系统使用率低于 90%，已完成的 scheduled project、Workspace 和兼容辅助文件无残留。

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

