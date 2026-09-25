# Conformance evidence

What this adapter claims against the Sympozium harness contract `v1alpha1`, and
what was run to prove it. The gates are the ones
[sympozium-ai/harness-adapters](https://github.com/sympozium-ai/harness-adapters)
asks an adapter to pass before publication
([`docs/adapter-contract.md`](https://github.com/sympozium-ai/harness-adapters/blob/main/docs/adapter-contract.md)).

This is evidence for that contract. It is not an endorsement by Anthropic.

## What runs

| | |
|---|---|
| Image | `docker.io/fooman/sympozium-harness-claude:v2.1.280-4` |
| Digest | `docker.io/fooman/sympozium-harness-claude@sha256:d29a44746954c035c8271ebb80660b0fa1381398e00e5cf675d63e5f539c8467` |
| Upstream | Claude Code `2.1.280`, the native linux binary from `@anthropic-ai/claude-code-linux-{x64,arm64}`, pinned as the `CLAUDE_CODE_VERSION` default and checked against npm's published SHA-512 |
| Base | `debian:trixie-slim`, pinned by index digest, so a rebuild months later is the same image |
| Contract | `v1alpha1`, checked at startup and refused if it is anything else |
| Runs as | UID 1000, read-only root filesystem, `/workspace` |
| Writable | only the platform's mounts: `$HOME`, `/tmp`, and the result mount |
| Platforms | `linux/amd64`, `linux/arm64` |
| Support owner | [`fooman/sympozium-harness-claude`](https://github.com/fooman/sympozium-harness-claude) |
| Support tier | Experimental |

The image downloads one pinned binary at build time and runs no installer, at
build time or at AgentRun startup. Nothing is downloaded during a run.

## Capabilities

Declared: **`persona`** and **`toolFilter`**.

| | How |
|---|---|
| `persona` | `spec.systemPrompt` is appended to Claude Code's system prompt with `--append-system-prompt`. |
| `toolFilter` | `spec.toolPolicy.allow` becomes `--tools`, which removes every other built-in tool from the model's context. `deny` becomes `--disallowedTools`, which holds in `bypassPermissions` mode. agent-runner's tool names are mapped to Claude Code's. `./verify.sh image` checks the result from Claude Code's own init event. |

Not declared, and rejected at admission if a run asks for them:

| | Why |
|---|---|
| `outputSchema`, `subagents`, `resume` | Rejected by Sympozium for any harness image; there is no mediated way for an external process to implement them. |

MCP and SkillPack tools are supported: `MCP_CONFIG_PATH` becomes one
`--mcp-config` of `http` servers, passed with `--strict-mcp-config`. The
`sympozium-skills` server applies `spec.toolPolicy` itself, whatever this
image declares. A registry entry this adapter cannot translate faithfully
(`auth`, `toolsAllow`, `toolsDeny`) fails the run.

## Accounting

Claude Code reports its own usage in its final `result` event, and the adapter
passes it on: `inputTokens` (cache reads and writes included),
`cachedInputTokens` (the cache-read part), `outputTokens`, `durationMs` and
`toolCalls`. A run that reports no usage reports no metrics, never zeros, and
malformed numbers are dropped rather than emitted.

Sympozium still requires `harnessPolicy.allowUnmetered: true` for this image,
as for every harness image: it cannot check an external harness's numbers.

## Evidence

`./verify.sh` is the suite. Every stage below is reproducible with docker and
no credential. The results were produced against a local build of this source
(`sympozium-harness-claude:dev`). `scripts/release.sh` reruns `image` and
`conformance` against the digest it publishes, before it records that digest
here.

| Stage | Proves | Result |
|---|---|---|
| `./verify.sh args` | the generated invocation (argv, env, MCP config) and every loud failure it owes: a missing credential, a subscription token aimed at a third party, a non-Anthropic provider, a pattern in allow, an untranslatable MCP entry, a redacted dump | 54 passed |
| `./verify.sh contract` | the result contract against a stub harness (success, error, a forged `__SYMPOZIUM_RESULT__` marker, an unwritable result path, metrics validation, the parse and log hooks, SIGTERM) and against a stub `claude` (stream-json results, usage, the skip marker, what reaches the pod log) | 68 passed |
| `./verify.sh image <tag>` | the pinned Claude Code boots in the image, and its own init event shows the named model, exactly the allowed built-in tool, and the MCP entry; the dead endpoint fails the run through the contract, not the flags | 7 passed |
| `./verify.sh conformance <tag>` | the container boundary: UID 1000, read-only root, `/workspace`, no TTY, the task from `/ipc/input/task.json`, the published failure-path smoke, a refused contract version, the official skip marker, identical boot on tmpfs, and SIGTERM | 17 passed |

The upstream fixture passes unmodified against the same image. It is pinned to
a commit and checked against the hash of what was reviewed, because the step
downloads a script and runs it:

```sh
curl -fsSLO https://raw.githubusercontent.com/sympozium-ai/harness-adapters/0d8f50c4be0c9ba2eeba1f68b9d4bab902793ef0/test/contract-smoke.sh
echo "3f2302f50b9a8742b39cd0554b8e591c735a0446dc6c0b05190c855e94321904  contract-smoke.sh" | sha256sum -c -
sh contract-smoke.sh claude-code <tag>     # claude-code contract failure-path smoke passed
```

Three checks trace back to real defects found while building this adapter:

- **Subprocess credential scrub.** `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` makes
  Claude Code require bubblewrap, and bubblewrap needs user namespaces, which
  the pod's security context blocks. Every run failed at startup. The adapter
  now turns the scrub off explicitly; README.md says what that exposes.
- **The browser code is not the token.** `claude setup-token` shows a
  single-use code in the browser before it prints the token in the terminal. A
  Secret holding the code fails as `401 Invalid bearer token`. The adapter no
  longer requires the token's prefix, and the docs say which value to store.
- **Usage shape.** Anthropic reports `input_tokens` without cache reads and
  writes, the opposite of OpenAI. The adapter normalises once, to the OpenAI
  shape agent-runner uses, and reports the cache-read part separately.

## Still outstanding

- **A cluster smoke on a real model call**, recorded here with the AgentRun
  name, the runtime source, and the digest Sympozium recorded on
  `status.harnessImageDigest`. `./verify.sh live <tag>` is one real turn
  through Anthropic with a subscription token, but it is not a run through
  Sympozium.
- **Evidence against the published digest.** The digest above predates this
  layout; the next `scripts/release.sh` run publishes, verifies and records
  one.
- **An SBOM and a vulnerability scan** of the published image.
- **A signature or attestation for the published image**, so an operator can
  check that the digest they approve was built from this source.
