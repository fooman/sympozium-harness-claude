#!/usr/bin/env bash
# Build, verify, publish and roll out a new adapter image. No arguments needed:
# the upstream pins and the tag are worked out here.
#
#   0. bump the Dockerfile's base image to the current debian:trixie-slim
#      index digest, so every release picks up Debian's security updates
#   1. bump Claude Code to npm's `latest` (scripts/pin-claude-code.sh rewrites
#      the version and both binary checksums)
#   2. choose the tag: v<claude-code-version>-<n>, where n is one more than
#      the highest build of that version already on Docker Hub. A re-run of
#      the same version therefore goes -1, -2, -3; a new version starts at -1
#   3. ./verify.sh args and contract (no docker)
#   4. build a local candidate and run ./verify.sh image on it. This is the
#      version-bump check, and it runs before anything is pushed, because a
#      Claude Code release can change a flag under the adapter
#   5. build and push a linux/amd64 + linux/arm64 image to Docker Hub, and
#      pull it back
#   6. ./verify.sh image and conformance against the digest that was pushed,
#      so the evidence is for the artifact an operator approves, not a local
#      build of the same source
#   7. record the release:
#        - on a new Claude Code version, add manifests/claude-code-<version>.yaml
#          next to the earlier ones, which stay as they are, digest included,
#          so two versions can be compared; and move README.md, CONFORMANCE.md
#          and the public example to the new version and runtime name
#        - write the new digest into README.md, CONFORMANCE.md, this version's
#          manifest and the public example
#
# It stops there. Rolling the release out to a cluster (the policy that admits
# the digest, the AgentRuntime, which Agents move) is the operator's side and
# is not part of this repository.
#
# Usage: scripts/release.sh [tag]
#
# Environment:
#   CLAUDE_CODE_VERSION  a version (2.1.289) or an npm dist-tag (latest,
#                        stable) to pin instead of `latest`
#   BUMP_CLAUDE   set to 0 to keep the Claude Code version the Dockerfile pins
#   BUMP_BASE     set to 0 to keep the base image the Dockerfile pins
#   DRY_RUN       set to 1 to print the bumps and the tag, put the Dockerfile
#                 back as it was, and stop before building anything
#   SKIP_TESTS    set to 1 to skip every verify.sh stage
set -euo pipefail

# Docker Hub user or org the image is published under.
DH_USER=fooman

repo="$DH_USER/sympozium-harness-claude"
image="docker.io/$repo"
ref_re="docker\.io/$DH_USER/sympozium-harness-claude@sha256:[0-9a-f]{64}"
builder=multiarch
candidate="sympozium-harness-claude:release-candidate"

cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

# rewrite FILE SED_ARGS...: sed in place, portably (BSD and GNU sed disagree
# on -i), keeping the file's own permissions.
rewrite() {
  local file="$1" tmp
  shift
  tmp="$(mktemp)"
  sed "$@" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

pinned_version() { sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' Dockerfile; }

# A failure after the pins were bumped leaves the Dockerfile ahead of what is
# published. Say so, rather than leave it to be found in a later diff.
meta=""
bumped=""
published=0
dockerfile_before=""
if [ "${DRY_RUN:-0}" = 1 ]; then
  dockerfile_before="$(mktemp)"
  cat Dockerfile > "$dockerfile_before"
fi
on_exit() {
  local rc=$?
  [ -z "$meta" ] || rm -f "$meta"
  if [ -n "$dockerfile_before" ]; then
    cat "$dockerfile_before" > Dockerfile
    rm -f "$dockerfile_before"
    return 0
  fi
  if [ "$rc" -ne 0 ] && [ -n "$bumped" ] && [ "$published" -eq 0 ]; then
    printf '\nNothing was published. The Dockerfile was bumped (%s); to undo: git checkout -- Dockerfile\n' "${bumped# }" >&2
  fi
}
trap on_exit EXIT

# ── 0. base image ───────────────────────────────────────────────────────────

if [ "${BUMP_BASE:-1}" != 0 ]; then
  step "base image: latest debian:trixie-slim"
  # The multi-architecture index digest, which is what the Dockerfile pins:
  # amd64 and arm64 builds both resolve through it.
  latest="$(docker buildx imagetools inspect debian:trixie-slim --format '{{.Manifest.Digest}}')"
  [[ "$latest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve debian:trixie-slim: $latest"
  current="$(sed -n 's/^ARG RUNTIME_IMAGE=debian:trixie-slim@//p' Dockerfile)"
  [[ "$current" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Dockerfile has no ARG RUNTIME_IMAGE=debian:trixie-slim@sha256:... line"
  if [ "$current" = "$latest" ]; then
    echo "already current: $latest"
  else
    rewrite Dockerfile "s|^ARG RUNTIME_IMAGE=debian:trixie-slim@$current\$|ARG RUNTIME_IMAGE=debian:trixie-slim@$latest|"
    grep -qx "ARG RUNTIME_IMAGE=debian:trixie-slim@$latest" Dockerfile || die "could not rewrite the base image line"
    bumped+=" base image"
    echo "bumped: $current"
    echo "    to: $latest"
  fi
fi

# ── 1. Claude Code ──────────────────────────────────────────────────────────

version_re='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
old_version="$(pinned_version)"
[[ "$old_version" =~ $version_re ]] || die "Dockerfile has no ARG CLAUDE_CODE_VERSION=<version> line"
version="$old_version"

if [ "${BUMP_CLAUDE:-1}" != 0 ]; then
  want="${CLAUDE_CODE_VERSION:-latest}"
  step "Claude Code: $want"
  if ! [[ "$want" =~ $version_re ]]; then
    # An npm dist-tag. `latest` is what `npm install` would give today.
    want="$(npm view "@anthropic-ai/claude-code@$want" version 2>/dev/null)" ||
      die "could not resolve @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest} on npm"
    [[ "$want" =~ $version_re ]] || die "npm returned no version for @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
  fi
  if [ "$want" = "$old_version" ]; then
    echo "already current: $old_version"
  else
    scripts/pin-claude-code.sh "$want" >/dev/null
    version="$(pinned_version)"
    [ "$version" = "$want" ] || die "pin-claude-code.sh left the Dockerfile at $version, not $want"
    bumped+=" Claude Code $old_version to $version"
    echo "bumped: $old_version"
    echo "    to: $version"
  fi
fi

# ── 2. tag ──────────────────────────────────────────────────────────────────

# next_tag prints v<version>-<n> for the first build number not yet used.
# Docker Hub's tag list gives the highest one for a public repository; the tag
# CONFORMANCE.md records covers a private one. Either can be stale, so the
# result is then probed against the registry itself, with docker's own
# credentials, until a free tag is found.
next_tag() {
  local prefix="v$version-" max=0 name n
  while IFS= read -r name; do
    n="${name#"$prefix"}"
    if [[ "$name" == "$prefix"* ]] && [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ]; then max="$n"; fi
  done < <(
    curl -fsS --max-time 15 "https://hub.docker.com/v2/repositories/$repo/tags?page_size=100&name=$prefix" 2>/dev/null |
      jq -r '.results[]?.name' 2>/dev/null || true
    grep -oE "sympozium-harness-claude:[A-Za-z0-9_][A-Za-z0-9_.-]*" CONFORMANCE.md 2>/dev/null | sed 's/.*://' || true
  )
  n=$((max + 1))
  while docker buildx imagetools inspect "$image:$prefix$n" >/dev/null 2>&1; do n=$((n + 1)); done
  printf '%s%s' "$prefix" "$n"
}

if [ $# -ge 1 ]; then
  tag="$1"
else
  step "tag"
  tag="$(next_tag)"
  echo "$tag"
fi
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "invalid tag: $tag" >&2; exit 2; }

if [ "${DRY_RUN:-0}" = 1 ]; then
  step "dry run: would release $image:$tag"
  echo "bumps:${bumped:- none}"
  if [ "$version" != "$old_version" ]; then
    echo "new manifest: manifests/claude-code-$version.yaml (manifests/claude-code-$old_version.yaml kept)"
  fi
  echo "Dockerfile restored; nothing built or pushed."
  exit 0
fi

# ── 3–4. verify before anything is pushed ───────────────────────────────────

docker buildx inspect "$builder" >/dev/null 2>&1 || docker buildx create --name "$builder" >/dev/null

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  step "verify: args, contract"
  ./verify.sh args
  ./verify.sh contract

  step "verify: image, on a local candidate of Claude Code $version"
  docker buildx build --builder "$builder" --load --tag "$candidate" .
  ./verify.sh image "$candidate"
fi

# ── 5–6. publish, then verify what was published ────────────────────────────

step "build and push $image:$tag (linux/amd64, linux/arm64)"
meta="$(mktemp)"
docker buildx build --builder "$builder" \
  --platform linux/amd64,linux/arm64 \
  --tag "$image:$tag" \
  --push \
  --metadata-file "$meta" \
  .

docker pull "$image:$tag"
digest="$(jq -r '."containerimage.digest" // empty' "$meta")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest in build metadata"
new_ref="$image@$digest"
published=1
echo "published: $new_ref"

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  step "verify: image, conformance against $new_ref"
  ./verify.sh image "$new_ref"
  ./verify.sh conformance "$new_ref"
fi

# ── 7. record ───────────────────────────────────────────────────────────────

version_manifest="manifests/claude-code-$version.yaml"

if [ "$version" != "$old_version" ]; then
  step "record Claude Code $version"
  old_manifest="manifests/claude-code-$old_version.yaml"
  old_dots="${old_version//./\\.}"   # the version as a sed pattern
  old_dashes="${old_version//./-}"   # as it appears in the runtime name
  new_dashes="${version//./-}"
  renames=(-e "s/$old_dots/$version/g" -e "s/v$old_dashes/v$new_dashes/g")

  # The earlier manifest stays exactly as it is, with the digest it was
  # published under. The new one starts as a copy with the names moved on.
  if [ ! -f "$version_manifest" ]; then
    [ -f "$old_manifest" ] || die "no $old_manifest to base $version_manifest on"
    sed "${renames[@]}" "$old_manifest" > "$version_manifest"
    echo "  $version_manifest (new; $old_manifest kept)"
  fi
  for f in README.md CONFORMANCE.md examples/agentrun-subscription.yaml; do
    [ -f "$f" ] || continue
    rewrite "$f" "${renames[@]}"
    echo "  $f"
  done
fi
[ -f "$version_manifest" ] || die "no $version_manifest for the pinned Claude Code $version"

step "record $digest"
# The files that name the current image. Every one must end up naming the
# same digest, because the allowlist and the runtime are matched as written.
# Earlier versions' manifests are deliberately not in this list.
recorded=(README.md CONFORMANCE.md "$version_manifest" examples/agentrun-subscription.yaml)

for f in "${recorded[@]}"; do
  [ -f "$f" ] || continue
  grep -qE "$ref_re" "$f" || continue
  rewrite "$f" -E "s|$ref_re|$new_ref|g"
  echo "  $f"
done
# The tag CONFORMANCE.md names, so a reader can find the image by tag too. It
# is also what next_tag falls back on for a private repository.
if [ -f CONFORMANCE.md ]; then
  rewrite CONFORMANCE.md -E "s|(docker\.io/$DH_USER/sympozium-harness-claude):[A-Za-z0-9_][A-Za-z0-9_.-]*|\1:$tag|g"
fi
stale=""
for f in "${recorded[@]}"; do
  [ -f "$f" ] || continue
  if grep -oE "$ref_re" "$f" | grep -vqxF "$new_ref"; then stale+=" $f"; fi
done
[ -z "$stale" ] || die "files still naming another digest:$stale"

printf '\nReleased %s\n         %s\n' "$image:$tag" "$new_ref"
printf 'Commit it: git add -A && git commit -m "published %s"\n' "$tag"
