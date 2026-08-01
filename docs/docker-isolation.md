# Docker 隔离

Regression Agent 不挂载 `/var/run/docker.sock`。它通过内部网络和 TLS 连接 `regression-docker`服务：

```text
Regression Agent
  DOCKER_HOST=tcp://regression-docker:2376
  DOCKER_TLS_VERIFY=1
  DOCKER_CERT_PATH=/certs/client
```

`regression-docker`是本地 P2 唯一的 privileged 容器。它不加入 Controller 的 control 网络，不发布宿主机端口，并使用独立证书和数据卷。Build Agent 只加入 control 网络，既没有 Docker CLI，也无法解析或连接 DIND 服务。

所有测试容器、网络和卷必须使用唯一 runId 或 Compose project。清理只能执行精确的 `docker compose -p <project> down --volumes --remove-orphans`或删除明确的资源名称，禁止 `docker system prune`等全局清理。

云服务器部署时优先用专用 Agent 主机、短生命周期虚拟机或隔离 BuildKit 替代 privileged DIND。
