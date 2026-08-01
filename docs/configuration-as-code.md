# 配置即代码

Jenkins Controller 启动时从 `jcasc/`加载配置。该目录以只读方式挂载到 `/var/jenkins_home/casc_configs`，并由 `CASC_JENKINS_CONFIG`指定。

## 配置分层

- `jenkins.yaml`：Controller 执行器、入站端口、URL 和基础安全设置
- `security.yaml`：本地开发账户，从 Docker Secret 文件读取密码
- `authorization.yaml`：全局角色和 XHSMedium Folder 角色
- `jobs.yaml`：Job DSL 入口和全局 SCM Shared Library
- `jobs/folders.groovy`：平台与 XHSMedium Folder
- `jobs/seed.groovy`：Seed 占位 Job 和 Shared Library 验证 Pipeline

配置文件互为补充，不应在多个文件中配置同一个叶子属性。JCasC 加载失败会阻止 Jenkins 完成启动。

## Shared Library

全局 Library 名称为 `jenkins-platform-library`，从以下公开仓库的 `main`分支读取：

```text
https://github.com/Swimming1997/YL_Jenkins.git
```

Library 根目录设置为 `shared-library`。验证任务 `Platform/Validation/shared-library-smoke`使用 `agent none`加载 Library 并调用 `platformIdentity()`，不会在 Controller 上执行项目构建。

## 修改流程

1. 修改 JCasC、Job DSL 或 Shared Library。
2. 执行 `scripts/validate.ps1`。
3. 审查 Git diff，确保没有 Secret。
4. 提交并推送 Shared Library 后再运行 SCM 加载验证。
5. 重建或重启 Controller，执行运行时和权限验证。

