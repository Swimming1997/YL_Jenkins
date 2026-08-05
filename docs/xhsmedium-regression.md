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

Regression Agent 与 DIND 通过同路径的专用 `regression_workspace`命名卷共享 Jenkins Workspace。该共享是远程 Docker bind mount 正确工作的必要条件；Controller、Build Agent 和宿主机目录均不挂载该卷。

## 受控离线依赖缓存

XHSMedium Dockerfile 的 `dependencies` target 先在宿主机 Docker 中按固定 SHA 构建。平台脚本为镜像写入完整 SHA 与角色标签，随后通过临时 tar 导入隔离 DIND：

```powershell
.\scripts\preload-xhsmedium-regression.ps1 `
  -SourcePath ..\xhsmedium-reference `
  -Sha b846dcd0771f3fdb81db9ae9c0e9f034d532d36e
```

Jenkins 运行时要求缓存标签与待测 SHA 完全一致。包装层只接受预期 Compose project，并对 runner、backend、frontend 注入 `NPM_OFFLINE=true`和对应缓存镜像。缓存缺失、角色错误或 SHA 不匹配都会在启动测试数据库前失败。

每次回归还会归档 `offline-dependency-cache.log`，分别记录 runner 与 backend/frontend 实际使用的完整固定 SHA。验收脚本直接检查该 Artifact，不依赖顶层 Console 是否转发项目执行器捕获的镜像构建输出。

runner 镜像内的三个 `node_modules`会被 Compose 命名卷覆盖。每个 project 首次启动 runner 时，平台入口脚本先确认 backend、frontend、automation 三个路径都是独立 mountpoint，只初始化这些卷的属主，然后使用 `setpriv`降权到 Regression Agent 的动态 UID/GID 再执行 sealed plan 原命令。入口脚本不以 root 身份运行项目测试，也不修改 fixed-SHA worktree。

XHSMedium 的初始化脚本会被 MySQL 官方 entrypoint `source`，其中的 `set -u`会继续影响官方脚本。平台从 fixed-SHA 仓库外附加一个极薄 wrapper，由它在独立 Bash 子进程执行原始初始化脚本；这样保留原始数据库名校验、schema 和 seed，同时避免 Shell option 泄漏。平台不修改 fixed-SHA Workspace、数据库结构或种子数据。

MySQL 8.4 锁定镜像的临时初始化服务器使用 `/var/lib/mysql/mysql.sock`。wrapper 只在独立子 Bash 中定义临时 `mysql()`函数，为原始脚本的 mysql 客户端调用附加该 socket；不改写原始脚本，也不把函数或 Shell option 写回官方 entrypoint。

依赖锁文件或待测 SHA 更新后必须先重新执行预加载。预加载只使用宿主机 Docker 客户端，不向 Agent 挂载 Docker Socket；临时源码快照和 tar 无论成功失败都会删除。

paper-server 不安装 PowerShell，使用 `scripts/preload-xhsmedium-regression.sh`完成等价预加载。它通过 `.secrets/xhsmedium_scm_token`只读获取指定完整 SHA，不读取服务器已有的其他 XHSMedium 工作目录；三个依赖 Stage 和全部测试运行仍在 Docker 中。该环境设置 `PAPER_SERVER_RESOURCE_MODE=true`，所以两小时 Timer Trigger 不会在重型 profile 停止时排队，固定 SHA 验收由管理员在 Regression profile 活跃期间手工触发。

Regression Agent 为准备 sealed plan 执行的三个 `npm ci`复用 CI 的有界网络重试器：只识别 `ECONNRESET`、`ETIMEDOUT`、`EAI_AGAIN`、`ENETUNREACH`、`ECONNREFUSED`和`ERR_SOCKET_TIMEOUT`，最多三次、延迟 2 秒和 4 秒。测试、automation build 和确定性依赖错误不重试，最终原始状态保持不变。

## 失败与精确清理

automation 自身的 `clean`完成后，Jenkins post 仍会对固定 Compose project 执行 `down --volumes --remove-orphans`。人工中断可能与 `docker compose run --rm`创建 one-off 容器并发，因此平台还会按精确 `com.docker.compose.project`标签重试移除该 project 的容器、卷和网络；连续三次观察为空才输出 `P4_EXACT_PROJECT_CLEANUP_OK`。辅助脚本只接受 `xhsmedium-test-scheduled-*`，禁止全局 prune，未收敛时让 post 失败。

可重复验收命令：

```powershell
.\scripts\test-xhsmedium-regression-resilience.ps1 `
  -FailureBuildNumber 9 `
  -TimeoutBuildNumber 10 `
  -InterruptionBuildNumber 12
```

当前韧性证据：构建 9 正确记录业务测试失败且 cleanup succeeded；构建 10 因验证超时为 `ABORTED`；构建 12 由管理员中断为 `ABORTED`，并在出现 one-off 创建竞态后由精确 helper 收敛到零残留。三者均未输出成功 marker，Workspace、npm cache 和兼容脚本也已清零。

## P4 完成证据

构建 19 对固定 SHA `b846dcd0771f3fdb81db9ae9c0e9f034d532d36e`完成真实离线回归，Jenkins 结果为 `SUCCESS`，runId 为 `scheduled-20260803-040000-b846dcd0`。11 个 Stage 全部 `PASSED`，Requirement 为 2 covered、0 partial、0 blocked，`firstFailure=null`，automation 用时 161859 ms，cleanup succeeded；Jenkins 总用时 274281 ms。归档的 `offline-dependency-cache.log`同时证明 runner、backend、frontend 使用该完整 SHA 的预加载缓存。官方验收确认精确 Compose project、Workspace、npm cache、MySQL 兼容脚本、runner 入口脚本和 cleanup helper 均无残留。

构建 13、14、15、16 分别在 UTC 20:00、22:00、00:00、02:00 由 `hudson.triggers.TimerTrigger$TimerTriggerCause`启动，证明 `0 */2 * * *`每两小时真实触发。TimerTriggerCause 与构建 19 的真实 PASSED 共同完成定时触发和业务成功验收。

## 安全边界

- 数据库名由 automation 生成，必须匹配 `xhsmedium_test_*`。
- Compose project、runId、数据库和卷按运行唯一隔离。
- 不调用共享数据库、真实浏览器 Profile、爬虫、FTP、飞书、OSS 或部署环境。
- 不执行 `docker system prune`；cleanup 仅作用于本次精确 Compose project。
- `interrupted`、`timeout`、cleanup 失败和 Requirement 缺口不得报告为通过。
