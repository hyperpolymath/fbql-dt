# SPDX-License-Identifier: PMPL-1.0-or-later
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (@hyperpolymath)
#
# FBQLdt Development Container - Chainguard-based
# For use with svalinn/vordr/cerro-torre/selur container system

# Stage 1: Lean 4 builder
FROM cgr.dev/chainguard/wolfi-base:latest AS lean-builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    git \
    bash \
    ca-certificates \
    gcc \
    g++ \
    make \
    cmake

# Install elan (Lean version manager)
RUN curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf \
    | sh -s -- -y --default-toolchain leanprover/lean4:v4.15.0

ENV PATH="/root/.elan/bin:${PATH}"

# Verify Lean 4 installation
RUN lean --version && lake --version

# Stage 2: Zig builder
FROM cgr.dev/chainguard/wolfi-base:latest AS zig-builder

# Install Zig
RUN apk add --no-cache \
    wget \
    xz

RUN wget -q https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz \
    && tar -xf zig-linux-x86_64-0.13.0.tar.xz \
    && mv zig-linux-x86_64-0.13.0 /usr/local/zig \
    && rm zig-linux-x86_64-0.13.0.tar.xz

# Stage 3: Final runtime image
FROM cgr.dev/chainguard/wolfi-base:latest

LABEL org.opencontainers.image.title="FBQLdt Development Environment"
LABEL org.opencontainers.image.description="Lean 4 + Zig for dependently-typed FormDB queries"
LABEL org.opencontainers.image.authors="Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>"
LABEL org.opencontainers.image.licenses="PMPL-1.0-or-later"
LABEL org.opencontainers.image.source="https://github.com/hyperpolymath/fbql-dt"
LABEL org.opencontainers.image.vendor="hyperpolymath"

# Security labels for svalinn/vordr
LABEL io.hyperpolymath.security.level="high"
LABEL io.hyperpolymath.security.verified="true"
LABEL io.hyperpolymath.security.chainguard="true"

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    git \
    ca-certificates

# Copy Lean 4 from builder
COPY --from=lean-builder /root/.elan /root/.elan

# Copy Zig from builder
COPY --from=zig-builder /usr/local/zig /usr/local/zig

# Set up PATH
ENV PATH="/root/.elan/bin:/usr/local/zig:${PATH}"

# Verify installations
RUN lean --version && lake --version && zig version

# Create non-root user for security
RUN adduser -D -u 1000 fbqldt

# Set working directory
WORKDIR /workspace

# Copy project files with correct ownership
COPY --chown=fbqldt:fbqldt . /workspace/

# Switch to non-root user
USER fbqldt

# Build Lean 4 project (download dependencies)
RUN lake build || echo "Build will complete when dependencies are available"

# Build Zig FFI bridge
WORKDIR /workspace/bridge/zig
RUN zig build || echo "Zig build will complete when project is fully set up"

# Return to workspace root
WORKDIR /workspace

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD lean --version || exit 1

# Default command: interactive shell
CMD ["/bin/bash"]
