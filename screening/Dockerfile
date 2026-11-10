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

# --- Bahulam CLI (global install so postinstall runs and drops the runtime
#     at /root/.bahulam/runtime/current/, which the CLI hardcodes).
#     Symlink /opt/bahulam-cli -> $(npm root -g)/@bahulam/code so the
#     vendored benchmark scripts (KEPLER_MAIN = /opt/bahulam-cli/src/
#     terminal/main.mjs) keep resolving. ---
RUN npm install -g "@bahulam/code@${BAHULAM_CODE_VERSION}" \
    && ln -sfn "$(npm root -g)/@bahulam/code" /opt/bahulam-cli \
    && ls -la /root/.bahulam/runtime/current/bin/ 2>&1 | head -5 \
    && node /opt/bahulam-cli/src/terminal/main.mjs --version 2>&1 | head -3

# --- Copy harness + benchmark scripts into the CLI tree so screen.py can
#     invoke the standard swe-bench/harness.py entrypoint. The harness
#     scripts live in the git repo, not the npm package. Vendored here for
#     reproducibility from this public repo. ---
COPY vendor/benchmark/  /opt/bahulam-cli/benchmark/

# --- Screen script + configs + benchmarks push ---
# CACHE_BUST 2026-08-22-1926 (bumps this line invalidates the COPY layer)
COPY screen.py                         /opt/screen/screen.py
COPY configs/                          /opt/screen/configs/
COPY scripts/entrypoint.sh             /opt/screen/entrypoint.sh
COPY scripts/push-to-benchmarks.sh     /opt/screen/push-to-benchmarks.sh
RUN chmod +x /opt/screen/entrypoint.sh /opt/screen/push-to-benchmarks.sh \
    && sha256sum /opt/screen/entrypoint.sh /opt/screen/push-to-benchmarks.sh

WORKDIR /opt/screen

ENV BAHULAM_CLI_DIR=/opt/bahulam-cli \
    BAHULAM_RUNTIME_MODE=bundled \
    LLM_GATEWAY=BahulamGateway

# /data is ephemeral inside the container. If a Railway Volume is attached
# via `railway volume add --mount /data`, it will overlay this path.
RUN mkdir -p /data

ENTRYPOINT ["/opt/screen/entrypoint.sh"]
