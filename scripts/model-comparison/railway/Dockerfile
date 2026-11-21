# Model-comparison runner — Railway image.
# Inference only (produces patches); Docker eval happens later on VM1, same
# split as screening/Dockerfile and the local pipeline (see
# run-model-on-instance.sh).
#
# Env required at runtime:
#   B0_TOKEN               Bahulam CLI token (b0_...)
# Env optional:
#   BAHULAM_GATEWAY_URL    default https://gateway.bahulam.ai/v1
#   BAHULAM_CODE_VERSION   default 0.2.6-beta.3 (pin the beta track that has
#                          the turn-cap + tool-dedup fixes; "latest" on npm
#                          is 0.2.5 and does NOT have them)
#   CONCURRENCY            default 4
#   HARNESS_TIMEOUT_S      default 1700
#   BAHULAM_MAX_TURNS      default 999
#   SOURCE_REPO_URL        default https://github.com/pydata/xarray.git

FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_VERSION=22 \
    BAHULAM_CODE_VERSION=0.2.6-beta.3 \
    BAHULAM_CLI_DIR=/opt/bahulam-cli \
    BAHULAM_CODE_DIR=/opt/bahulam-cli \
    BAHULAM_RUNTIME_MODE=bundled \
    LLM_GATEWAY=BahulamGateway \
    DATA_DIR=/data

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        git curl ca-certificates jq perl \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@bahulam/code@${BAHULAM_CODE_VERSION}" \
    && ln -sfn "$(npm root -g)/@bahulam/code" /opt/bahulam-cli \
    && node /opt/bahulam-cli/src/terminal/main.mjs --version 2>&1 | head -3

# This directory is self-contained (bash scripts copied in from
# scripts/model-comparison/ alongside this run's frozen config) so
# `railway up` from here uploads a flat build context Railpack can see
# the Dockerfile in directly.
WORKDIR /opt/model-comparison

COPY run-model-on-instance.sh dispatch-batch.sh instance.json models.json supervisor.py ./
RUN chmod +x run-model-on-instance.sh dispatch-batch.sh

RUN mkdir -p /data

EXPOSE 8000
CMD ["python3", "/opt/model-comparison/supervisor.py"]
