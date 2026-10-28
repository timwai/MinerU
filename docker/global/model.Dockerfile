# MinerU VLM model service for split deployment.
#
# The service exposes the model through OpenAI-compatible /v1/models and
# /v1/chat/completions endpoints. It does not download the Hybrid small-model
# bundle used by the parsing service.
FROM vllm/vllm-openai:v0.21.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        libgl1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mineru
COPY . /opt/mineru

# Reuse vLLM from the base image and install MinerU's VLM adapter/runtime.
RUN python3 -m pip install -U '.[torch]' --break-system-packages && \
    python3 -m pip cache purge

ENV MINERU_MODEL_SOURCE=local \
    MINERU_MODEL_VLM_ENGINE=vllm

# Download only the VLM weights; the parser-side ONNX bundle lives in the
# service image instead.
RUN mineru-kit models download MinerU2.5-Pro-2605-1.2B --source huggingface

EXPOSE 30000

ENTRYPOINT ["mineru-kit"]
CMD ["vlm-server", "--engine", "vllm", "--host", "0.0.0.0", "--port", "30000"]
