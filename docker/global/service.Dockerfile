# MinerU parsing service image for split deployment.
#
# This image intentionally contains only the lightweight Hybrid small-model
# bundle. The heavyweight VLM is reached through an OpenAI-compatible HTTP
# endpoint configured with MINERU_MODEL_VLM_SERVER_URL.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        libgl1 \
        libglib2.0-0 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mineru
COPY . /opt/mineru

RUN python -m pip install --upgrade pip && \
    python -m pip install .

# The parsing service keeps layout/OCR/MFR/table preprocessing local, but does
# not download the MinerU2.5 VLM weights.
ENV MINERU_MODEL_SOURCE=local \
    MINERU_MODEL_SMALL_BACKEND=onnx

RUN mineru-kit models download MinerU-4_models_onnx --source huggingface

EXPOSE 8000

ENTRYPOINT ["mineru-kit"]
CMD ["api-server", "--host", "0.0.0.0", "--port", "8000", "--tier", "standard", "--preload-models"]
