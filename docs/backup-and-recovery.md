# 备份与恢复

本地开发阶段目标为 RPO 24 小时、RTO 4 小时。云端目标需重新审批。

## 备份范围

`scripts/backup.ps1`短暂停止 Controller，并归档完整 `/var/jenkins_home`。归档包含 Jenkins 配置、用户哈希、加密密钥、Job 和运行记录，因此必须视为敏感文件；默认写入 Git 忽略的 `backups/`目录。

JCasC、Job DSL 和插件清单由 Git 保存，不依赖 Jenkins Home 备份。`.secrets/`不进入备份归档，应通过云端密钥系统或独立加密介质保护。

## 创建备份

```powershell
.\scripts\backup.ps1
```

脚本在 `finally`中重新启动原 Controller。备份失败不能被报告为成功。

## 安全恢复

```powershell
.\scripts\restore.ps1 `
  -BackupFile .\backups\jenkins-home-<timestamp>.tar.gz `
  -TargetVolume jenkins_restore_test
```

恢复脚本只允许写入不存在的新卷，拒绝覆盖已有卷。验证恢复实例时必须使用独立 Compose project、端口和卷；验证完成后删除对应容器、网络和测试卷。

本地自动恢复演练：

```powershell
.\scripts\test-backup-restore.ps1 -ExpectedRegressionBuild 19
```

脚本在备份前创建唯一即时 RPO 探针，对归档计算 SHA-256，恢复至新卷并以随机 localhost 端口启动隔离 Controller；随后验证管理员认证、历史构建和探针，记录 RTO，最后精确删除演练容器、卷、探针和敏感归档。

## 云端补充要求

- 备份加密、校验和及异地副本
- 备份介质最小权限和访问审计
- 定期自动备份与失败告警
- 密钥系统独立备份
- 在全新主机执行恢复演练并记录耗时
