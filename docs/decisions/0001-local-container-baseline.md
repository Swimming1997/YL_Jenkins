# ADR-0001：本地容器化开发基线

- 状态：已接受（G0/P0）
- 日期：2026-08-01
- 适用范围：本地开发环境；云服务器方案需在部署前复审

## 背景

Jenkins 平台未来部署到云服务器，当前先在 Windows 主机的 Docker Desktop Linux 引擎中模拟。用户要求运行环境全部进入 Docker，不在本机安装 Jenkins 或项目运行依赖。Jenkins 平台暂时没有远程 Git 仓库，XHSMedium 位于 `https://github.com/MuFannnn/xhsmedium.git`。

## 决策

1. Controller 使用 Jenkins `2.568.1-jdk21`，同时锁定官方镜像 digest。
2. Controller 以非 root 的镜像默认用户运行，不挂载 Docker Socket。
3. HTTP 端口在 P0 仅绑定 `127.0.0.1`，不对局域网公开。
4. Jenkins Home 使用独立 named volume；删除容器不等于删除数据。
5. 插件及传递依赖使用明确版本，并在镜像构建阶段安装。
6. Agent 默认采用 Linux。XHSMedium 的调度入口由 Node.js 实现，现有 Jenkinsfile 的 PowerShell 调用可在后续改为 Linux `sh` 薄适配。
7. 平台工程使用独立 Git 根目录，不在 `C:\Users\Administrator` 的外层仓库中暂存或提交。
8. P0 保留 Jenkins Setup Wizard；JCasC、正式身份认证和 RBAC 在 P1 实现。
9. FTP 和飞书属于允许评估的后续集成，但没有精确目标、用途和凭据前不调用。

## 临时恢复目标

本地开发阶段采用以下临时目标：

- RPO：24小时。进入持续配置开发后，每日至少备份一次 Jenkins Home 关键数据。
- RTO：4小时。应能在全新 Docker 主机上重建镜像、恢复数据并完成健康验证。

云服务器的正式 RPO/RTO、备份介质、加密、异地副本和责任人必须在部署前重新审批，不能直接沿用本地临时值。

## 已知约束

- 当前 Jenkins 平台没有远程仓库，因此暂不配置 Webhook。
- 本地使用 HTTP，只能监听 localhost；云端必须配置 HTTPS 和反向代理。
- P0 只验证 Controller 可重复构建和启动，不创建业务 Job、Agent 或真实凭据。
- Docker Desktop 是本地模拟设施，不代表最终云端运行形态。

## 后续门禁

- P1：JCasC、认证、RBAC、Folder、Job DSL 和配置恢复。
- P2：隔离 Agent 与经评审的 Docker 构建方式，禁止不可信 PR 访问宿主机 Socket。
- P3：平台远程仓库、GitHub Webhook、XHSMedium 薄 Jenkinsfile 与 CI。
- P4：固定 SHA 定时回归、Requirement 证据和精确 cleanup。
- P5 以后：安全冻结解除、镜像仓库、FTP/飞书精确目标及部署授权。

