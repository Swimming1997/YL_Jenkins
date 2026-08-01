# XHSMedium 只读 CI

`XHSMedium/CI/read-only` 是 P3A 试点作业。它只从固定的私有仓库读取源码，在隔离 Build Agent 中验证项目，不修改业务仓库、不发布制品、不部署，也不连接数据库或业务外部系统。

## 参数与源码身份

- `BRANCH` 默认是 `dev`，只接受安全的 Git 分支名称。
- `GIT_SHA` 可留空；非空时必须是完整的 40 位十六进制 SHA。
- 仓库 URL 固定为 `https://github.com/MuFannnn/xhsmedium.git`，不能通过构建参数覆盖。
- Jenkins 凭据 `xhsmedium-scm-readonly` 读取 `.secrets/xhsmedium_scm_token` 对应的 Docker Secret。Token 必须只授权该仓库的 `Contents: Read-only`。
- 未指定 SHA 时，作业先通过 `git ls-remote` 将分支解析为 SHA，再按该 SHA Checkout。构建日志和 `ci-evidence/build-metadata.txt` 都记录最终身份。

解析阶段通过 `/tmp` 中按 Jenkins `BUILD_TAG` 唯一命名、脚本内容不含密钥的临时 `GIT_ASKPASS` 包装读取 Jenkins 注入的环境变量；包装在 `finally` 和 `post` 中清理，随后退出凭据作用域。项目源码和 npm 命令不会获得 Token，日志及归档也不得包含 Token。

这是手工试点作业。P3A 不配置 Webhook、Multibranch Pipeline 或 GitHub 状态回写。

## 执行内容

作业使用 `xhsmedium-build` 标签并依次运行：

```text
backend:   npm ci → npm test -- --runInBand → npm run build
frontend:  npm ci → npm run lint → npm test → npm run build
automation: npm ci → npm test → npm run validate
regression: npm ci → npm test
```

所有 npm 依赖均安装在容器内的临时 Workspace。作业禁止并发，后一次手工触发会取消仍在运行的前一次构建；全局超时为 45 分钟。无论成功、失败或超时，证据归档后都会删除 Workspace。

Build Agent Workspace tmpfs 允许执行 Jenkins Git 包装及 `node_modules/.bin`，但仍保留 `nosuid`、`nodev`、`no-new-privileges`、能力裁剪和无 Docker/宿主机挂载边界。

CI 在不提高 Build Agent 1 GiB 容器内存上限的情况下按模块限制 Node heap：backend 为 704 MiB，frontend、automation 和 regression 为 512 MiB。模块保持串行，避免 Node 与 Jenkins Agent JVM 共同触发 cgroup OOM。

backend 的 `npm run lint` 当前包含 `--fix`，因此被明确排除。构建控制台和元数据会报告该质量缺口；在 XHSMedium 增加只读 `lint:check` 前，不能把该缺口解释为已通过。

## 证据与边界

成功构建归档：

- 固定仓库、分支、SHA、Jenkins 构建编号和时间身份；
- backend Jest JSON；
- backend、frontend、automation、regression 命令日志。

这些内容仅证明对应 SHA 通过首期 CI 检查，不是 Release 制品。除限定仓库的只读 SCM 凭据外，作业不含或持有 Docker、数据库、FTP、飞书、OSS、浏览器 Profile、发布或部署操作及其凭据。

## 验证

平台配置加载后执行：

```powershell
.\scripts\test-xhsmedium-ci.ps1 -Branch dev
```

脚本会触发一次真实构建，检查执行节点、完整 SHA、归档证据、Controller executor 和 Workspace 清理。如果业务仓库已有检查失败，脚本保留 Jenkins 构建链接和第一处可识别失败，不修改业务代码。
