# P7 生产发布前置门禁

本文是 P7-G0-D1 的只读审计结果，用于决定生产发布能力能否开始实施。它不授权生产部署，不创建生产凭据，不把 paper-server 解释为生产服务器，也不允许当前 dev/test Job、DIND 或本地账户直接用于生产。

## 审计结论

G0～P6 已提供可重建 Jenkins、隔离 Agent、不可变 digest、Release Approval、dev/test 幂等部署、跨版本回滚、运行残留治理和本地恢复演练。这些能力可以作为 P7 的技术基线，但生产前置条件尚未关闭：生产目标和网络未确定，身份和双人审批没有真实主体，Registry 与 Secret 仍是受控测试实现，正式 RPO/RTO、通知、业务冒烟和数据回滚均未审批。

因此 P7 当前状态为`BLOCKED_BY_DECISIONS`。只能继续完成门禁决策和隔离设计；在所有阻断项取得明确授权与验收方案前，不得创建生产 Folder、生产 Deploy Agent、生产 Credential或生产 Job。

## 已有可复用基线

| 能力 | 当前证据 | P7 可复用边界 |
|---|---|---|
| 配置即代码 | JCasC、Job DSL、Shared Library和固定插件版本 | 生产配置仍需独立评审，不能直接启用占位角色 |
| 最小权限 Agent | Controller executor为0；Build Agent无Docker；重型Agent只连接专用TLS DIND | 生产Agent必须使用独立身份、网络和固定host key，不能复用dev/test Agent |
| 制品身份 | Release按完整SHA构建一次，Approval与Deploy使用Registry digest | 正式Registry启用后必须生成新的授权候选或受控迁移并复核digest |
| 非生产部署 | dev/test隔离、显式确认、健康检查、NOOP和跨digest回滚 | 仅证明机制，不代表生产数据、域名、证书或业务冒烟通过 |
| 审计证据 | Jenkins result、Console、Artifact、Approval Build和部署/回滚JSON | 仍缺可信企业操作者身份、外部审计归档与告警接收方 |
| 恢复与残留治理 | Jenkins Home隔离恢复、20/5保留、trace与专用DIND精确清理 | 正式备份介质、异地副本、Registry/数据库恢复和生产保留期需重新审批 |

## 门禁矩阵

| ID | 门禁 | 当前状态 | 关闭门禁所需决策与证据 |
|---|---|---|---|
| P7-G01 | 生产目标与网络边界 | 阻断 | 明确服务器/集群、地域、责任人、域名、VPN或云内网、防火墙、入口代理、数据盘和容量；确认所有平台与业务部署均在Docker内，禁止公网2375和宿主Docker Socket |
| P7-G02 | 企业身份与RBAC | 阻断 | 选择OIDC或LDAP，给出认证端点、组名和负责人；将developers、test-leads、release-managers、operations映射到真实组并验证匿名、离职、越权和管理员应急访问 |
| P7-G03 | 双人审批 | 阻断 | 明确申请人与批准人角色、是否允许自批、批准有效期、目标环境/digest绑定、撤销规则和紧急流程；必须由两个不同的企业身份形成不可篡改记录 |
| P7-G04 | 生产Deploy Agent | 阻断 | 明确Agent部署位置、短生命周期或固定节点、固定known_hosts、TLS Docker端点、网络白名单和资源上限；不得复用dev/test Agent、密钥或DIND数据 |
| P7-G05 | 正式Registry | 阻断 | 确认域名、可信HTTPS证书、Push与pull-only账号、CA安装、备份、容量、监控和证书续期；删除生产路径中的insecure Registry例外 |
| P7-G06 | Secret存储与轮换 | 阻断 | 选择云密钥系统、Vault或独立加密介质；定义生产数据库、JWT、加密键、Registry和Agent密钥的所有者、读取主体、轮换周期、吊销及泄漏响应 |
| P7-G07 | 备份恢复 | 阻断 | 审批Jenkins Home、Registry、数据库和部署状态的RPO/RTO、加密介质、异地副本、失败告警、恢复责任人和演练周期；完成全新主机恢复证据 |
| P7-G08 | 维护窗口与通知 | 阻断 | 明确变更时段、冻结窗口、批准超时、通知渠道、接收人、失败升级和外部系统测试目标；当前平台未授权调用FTP、飞书或其他真实通知系统 |
| P7-G09 | 数据迁移与业务冒烟 | 阻断 | 明确数据库迁移顺序、兼容窗口、备份点、失败回退、脱敏测试数据和关键业务冒烟；根HTTP健康检查不能替代业务验收 |
| P7-G10 | 审计、告警与保留 | 部分 | 审批生产日志/Artifact保留期、审计导出目标、时钟同步、磁盘/证书/Registry/Jenkins告警阈值和接收人；证明操作者、审批者、digest、环境和时间可关联 |
| P7-G11 | Jenkins故障隔离 | 部分 | 证明Controller、Registry或Agent故障不停止已运行生产服务；生产目标不得依赖Jenkins容器持续在线，回滚入口在Jenkins不可用时仍有受控应急方案 |

“部分”表示已有本地机制但没有生产决策或真实环境证据，不能视为通过。所有门禁都必须记录负责人、计划日期、决策结论和证据位置；不得用默认值代替业务、安全或运维负责人确认。

## 必须保持的安全不变量

- paper-server继续仅用于受控CI、回归、Release和非生产验收，不自动升级为生产目标。
- 服务器上的Jenkins、Agent、Registry、数据库、反向代理和业务服务必须运行在Docker中；宿主机只承担经审批的Docker、网络、存储和运维工具。
- Controller executor保持为0，Build Agent不能获得Docker CLI、生产网络或生产Credential。
- Release只构建一次；生产Deploy只接受已批准的不可变digest，不Checkout、不编译、不Push、不重新打标签。
- 生产Deploy Agent只能读取目标环境的最小Secret和Registry pull-only Credential，不能读取Push Credential或其他环境Secret。
- 不开放未认证Docker API，不挂载宿主Docker Socket，不使用全局prune，不跨项目删除卷、镜像、数据库或备份。
- 生产变更、数据迁移、外部通知、真实Secret写入和故障注入分别需要精确授权；测试授权不自动延伸到生产。

## 需要业务方和运维方提供的信息

只需提供标识、策略和目标，不应在文档或聊天中提交密码、Token、私钥或数据库连接串：

1. 生产目标名称、网络拓扑、域名和负责人。
2. OIDC/LDAP类型及四个业务组的正式名称。
3. 双人审批角色、不可自批规则和紧急审批责任人。
4. Registry域名、证书来源和Push/pull账号责任边界。
5. Secret系统、备份介质、RPO/RTO和恢复责任人。
6. 维护窗口、通知渠道、告警接收人和审计保留期。
7. 数据库迁移负责人、关键业务冒烟清单和回滚时限。

## 后续实施顺序

1. `P7-G0-D2 决策台账关闭`：填入上述决策、负责人、日期和证据，不改运行配置。
2. `P7.1 身份与审批隔离实现`：先在独立Docker验收环境实现OIDC/LDAP、生产角色和双人审批状态机，完成越权矩阵。
3. `P7.2 Registry、Secret与备份基础设施`：建立可信HTTPS、pull-only Credential、正式密钥系统和可恢复备份，先做独立smoke。
4. `P7.3 生产Agent与网络`：创建独立Deploy Agent连接和固定host identity，只验证连接、权限与隔离，不部署业务。
5. `P7.4 生产Deploy与Operations Job`：实现维护窗口、digest部署、业务冒烟、回滚、操作者证据、通知和白名单运维。
6. `P7.5 非生产等价演练`：在与生产拓扑等价但无真实数据的Docker环境完成成功、拒绝、超时、中断、回滚、Controller故障和零残留矩阵。
7. `P7.6 生产启用`：单独审批目标SHA/digest、窗口、操作者和回滚点后才能执行；不得由前序测试授权自动触发。

每个阶段都应先形成独立任务单，再分别授权代码修改、提交推送、基础设施变更和环境验收。
