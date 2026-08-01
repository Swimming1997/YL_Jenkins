# XHSMedium 接入勘察

- 勘察日期：2026-08-01
- 仓库：`https://github.com/MuFannnn/xhsmedium.git`
- 默认分支：`dev`
- 勘察 SHA：`1ac17fb695a8099fe01e0cd9311b6f272c23a491`
- 操作方式：浅克隆后只读检查；未安装依赖、未运行测试、未修改仓库；本地参考副本的 `origin` push URL 已设为 `DISABLED`

## 仓库约束

仓库根目录的 `AGENTS.md`声明 XHSMedium 处于安全冻结状态。冻结解除前禁止推送、打标签、创建 PR、发布制品和部署。`automation/`是唯一的测试编排、Catalog、Planner、Executor 和证据管道；Jenkins 不得创建第二套 Runner 或 Coverage 格式。

真实数据库、浏览器 Profile、爬虫、OSS、FTP 和飞书需要针对精确目标单独授权。用户已允许后续评估 FTP 和飞书，但当前没有目标地址、数据范围和凭据，因此 P0 不调用这些系统。

## 运行基线

- 根项目、backend、frontend、automation：Node.js `>=20`、npm `>=10`
- regression：Node.js `>=20`、npm `>=10`
- 根项目及四个子项目均存在 `package-lock.json`，CI 可使用 `npm ci`
- Docker 回归使用 MySQL 8.4、backend、frontend 和 runner 容器
- 隔离数据库必须匹配 `xhsmedium_test_*`并使用唯一 Compose project、卷和 runId

## 建议 CI 命令

| 模块 | 安装 | 只读验证命令 | 备注 |
|---|---|---|---|
| backend | `npm ci` | `npm test -- --runInBand`、`npm run build` | 当前 `lint`包含 `--fix`，不能直接用于只读 CI |
| frontend | `npm ci` | `npm run lint`、`npm test`、`npm run build` | `lint`实际执行 `tsc --noEmit` |
| automation | `npm ci` | `npm test`、`npm run validate` | 两个命令都会先构建，可在后续优化重复编译 |
| regression | `npm ci` | `npm test` | 依赖 `better-sqlite3`，Linux Agent 需验证原生模块安装 |

根项目没有统一测试脚本，不应使用根目录 `npm test`作为 CI 入口。

## 定时回归入口

现有正式入口：

```text
regression/Jenkinsfile
→ node regression/src/scheduled-entry.js --branch dev --build-number <number>
→ 固定远端SHA并创建detached worktree
→ automation生成scheduled-regression Docker sealed plan
→ run --plan执行
→ 验证Requirement证据并finally清理worktree和租约
```

现有 Jenkinsfile 使用 `powershell`步骤，但 `scheduled-entry.js`和 `fixed-sha-runner.js`已处理 Windows/Linux 的命令差异。Linux Agent 接入时可将薄 Jenkinsfile 调用调整为 `sh`，不需要重写调度器。

## 接入阻塞与风险

1. backend 缺少不修改文件的 `lint:check`脚本，正式 CI 前应在业务仓库增加。
2. P0 没有修改 XHSMedium；Linux 命令、依赖安装和 Docker 回归仍需在 P3/P4 通过容器实测。
3. 回归 Docker Compose 使用 `docker.m.daocloud.io/library/mysql:8.4`，云端必须确认该镜像源的网络与供应链策略。
4. runner 当前 bind mount 整个工作区，P4 需验证权限、产物路径和中断后的精确清理。
5. Jenkins Controller 不应直接运行 XHSMedium 代码；所有业务命令必须进入隔离 Agent。
6. 安全冻结解除前，CI 和回归不得推送制品、调用真实 FTP/飞书或部署环境。

## P3/P4 前置结论

- Linux Agent 路线可行，但仍需运行验证。
- SCM 首期可匿名只读访问公开 GitHub 仓库；Webhook 需等待 Jenkins 平台远程仓库和入口确定。
- Jenkins 应复用项目现有 sealed plan、Requirement 证据和 cleanup 语义。
- 正式 CI 必须固定检出 SHA，并确保 Fork/PR 不获得高权限 Docker 或外部系统凭据。
