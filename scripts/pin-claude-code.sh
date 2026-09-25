#!/usr/bin/env bash
# Pin a Claude Code release: rewrite CLAUDE_CODE_VERSION and the two binary
# checksums in the Dockerfile, from the SHA-512 integrity npm publishes for the
# native linux packages. Then build and run ./verify.sh image, which is what
# says the bump still maps.
#
# Usage: scripts/pin-claude-code.sh 2.1.281
set -euo pipefail

version="${1:?usage: $0 <claude-code version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "not a version: $version" >&2; exit 2; }
cd "$(dirname "$0")/.."

sha512_hex() {
  local integrity
  integrity="$(npm view "@anthropic-ai/claude-code-linux-$1@${version}" dist.integrity 2>/dev/null)"
  [[ "$integrity" == sha512-* ]] || { echo "no sha512 integrity for linux-$1@${version}" >&2; exit 1; }
  printf '%s' "${integrity#sha512-}" | base64 -d | od -An -tx1 -v | tr -d ' \n'
}

x64="$(sha512_hex x64)"
arm64="$(sha512_hex arm64)"

tmp="$(mktemp)"
sed -E \
  -e "s/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=${version}/" \
  -e "s/^ARG CLAUDE_CODE_SHA512_X64=.*/ARG CLAUDE_CODE_SHA512_X64=${x64}/" \
  -e "s/^ARG CLAUDE_CODE_SHA512_ARM64=.*/ARG CLAUDE_CODE_SHA512_ARM64=${arm64}/" \
  Dockerfile > "$tmp"
[ "$(grep -cE "^ARG CLAUDE_CODE_(VERSION=${version}|SHA512_X64=${x64}|SHA512_ARM64=${arm64})$" "$tmp")" -eq 3 ] ||
  { rm -f "$tmp"; echo "could not find the three ARG lines in Dockerfile" >&2; exit 1; }
mv "$tmp" Dockerfile

grep -E '^ARG CLAUDE_CODE_' Dockerfile
echo
echo "Next: docker build -t sympozium-harness-claude:dev . && ./verify.sh image sympozium-harness-claude:dev"
echo "Then rename the AgentRuntime (manifests/, examples/, README.md) to the new version."
