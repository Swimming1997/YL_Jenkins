# XHSMedium 候选制品与 Release

P5 使用独立 `release-agent`和专用 TLS `release-docker`构建 XHSMedium backend、frontend 候选镜像。Release Agent 不挂载宿主机 Docker Socket，不持有持久 Registry 密码，只在受限 Stage 中通过 Jenkins Credentials 注入认证。

## 本地拓扑

```text
Jenkins Controller
  → Release Agent
    → TLS Release DIND
      → Basic Auth Registry（registry:5000）

宿主机验收入口：http://127.0.0.1:5000
```

本地 Registry 使用固定 digest 的 `registry:2.8.3`，数据和 htpasswd 分别存放在命名卷。宿主机端口只绑定 localhost；Build Agent 和 Regression Agent 无法解析 Registry。为了在本地内部网络模拟，Release DIND 只对 `registry:5000`启用 insecure-registry。该 HTTP 例外禁止复制到云服务器。

## 候选制品

`XHSMedium/Release/candidate`必须接收完整 Git SHA、同 SHA 的成功 CI Build Number 和成功 Regression Build Number。准入通过后固定检出 SHA，并构建：

```text
registry:5000/xhsmedium/backend:git-<40位SHA>
registry:5000/xhsmedium/frontend:git-<40位SHA>
```

Pipeline 在镜像中写入 `org.opencontainers.image.revision`和 `org.opencontainers.image.source`标签。完整 SHA 标签只允许首次创建；已存在时在任何 build 之前失败。成功后归档 `candidate-manifest.json`，其中包含 Git SHA、CI/回归构建号、Registry digest 和可直接交给未来 Deploy 的 `repository@sha256:...`引用。

如果首次候选在两个镜像均已 Push 后、归档 manifest 前失败，只能显式填写 `RECOVER_FROM_FAILED_BUILD`接管。恢复路径通过只读 Jenkins API 验证原构建为 `FAILURE`且 branch、SHA、CI 和回归构建号完全一致；随后要求两个完整 SHA 标签同时存在，并核对两个镜像的 revision、source 和 RepoDigest。恢复路径不 checkout、不执行 Docker build 或 Push，并在 manifest 中写入 `recoveredFromFailedBuild`。缺少任一镜像、元数据不符或普通重复 SHA 都会失败。

## Release 批准

`XHSMedium/Release/approve`只读取成功候选的 manifest，按 digest 拉取并重新验证 revision 标签，然后归档 `approved-release-manifest.json`。批准过程禁止 Docker build、重新打标签和部署；P6 必须直接使用批准 manifest 内的 digest。

## 本地启动与验证

```powershell
.\scripts\generate-secrets.ps1
.\scripts\generate-agent-keys.ps1
docker compose up -d --build registry release-docker release-agent
docker compose up -d --force-recreate controller
.\scripts\test-xhsmedium-release.ps1
```

本地 P5 验收使用固定 SHA `b846dcd0771f3fdb81db9ae9c0e9f034d532d36e`：CI 构建 18、回归构建 19、原失败候选构建 3、无重建恢复候选构建 4、重复 SHA 拒绝构建 5、Release 批准构建 2。恢复候选和批准均为 `SUCCESS`，重复候选为预期 `FAILURE`；最终 digest 为：

```text
backend  sha256:e4a0f2c302d9e2be3a758c865775d70f08b107371fd0d310e7b8ec6b2143f2c2
frontend sha256:42b094476292029db5293a04b2ddf810594e234179cc8e677b239c5e04c3f1b3
```

复核既有证据且不创建新构建：

```powershell
.\scripts\test-xhsmedium-release.ps1 `
  -RecoveryFromFailedBuild 3 `
  -ExistingCandidateBuild 4 `
  -ExistingDuplicateBuild 5 `
  -ExistingApprovalBuild 2
```

Registry 数据是 P5 的持久制品，不属于临时 cleanup。Release DIND 中的本地标签、Docker 登录配置和 Jenkins Workspace 必须在每个 Build 后清理。不得运行 Registry 全局删除或垃圾回收来绕过不可变标签门禁。
