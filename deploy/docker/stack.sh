#!/usr/bin/env bash
# Reusable up/down wrapper around the docker-compose.yml (+ optional override)
# files in this directory, so the right -f combination and prerequisite env
# vars don't have to be memorized per invocation.
#
# Usage:
#   deploy/docker/stack.sh [--gpu nvidia|rocm] [--sandbox] <command> [-- <extra docker compose args>]
#
# Commands:
#   up        docker compose up -d --build (the default; --build keeps images
#             current with local source changes)
#   down      docker compose down (stops and removes containers; volumes are
#             NOT removed unless you pass `-- --volumes` yourself)
#   build     docker compose build (build/rebuild images without starting)
#   logs      docker compose logs -f
#   status    docker compose ps
#
# Examples:
#   deploy/docker/stack.sh up                    # base stack: jarvis + ollama
#   deploy/docker/stack.sh --gpu nvidia up        # + NVIDIA GPU override
#   deploy/docker/stack.sh --sandbox up           # + sandbox image, docker.sock (see security warning in docker-compose.sandbox.yml)
#   deploy/docker/stack.sh down
#   deploy/docker/stack.sh status
#
# Requires deploy/docker/.env with OPENJARVIS_API_KEY set (see .env.example).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GPU=""
SANDBOX=0
COMMAND=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --gpu)
            GPU="${2:?--gpu requires nvidia or rocm}"
            shift 2
            ;;
        --sandbox)
            SANDBOX=1
            shift
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        up|down|build|logs|status)
            COMMAND="$1"
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$COMMAND" ]; then
    echo "usage: $0 [--gpu nvidia|rocm] [--sandbox] {up|down|build|logs|status} [-- extra-args]" >&2
    exit 1
fi

FILES=(-f docker-compose.yml)

case "$GPU" in
    "") ;;
    nvidia) FILES+=(-f docker-compose.gpu.nvidia.yml) ;;
    rocm) FILES+=(-f docker-compose.gpu.rocm.yml) ;;
    *)
        echo "unknown --gpu value: $GPU (expected nvidia or rocm)" >&2
        exit 1
        ;;
esac

if [ "$SANDBOX" -eq 1 ]; then
    FILES+=(-f docker-compose.sandbox.yml)
    if [ -z "${DOCKER_GID:-}" ]; then
        if [ -S /var/run/docker.sock ]; then
            export DOCKER_GID
            DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
            echo "stack.sh: DOCKER_GID not set, derived $DOCKER_GID from /var/run/docker.sock" >&2
        else
            echo "stack.sh: --sandbox requires DOCKER_GID set, or a readable /var/run/docker.sock to derive it from" >&2
            exit 1
        fi
    fi
fi

if [ ! -f .env ]; then
    echo "stack.sh: deploy/docker/.env is missing (copy .env.example and set OPENJARVIS_API_KEY)" >&2
    exit 1
fi

case "$COMMAND" in
    up)
        exec docker compose "${FILES[@]}" up -d --build "${EXTRA_ARGS[@]}"
        ;;
    down)
        exec docker compose "${FILES[@]}" down "${EXTRA_ARGS[@]}"
        ;;
    build)
        exec docker compose "${FILES[@]}" build "${EXTRA_ARGS[@]}"
        ;;
    logs)
        exec docker compose "${FILES[@]}" logs -f "${EXTRA_ARGS[@]}"
        ;;
    status)
        exec docker compose "${FILES[@]}" ps "${EXTRA_ARGS[@]}"
        ;;
esac
