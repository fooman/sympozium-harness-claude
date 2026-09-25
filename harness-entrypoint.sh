#!/usr/bin/env bash
# harness-entrypoint.sh: the Claude Code adapter.
#
# Claude Code is configured by per-run flags and environment, so this adapter's
# job is to turn what Sympozium supplies into one `claude -p` invocation:
#
#   TASK / /ipc/input/task.json  → stdin, so a task is never read as a flag
#   ANTHROPIC_API_KEY            → CLAUDE_CODE_OAUTH_TOKEN for a subscription
#                                  token, ANTHROPIC_API_KEY for an API key
#   MODEL_NAME                   → --model, and every model slot Claude Code
#                                  would otherwise fill with a default
#   MODEL_BASE_URL               → ANTHROPIC_BASE_URL, minus a trailing /v1
#   SYSTEM_PROMPT                → --append-system-prompt
#   TOOL_POLICY_ALLOW            → --tools (the built-in tool set)
#   TOOL_POLICY_DENY             → --disallowedTools
#   MCP_CONFIG_PATH (JSON)       → one generated --mcp-config, strictly
#   task.parameters.args         → extra claude flags, after the adapter's
#
# The answer comes back from Claude Code's stream-json output, with real token
# usage, through harness::parse_output. The pod log shows one line per tool
# call, never model text or tool input, through harness::log_filter.
set -euo pipefail

# shellcheck source=./harness-lib.sh
# The path is overridable so verify.sh can drive this script from a checkout
# without an installed image; in the image it is always the copied library.
. "${HARNESS_LIB:-/usr/local/lib/harness-lib.sh}"

# Names the backend in harness-lib's log line and in a failure result, so a
# pod log says which harness exited non-zero rather than "unknown".
export HARNESS_BACKEND=claude-code

harness::require_contract

# HARNESS_DUMP_ARGS=1 prints the generated invocation as JSON and exits without
# running Claude Code. verify.sh asserts against it. Credentials are
# redacted in that mode: the dump is meant to be pasted into a terminal or a
# bug report, which is not somewhere a live token belongs.
DUMP_ONLY="${HARNESS_DUMP_ARGS:-}"

# A skip marker ends the run before any credential or task is read. Not in a
# dump, which must not consume the workspace fallback marker.
[ -n "$DUMP_ONLY" ] || harness::check_skip

# ── credential ──────────────────────────────────────────────────────────────
#
# Sympozium injects only allowlisted Secret keys, and CLAUDE_CODE_OAUTH_TOKEN
# is not on that list. A subscription token from `claude setup-token` is
# therefore stored under ANTHROPIC_API_KEY. Anthropic API keys have a fixed
# prefix (sk-ant-api); for subscription tokens the adapter does not rely on
# one. So it recognises the API key and treats anything else as a token,
# unless the run points at a non-Anthropic endpoint, where only an API key can
# work. Claude Code prefers ANTHROPIC_API_KEY over an OAuth token, so exactly
# one of the two is exported.
ANTHROPIC_URL=https://api.anthropic.com
BASE_URL="${MODEL_BASE_URL:-}"
BASE_URL="${BASE_URL%/}"
BASE_URL="${BASE_URL%/v1}"

# Tokens pasted from a wrapped terminal line often carry whitespace.
oauth_token="$(tr -d '[:space:]' <<<"${CLAUDE_CODE_OAUTH_TOKEN:-}")"
api_key="$(tr -d '[:space:]' <<<"${ANTHROPIC_API_KEY:-}")"
if [ -z "$oauth_token" ] && [ -n "$api_key" ] && [[ "$api_key" != sk-ant-api* ]] &&
  { [ -z "$BASE_URL" ] || [ "$BASE_URL" = "$ANTHROPIC_URL" ] || [[ "$api_key" == sk-ant-oat* ]]; }; then
  oauth_token="$api_key"
fi
[ -z "$oauth_token" ] || api_key=""

# Every other platform key and MCP credential goes too: Claude Code uses none
# of them, and the commands it runs inherit its environment.
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
harness::drop_credentials

if [ -n "$oauth_token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"
  AUTH_MODE=subscription
elif [ -n "$api_key" ]; then
  export ANTHROPIC_API_KEY="$api_key"
  AUTH_MODE=api-key
else
  harness::fail "harness/claude-code: no Anthropic credential. spec.model.authSecretRef must name a Secret with the key ANTHROPIC_API_KEY, holding a subscription token (claude setup-token) or an API key"
fi
unset oauth_token api_key

# ── model routing ───────────────────────────────────────────────────────────
#
# Sympozium sets MODEL_NAME/MODEL_BASE_URL/MODEL_PROVIDER and injects the
# credential, then stops; nothing verifies that a harness routes where the
# AgentRun says. Claude Code only speaks the Anthropic Messages API, so any
# other provider is refused rather than sent somewhere it cannot work.
[ "${MODEL_PROVIDER:-}" = anthropic ] ||
  harness::fail "harness/claude-code: MODEL_PROVIDER (spec.model.provider) is \"${MODEL_PROVIDER:-}\"; this adapter only routes to provider \"anthropic\""

MODEL="${MODEL_NAME:-}"
[ -n "$MODEL" ] || harness::fail "harness/claude-code: no model supplied (spec.model.model)"
model_re='^[][A-Za-z0-9._:@/-]+$'
[[ "$MODEL" =~ $model_re ]] || harness::fail "harness/claude-code: MODEL_NAME \"$MODEL\" is not a valid model name"

# Pin every model slot to the one the AgentRun names, so background work and
# subagents do not quietly use a model the manifest never mentioned.
unset ANTHROPIC_SMALL_FAST_MODEL
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"

unset ANTHROPIC_BASE_URL
if [ -n "$BASE_URL" ]; then
  if [ "$AUTH_MODE" = subscription ] && [ "$BASE_URL" != "$ANTHROPIC_URL" ]; then
    # A subscription token is only valid at Anthropic. Sending it anywhere
    # else would hand it to a third party.
    harness::fail "harness/claude-code: MODEL_BASE_URL \"$MODEL_BASE_URL\" is not Anthropic; a subscription token is only sent to $ANTHROPIC_URL"
  fi
  [[ "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]] ||
    harness::fail "harness/claude-code: MODEL_BASE_URL (spec.model.baseURL) must be an absolute http(s) URL, got \"$MODEL_BASE_URL\""
  [ "$BASE_URL" = "$ANTHROPIC_URL" ] || export ANTHROPIC_BASE_URL="$BASE_URL"
fi

# ── harness hygiene ─────────────────────────────────────────────────────────
#
# $HOME is the run's fresh emptyDir, so Claude Code's config and state start
# empty every run: no ambient login, settings or MCP servers to win over what
# the AgentRun says.
export CLAUDE_CONFIG_DIR="${HOME:-/home/agent}/.claude"
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# Claude Code's subprocess credential scrub needs bubblewrap and user
# namespaces, which the harness pod's seccomp profile and dropped capabilities
# do not allow. Turned off explicitly so it cannot fail the run; the README
# says what that exposes.
export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0

argv=(
  -p
  --output-format stream-json
  --verbose
  --model "$MODEL"
  --permission-mode bypassPermissions
  --no-session-persistence
  # Only settings from the fresh $HOME. /workspace is agent-written and
  # persists between runs; its .claude/settings*.json could otherwise add
  # hooks, env or an apiKeyHelper.
  --setting-sources user
  --strict-mcp-config
)

# ── persona ─────────────────────────────────────────────────────────────────
#
# Appended rather than replaced, so Claude Code keeps its own tool-use
# instructions. The persona still governs the run.
append_prompt="${SYSTEM_PROMPT:-}"
if [ -d /skills ] && [ -n "$(find /skills -mindepth 1 -maxdepth 3 -type f -print -quit 2>/dev/null)" ]; then
  append_prompt+="${append_prompt:+$'\n\n'}Skill files for this run are mounted read-only at /skills. Read the ones relevant to the task."
fi
[ -z "$append_prompt" ] || argv+=(--append-system-prompt "$append_prompt")

# ── MCP ─────────────────────────────────────────────────────────────────────
#
# Entries needing credentials or per-server tool filters cannot be translated
# faithfully, so the run fails rather than dropping the filter. In practice the
# only entry is sympozium-skills: Sympozium rejects harness runs that inherit
# remote MCP servers.
REGISTRY="$(harness::mcp_registry)" || harness::fail "harness/claude-code: MCP_CONFIG_PATH ($MCP_CONFIG_PATH) is not a JSON object"
unsupported="$(jq -r '[.servers[]? | select(.auth != null or ((.toolsAllow // []) | length) > 0 or ((.toolsDeny // []) | length) > 0) | .name] | join(",")' <<<"$REGISTRY")"
[ -z "$unsupported" ] || harness::fail "harness/claude-code: MCP servers with auth or per-server tool filters are not supported: $unsupported"
bad_names="$(jq -r '[.servers[]? | .name | select(test("^[A-Za-z0-9_-]+$") | not)] | join(",")' <<<"$REGISTRY")"
[ -z "$bad_names" ] || harness::fail "harness/claude-code: MCP server names must match [A-Za-z0-9_-]+: $bad_names"
MCP_CONFIG="$(jq -c '{mcpServers: (reduce (.servers // [])[] as $s ({};
    . + {($s.name): ({type: "http", url: $s.url}
      + (if (($s.headers // {}) | length) > 0 then {headers: $s.headers} else {} end))}))}' <<<"$REGISTRY")"
MCP_CONFIG_FILE="$CLAUDE_CONFIG_DIR/sympozium-mcp.json"
argv+=(--mcp-config "$MCP_CONFIG_FILE")
mcp_timeout_s="$(jq '[.servers[]?.timeout // 0] | max // 0' <<<"$REGISTRY")"
[ "$mcp_timeout_s" -le 0 ] || export MCP_TOOL_TIMEOUT="$((mcp_timeout_s * 1000))"

# ── tool filter ─────────────────────────────────────────────────────────────
#
# spec.toolPolicy names are Claude Code tool names (Bash, Read, Edit, ...).
# Sympozium's own agent-runner names are mapped too, so a policy written for
# agent-runner does not silently stop applying. Any other name is taken as a
# SkillPack tool; the skill tool server enforces those itself, and on deny it
# is also removed here by its MCP name.
claude::map_tool() {
  case "$1" in
    execute_command) echo Bash ;;
    read_file) echo Read ;;
    write_file) printf '%s\n' Write Edit NotebookEdit ;;
    list_directory) echo Glob ;;
    *) echo "$1" ;;
  esac
}
claude::is_builtin() { [[ "$1" =~ ^[A-Z][A-Za-z]*$ ]]; }

if [ -n "${TOOL_POLICY_ALLOW:-}" ]; then
  allowed=()
  while IFS= read -r entry; do
    [[ "$entry" == *'('* ]] &&
      harness::fail "harness/claude-code: toolPolicy.allow entry \"$entry\" is a pattern; allow takes tool names only, put patterns in deny"
    while IFS= read -r t; do
      if claude::is_builtin "$t"; then allowed+=("$t"); fi
    done < <(claude::map_tool "$entry")
  done < <(harness::split_csv "$TOOL_POLICY_ALLOW")
  # An allow list without built-in names leaves Claude Code no built-in tools.
  argv+=(--tools "$(IFS=,; echo "${allowed[*]:-}")")
fi

if [ -n "${TOOL_POLICY_DENY:-}" ]; then
  denied=()
  while IFS= read -r entry; do
    while IFS= read -r t; do
      if claude::is_builtin "$t" || [[ "$t" =~ ^[A-Z][A-Za-z]*\(.*\)$ ]] || [[ "$t" == mcp__* ]]; then
        denied+=("$t")
      else
        denied+=("mcp__sympozium-skills__$t")
      fi
    done < <(claude::map_tool "$entry")
  done < <(harness::split_csv "$TOOL_POLICY_DENY")
  [ "${#denied[@]}" -eq 0 ] || argv+=(--disallowedTools "${denied[@]}")
fi

# Extra argv from task.parameters.args, set by the AgentRun author.
argv+=("$@")

if [ -n "$DUMP_ONLY" ]; then
  # env lists what Claude Code will see that the adapter decides: the model
  # pins, the endpoint, hygiene switches, and which credentials survived.
  # argv travels NUL-separated: as jq positional arguments, "-p" would be read
  # as one of jq's own options.
  jq -n --arg auth "$AUTH_MODE" --argjson mcp "$MCP_CONFIG" \
    --argjson argv "$(printf '%s\0' claude "${argv[@]}" | jq -Rs 'split("\u0000") | .[:-1]')" \
    --argjson platform_keys "$(printf '%s\n' "${HARNESS_PLATFORM_AUTH_KEYS[@]}" | jq -R . | jq -s .)" '
      { auth: $auth,
        argv: $argv,
        mcpConfig: $mcp,
        env: ($ENV | with_entries(
          select((.key | test("^(ANTHROPIC_|CLAUDE_|MCP_|DISABLE_AUTOUPDATER$)")) or (.key | IN($platform_keys[])))
          | if (.key | test("(API_KEY|TOKEN)$") or startswith("MCP_AUTH_")) or (.key | IN($platform_keys[]))
            then .value = "<redacted>" else . end)) }'
  exit 0
fi

# ── run ─────────────────────────────────────────────────────────────────────

TASK_TEXT="$(harness::task)"
[ -n "$TASK_TEXT" ] || harness::fail "harness/claude-code: no task supplied (TASK env is empty and /ipc/input/task.json has no task)"

mkdir -p "$CLAUDE_CONFIG_DIR" 2>/dev/null && [ -w "$CLAUDE_CONFIG_DIR" ] ||
  harness::fail "harness/claude-code: \$HOME ($HOME) is not writable"
( umask 077; printf '%s' "$MCP_CONFIG" > "$MCP_CONFIG_FILE" ) ||
  harness::fail "harness/claude-code: could not write $MCP_CONFIG_FILE"

HARNESS_STDIN="$CLAUDE_CONFIG_DIR/sympozium-task.txt"
( umask 077; printf '%s' "$TASK_TEXT" > "$HARNESS_STDIN" ) ||
  harness::fail "harness/claude-code: could not write the task file"

# harness::log_filter is the pod-log view of the stream: one line per tool
# call, and any line that is not JSON (Claude Code's own stderr) as it came.
# Model text and tool inputs stay out of the log.
harness::log_filter() {
  jq -rR --unbuffered '
    . as $line
    | (try fromjson catch null) as $event
    | if ($event | type) == "object" then
        if $event.type == "assistant" then
          $event.message.content[]? | select(.type == "tool_use") | "harness/claude-code > tool \(.name)"
        elif $event.type == "system" and $event.subtype == "init" then
          "harness/claude-code > session model=\($event.model) tools=\($event.tools | length) mcp=\([$event.mcp_servers[]? | "\(.name):\(.status)"] | join(","))"
        else empty end
      else "harness/claude-code ! \($line)" end'
}

# harness::parse_output builds the result from the stream's final `result`
# event.
#
# Metrics are normalised here, once, to the OpenAI usage shape Sympozium's
# agent-runner uses: inputTokens is every input token, cached or not, and
# cachedInputTokens is the cache-read part of it. Anthropic reports
# input_tokens as the uncached remainder, with cache reads and cache writes as
# separate counts. Cache writes are ordinary input here, as in OpenAI. Absent,
# not zero: no reported usage means no metrics.
harness::parse_output() {
  local out="$1" rc="$2" result_line tool_calls detail
  result_line="$(jq -cR 'fromjson? | select(type == "object" and .type == "result")' "$out" | tail -n 1)"
  if [ -z "$result_line" ]; then
    # Prefer the error line over a crash dump of bundled source.
    detail="$(grep -m1 -iE '^[[:space:]]*error:' "$out" || tail -c 2000 "$out")"
    jq -cn --arg e "Claude Code exited ${rc} without a result: ${detail:0:2000}" '{status: "error", error: $e}'
    return 0
  fi
  tool_calls="$(jq -R 'fromjson? | select(type == "object" and .type == "assistant") | .message.content[]?
    | select(.type == "tool_use") | 1' "$out" | wc -l | tr -d ' ')"
  jq -c --argjson tools "$tool_calls" '
    (.usage // {}) as $u
    | ({durationMs: (.duration_ms // 0),
        inputTokens: (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
        outputTokens: ($u.output_tokens // 0),
        toolCalls: $tools}
       + (if $u | has("cache_read_input_tokens") then {cachedInputTokens: $u.cache_read_input_tokens} else {} end)
       | if .inputTokens == 0 and .outputTokens == 0 then null else . end) as $metrics
    | if (.is_error // false) or (.subtype != "success") then
        {status: "error",
         error: ("Claude Code failed: " + ([(.subtype | select(. != "success")), .result,
                   ((.errors // []) | map(tostring) | join("; "))]
                  | map(select(. != null and . != "")) | join(": ") | .[0:4000]))}
      elif ((.result // "") == "") then
        {status: "error", error: "Claude Code returned an empty response"}
      else
        {status: "success", response: .result}
      end
    + (if $metrics == null then {} else {metrics: $metrics} end)' <<<"$result_line"
}

echo "harness/claude-code: $(claude --version 2>/dev/null | head -n1) model=$MODEL auth=$AUTH_MODE" >&2
harness::run claude "${argv[@]}"
