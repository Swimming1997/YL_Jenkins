# 运行残留治理方案

本文定义 Jenkins 平台在 CI、Regression、Release 和非生产部署运行后的残留分类、保留上限、清理顺序、水位门禁和后续开发任务。目标不是追求无条件清空，而是让临时资源归零、证据和缓存有界、持久数据受保护，并使每次删除都可定位、可验证、可审计。

## 治理原则

- 每个运行必须有唯一的 Build number、runId、Compose project、Workspace 和 Artifact 路径。
- 清理只能使用 runId、完整 SHA、Compose project 或专用 DIND 等精确边界；禁止宿主级 `docker system prune`、`docker volume prune`和共享 Compose 的 `down --volumes`。
- 先归档 `summary.json`、`coverage-map.json`、`first-failure.json`和首个有效失败，再删除运行资源。
- cleanup 失败、中断、超时或残留检查失败时，运行保持失败或基础设施失败，不得输出成功 marker。
- Langfuse、New API、业务数据库、Jenkins Home、Registry 和备份属于持久数据，不进入日常运行清理。

## 残留分类与保留矩阵

| 类别 | 典型对象 | 目标状态 | 保留策略 |
|---|---|---|---|
| 单次运行临时资源 | Compose 容器、网络、卷、one-off runner、测试数据库 | 每轮结束为 0 | `post`按精确 project 清理并连续三次观察为空 |
| Workspace 与临时文件 | Jenkins Workspace、npm cache、AskPass、Docker config、兼容脚本、预载源码和 tar | 每轮结束为 0 | 成功、失败、中断均在 `finally/post`删除并检查 |
| DIND 运行镜像 | `xhsmedium-test-scheduled-<runId>-*` | Artifact 归档后为 0 | 按精确 runId 删除；不得跨项目按模糊名称清理 |
| 依赖缓存 | `xhsmedium-deps-<sha>-{backend,frontend,runner}` | 有界保留 | 保留当前验收 SHA 和上一已验证 SHA；更旧 SHA 在无运行引用后删除 |
| 固定输入镜像 | 锁定 MySQL、Node、Playwright 镜像 | 按 digest 保留 | 只有锁定 digest 更新并完成新基线后才删除旧输入 |
| DIND BuildKit cache | 专用 Regression/Release/Deploy DIND 构建层 | 有界保留 | 目标不超过 4 GiB；超过 8 GiB或进入磁盘告警水位时清理专用 daemon cache |
| Jenkins 构建记录 | Console、result、description、duration | 有界保留 | 当前构建记录保留 20 条；明确 pin 的验收基线除外 |
| Jenkins Artifact | 结构化证据、日志、报告、截图 | 有界保留 | 目标保留最近 5 个完整 Artifact；更早构建保留 Console/结果元数据 |
| Playwright trace | `playwright*-report/data/*.zip` | 严格有界 | 仅保留最近 2 个仍需诊断的失败 trace，最长 7 天；结案后删除 trace，保留 JSON、日志和截图 |
| 持久平台/业务数据 | Jenkins Home、Registry、Postgres、ClickHouse、MinIO、备份 | 禁止日常删除 | 按各自备份、恢复和 Registry 保留政策治理 |

## 单次运行清理契约

每个重型 Job 的清理必须按以下顺序执行：

1. 结束业务写入并保存首个失败与 Requirement 证据。
2. 运行项目自身 cleanup，验证测试表或隔离数据库无业务残留。
3. 对精确 Compose project 执行 `down --volumes --remove-orphans`。
4. 按 `com.docker.compose.project`精确处理与 `run --rm`竞态产生的 one-off 容器。
5. 删除本轮 Workspace、npm cache、凭据包装、Docker config、兼容脚本和预载临时文件。
6. Artifact 归档成功后删除本轮 `xhsmedium-test-<runId>-*`镜像。
7. 连续三次检查本轮容器、卷、网络、Workspace 和临时目录均为空。
8. 记录 cleanup 的对象数量、释放字节数、剩余磁盘、是否成功及失败原因。

Job 只在业务 Stage 通过、Requirement 无 partial/blocked、cleanup 成功且残留检查为零时输出成功 marker。

## 磁盘水位与动作

| 可用磁盘 | 状态 | 必须动作 |
|---:|---|---|
| `>= 30 GiB` | 正常 | 允许一个重型 profile；执行每轮标准 cleanup |
| `25–30 GiB` | 预警 | 禁止并行重型任务；完成后审计 DIND、Artifact 和 cache 增量 |
| `20–25 GiB` | 严重 | 不启动新重型任务；先清理精确 run 镜像、过期 trace 和专用 DIND cache |
| `< 20 GiB` | 紧急 | 保持所有重型 profile 停止；只执行有清单的精确清理并升级处理 |

内存仍要求至少 4 GiB available。磁盘与内存任一不满足时，排队或拒绝启动不属于测试失败，也不得生成虚假 Coverage。

## 定期审计与清理顺序

审计至少在重型 profile 启动前、停止后以及每日维护窗口执行一次，记录：

- `df -h /`与 inode 水位；
- 宿主 Docker Images、Volumes、Build Cache 的总量与可回收量；
- 每个专用 DIND 的镜像、BuildKit cache 和运行容器；
- Jenkins Home、各 Job 和各 Build Artifact 的大小；
- 最大 Artifact/trace 文件及其 Build、runId 和 SHA；
- Jenkins 队列、重型 profile 和已 pin 基线状态。

清理按风险从低到高执行：

1. 已归档运行的精确 run 镜像和临时文件；
2. 超出保留策略的失败 trace；
3. 超出 SHA 窗口的依赖缓存；
4. 专用 DIND BuildKit cache；
5. Jenkins Job 自身 build/artifact discarder；
6. 宿主共享镜像、卷、Registry 或数据库只能另行形成清单并获得专项授权。

不得为了回收空间删除当前验收 SHA 缓存、唯一成功基线、尚未归档的失败证据或任何其他项目的数据。

## 清理证据

自动或人工清理均应输出一条结构化摘要，至少包含：

```text
RESIDUE_CLEANUP_EVIDENCE scope=<job/runId/dind> removed_images=<n> removed_traces=<n> reclaimed_bytes=<n> disk_available_bytes=<n> residue=0 status=OK
```

证据不得包含 Token、Cookie、密码、连接串或真实业务数据。删除前后的对象清单和大小只记录资源名称、runId、SHA、Build number 与字节数。

## 开发实施计划

### RRM-D1：治理契约与手册

- 状态：本文档落地后完成。
- 输出：分类、保留矩阵、水位、禁止项、清理顺序和证据格式。
- 验证：文档入口一致，现有安全边界无冲突。

### RRM-D2：每轮运行镜像自动清理

- 状态：实现完成，待固定 SHA 的 paper-server 全量回归验收。
- 范围：Regression Job、精确 cleanup helper、静态验证与成功/失败/中断测试。
- 结果：Artifact 归档后删除本轮精确 `xhsmedium-test-<runId>-*`镜像；保留固定输入与允许窗口内的依赖缓存。
- 门禁：合法项目在镜像尚未生成时允许空集合并输出 `removed_images=0`；候选镜像超出三种允许角色时删除前失败关闭；不得调用全局 prune。

### RRM-D3：专用 DIND 维护任务

- 状态：待开发。
- 范围：只读审计脚本、管理员触发的维护 Job、专用 Regression/Release/Deploy DIND。
- 结果：报告并清理超限 BuildKit cache、旧 SHA 缓存和已结案 trace，输出结构化清理证据。
- 门禁：Jenkins 队列为空、对应 profile 无运行 Job、保留清单已生成且持久数据不在作用域。

### RRM-D4：保留策略与水位门禁

- 状态：待开发。
- 范围：Job DSL build/artifact discarder、重型 Job 启动前检查、验证脚本和告警文档。
- 结果：构建记录 20、完整 Artifact 5、失败 trace 2/7 天；低于 25 GiB 告警，低于 20 GiB拒绝重型任务。
- 验证：模拟水位、过期 Artifact、失败/中断 cleanup 和 Agent 重连后，均不误删当前或其他项目资源。

## 2026-08-05 paper-server 基线记录

本次人工治理将可用磁盘从约 20 GiB恢复到约 34 GiB：删除专用 Regression DIND 中 32 个历史运行/旧缓存镜像、清空其 BuildKit cache，并删除构建 5–12 的 18 个已结案 Playwright trace（约 1.12 GB）。最终 SHA `b48c1e8f98df9a085452d8746cba024d8e263fea`的三类依赖缓存、固定输入镜像、构建 13 的成功证据、失败日志、JSON 和截图均保留；Langfuse、New API、数据库和 Registry 未进入清理范围。
