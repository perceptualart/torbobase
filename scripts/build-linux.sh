#!/usr/bin/env bash
# build-linux.sh — Build Torbo Base for Linux via Docker
# Produces dist/torbo-base-linux-amd64.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"

echo "=== Torbo Base — Linux Build ==="
echo "Project: $PROJECT_DIR"

# Ensure dist directory exists
mkdir -p "$DIST_DIR"

# Build Docker image
echo ""
echo "--- Building Docker image ---"
docker build -t torbo-base "$PROJECT_DIR"

# Extract binary from image
echo ""
echo "--- Extracting binary ---"
CONTAINER_ID=$(docker create torbo-base)
docker cp "$CONTAINER_ID:/home/torbo/torbo-base-server" "$DIST_DIR/torbo-base-server"
docker rm "$CONTAINER_ID" > /dev/null

# Create tarball
echo ""
echo "--- Creating archive ---"
cd "$DIST_DIR"
tar czf torbo-base-linux-amd64.tar.gz torbo-base-server
rm -f torbo-base-server

ARCHIVE="$DIST_DIR/torbo-base-linux-amd64.tar.gz"
SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo ""
echo "=== Build complete ==="
echo "Archive: $ARCHIVE ($SIZE)"
echo ""
echo "To run:"
echo "  tar xzf torbo-base-linux-amd64.tar.gz"
echo "  TORBO_PORT=18790 TORBO_HOST=0.0.0.0 ./torbo-base-server"
echo ""
echo "Or use Docker:"
echo "  docker run -p 18790:18790 torbo-base"
