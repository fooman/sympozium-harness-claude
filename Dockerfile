# Harness backend: Anthropic Claude Code
#
# This is an *adapter*, not a repackaged harness: the image is the upstream
# harness plus harness-lib.sh and the entrypoint that maps Sympozium's task
# contract onto Claude Code. See README.md, and the contract in Sympozium's
# docs/modes/harness-adapters.md.
#
# Runs non-root (UID 1000) with a read-only rootfs, matching every other
# Sympozium agent pod. $HOME is an emptyDir the controller mounts at
# /home/agent, and the entrypoint points CLAUDE_CONFIG_DIR inside it — the
# harness gets a writable home without the pod security context being relaxed.
#
# Claude Code ships as one native binary per platform, in the npm packages
# @anthropic-ai/claude-code-linux-{x64,arm64}. The image takes that binary and
# nothing else: no node, no npm, and no installer. The wrapper package's
# postinstall script is what would normally pick the binary; here the
# Dockerfile picks it, and checks it against the SHA-512 npm publishes for that
# exact version.
#
# The base is pinned by digest, the way sympozium-ai/harness-adapters pins its
# own. The tag stays in front of the digest so the line is readable, but docker
# resolves the digest and ignores the tag: `trixie-slim` moves on every Debian
# point release, and rebuilding the same source months apart would otherwise
# produce a different image under a digest an operator already approved. This
# is the multi-architecture index digest, so amd64 and arm64 builds both still
# resolve.
#
# Bumping it is a commit and a `./verify.sh image` run, the same as bumping
# CLAUDE_CODE_VERSION. Get a current one with:
#   docker buildx imagetools inspect debian:trixie-slim --format '{{.Manifest.Digest}}'
ARG RUNTIME_IMAGE=debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# ── stage 1: fetch and verify the pinned binary ─────────────────────────────
FROM ${RUNTIME_IMAGE} AS harness

# CLAUDE_CODE_VERSION pins the upstream harness, and the two checksums pin
# the exact binaries for it. They move together: scripts/pin-claude-code.sh
# <version> rewrites all three from npm's published integrity.
#
# The default is an exact version rather than `latest`, because an adapter's
# image has to say which upstream release it is an adapter *for*. Claude Code
# releases often and changes flags, so a floating default would make two
# builds of the same source a different agent, and the digest an operator
# approved would stop meaning anything. Bumping it is a commit, and
# `./verify.sh image` is what says whether the bump still maps.
ARG CLAUDE_CODE_VERSION=2.1.280
ARG CLAUDE_CODE_SHA512_X64=7491d616b0d2219dba85d2ee7272b77a12e6cddcd897732c3c2d51cd472d0146989d9947e647c06719caf2a611010f3d197dce3eb2ec9c576dfd09cffb40a4e9
ARG CLAUDE_CODE_SHA512_ARM64=cc1e28aab1708a6915fc59813a4571beff22620b2e0d2a7bfcc63cb984e7b384821380f0747cf9f17d5c3b5b20a8b9c247de80d2853b622ae8bf5524de218a00
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) arch=x64;   sum="$CLAUDE_CODE_SHA512_X64" ;; \
      arm64) arch=arm64; sum="$CLAUDE_CODE_SHA512_ARM64" ;; \
      *) echo "unsupported TARGETARCH $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/claude.tgz \
      "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-${arch}/-/claude-code-linux-${arch}-${CLAUDE_CODE_VERSION}.tgz"; \
    echo "${sum}  /tmp/claude.tgz" | sha512sum -c -; \
    mkdir -p /out; \
    tar -xzf /tmp/claude.tgz -C /out --strip-components=1 package/claude package/LICENSE.md; \
    chmod 0755 /out/claude

# ── stage 2: the image that ships ───────────────────────────────────────────
FROM ${RUNTIME_IMAGE}

# git is for the *agent*, not the harness: the adapter never shells out to it,
# but a coding agent diffs, logs and commits with it. It costs ~79MB, because
# Debian's git depends on perl, so it is a build-time choice rather than an
# assumption. Turn it off for an agent that only reads and writes files:
#   docker build --build-arg INSTALL_GIT=false ...
#
# ripgrep is for Claude Code's search tools, and small.
ARG INSTALL_GIT=true

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash jq ca-certificates ripgrep \
    && if [ "${INSTALL_GIT}" = "true" ]; then \
         apt-get install -y --no-install-recommends git; \
       fi \
    && rm -rf /var/lib/apt/lists/* \
    # The pod runs as 1000 with $HOME at /home/agent. Creating the user here
    # means a bare `docker run` has a real home too, rather than a uid with
    # nowhere to write.
    && groupadd --gid 1000 agent \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/agent --shell /bin/bash agent \
    && mkdir -p /workspace && chown 1000:1000 /workspace

COPY --from=harness /out/claude /usr/local/bin/claude
COPY --from=harness /out/LICENSE.md /usr/local/share/doc/claude-code/LICENSE.md
RUN claude --version

COPY harness-lib.sh /usr/local/lib/harness-lib.sh
COPY harness-entrypoint.sh /usr/local/bin/harness-entrypoint.sh
RUN chmod 0755 /usr/local/bin/harness-entrypoint.sh && chmod 0644 /usr/local/lib/harness-lib.sh

USER 1000
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/harness-entrypoint.sh"]
