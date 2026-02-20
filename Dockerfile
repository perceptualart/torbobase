# Torbo Base — Linux Docker Build
# Multi-stage build: compile with full SDK, run with slim runtime
# (c) 2026 Perceptual Art LLC — Apache 2.0

# Stage 1: Build
FROM swift:5.10-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifest first for dependency caching
COPY Package.swift .

# Resolve dependencies (cached if Package.swift unchanged)
RUN swift package resolve

# Copy source
COPY Sources/ Sources/

# Build release binary (dynamic Swift stdlib)
RUN swift build -c release -Xlinker -lsqlite3

# Stage 2: Runtime (slim Swift image — includes Swift runtime + ICU + libdispatch)
FROM swift:5.10-jammy-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app user
RUN useradd -m -s /bin/bash torbo

WORKDIR /home/torbo

# Copy binary from builder
COPY --from=builder /app/.build/release/TorboBase ./torbo-base-server

# Create data directories (XDG-compliant: ~/.config/torbobase/)
RUN mkdir -p .config/torbobase/agents \
             .config/torbobase/skills \
             .config/torbobase/memory \
             .config/torbobase/documents \
             .config/torbobase/logs \
             .config/torbobase/mcp \
             .config/torbobase/users && \
    chown -R torbo:torbo /home/torbo

USER torbo

# Default environment
ENV HOME=/home/torbo
ENV TORBO_PORT=4200
ENV TORBO_HOST=0.0.0.0
ENV TORBO_ACCESS_LEVEL=1

EXPOSE 4200

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:4200/health || exit 1

CMD ["./torbo-base-server"]
