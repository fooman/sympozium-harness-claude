# sympozium-harness-claude

A [Sympozium](https://github.com/sympozium-ai/sympozium) harness adapter for
[Claude Code](https://code.claude.com), with Claude subscription support.

Sympozium's `task.mode: harness` runs an external agent harness as the pod's primary process
instead of `agent-runner`. The workspace PVC, SkillPack tools, gates, retries and the run-detail
UI keep working, because the result contract is unchanged. Sympozium ships that seam and no
harnesses. This repo is one adapter for it.

The adapter runs `claude -p` once per run. It can bill a Claude Pro or Max subscription instead
of API credits: give it a long-lived token from `claude setup-token`. An Anthropic API key works
too.

> Needs Sympozium **v0.10.51** or later. Harness mode landed in v0.10.49. v0.10.51 added the
> `harnessPolicy.allowUnmetered` opt-in every harness image needs, and fixed the SkillPack
> sidecar's startup probe, without which a run with sidecar tools never starts.

## Try it

Two objects do the work. An administrator writes an `AgentRuntime` that pins the image digest,
states the contract version and declares what the image honours. Runs then name the runtime and
restate none of it.

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: AgentRuntime
metadata:
  name: claude-code-v2-1-280
spec:
  image: docker.io/fooman/sympozium-harness-claude@sha256:d29a44746954c035c8271ebb80660b0fa1381398e00e5cf675d63e5f539c8467
  contractVersion: v1alpha1
  capabilities: [persona, toolFilter]
  supportOwner: platform@example.com
```

```yaml
task:
  mode: harness
  parameters:
    runtime: claude-code-v2-1-280
    prompt: "Summarise what /workspace contains."
```

**[`examples/agentrun-subscription.yaml`](examples/agentrun-subscription.yaml)** is the whole
thing on a subscription: the policy that permits harness mode, the runtime, an Agent bound to
both, and a run, with every non-obvious field explained inline.

```sh
claude setup-token                  # on a machine logged in to Claude
printf 'Token: '; read -rs CLAUDE_TOKEN; echo
kubectl create secret generic claude-subscription --from-literal=ANTHROPIC_API_KEY="$CLAUDE_TOKEN"
unset CLAUDE_TOKEN
kubectl apply -f examples/agentrun-subscription.yaml
kubectl logs -f -l sympozium.ai/agent-run=claude-demo -c agent
```

Bind the runtime to an Agent with `spec.runtimeRef` and Sympozium converts that Agent's ordinary
string-form tasks into harness mode too. Channel messages, schedules, API calls and New Run then
reach Claude Code without anyone writing an object-form task. The adapter needs no `baseURL` and
no `spec.env`, so those string-form runs work as they are.

Harness mode fails closed twice. The Agent must be bound to a `SympoziumPolicy` with
`harnessPolicy.enabled: true`, and that policy must also set `harnessPolicy.allowUnmetered: true`.

## Subscription or API key

Sympozium injects only the Secret keys on its `allowedAuthSecretKeys` list, and
`CLAUDE_CODE_OAUTH_TOKEN` is not one of them. The Sympozium docs say not to widen that list to
make an adapter work. So both kinds of credential go in the Secret under `ANTHROPIC_API_KEY`, and
the adapter decides which one it holds:

| Value | `spec.model.baseURL` | Claude Code gets | Bills |
|---|---|---|---|
| starts with `sk-ant-api` | any | `ANTHROPIC_API_KEY` | API credits |
| anything else | empty or `https://api.anthropic.com` | `CLAUDE_CODE_OAUTH_TOKEN` | your subscription |
| anything else | another endpoint | `ANTHROPIC_API_KEY` | that endpoint |

Anthropic API keys have a fixed prefix, so the adapter recognises those and treats anything else
as a token. The third row exists because a subscription token only works at Anthropic, so a
value meant for a proxy has to be that proxy's key. A value starting with `sk-ant-oat`, the
format `claude setup-token` prints, is never sent anywhere but Anthropic. The adapter strips
whitespace from the value, since a token copied from a wrapped terminal line often has a newline
in it.

Claude Code prefers an API key over a token when both are set, so the adapter exports exactly
one. If a later Sympozium adds `CLAUDE_CODE_OAUTH_TOKEN` to the allowlist, the adapter takes it
from there first.

`claude setup-token` works in two steps. The browser shows a short code that you paste back into
the terminal, and then the terminal prints the token. Store the token. The code is single-use,
and a Secret holding it fails every run with `401 Invalid bearer token`.

Subscription usage counts against your plan's limits and is governed by its terms. A subscription
belongs to one person.

## Pin the digest

A tag is rejected, by the admission webhook and again by the controller. In harness mode the image
is not an accessory to the run. It is the agent process. Get the digest for a tag with:

```sh
docker buildx imagetools inspect docker.io/fooman/sympozium-harness-claude:<tag> \
  --format '{{.Manifest.Digest}}'
```

That digest goes in two places, and they must match as written: the runtime's `spec.image`, and
`SympoziumPolicy.imagePolicy.allowedRegistries`. The allowlist is a plain string prefix, so an
entry that ends at the full digest admits one artifact. An empty list means no restriction at all.

The digest in this README, in `examples/` and in `manifests/` is the latest published image.
`scripts/release.sh` updates all of them together when it publishes a new one.

Sympozium records what ran on the AgentRun's status. `harnessImageDigest` is the image that
executed, and `harnessRuntimeRef`, `harnessContractVersion` and `harnessRuntimeSource` say which
`AgentRuntime` resolved, under which contract, and whether the run named it or inherited it from
the Agent.

## What it maps

| Sympozium supplies | Claude Code gets |
|---|---|
| the task text | stdin, so a task starting with `-` is never read as a flag |
| `ANTHROPIC_API_KEY` | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, see above |
| `spec.model.model` | `--model`, and every model slot Claude Code would otherwise fill itself |
| `spec.model.baseURL` | `ANTHROPIC_BASE_URL`, minus a trailing `/v1` |
| `spec.systemPrompt` | `--append-system-prompt` |
| `spec.toolPolicy.allow` | `--tools`, the built-in tool set |
| `spec.toolPolicy.deny` | `--disallowedTools` |
| `MCP_CONFIG_PATH` | one generated `--mcp-config`, with `--strict-mcp-config` |
| `task.parameters.args` | extra `claude` flags, after the adapter's own |

`spec.model.provider` must be `anthropic`. Claude Code only speaks the Anthropic API, so the
adapter refuses any other provider rather than send the run somewhere it cannot work.

The model named on the run is the only model the run uses. The adapter sets `ANTHROPIC_MODEL`,
the three `ANTHROPIC_DEFAULT_*_MODEL` variables and `CLAUDE_CODE_SUBAGENT_MODEL` to it, so
background tasks and subagents do not fall back to a default the manifest never mentioned.

Nothing ambient can outrank that. `$HOME` is a fresh `emptyDir` per run, and the adapter loads
settings only from there (`--setting-sources user`). A `.claude/settings.json` that an earlier
run left in `/workspace` cannot add hooks, change the model or set an `apiKeyHelper`. A
`.mcp.json` there is ignored too.

Claude Code runs with `--permission-mode bypassPermissions`, because nobody can answer a
permission prompt in a pod. The pod is the sandbox: UID 1000, read-only root, no Kubernetes
token, and `/ipc` narrowed to `input/` and `output/`. `toolPolicy` narrows what the model can do
inside it.

## Declare `persona` and `toolFilter`

That declaration is the whole basis on which Sympozium admits a harness run, and this image
honours both fields.

**`persona`.** `spec.systemPrompt` is appended to Claude Code's own system prompt rather than
replacing it, because that prompt carries Claude Code's tool-use instructions.

**`toolFilter`.** Policy names are Claude Code tool names: `Bash`, `Read`, `Edit`, `WebFetch`
and so on.

- An allow list becomes `--tools`, which removes every other built-in tool from the model's
  context. It filters; it does not prompt. An allow list naming no built-in tool leaves none.
- A deny list becomes `--disallowedTools`. Deny rules hold in `bypassPermissions` mode, and
  Claude Code patterns such as `Bash(rm:*)` work there.
- Allow takes names only. A pattern in allow fails the run, since no permission step exists to
  enforce it.
- agent-runner's names are mapped, so a policy written for agent-runner still applies:
  `execute_command` is `Bash`, `read_file` is `Read`, `write_file` is `Write`, `Edit` and
  `NotebookEdit`, and `list_directory` is `Glob`.
- Any other name is a SkillPack tool. Sympozium's own MCP server enforces those whatever this
  image declares. On deny the adapter also removes them by their MCP name,
  `mcp__sympozium-skills__<name>`.

`./verify.sh image` checks this against the real binary. With `toolPolicy.allow: [Read,
kubectl_get]`, Claude Code's own init event lists exactly one built-in tool.

`outputSchema`, `subagents` and `resume` are rejected for any harness image. Claude Code's
in-process subagents are not Sympozium child runs, and they inherit the tool filter.

## Token usage

Unlike most harness adapters, this one reports real usage. Claude Code's final `result` event
carries it, and the adapter converts it once, to the usage shape agent-runner uses for OpenAI:

| Metric | From Claude Code |
|---|---|
| `inputTokens` | `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` |
| `cachedInputTokens` | `cache_read_input_tokens`, a part of `inputTokens` |
| `outputTokens` | `output_tokens` |
| `durationMs` | `duration_ms` |
| `toolCalls` | `tool_use` blocks in the stream, subagents included |

Anthropic reports it the other way round: `input_tokens` is only the uncached remainder. A long
Claude Code run re-reads its cached context on every tool call, so most of `inputTokens` is
usually `cachedInputTokens`.

Sympozium's controller does not read `cachedInputTokens` yet. `status.tokenUsage` and the cost
estimate treat all input as full price, and the breakdown is visible only in the pod log and
`result.json`. On a subscription the cost estimate is notional anyway. A run with no reported
usage reports no metrics rather than zeros.

`harnessPolicy.allowUnmetered: true` is still required. Sympozium cannot check any external
harness's numbers, so it treats every harness image as unmetered.

## Things that will bite

**The credential is readable inside the run.** Claude Code needs it in its environment, and
`Bash` and every other tool that runs code start as the same user. Claude Code can scrub it from
subprocesses (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`), but the scrub needs bubblewrap and user
namespaces, which the harness pod's seccomp profile blocks. The adapter turns it off so it cannot
fail the run. A prompt-injected run with `Bash` could send the token out of the pod. For
untrusted input, deny `Bash` and `WebFetch`, add a NetworkPolicy that allows egress only to
`api.anthropic.com` and what the run needs, or both. Run `claude setup-token` again if you think a
token leaked. The adapter unsets every other platform key and every `MCP_AUTH_*` before Claude
Code starts, and never logs the credential.

**MCP is SkillPack tools only.** Sympozium rejects harness runs that inherit remote MCP servers
until it has a trusted local mediator for their credentials, so the registry holds only
`sympozium-skills`. If an entry ever arrives with `auth`, `toolsAllow` or `toolsDeny`, the run
fails rather than drop what the adapter cannot translate.

**Skill instructions are pointed at, not inlined.** agent-runner pastes every file in `/skills`
into its system prompt. This adapter adds one line saying they are there, and Claude reads them
with `Read`. A `toolPolicy.allow` without `Read` leaves them unreadable.

**`/workspace/CLAUDE.md` still loads** as project instructions. It lives in the workspace, which
earlier runs write to, so treat it like the rest of the workspace.

## Contract version

This image implements the `v1alpha1` adapter contract and runs under no other. It reads
`SYMPOZIUM_HARNESS_CONTRACT_VERSION` at startup and refuses anything that is not `v1alpha1`,
absent included, through the result contract. A platform upgrade that changes the contract
therefore fails loudly, rather than producing a run whose answer goes somewhere nothing reads.

The version this image implements is a constant in `harness-lib.sh`, so bumping it is a code
change and a rebuild. Running the image outside Sympozium has to name the contract:

```sh
docker run --rm -e SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1 … <image>
```

## Operating notes

The pod log shows one line per event worth watching, and never model text or tool input:

```
harness/claude-code: 2.1.280 (Claude Code) model=claude-sonnet-5 auth=subscription
harness/claude-code > session model=claude-sonnet-5 tools=12 mcp=sympozium-skills:connected
harness/claude-code > tool Bash
harness/claude-code > tool Edit
```

A preRun hook that finds no work can skip the run. The adapter reads `/ipc/control/skip`, or
`/workspace/.sympozium/skip` on releases that do not mount `/ipc/control`, and reports
`{"status": "skipped"}` with the file's content as the reason. It needs no task or credential to
do that, and it removes the workspace copy once read so a leftover never skips the next run.

`task.parameters.args` goes after the adapter's own flags, so the run author can override them:
`'["--max-turns","20"]'`, say.

## Conformance

The gates are the ones
[sympozium-ai/harness-adapters](https://github.com/sympozium-ai/harness-adapters) asks an adapter to
pass before publication, and **[CONFORMANCE.md](CONFORMANCE.md)** records what this adapter claims
against them and what was run to prove it. `manifests/claude-code-2.1.280.yaml` is the
`AgentRuntime` on its own.

## Build and check

```sh
docker build -t sympozium-harness-claude:dev .
./verify.sh args                                     # the generated invocation, no docker
./verify.sh contract                                 # the result contract, against stubs, no docker
./verify.sh image sympozium-harness-claude:dev       # the real Claude Code against a dead endpoint
./verify.sh conformance sympozium-harness-claude:dev # the container boundary
CLAUDE_CODE_OAUTH_TOKEN=… ./verify.sh live sympozium-harness-claude:dev   # one real turn
```

Everything but `live` runs with no credential and no cluster, and
[`.github/workflows/verify.yml`](.github/workflows/verify.yml) runs all of it on every push, plus
the upstream fixture unmodified.

The image contains Claude Code's native linux binary and nothing else from npm. The
Dockerfile pins `CLAUDE_CODE_VERSION` and the SHA-512 of each architecture's binary, and the base
image by index digest, so two builds of the same source are the same agent. To move to a new
Claude Code release:

```sh
scripts/pin-claude-code.sh 2.1.281      # rewrites the version and both checksums from npm
docker build -t sympozium-harness-claude:dev .
./verify.sh image sympozium-harness-claude:dev
```

`./verify.sh image` is the check that matters on a bump. Claude Code changes flags between
releases, and a flag whose meaning shifted still produces a run that succeeds. `--build-arg
INSTALL_GIT=false` drops ~79MB if the agent does not need git.

`scripts/release.sh <tag>` publishes: it runs the checks, pushes both architectures, reruns
`image` and `conformance` against the pushed digest, and records that digest everywhere this repo
names it.

Claude Code itself is Anthropic's software, © Anthropic PBC, and its use is subject to
[Anthropic's legal agreements](https://code.claude.com/docs/en/legal-and-compliance). This repo
contains none of it. The image downloads the binary from npm at build time.

## See also

- [Task mode: harness](https://github.com/sympozium-ai/sympozium/blob/main/docs/modes/harness.md): the mode, the `AgentRuntime` resource, and what Sympozium supplies
- [Writing a harness adapter](https://github.com/sympozium-ai/sympozium/blob/main/docs/modes/harness-adapters.md): the contract both sides implement
- [sympozium-ai/harness-adapters](https://github.com/sympozium-ai/harness-adapters): the adapter program, its conformance gates, and the reference, Pi and Hermes adapters
- [fooman/sympozium-harness-dsh](https://github.com/fooman/sympozium-harness-dsh): the DeepSeek Harness adapter this one shares `harness-lib.sh` with
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference): the flags this adapter passes
