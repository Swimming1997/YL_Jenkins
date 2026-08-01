# 认证与授权

P1 使用 Jenkins 本地用户数据库，只用于 Docker 开发环境。Signup、匿名读取、Remember Me 和 Setup Wizard 均关闭。

## 本地账户

| 账户 | 用途 | 权限 |
|---|---|---|
| `admin` | 本地平台管理 | `Overall/Administer` |
| `audit` | 权限验收和只读审计 | 查看平台、View 和 Job，不能配置或构建 |

密码由 `scripts/generate-secrets.ps1`随机生成，存放在 `.secrets/`。Compose 将文件挂载为 Docker Secret，JCasC 通过 `readFile`读取。密码不进入镜像、环境变量或 Git。

## 角色定义

| 角色 | 匹配范围 | 计划能力 |
|---|---|---|
| developers | `XHSMedium/CI` | 查看、构建、取消、Workspace |
| test-leads | `XHSMedium/CI`和`Regression` | 查看、构建、取消、Workspace |
| release-managers | `XHSMedium/Release` | 查看、构建、取消 |
| operations | `XHSMedium/Deploy`和`Operations` | 查看、构建、取消 |

这些角色在 P1 仅绑定未来身份组名称，没有创建对应本地业务账户，也没有获得真实环境凭据。云端部署时应接入 LDAP/OIDC，并将企业组映射到这些角色。

## 验证

`scripts/test-authorization.ps1`验证匿名、管理员和审计账户。脚本只在内存中创建 Basic Authorization Header，不打印密码。

