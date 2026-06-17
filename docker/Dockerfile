# muster - portable Rancher provisioner image.
#
# A single multi-arch image (amd64 + arm64) carrying muster and its pinned
# toolchain, so any host with Docker can run it identically: macOS, Windows
# (WSL2) or Linux. There is no host dependency on bash, k3d, helm or node.
#
# k3d inside the container drives the HOST Docker daemon over a bind-mounted
# socket and creates SIBLING containers (not docker-in-docker). Because k3d
# bind-mounts come from the host, paths passed to --dashboard-dist must be
# host paths visible to the host daemon.
#
# Security posture:
#   * base image pinned by digest (not just a moving tag)
#   * every downloaded tool pinned to an exact version and SHA256, verified
#     fail-closed at build time (see docker/install-tools.sh)
#   * final image runs as a non-root user
#   * no secrets baked in; the bootstrap password is a runtime input

# --- builder: fetch and verify the toolchain --------------------------------
FROM registry.suse.com/bci/bci-base:15.6@sha256:c4bd6f1a43a3d80e9345e75a0e115e9a34daee55120ad4ba2f14d71bd29ba1eb AS builder

ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

RUN zypper --non-interactive install --no-recommends \
      curl tar gzip xz gawk && \
    zypper clean --all

COPY docker/install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh

# --- final: minimal runtime -------------------------------------------------
FROM registry.suse.com/bci/bci-base:15.6@sha256:c4bd6f1a43a3d80e9345e75a0e115e9a34daee55120ad4ba2f14d71bd29ba1eb

LABEL org.opencontainers.image.title="muster" \
      org.opencontainers.image.description="Portable Rancher management-cluster provisioner for E2E testing" \
      org.opencontainers.image.source="https://github.com/izaac/muster" \
      org.opencontainers.image.licenses="Apache-2.0"

# Runtime-only packages: git (build-ui checkout), curl + ca-certificates
# (verified downloads at run time), tar/gzip (chart handling). bash and
# sha256sum are already present in bci-base.
RUN zypper --non-interactive install --no-recommends \
      bash git curl ca-certificates tar gzip && \
    zypper clean --all && \
    update-ca-certificates

COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/nodejs/ /usr/local/lib/nodejs/

# A non-root user owns nothing privileged. Docker socket access is granted at
# run time by matching the host docker group's GID (see docker/README).
RUN groupadd --system muster && \
    useradd --system --gid muster --create-home --home-dir /home/muster muster

COPY --chown=root:root . /opt/muster
RUN ln -sf /opt/muster/muster /usr/local/bin/muster && \
    install -m 0755 /opt/muster/docker/entrypoint.sh /usr/local/bin/entrypoint.sh && \
    rm -rf /opt/muster/.git

ENV XDG_CACHE_HOME=/home/muster/.cache
WORKDIR /home/muster

# The container starts as root so the entrypoint can grant the muster user
# access to the bind-mounted Docker socket (whose GID varies by platform),
# then drops to the unprivileged muster user via gosu before running muster.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh", "muster"]
CMD ["help"]
