# Torbo Base — Linux Docker Build
# Multi-stage build: compile with Swift, run with slim image

# Stage 1: Build
FROM swift:5.10-jammy AS builder

WORKDIR /app

# Copy manifest first for dependency caching
COPY Package.swift .

# Resolve dependencies (cached if Package.swift unchanged)
RUN swift package resolve 2>/dev/null || true

# Copy source
COPY Sources/ Sources/

# Build release binary
RUN swift build -c release \
    --static-swift-stdlib \
    -Xlinker -lsqlite3 \
    2>&1 | tail -5

# Stage 2: Runtime
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    libcurl4 \
    ca-certificates \
    python3 \
    poppler-utils \
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
             .config/torbobase/mcp && \
    chown -R torbo:torbo /home/torbo

USER torbo

# Default environment
ENV TORBO_PORT=18790
ENV TORBO_HOST=0.0.0.0

EXPOSE 18790

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -sf http://localhost:18790/health || exit 1

# Run
CMD ["./torbo-base-server"]
