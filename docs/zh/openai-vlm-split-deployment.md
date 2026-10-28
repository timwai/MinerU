# MinerU 模型与解析服务分离部署

MinerU 4 的 `standard` 解析链路可以把重量级 VLM 从解析服务中拆出，并通过 OpenAI-compatible HTTP API 调用模型节点。解析节点只保留 Hybrid 前处理需要的轻量小模型（Layout / OCR / MFR / Table），不加载或下载 MinerU2.5 VLM 权重。

## 架构

```text
Client
  |
  v
MinerU API / parser node                    VLM / GPU node
:8000                                       :30000
  |                                            ^
  |  GET  /v1/models                           |
  +--------------------------------------------+
  |  POST /v1/chat/completions                 |
  +--------------------------------------------+

Local on parser node:
- PP-DocLayoutV2
- PaddleOCR
- FormulaNet
- Table models

Remote on model node:
- MinerU2.5-Pro-2605-1.2B
- vLLM (or another MinerU-compatible OpenAI serving backend)
```

## Docker Compose 一键启动

在仓库根目录执行：

```bash
docker compose -f docker/compose.split.yaml up -d --build
```

模型服务监听 `30000`，解析 API 监听 `8000`。解析容器会等待模型服务健康后启动，并在启动阶段预加载本地小模型以及远程 VLM 客户端。

检查服务：

```bash
curl http://127.0.0.1:30000/v1/models
curl http://127.0.0.1:8000/v1/health
```

停止：

```bash
docker compose -f docker/compose.split.yaml down
```

如需选择 GPU：

```bash
MINERU_GPU_ID=1 docker compose -f docker/compose.split.yaml up -d --build
```

## 两台机器独立部署

### 1. GPU 模型节点

模型节点只需要运行 VLM 服务：

```bash
export MINERU_MODEL_SOURCE=local
export MINERU_MODEL_VLM_ENGINE=vllm

mineru-kit models download MinerU2.5-Pro-2605-1.2B --source huggingface
mineru-kit vlm-server --engine vllm --host 0.0.0.0 --port 30000
```

服务对外提供 OpenAI-compatible 接口：

- `GET /v1/models`
- `POST /v1/chat/completions`

### 2. 解析节点

解析节点使用 ONNX 小模型，不需要 GPU，也不需要下载 VLM 权重：

```bash
export MINERU_MODEL_SOURCE=local
export MINERU_MODEL_SMALL_BACKEND=onnx
export MINERU_MODEL_VLM_SERVER_URL=http://MODEL_HOST:30000/v1

mineru-kit models download MinerU-4_models_onnx --source huggingface
mineru-kit api-server \
  --host 0.0.0.0 \
  --port 8000 \
  --tier standard \
  --preload-models
```

`MODEL_HOST` 替换为模型服务器 IP 或域名。

## OpenAI-compatible 服务配置

MinerU 的远程 VLM 客户端支持以下配置：

```yaml
model:
  small_backend: onnx
  vlm:
    server_url: http://MODEL_HOST:30000/v1
    api_key: ""
    model: ""
    http_timeout: 600
    max_concurrency: 100
```

也可以全部通过环境变量设置：

```bash
export MINERU_MODEL_SMALL_BACKEND=onnx
export MINERU_MODEL_VLM_SERVER_URL=http://MODEL_HOST:30000/v1
export MINERU_MODEL_VLM_API_KEY=your-api-key
export MINERU_MODEL_VLM_MODEL=your-served-model-name
export MINERU_MODEL_VLM_HTTP_TIMEOUT=600
export MINERU_MODEL_VLM_MAX_CONCURRENCY=100
```

当 `MINERU_MODEL_VLM_MODEL` 为空时，MinerU 会调用 `/v1/models` 自动发现模型；自动发现要求上游只返回一个可用模型。如果上游返回多个模型，请显式设置模型名。

如果上游没有实现 `/v1/models`，必须显式设置 `MINERU_MODEL_VLM_MODEL`。显式模型名存在时 MinerU 会直接调用 `/v1/chat/completions`，不会请求或校验 `/v1/models`：

```bash
export MINERU_MODEL_VLM_SERVER_URL=https://example.com/v1
export MINERU_MODEL_VLM_MODEL=MinerU2.5-Pro-2605-1.2B
export MINERU_MODEL_VLM_API_KEY=your-api-key
```

设置 `MINERU_MODEL_VLM_API_KEY` 后，解析服务会使用标准 Bearer 认证：

```http
Authorization: Bearer <api-key>
```

## 对上游 OpenAI 接口的要求

上游并不是任意文本大模型都可以替代。服务必须托管 MinerU2.5 VLM 或与其输入输出行为兼容的模型，并支持 MinerU 所需的多模态 Chat Completions 请求。推荐使用仓库自带的：

```bash
mineru-kit vlm-server
```

它会处理 MinerU 对 vLLM / llama.cpp / LMDeploy / MLX 的适配，并提供统一的 OpenAI-compatible 接口。

## 分离边界说明

本方案把最重的 MinerU2.5 VLM 和 GPU 推理从解析进程中完全移出，因此：

- 解析节点不占用 VLM 显存；
- 多个解析节点可以共享一个或多个 VLM 服务；
- VLM 节点可以独立扩容、升级和限流；
- 解析节点仍会运行 Layout、OCR、公式识别和表格识别的小模型。

这些小模型属于 Hybrid 解析流水线的结构化检测/识别阶段，它们的输入输出不是 OpenAI Chat Completions 语义。若要连这些模型也全部远程化，应增加专用的推理 RPC 协议或模型网关，而不建议把检测框、OCR 批次和表格张量强行伪装成 OpenAI Chat API。
