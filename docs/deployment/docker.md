# Docker Deployment

OpenJarvis provides Docker images for both CPU-only and GPU-accelerated deployments, along with a Docker Compose configuration that bundles the API server with an Ollama inference backend.

## Quick Start

The container binds `0.0.0.0`, so an **API key is required** — the server
refuses to start on a non-loopback address without one. Set it first:

```bash
cd deploy/docker
cp .env.example .env
echo "OPENJARVIS_API_KEY=$(jarvis auth generate-key)" > .env   # or paste your own
```

Then start both the API server and an Ollama backend. `deploy/docker/stack.sh`
is a thin wrapper around `docker compose` that picks the right `-f` file
combination for you (base stack, GPU override, sandbox override) instead of
having to remember them:

```bash
deploy/docker/stack.sh up
```

This is equivalent to
`docker compose -f deploy/docker/docker-compose.yml up -d --build` if you'd
rather invoke Compose directly. `OPENJARVIS_API_KEY` is read from `.env` (or
your shell environment) and Compose fails fast if it is unset. Clients must
then send `Authorization: Bearer <key>` on `/v1/*` and `/api/*` requests.

This brings up two services:

| Service  | Port  | Description                        |
|----------|-------|------------------------------------|
| `jarvis` | 8000  | OpenJarvis API server              |
| `ollama` | 11434 | Ollama inference engine            |

Verify the server is running:

```bash
curl http://localhost:8000/health
```

Expected response:

```json
{"status": "ok"}
```

## Docker Images

### CPU-Only Image (`Dockerfile`)

The default `Dockerfile` uses a multi-stage build based on `python:3.12-slim` to produce a minimal image.

**Build stages:**

1. **Builder stage** -- installs `uv` and the `openjarvis[server]` package (which includes FastAPI, uvicorn, and all server dependencies) from the project source.
2. **Runtime stage** -- copies only the installed Python packages and application code from the builder, keeping the final image small.

```dockerfile
FROM python:3.12-slim AS builder

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --no-cache-dir uv && \
    uv pip install --system ".[server]"

FROM python:3.12-slim

COPY --from=builder /usr/local /usr/local
COPY --from=builder /app /app
WORKDIR /app

EXPOSE 8000

ENTRYPOINT ["jarvis"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8000"]
```

Build it manually:

```bash
docker build -t openjarvis:latest .
```

Run it standalone:

```bash
docker run -d -p 8000:8000 openjarvis:latest
```

### GPU Image (`Dockerfile.gpu`)

The GPU image is built on `nvidia/cuda:12.4.0-runtime-ubuntu22.04` and includes the CUDA 12.4 runtime libraries, enabling GPU-accelerated inference when paired with a GPU-capable engine like vLLM or SGLang.

```dockerfile
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --no-cache-dir uv && \
    uv pip install --system ".[server]"

FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local
COPY --from=builder /app /app
WORKDIR /app

EXPOSE 8000

ENTRYPOINT ["jarvis"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8000"]
```

Build the GPU image:

```bash
docker build -f Dockerfile.gpu -t openjarvis:gpu .
```

Run with GPU access (requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)):

```bash
docker run -d --gpus all -p 8000:8000 openjarvis:gpu
```

!!! note "NVIDIA Container Toolkit required"
    The host machine must have the NVIDIA Container Toolkit installed for `--gpus` to work. See the [NVIDIA installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) for setup instructions.

## Docker Compose Configuration

`deploy/docker/docker-compose.yml` defines a complete deployment with the
OpenJarvis API server and an Ollama backend (see that file for the exact,
current definition — base images are pinned by digest, so treat this as an
illustrative excerpt rather than something to copy verbatim):

```yaml
services:
  jarvis:
    build:
      context: ../..
      dockerfile: deploy/docker/Dockerfile
    ports:
      - "8000:8000"
    environment:
      - OPENJARVIS_ENGINE_DEFAULT=ollama
      - OLLAMA_HOST=http://ollama:11434
      - OPENJARVIS_API_KEY=${OPENJARVIS_API_KEY:?...}
    volumes:
      - jarvis-home:/home/openjarvis/.openjarvis
    depends_on:
      ollama:
        condition: service_healthy
    networks:
      - openjarvis
    restart: unless-stopped

  ollama:
    image: ollama/ollama:0.30.10@sha256:...
    ports:
      - "11434:11434"
    volumes:
      - ollama-models:/root/.ollama
    healthcheck:
      test: ["CMD", "ollama", "list"]
    networks:
      - openjarvis
    restart: unless-stopped

networks:
  openjarvis:
    name: openjarvis

volumes:
  ollama-models:
  jarvis-home:
```

### Environment Variables

The `jarvis` service is configured through environment variables:

| Variable                      | Description                                             | Default                    |
|-------------------------------|---------------------------------------------------------|----------------------------|
| `OPENJARVIS_ENGINE_DEFAULT`   | Inference engine backend to use                         | `ollama`                   |
| `OLLAMA_HOST`                 | URL of the Ollama server (uses the Docker service name) | `http://ollama:11434`      |
| `OPENJARVIS_API_KEY`          | Required — the container binds `0.0.0.0`, so Compose refuses to start without this set | none, must be set |

### Networks

Both services join one explicitly-named `openjarvis` Compose network (rather
than the compose-project-default network), so overrides — the GPU and
sandbox files below — can join it by name regardless of which directory
Compose is invoked from.

### Volumes

- `ollama-models` persists downloaded models across container restarts, so
  models do not need to be re-pulled after a `docker compose down` /
  `docker compose up` cycle.
- `jarvis-home` persists the entire OpenJarvis state root (`config.toml`,
  `memory.db`, `telemetry.db`, `traces.db` — see "Persisting Data" below) at
  `/home/openjarvis/.openjarvis`, the non-root `openjarvis` user's home
  directory inside the container. This is mounted by default; you do not need
  to add it yourself.

### Service Dependencies

The `jarvis` service's `depends_on` waits for Ollama's `service_healthy`
condition (not just container-started), so the API server never starts
racing an Ollama backend that isn't ready to serve yet. Both services use
`restart: unless-stopped` to automatically recover from crashes.

## Custom Configuration

### Mounting a Configuration File

The image's non-root user is `openjarvis` (uid/gid `10001`), whose home is
`/home/openjarvis` — not `/root`, since the process never runs as root. To
use a custom `config.toml`, mount it at that path:

```yaml
services:
  jarvis:
    volumes:
      - jarvis-home:/home/openjarvis/.openjarvis
      - ./my-config.toml:/home/openjarvis/.openjarvis/config.toml:ro
```

### Persisting Data

Handled by default — no action needed. `docker-compose.yml`'s `jarvis-home`
named volume already mounts the entire OpenJarvis state root at
`/home/openjarvis/.openjarvis`, preserving:

- `telemetry.db` -- inference call telemetry records
- `memory.db` -- the default SQLite memory backend
- `traces.db` -- interaction trace records
- `config.toml` -- user configuration

across `docker compose down` / `up` cycles. `docker compose down --volumes`
(or `deploy/docker/stack.sh down -- --volumes`) still removes it if you
deliberately want a clean slate.

### GPU

Use the digest-pinned override files rather than hand-editing the base
compose file — they're already wired up:

```bash
deploy/docker/stack.sh --gpu nvidia up   # docker-compose.gpu.nvidia.yml — requires the NVIDIA Container Toolkit
deploy/docker/stack.sh --gpu rocm up     # docker-compose.gpu.rocm.yml — requires host ROCm + /dev/kfd, /dev/dri access
```

Each override swaps `jarvis`'s `dockerfile` to the matching GPU variant
(`Dockerfile.gpu` / `Dockerfile.gpu.rocm`) and adds the device
reservations/mounts that variant needs; see the override files themselves for
the exact device list.

### Sandbox (opt-in, security-sensitive)

`Dockerfile.sandbox` builds the `openjarvis-sandbox:latest` image that
`sandbox.ContainerRunner` shells out to `docker` to launch on demand, for
isolated agent code execution. It is not part of the default stack:

```bash
deploy/docker/stack.sh --sandbox up
```

enabling it mounts the **host's** `/var/run/docker.sock` into the `jarvis`
container so it can launch those sibling containers (Docker-out-of-Docker).
**This is equivalent to granting the `jarvis` container root on the host** —
anything able to reach the socket can start a privileged container and
escape confinement. Only enable it on a host you trust the jarvis workload
on, and never combine it with exposing the API port to an untrusted network.
See `deploy/docker/docker-compose.sandbox.yml` for the full detail, including
a known upstream gap: `openjarvis.sandbox.entrypoint` doesn't exist yet under
`src/openjarvis/sandbox/`, so a launched sandbox container currently builds
but fails immediately at run time until that module is added.

## Health Check

The API server exposes a `GET /health` endpoint that checks whether the underlying inference engine is responsive:

```bash
curl http://localhost:8000/health
```

A healthy response returns HTTP 200:

```json
{"status": "ok"}
```

An unhealthy engine returns HTTP 503:

```json
{"detail": "Engine unhealthy"}
```

You can integrate this into your Docker Compose healthcheck:

```yaml
services:
  jarvis:
    # ... other config ...
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
```

## Building Custom Images

### Adding Extra Dependencies

To include additional engine backends (such as vLLM or ColBERT memory), modify the install command in the Dockerfile:

```dockerfile
RUN pip install --no-cache-dir uv && \
    uv pip install --system ".[server,inference-vllm,memory-colbert]"
```

### Overriding the Default Command

The entrypoint is `jarvis` and the default command is `serve --host 0.0.0.0 --port 8000`. Override the command to change server options:

```bash
docker run -d -p 9000:9000 openjarvis:latest \
  serve --host 0.0.0.0 --port 9000 --engine ollama --model qwen3:8b
```

Or in Docker Compose:

```yaml
services:
  jarvis:
    build: .
    command: ["serve", "--host", "0.0.0.0", "--port", "9000", "--model", "qwen3:8b"]
    ports:
      - "9000:9000"
```

### Available CLI Options for `jarvis serve`

| Option               | Description                                         |
|----------------------|-----------------------------------------------------|
| `--host`             | Bind address (default: from config, typically `0.0.0.0`) |
| `--port`             | Port number (default: from config, typically `8000`)     |
| `-e` / `--engine`    | Engine backend (`ollama`, `vllm`, `llamacpp`, `sglang`)  |
| `-m` / `--model`     | Default model name                                       |
| `-a` / `--agent`     | Agent for non-streaming requests (`simple`, `orchestrator`, `react`, `openhands`) |

## Pulling Models

After starting the Ollama container, you need to pull at least one model before the API server can serve requests:

```bash
docker compose exec ollama ollama pull qwen3:8b
```

Verify models are available through the API:

```bash
curl http://localhost:8000/v1/models
```
