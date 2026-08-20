# Bahulam model screening — Railway image.
# Runs the swe-bench harness against a 30-instance screen set.
# No Docker inside — Docker eval happens later on VM1.
#
# Env required at runtime:
#   B0_TOKEN                       Bahulam CLI token (b0_...)
#   CANDIDATE_MODEL                model slug e.g. openai/gpt-5.6-sol
# Env optional:
#   BAHULAM_GATEWAY_URL            default https://gateway.bahulam.ai/v1
#   BAHULAM_CODE_VERSION           default latest
#   HARNESS_TIMEOUT_S              default 600
#   HARNESS_PARALLEL               default 3
#   OUTPUT_DIR                     default /data/screen-<model>-<yyyymmdd-hhmm>
#   UPLOAD_ON_DONE                 default 0; if 1, tarballs /data and uploads to $UPLOAD_URL

FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_VERSION=22 \
    BAHULAM_CODE_VERSION=latest \
    HARNESS_TIMEOUT_S=600 \
    HARNESS_PARALLEL=3

# --- OS deps: git for repo clones, curl+nodejs for the CLI, jq for one-liners ---
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        git curl ca-certificates jq gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Python deps: datasets + swe-bench-harness for instance fetching ---
RUN pip install --no-cache-dir --quiet \
        datasets \
        pyyaml \
        swebench \
    && rm -rf /root/.cache/pip

# --- Bahulam CLI + Linux runtime (installed as a plain npm package tree
#     so the harness scripts can `node src/terminal/main.mjs` against it) ---
WORKDIR /opt/bahulam-cli
RUN npm pack "@bahulam/code@${BAHULAM_CODE_VERSION}" \
        --pack-destination /tmp \
    && tar xzf /tmp/bahulam-code-*.tgz --strip-components=1 -C /opt/bahulam-cli \
    && npm install --no-save --omit=optional "@bahulam/runtime-linux-x64@${BAHULAM_CODE_VERSION}" \
    && rm /tmp/bahulam-code-*.tgz

# --- Copy harness + benchmark scripts into the CLI tree so screen.py can
#     invoke the standard swe-bench/harness.py entrypoint. The harness
#     scripts live in the git repo, not the npm package. Railway builds
#     mount them via COPY. ---
COPY vendor/benchmark/  /opt/bahulam-cli/benchmark/
COPY vendor/scripts/    /opt/bahulam-cli/scripts/

# --- Screen script + configs ---
COPY screen.py          /opt/screen/screen.py
COPY configs/           /opt/screen/configs/
COPY scripts/entrypoint.sh /opt/screen/entrypoint.sh
RUN chmod +x /opt/screen/entrypoint.sh

WORKDIR /opt/screen

ENV BAHULAM_CLI_DIR=/opt/bahulam-cli \
    BAHULAM_RUNTIME_MODE=bundled \
    LLM_GATEWAY=BahulamGateway

# Railway persistent volumes are mounted at /data
VOLUME ["/data"]

ENTRYPOINT ["/opt/screen/entrypoint.sh"]
