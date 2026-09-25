#!/usr/bin/env bash
# Build, verify, publish and roll out a new adapter image.
#
#   0. bump the Dockerfile's base image to the current debian:trixie-slim
#      index digest, so every release picks up Debian's security updates; the
#      steps below then build and verify on that base
#   1. ./verify.sh args and contract (no docker)
#   2. build and push a linux/amd64 + linux/arm64 image to Docker Hub, and
#      pull it back
#   3. ./verify.sh image and conformance against the digest that was pushed,
#      so the evidence is for the artifact an operator approves, not a local
#      build of the same source
#   4. swap the new digest in for the old one everywhere it is recorded:
#      README.md, CONFORMANCE.md, manifests/, examples/ (including the local,
#      gitignored rendered manifest)
#   5. apply the rendered manifest and wait for the AgentRuntime to resolve it
#
# Usage: scripts/release.sh <tag>          e.g. 2.1.280-3
#
# Environment:
#   MANIFEST    rendered manifest to apply (default: examples/claude-code.rendered.yaml)
#   APPLY       set to 0 to publish and record without applying
#   NAMESPACE   namespace of the AgentRuntime (default: default)
#   RUNTIME     AgentRuntime name (default: claude-code-v2-1-280)
#   SKIP_TESTS  set to 1 to skip every verify.sh stage
#   BUMP_BASE   set to 0 to keep the base image the Dockerfile pins
set -euo pipefail

# Docker Hub user or org the image is published under.
DH_USER=fooman

tag="${1:?usage: $0 <tag>}"
manifest="${MANIFEST:-examples/claude-code.rendered.yaml}"
namespace="${NAMESPACE:-default}"
runtime="${RUNTIME:-claude-code-v2-1-280}"
image="docker.io/$DH_USER/sympozium-harness-claude"
ref_re="docker\.io/$DH_USER/sympozium-harness-claude@sha256:[0-9a-f]{64}"

cd "$(dirname "$0")/.."

[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "invalid tag: $tag" >&2; exit 2; }

step() { printf '\n==> %s\n' "$*"; }

# The files that record the published digest. Every one must end up naming the
# same image, because the allowlist and the runtime are matched as written.
shopt -s nullglob
recorded=(README.md CONFORMANCE.md manifests/*.yaml examples/*.yaml)
shopt -u nullglob

if [ "${BUMP_BASE:-1}" != 0 ]; then
  step "base image: latest debian:trixie-slim"
  # The multi-architecture index digest, which is what the Dockerfile pins:
  # amd64 and arm64 builds both resolve through it.
  latest="$(docker buildx imagetools inspect debian:trixie-slim --format '{{.Manifest.Digest}}')"
  [[ "$latest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "could not resolve debian:trixie-slim: $latest" >&2; exit 1; }
  current="$(sed -n 's/^ARG RUNTIME_IMAGE=debian:trixie-slim@//p' Dockerfile)"
  [[ "$current" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Dockerfile has no ARG RUNTIME_IMAGE=debian:trixie-slim@sha256:... line" >&2; exit 1; }
  if [ "$current" = "$latest" ]; then
    echo "already current: $latest"
  else
    tmp="$(mktemp)"
    sed "s|^ARG RUNTIME_IMAGE=debian:trixie-slim@$current\$|ARG RUNTIME_IMAGE=debian:trixie-slim@$latest|" Dockerfile > "$tmp"
    grep -qx "ARG RUNTIME_IMAGE=debian:trixie-slim@$latest" "$tmp" || { rm -f "$tmp"; echo "could not rewrite the base image line" >&2; exit 1; }
    cat "$tmp" > Dockerfile
    rm -f "$tmp"
    echo "bumped: $current"
    echo "    to: $latest"
  fi
fi

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  step "verify: args, contract"
  ./verify.sh args
  ./verify.sh contract
fi

step "build and push $image:$tag (linux/amd64, linux/arm64)"
docker buildx use multiarch 2>/dev/null || docker buildx create --name multiarch --use >/dev/null
meta="$(mktemp)"
trap 'rm -f "$meta"' EXIT
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag "$image:$tag" \
  --push \
  --metadata-file "$meta" \
  .

docker pull "$image:$tag"
digest="$(jq -r '."containerimage.digest" // empty' "$meta")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest in build metadata" >&2; exit 1; }
new_ref="$image@$digest"
echo "published: $new_ref"

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  step "verify: image, conformance against $new_ref"
  ./verify.sh image "$new_ref"
  ./verify.sh conformance "$new_ref"
fi

step "record $digest"
for f in "${recorded[@]}"; do
  grep -qE "$ref_re" "$f" || continue
  [ "$f" != "$manifest" ] || cp "$f" "$f.bak"
  tmp="$(mktemp)"
  sed -E "s|$ref_re|$new_ref|g" "$f" > "$tmp"
  cat "$tmp" > "$f"   # keeps the file's own permissions
  rm -f "$tmp"
  echo "  $f"
done
# The tag CONFORMANCE.md names, so a reader can find the image by tag too.
if [ -f CONFORMANCE.md ]; then
  tmp="$(mktemp)"
  sed -E "s|(docker\.io/$DH_USER/sympozium-harness-claude):[A-Za-z0-9_][A-Za-z0-9_.-]*|\1:$tag|g" CONFORMANCE.md > "$tmp"
  cat "$tmp" > CONFORMANCE.md
  rm -f "$tmp"
fi
stale=""
for f in "${recorded[@]}"; do
  if grep -oE "$ref_re" "$f" | grep -vqxF "$new_ref"; then stale+=" $f"; fi
done
[ -z "$stale" ] || { echo "files still naming another digest:$stale" >&2; exit 1; }

released() {
  printf '\nReleased %s\nCommit the recorded digest: git add -A && git commit -m "published %s"\n' "$new_ref" "$tag"
}

if [ "${APPLY:-1}" = 0 ] || [ ! -f "$manifest" ]; then
  step "not applying (APPLY=0, or no $manifest)"
  released
  exit 0
fi

step "apply $manifest"
kubectl apply -f "$manifest"

step "wait for AgentRuntime $namespace/$runtime to resolve $digest"
resolved=""
for _ in $(seq 30); do
  resolved="$(kubectl -n "$namespace" get agentruntime "$runtime" -o jsonpath='{.status.resolvedImageDigest}' 2>/dev/null || true)"
  if [[ "$resolved" == *"$digest"* ]]; then
    echo "resolved: $resolved"
    released
    printf 'Roll back the cluster: mv %s.bak %s && kubectl apply -f %s\n' "$manifest" "$manifest" "$manifest"
    exit 0
  fi
  sleep 2
done
echo "AgentRuntime still reports '${resolved:-nothing}' after 60s; check: kubectl -n $namespace describe agentruntime $runtime" >&2
exit 1
