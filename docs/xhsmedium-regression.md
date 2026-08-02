# XHSMedium 定时回归

`XHSMedium/Regression/scheduled`在每个偶数整点运行：

```text
只读解析 dev 完整 SHA
→ Regression Agent 固定检出该 SHA
→ 本地 bare origin 固定 dev，防止运行中漂移
→ 复用 regression/scheduled-entry.js
→ automation 生成并执行 sealed scheduled-regression Docker plan
→ 归档 Requirement 证据并精确清理 Compose 项目、卷和 Workspace
```

业务容器只在隔离的 `regression-docker`中运行。该 DIND 不挂载宿主机 Docker Socket、不发布端口，也没有公网出口。

## 受控离线依赖缓存

XHSMedium Dockerfile 的 `dependencies` target 先在宿主机 Docker 中按固定 SHA 构建。平台脚本为镜像写入完整 SHA 与角色标签，随后通过临时 tar 导入隔离 DIND：

```powershell
.\scripts\preload-xhsmedium-regression.ps1 `
  -SourcePath ..\xhsmedium-reference `
  -Sha 208d36fb42dda939184cbec2f1f829c8480c4d5f
```

Jenkins 运行时要求缓存标签与待测 SHA 完全一致。包装层只接受预期 Compose project，并对 runner、backend、frontend 注入 `NPM_OFFLINE=true`和对应缓存镜像。缓存缺失、角色错误或 SHA 不匹配都会在启动测试数据库前失败。

依赖锁文件或待测 SHA 更新后必须先重新执行预加载。预加载只使用宿主机 Docker 客户端，不向 Agent 挂载 Docker Socket；临时源码快照和 tar 无论成功失败都会删除。

## 安全边界

- 数据库名由 automation 生成，必须匹配 `xhsmedium_test_*`。
- Compose project、runId、数据库和卷按运行唯一隔离。
- 不调用共享数据库、真实浏览器 Profile、爬虫、FTP、飞书、OSS 或部署环境。
- 不执行 `docker system prune`；cleanup 仅作用于本次精确 Compose project。
- `interrupted`、`timeout`、cleanup 失败和 Requirement 缺口不得报告为通过。
