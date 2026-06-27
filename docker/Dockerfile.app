# Build stage
FROM golang:1.26-bookworm AS builder

WORKDIR /app

# 通过构建参数接收敏感信息
ARG GOPRIVATE_ARG
ARG GOPROXY_ARG
ARG GOSUMDB_ARG=off
ARG APK_MIRROR_ARG

# 设置Go环境变量
ENV GOPRIVATE=${GOPRIVATE_ARG}
ENV GOPROXY=${GOPROXY_ARG}
ENV GOSUMDB=${GOSUMDB_ARG}

# Install dependencies
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y git build-essential libsqlite3-dev

# Install migrate tool
RUN go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

# Copy go mod and sum files
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd/download cmd/download
RUN go run cmd/download/duckdb/duckdb.go
COPY . .

# Get version and commit info for build injection
ARG VERSION_ARG
ARG COMMIT_ID_ARG
ARG BUILD_TIME_ARG
ARG GO_VERSION_ARG

# Optional: GOAMD64 microarchitecture level (v1/v2/v3/v4).
# Leave empty to auto-detect from the build host's /proc/cpuinfo
# (Docker passes the host CPU through, so detection is accurate).
# Set explicitly (e.g. GOAMD64_ARG=v3) to force a level.
ARG GOAMD64_ARG=

# Optional: toggle aggressive optimizations.
# AGGRESSIVE_OPT=1 (default) enables -pgo=auto, -trimpath, -gcflags="-l=4", -ldflags="-s -w".
# AGGRESSIVE_OPT=0 falls back to the plain `make build-prod` path.
ARG AGGRESSIVE_OPT=1

# Set build-time variables
ENV VERSION=${VERSION_ARG}
ENV COMMIT_ID=${COMMIT_ID_ARG}
ENV BUILD_TIME=${BUILD_TIME_ARG}
ENV GO_VERSION=${GO_VERSION_ARG}

# Resolve the GOAMD64 level: explicit arg wins; otherwise auto-detect.
RUN set -eux; \
    if [ -n "$GOAMD64_ARG" ]; then \
        echo "GOAMD64 forced to $GOAMD64_ARG via build arg"; \
    else \
        if grep -q 'avx2' /proc/cpuinfo \
           && grep -q 'bmi1' /proc/cpuinfo \
           && grep -q 'bmi2' /proc/cpuinfo \
           && grep -q 'fma' /proc/cpuinfo \
           && grep -q 'lzcnt' /proc/cpuinfo \
           && grep -q 'movbe' /proc/cpuinfo; then \
            GOAMD64_ARG=v3; \
            echo "✅ CPU supports GOAMD64=v3 (avx2+bmi1+bmi2+fma+lzcnt+movbe)"; \
        elif grep -q 'popcnt' /proc/cpuinfo \
             && grep -q 'sse4_1' /proc/cpuinfo \
             && grep -q 'sse4_2' /proc/cpuinfo \
             && grep -q 'ssse3' /proc/cpuinfo \
             && grep -q 'cx16' /proc/cpuinfo; then \
            GOAMD64_ARG=v2; \
            echo "✅ CPU supports GOAMD64=v2 (popcnt+sse4_1+sse4_2+ssse3+cx16)"; \
        else \
            GOAMD64_ARG=v1; \
            echo "⚠️  CPU only supports GOAMD64=v1 (default)"; \
        fi; \
    fi; \
    echo "GOAMD64_RESOLVED=$GOAMD64_ARG" > /tmp/goamd64.env

# Build the application.
# Path A (default): aggressive optimizations — PGO + trimpath + inlining tuning + stripped binary.
# Path B: plain `make build-prod` (set AGGRESSIVE_OPT=0).
RUN --mount=type=cache,target=/go/pkg/mod \
    set -eux; \
    . /tmp/goamd64.env; \
    if [ "$AGGRESSIVE_OPT" = "1" ]; then \
        eval "$$(./scripts/get_version.sh env)"; \
        LDFLAGS="$$(./scripts/get_version.sh ldflags) -X 'google.golang.org/protobuf/reflect/protoregistry.conflictPolicy=warn'"; \
        PGO_FLAG=""; \
        if ls default.pgo >/dev/null 2>&1; then \
            PGO_FLAG="-pgo=auto"; \
            echo ">> Found default.pgo, enabling PGO"; \
        else \
            echo ">> No default.pgo found, skipping PGO (Go will not error)"; \
        fi; \
        echo ">> Building with aggressive optimizations (GOAMD64=$$GOAMD64_RESOLVED)"; \
        CGO_ENABLED=1 \
        CGO_CFLAGS="-Wno-deprecated-declarations" \
        GOAMD64=$$GOAMD64_RESOLVED \
        go build \
            $$PGO_FLAG \
            -trimpath \
            -gcflags="-l=4" \
            -ldflags="-w -s $$LDFLAGS" \
            -o WeKnora ./cmd/server; \
    else \
        echo ">> Building with plain make build-prod"; \
        make build-prod; \
    fi
RUN --mount=type=cache,target=/go/pkg/mod cp -r /go/pkg/mod/github.com/yanyiwu/ /app/yanyiwu/

# Final stage
FROM debian:12.12-slim

WORKDIR /app

ARG APK_MIRROR_ARG

# Create a non-root user first
RUN useradd -m -s /bin/bash appuser

# First, install ca-certificates without mirror to ensure HTTPS works
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Then switch to mirror if specified and install other packages
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential postgresql-client default-mysql-client tzdata sed curl bash vim wget \
        libsqlite3-0 \
        python3 python3-pip python3-dev libffi-dev libssl-dev \
        nodejs npm \
        gosu \
        ffmpeg && \
    python3 -m pip install --break-system-packages --upgrade pip setuptools wheel && \
    mkdir -p /home/appuser/.local/bin && \
    curl -LsSf https://astral.sh/uv/install.sh | CARGO_HOME=/home/appuser/.cargo UV_INSTALL_DIR=/home/appuser/.local/bin sh && \
    chown -R appuser:appuser /home/appuser && \
    ln -sf /home/appuser/.local/bin/uvx /usr/local/bin/uvx && \
    chmod +x /usr/local/bin/uvx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create data directories and set permissions
RUN mkdir -p /data/files && \
    chown -R appuser:appuser /app /data/files

# Copy migrate tool from builder stage
COPY --from=builder /go/bin/migrate /usr/local/bin/
COPY --from=builder /app/yanyiwu/ /go/pkg/mod/github.com/yanyiwu/

# Copy the binary from the builder stage
COPY --from=builder /app/config ./config
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/migrations ./migrations
COPY --from=builder /app/dataset/samples ./dataset/samples
COPY --from=builder /app/skills/preloaded ./skills/preloaded
# Keep a read-only backup so bind-mount cannot erase built-in skills
COPY --from=builder /app/skills/preloaded ./skills/_builtin
COPY --from=builder /root/.duckdb /home/appuser/.duckdb
COPY --from=builder /app/WeKnora .

# Copy and make entrypoint script executable
COPY --from=builder /app/scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh

# Make scripts executable
RUN chmod +x ./scripts/*.sh

# Expose ports
EXPOSE 8080


ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
CMD ["./WeKnora"]
