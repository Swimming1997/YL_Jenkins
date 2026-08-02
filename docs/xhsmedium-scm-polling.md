# XHSMedium 每小时拉新

`XHSMedium/CI/watch-dev` 每小时在 Jenkins 哈希分钟执行一次，只通过固定只读凭据查询 `dev` 的远端 SHA。它不 Checkout 完整仓库，也不运行 npm。

```text
每小时 git ls-remote dev
→ SHA 与最近一次已观察值相同：记录 SCM_NO_CHANGE 后结束
→ SHA 变化：以 BRANCH=dev、GIT_SHA=<完整 SHA> 异步触发 XHSMedium/CI/read-only
```

首次运行使用 P3A 成功构建 16 的 SHA `1ac17fb695a8099fe01e0cd9311b6f272c23a491` 作为基线。以后每次 watcher build 的 description 持久记录最近已观察 SHA。一个 SHA 无论 CI 成功或失败都只自动触发一次；同一 SHA 的重跑由人员手工触发。

轮询 Job 使用 `H * * * *`，即每小时一次、具体分钟由 Jenkins 哈希分散。多个提交发生在两个周期之间时只触发最新 SHA。CI 占用唯一 Build Agent 时，watcher 会排队，并在 Agent 可用后检查当时最新 SHA。

该模式只需要 Jenkins 主动访问 GitHub，不要求公网地址、Webhook、Tunnel 或第三方 Relay。未来迁移云服务器后可以继续使用相同模式。

验证：

```powershell
.\scripts\test-xhsmedium-watcher.ps1
.\scripts\test-xhsmedium-watcher.ps1 -TestChangeTrigger
```

默认脚本连续运行两次 watcher，在远端 SHA 未变化时证明不会增加完整 CI 的 next build number。`-TestChangeTrigger` 会临时把上一条 watcher build description 改为合成旧 SHA，证明下一次 watcher 恰好触发一次完整 CI，然后恢复历史描述；它不修改 GitHub 仓库。两种模式都检查 Workspace 与 AskPass 清理。
