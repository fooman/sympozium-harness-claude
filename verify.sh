#!/usr/bin/env bash
# verify.sh — the version-bump check for this adapter.
#
# The adapter's risk surface is whether the invocation it generates still means
# what it did against the pinned Claude Code: a renamed flag fails loudly, but
# a flag whose meaning shifted, or a tool filter that stopped filtering, still
# produces a run that succeeds. Five stages, each one a bigger commitment:
#
#   ./verify.sh args             asserts the generated invocation (argv, env,
#                                MCP config) and every loud failure it owes.
#   ./verify.sh contract         the result contract's own semantics: harness-
#                                lib against a stub harness, then the
#                                entrypoint against a stub `claude` that plays
#                                back canned stream-json runs.
#   ./verify.sh image <tag>      boots the real Claude Code in the built image
#                                against a dead endpoint, and checks from its
#                                own init event that the model, the tool filter
#                                and the MCP entry arrived.
#   ./verify.sh conformance <tag>  the container-boundary gates from
#                                sympozium-ai/harness-adapters: UID 1000, a
#                                read-only root, /workspace, no TTY, a refused
#                                contract version, the published failure-path
#                                smoke, the skip marker, the same boot on tmpfs,
#                                and SIGTERM.
#   ./verify.sh live <tag>       one real turn through Anthropic. Reads a
#                                subscription token or API key from
#                                CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY.
#
# `args` and `contract` need only bash and jq. `image` and `conformance` need
# docker; only `live` needs a credential. CONFORMANCE.md records what each
# stage proves and what is still outstanding.
set -uo pipefail

cd "$(dirname "$0")" || exit 2
ROOT="$PWD"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '       %s\n' "$2"
  return 0
}

TMP=""

# CLEANUP_IMAGE is set by the stages that bind-mount host directories into a
# container running as UID 1000, which is the gate rather than an accident. On
# Linux the files that container leaves are owned by 1000, so whoever ran this
# script cannot always unlink them. The same image removes its own leftovers
# as root, and anything still stuck is dropped quietly. This is a disposable
# directory under TMPDIR.
CLEANUP_IMAGE=""
cleanup() {
  [ -n "$TMP" ] || return 0
  if [ -n "$CLEANUP_IMAGE" ]; then
    docker run --rm --user 0:0 -v "$TMP:/cleanup" --entrypoint rm "$CLEANUP_IMAGE" \
      -rf /cleanup/home /cleanup/tmp /cleanup/ipc /cleanup/control /cleanup/ws >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# json_is "<file>" "<name>" "<filter>" "<expected>"
json_is() {
  local file="$1" name="$2" filter="$3" want="$4" got
  got="$(jq -r "$filter" "$file" 2>&1)"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "$filter -> $got (want $want)"; fi
}

# ── stage: args ─────────────────────────────────────────────────────────────

# dump runs the entrypoint in dump-args mode with an environment containing
# exactly the assignments given — env -i so a stray ANTHROPIC_API_KEY on the
# developer's machine cannot decide a fixture's outcome. The defaults below
# are a minimal valid run; later assignments win.
dump() {
  env -i \
    PATH="$PATH" \
    HOME="$TMP/home" \
    HARNESS_LIB="$ROOT/harness-lib.sh" \
    SYMPOZIUM_RESULT_PATH="$TMP/result.json" \
    SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1 \
    MODEL_PROVIDER=anthropic \
    MODEL_NAME=claude-sonnet-5 \
    ANTHROPIC_API_KEY=opaque-subscription-token \
    HARNESS_DUMP_ARGS=1 \
    "$@" \
    bash "$ROOT/harness-entrypoint.sh" "${DUMP_ARGS[@]}"
}
DUMP_ARGS=()

# jq_is "<name>" "<filter>" "<expected>" — asserts against $DUMP.
jq_is() {
  local name="$1" filter="$2" want="$3" got
  got="$(jq -r "$filter" <<<"$DUMP" 2>&1)"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "want [$want], got [$got]"; fi
}

# after "<flag>": the argv entries following a flag, up to the next flag.
after() { printf '.argv as $a | ($a | index("%s")) as $i | if $i == null then "absent" else [$a[$i+1:][] ] | (map(startswith("--")) | index(true)) as $n | .[0:($n // length)] | join(" ") end' "$1"; }

# rejects "<name>" "<substring the message must contain>" env...
rejects() {
  local name="$1" want="$2" out rc
  shift 2
  out="$(dump "$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$name" "expected a non-zero exit, got 0"
  elif ! grep -qF "$want" <<<"$out"; then
    fail "$name" "message did not mention [$want]: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  else
    pass "$name"
  fi
}

verify_args() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/home"
  echo "args: generated invocation (bash + jq, no docker)"

  # The baseline: a subscription run that names nothing optional.
  DUMP="$(dump)" || fail "bare run exits 0"
  jq_is "an unprefixed credential is a subscription token" '.auth' 'subscription'
  jq_is "the token travels as CLAUDE_CODE_OAUTH_TOKEN" '.env.CLAUDE_CODE_OAUTH_TOKEN' '<redacted>'
  jq_is "no API key alongside the token" '.env | has("ANTHROPIC_API_KEY")' 'false'
  jq_is "print mode" '.argv[1]' '-p'
  jq_is "stream-json output" "$(after --output-format)" 'stream-json'
  jq_is "--model is MODEL_NAME" "$(after --model)" 'claude-sonnet-5'
  jq_is "no permission prompts in a pod" "$(after --permission-mode)" 'bypassPermissions'
  jq_is "workspace settings are not loaded" "$(after --setting-sources)" 'user'
  jq_is "only the generated MCP config" '.argv | index("--strict-mcp-config") != null' 'true'
  jq_is "no session is persisted" '.argv | index("--no-session-persistence") != null' 'true'
  jq_is "MCP config lives in the run's home" "$(after --mcp-config) | endswith(\"/.claude/sympozium-mcp.json\")" 'true'
  jq_is "an empty registry is an empty config" '.mcpConfig.mcpServers | length' '0'
  jq_is "no persona flag without a system prompt" "$(after --append-system-prompt)" 'absent'
  jq_is "no tool filter without a tool policy" "$(after --tools)" 'absent'
  jq_is "subagents pinned to the named model" '.env.CLAUDE_CODE_SUBAGENT_MODEL' 'claude-sonnet-5'
  jq_is "small/fast slot pinned to the named model" '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL' 'claude-sonnet-5'
  jq_is "no base URL override by default" '.env | has("ANTHROPIC_BASE_URL")' 'false'
  jq_is "config dir is under HOME" '.env.CLAUDE_CONFIG_DIR | endswith("/home/.claude")' 'true'
  jq_is "autoupdater off" '.env.DISABLE_AUTOUPDATER' '1'
  jq_is "bubblewrap env scrub off" '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' '0'

  echo "args: credentials"
  DUMP="$(dump ANTHROPIC_API_KEY=sk-ant-api03-key MODEL_BASE_URL=https://proxy.example.com/v1/)"
  jq_is "an sk-ant-api key is an API key" '.auth' 'api-key'
  jq_is "no OAuth token in API key mode" '.env | has("CLAUDE_CODE_OAUTH_TOKEN")' 'false'
  jq_is "base URL mapped without /v1" '.env.ANTHROPIC_BASE_URL' 'https://proxy.example.com'
  DUMP="$(dump ANTHROPIC_API_KEY=proxy-key MODEL_BASE_URL=https://proxy.example.com)"
  jq_is "an unprefixed value for a proxy is that proxy's key" '.auth' 'api-key'
  DUMP="$(dump MODEL_BASE_URL=https://api.anthropic.com/v1)"
  jq_is "the Anthropic URL keeps subscription mode" '.auth' 'subscription'
  jq_is "the Anthropic URL is not exported" '.env | has("ANTHROPIC_BASE_URL")' 'false'
  DUMP="$(dump ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=explicit-token)"
  jq_is "an explicit CLAUDE_CODE_OAUTH_TOKEN is used" '.auth' 'subscription'
  DUMP="$(dump OPENAI_API_KEY=o DEEPSEEK_API_KEY=d API_KEY=a MCP_AUTH_REMOTE=m)"
  jq_is "other platform keys are dropped" '[.env | keys[] | select(. == "OPENAI_API_KEY" or . == "DEEPSEEK_API_KEY" or . == "API_KEY")] | length' '0'
  jq_is "MCP credentials are dropped" '[.env | keys[] | select(startswith("MCP_AUTH_"))] | length' '0'
  DUMP="$(dump)"
  jq_is "no credential value in the dump" '[.. | strings | select(test("opaque-subscription-token"))] | length' '0'

  echo "args: persona, tool policy, MCP, extra args"
  DUMP="$(dump SYSTEM_PROMPT='say "hi" --tools Bash')"
  jq_is "persona is appended, verbatim" "$(after --append-system-prompt)" 'say "hi" --tools Bash'
  jq_is "a persona cannot add a flag" "$(after --tools)" 'absent'

  DUMP="$(dump TOOL_POLICY_ALLOW='Read, execute_command,kubectl_get' TOOL_POLICY_DENY='write_file,Bash(rm:*),kubectl_delete')"
  jq_is "allow maps to the built-in tool set" "$(after --tools)" 'Read,Bash'
  jq_is "deny maps to disallowed tools" "$(after --disallowedTools)" 'Write Edit NotebookEdit Bash(rm:*) mcp__sympozium-skills__kubectl_delete'
  DUMP="$(dump TOOL_POLICY_ALLOW=kubectl_get)"
  jq_is "allow without built-ins disables every built-in tool" '.argv | (index("--tools")) as $i | .[$i+1]' ''

  cat > "$TMP/mcp.json" <<'JSON'
{"servers":[{"name":"sympozium-skills","url":"http://127.0.0.1:8771/","toolsPrefix":"","timeout":120},
            {"name":"team-tools","url":"https://tools.example/mcp","timeout":30,"headers":{"X-Env":"prod"}}]}
JSON
  DUMP="$(dump MCP_CONFIG_PATH="$TMP/mcp.json")"
  jq_is "one http server per registry entry" '.mcpConfig.mcpServers | to_entries | map("\(.key)=\(.value.type)") | join(",")' 'sympozium-skills=http,team-tools=http'
  jq_is "operator headers kept" '.mcpConfig.mcpServers["team-tools"].headers["X-Env"]' 'prod'
  jq_is "MCP tool timeout is the largest, in ms" '.env.MCP_TOOL_TIMEOUT' '120000'

  DUMP_ARGS=(--max-turns 3)
  DUMP="$(dump)"
  DUMP_ARGS=()
  jq_is "task.parameters.args come last" '.argv[-2:] | join(" ")' '--max-turns 3'

  # The contract version is checked before any work. Not overridable on the
  # run by design: see harness-lib.sh.
  echo "args: contract version"
  rejects "an unknown contract is refused" "adapter contract, but Sympozium offers v1beta1" \
    SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1beta1
  rejects "an absent contract is refused" "is unset" SYMPOZIUM_HARNESS_CONTRACT_VERSION=
  DUMP="$(dump HARNESS_CONTRACT_VERSION=v1beta1)" \
    || fail "the implemented version cannot be redefined" "an injected HARNESS_CONTRACT_VERSION took effect"
  jq_is "the implemented version cannot be redefined" '.auth' 'subscription'

  echo "args: loud failures"
  rejects "no credential" "no Anthropic credential" ANTHROPIC_API_KEY=
  rejects "a non-anthropic provider" "only routes to provider" MODEL_PROVIDER=openai
  rejects "no model" "no model supplied" MODEL_NAME=
  rejects "a model name with spaces" "not a valid model name" MODEL_NAME='claude sonnet'
  rejects "a subscription token to a third party" "only sent to https://api.anthropic.com" \
    ANTHROPIC_API_KEY=sk-ant-oat01-x MODEL_BASE_URL=https://proxy.example.com
  rejects "an explicit token to a third party" "only sent to https://api.anthropic.com" \
    ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=t MODEL_BASE_URL=https://proxy.example.com
  rejects "a relative base URL" "must be an absolute http(s) URL" ANTHROPIC_API_KEY=k MODEL_BASE_URL=proxy.example.com
  rejects "a pattern in allow" "is a pattern" TOOL_POLICY_ALLOW='Bash(git:*)'
  printf '%s' '{"servers":[{"name":"remote","url":"https://mcp.example.com","auth":{"type":"bearer","secretKey":"t"}}]}' > "$TMP/mcp-auth.json"
  rejects "an MCP server needing auth" "not supported: remote" MCP_CONFIG_PATH="$TMP/mcp-auth.json"
  printf '%s' '{"servers":[{"name":"filtered","url":"https://mcp.example.com","toolsDeny":["x"]}]}' > "$TMP/mcp-filter.json"
  rejects "an MCP server with its own tool filter" "not supported: filtered" MCP_CONFIG_PATH="$TMP/mcp-filter.json"
  printf '%s' '{"servers":[{"name":"team.tools","url":"https://mcp.example.com"}]}' > "$TMP/mcp-name.json"
  rejects "an MCP server name Claude Code cannot namespace" "must match" MCP_CONFIG_PATH="$TMP/mcp-name.json"
  printf '%s' '["not","an","object"]' > "$TMP/mcp-bad.json"
  rejects "a registry that is not an object" "is not a JSON object" MCP_CONFIG_PATH="$TMP/mcp-bad.json"
}

# ── stage: contract ─────────────────────────────────────────────────────────
#
# The result contract's own semantics. These are the gates
# sympozium-ai/harness-adapters asks an adapter to prove before publication
# (docs/adapter-contract.md) that need no image: valid success, error,
# missing-result and malformed-result behaviour, metrics semantics, and SIGTERM.
#
# Two halves. The first is harness-lib.sh against an ordinary command, because
# every one of those is a property of the library. The second is the
# entrypoint against a stub `claude` that plays back stream-json, because
# turning that stream into a result is this adapter's own code.

# stub runs harness::run against an ordinary command, with the library sourced
# exactly as the entrypoint sources it. $1 is where the result goes. STUB_SETUP,
# if set, is evaluated after sourcing: it is how a test defines a hook.
stub() {
  local result="$1"; shift
  env -i PATH="$PATH" HOME="$TMP/home" \
    HARNESS_BACKEND=stub \
    SYMPOZIUM_RESULT_PATH="$result" \
    STUB_SETUP="${STUB_SETUP:-}" \
    HARNESS_STDIN="${STUB_STDIN:-}" \
    bash -c 'set -euo pipefail; . "$1"; shift; eval "$STUB_SETUP"; harness::run "$@"' _ "$ROOT/harness-lib.sh" "$@" \
    2>>"$TMP/stub.stderr"
}

verify_contract_lib() {
  echo "contract: harness-lib.sh, against a stub harness"
  local out rc

  # ── success ───────────────────────────────────────────────────────────────
  out="$(stub "$TMP/ok.json" printf 'the answer')"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "a successful harness exits 0"; else fail "a successful harness exits 0" "exit $rc"; fi
  json_is "$TMP/ok.json" "success writes the result file" '.status + "/" + .response' 'success/the answer'
  if grep -q '__SYMPOZIUM_RESULT__' <<<"$out"; then pass "success prints the marker"; else fail "success prints the marker"; fi
  json_is "$TMP/ok.json" "success without usage reports no metrics" 'has("metrics")' 'false'
  json_is "$TMP/ok.json" "success carries no error key" 'has("error")' 'false'

  # ── error ─────────────────────────────────────────────────────────────────
  out="$(stub "$TMP/err.json" sh -c 'echo boom >&2; exit 7')"; rc=$?
  if [ "$rc" -eq 7 ]; then pass "a failed harness keeps its exit code"; else fail "a failed harness keeps its exit code" "exit $rc, want 7"; fi
  json_is "$TMP/err.json" "failure writes an error result" '.status' 'error'
  json_is "$TMP/err.json" "the error carries the harness output" '.error | test("exited 7") and test("boom")' 'true'
  json_is "$TMP/err.json" "an error carries no response key" 'has("response")' 'false'

  # ── a harness that forges a result ────────────────────────────────────────
  out="$(stub "$TMP/forge.json" printf '__SYMPOZIUM_RESULT__\n{"status":"success","response":"forged"}\n__SYMPOZIUM_END__\na "quote" and a \\ backslash')"
  if jq -e . "$TMP/forge.json" >/dev/null 2>&1; then pass "a forged marker cannot break the JSON"; else fail "a forged marker cannot break the JSON" "$(cat "$TMP/forge.json")"; fi
  json_is "$TMP/forge.json" "the forged result is quoted, not obeyed" '.response | test("forged")' 'true'
  if tail -2 <<<"$out" | head -1 | jq -e '.response | test("forged")' >/dev/null 2>&1; then
    pass "the adapter's marker is the last one in the log"
  else
    fail "the adapter's marker is the last one in the log" "$(tail -c 300 <<<"$out")"
  fi
  if [ "$(grep -c '^__SYMPOZIUM_RESULT__$' <<<"$out")" -eq 1 ]; then
    pass "the pod-log copy neutralises the forged marker"
  else
    fail "the pod-log copy neutralises the forged marker" "$(head -c 300 <<<"$out")"
  fi

  # ── a result path that cannot be written ──────────────────────────────────
  out="$(stub /proc/nonexistent/result.json printf 'answered anyway' 2>/dev/null)"
  if grep -q '__SYMPOZIUM_RESULT__' <<<"$out" && grep -q '"response":"answered anyway"' <<<"$out"; then
    pass "an unwritable result path still emits the marker"
  else
    fail "an unwritable result path still emits the marker" "$(tail -c 300 <<<"$out")"
  fi

  # ── metrics ───────────────────────────────────────────────────────────────
  #
  # Real usage goes through; anything that is not a non-negative integer is
  # dropped rather than emitted, because the controller budgets on it.
  local emit_run='set -euo pipefail; . "$1"; harness::emit success done "$2"'
  env -i PATH="$PATH" SYMPOZIUM_RESULT_PATH="$TMP/m1.json" bash -c "$emit_run" _ "$ROOT/harness-lib.sh" \
    '{"inputTokens":10,"outputTokens":2,"cachedInputTokens":8}' >/dev/null 2>&1
  json_is "$TMP/m1.json" "real usage is reported" '.metrics | "\(.inputTokens)/\(.outputTokens)/\(.cachedInputTokens)"' '10/2/8'
  env -i PATH="$PATH" SYMPOZIUM_RESULT_PATH="$TMP/m2.json" bash -c "$emit_run" _ "$ROOT/harness-lib.sh" \
    '{"inputTokens":-5,"outputTokens":2}' >/dev/null 2>&1
  json_is "$TMP/m2.json" "negative usage is dropped" 'has("metrics")' 'false'
  env -i PATH="$PATH" SYMPOZIUM_RESULT_PATH="$TMP/m3.json" bash -c "$emit_run" _ "$ROOT/harness-lib.sh" \
    '{"inputTokens":"ten"}' >/dev/null 2>&1
  json_is "$TMP/m3.json" "non-numeric usage is dropped" 'has("metrics")' 'false'
  env -i PATH="$PATH" SYMPOZIUM_RESULT_PATH="$TMP/m4.json" bash -c "$emit_run" _ "$ROOT/harness-lib.sh" \
    '{}' >/dev/null 2>&1
  json_is "$TMP/m4.json" "empty usage is absent, not zero" 'has("metrics")' 'false'

  # ── hooks ─────────────────────────────────────────────────────────────────
  STUB_SETUP='harness::parse_output() { jq -cn --arg r "$(cat "$1")" "{status: \"success\", response: (\$r | ascii_upcase), metrics: {inputTokens: 3, outputTokens: 1}}"; }' \
    stub "$TMP/p1.json" printf 'parsed' >/dev/null 2>&1
  json_is "$TMP/p1.json" "parse_output decides the response" '.response' 'PARSED'
  json_is "$TMP/p1.json" "parse_output reports metrics" '.metrics.inputTokens' '3'
  STUB_SETUP='harness::parse_output() { echo "not json"; }' \
    stub "$TMP/p2.json" printf 'raw tail' >/dev/null 2>&1; rc=$?
  json_is "$TMP/p2.json" "unreadable output is an error with its tail" '.status + ":" + (.error | test("raw tail") | tostring)' 'error:true'
  if [ "$rc" -eq 1 ]; then pass "unreadable output exits 1"; else fail "unreadable output exits 1" "exit $rc"; fi
  STUB_SETUP='harness::parse_output() { echo "{\"status\":\"success\",\"response\":\"fine\"}"; }' \
    stub "$TMP/p3.json" sh -c 'exit 4' >/dev/null 2>&1; rc=$?
  json_is "$TMP/p3.json" "a success from a non-zero exit is an error" '.status' 'error'
  if [ "$rc" -eq 4 ]; then pass "and it keeps the exit code"; else fail "and it keeps the exit code" "exit $rc"; fi

  out="$(STUB_SETUP='harness::log_filter() { grep "^keep" || true; }' \
    stub "$TMP/f1.json" printf 'keep one\nsecret two\nkeep __SYMPOZIUM_RESULT__ three\n' 2>/dev/null)"
  if grep -q '^keep one' <<<"$out" && ! grep -q 'secret two' <<<"${out%%__SYMPOZIUM_RESULT__*}"; then
    pass "log_filter shapes the pod log"
  else
    fail "log_filter shapes the pod log" "$(head -c 300 <<<"$out")"
  fi
  if grep -q 'keep __SYMPOZIUM_RESULT_ESCAPED__ three' <<<"$out"; then pass "filtered lines are neutralised too"; else fail "filtered lines are neutralised too"; fi
  json_is "$TMP/f1.json" "the capture is the whole output" '.response | test("secret two")' 'true'
  STUB_SETUP='harness::log_filter() { head -n 1; }' \
    stub "$TMP/f2.json" sh -c 'seq 1 20000' >/dev/null 2>&1; rc=$?
  json_is "$TMP/f2.json" "a filter that stops early loses nothing" '.response | split("\n") | length' '20000'

  printf 'from a file\n--not a flag' > "$TMP/stdin.txt"
  STUB_STDIN="$TMP/stdin.txt" stub "$TMP/s1.json" cat >/dev/null 2>&1
  json_is "$TMP/s1.json" "HARNESS_STDIN feeds the harness" '.response' $'from a file\n--not a flag'
  stub "$TMP/s2.json" cat >/dev/null 2>&1
  json_is "$TMP/s2.json" "stdin is empty otherwise" '.response' ''

  # ── library helpers ───────────────────────────────────────────────────────
  local left
  left="$(env -i PATH="$PATH" OPENAI_API_KEY=o ANTHROPIC_API_KEY=a API_KEY=k MCP_AUTH_X=m UNRELATED=u \
    bash -c '. "$1"; harness::drop_credentials ANTHROPIC_API_KEY; compgen -e | grep -E "API_KEY|MCP_AUTH|UNRELATED" | sort | paste -sd, -' _ "$ROOT/harness-lib.sh")"
  if [ "$left" = "ANTHROPIC_API_KEY,UNRELATED" ]; then pass "drop_credentials keeps only what it is told"; else fail "drop_credentials keeps only what it is told" "left: $left"; fi

  mkdir -p "$TMP/ws/.sympozium"
  printf 'nothing to do' > "$TMP/ws/.sympozium/skip"
  out="$(env -i PATH="$PATH" SYMPOZIUM_RESULT_PATH="$TMP/skip.json" SKIP_MARKER_FALLBACK="$TMP/ws/.sympozium/skip" \
    bash -c '. "$1"; harness::check_skip; echo "not reached"' _ "$ROOT/harness-lib.sh" 2>/dev/null)"; rc=$?
  json_is "$TMP/skip.json" "a skip marker reports skipped with its reason" '.status + ":" + .response' 'skipped:nothing to do'
  if [ "$rc" -eq 0 ] && ! grep -q 'not reached' <<<"$out"; then pass "a skip exits 0 before any work"; else fail "a skip exits 0 before any work" "exit $rc"; fi
  if [ ! -e "$TMP/ws/.sympozium/skip" ]; then pass "the fallback marker is removed once read"; else fail "the fallback marker is removed once read"; fi
  out="$(env -i PATH="$PATH" SKIP_MARKER_FALLBACK="$TMP/ws/.sympozium/skip" \
    bash -c '. "$1"; harness::check_skip; echo "ran"' _ "$ROOT/harness-lib.sh" 2>/dev/null)"
  if [ "$out" = ran ]; then pass "no marker runs normally"; else fail "no marker runs normally" "$out"; fi

  # ── SIGTERM ───────────────────────────────────────────────────────────────
  #
  # Sympozium sends SIGTERM on a timeout, a cancel or an eviction, and only
  # PID 1 receives it. The adapter shell reports its own PID so the signal
  # goes to it rather than to a wrapper subshell; see the dsh adapter's
  # verify.sh for why that matters.
  local pidfile="$TMP/sig.pid" pid i
  env -i PATH="$PATH" HOME="$TMP/home" \
    HARNESS_BACKEND=stub \
    SYMPOZIUM_RESULT_PATH="$TMP/sig.json" \
    bash -c 'set -euo pipefail; echo $$ > "$1"; . "$2"; shift 2; harness::run "$@"' \
      _ "$pidfile" "$ROOT/harness-lib.sh" \
      sh -c 'echo started; exec sleep 31' \
    > "$TMP/sig.out" 2>&1 &
  local wrapper=$!

  for i in $(seq 1 100); do
    [ -s "$pidfile" ] && grep -q started "$TMP/sig.out" 2>/dev/null && break
    sleep 0.1
  done
  pid="$(cat "$pidfile" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null
  else
    fail "SIGTERM reaches the adapter" "the adapter never reported its PID"
    kill -TERM "$wrapper" 2>/dev/null
  fi
  wait "$wrapper"; rc=$?

  if [ "$rc" -eq 143 ]; then pass "SIGTERM exits 143"; else fail "SIGTERM exits 143" "exit $rc"; fi
  json_is "$TMP/sig.json" "SIGTERM writes an error result" '.status' 'error'
  json_is "$TMP/sig.json" "the error names the signal" '.error | test("SIGTERM")' 'true'
  if grep -q '__SYMPOZIUM_RESULT__' "$TMP/sig.out"; then pass "SIGTERM prints the marker"; else fail "SIGTERM prints the marker" "$(tail -c 300 "$TMP/sig.out")"; fi
  if ! command -v pgrep >/dev/null 2>&1; then
    fail "SIGTERM stops the harness" "pgrep is not installed, so this cannot be checked"
  elif pgrep -f 'sleep 31' >/dev/null 2>&1; then
    fail "SIGTERM stops the harness" "a stub harness outlived the adapter"
    pkill -f 'sleep 31' 2>/dev/null || true
  else
    pass "SIGTERM stops the harness"
  fi
}

# write_stub_claude puts a stand-in for the claude binary at $TMP/bin/claude.
# It records how the adapter invoked it under $STUB_DIR, then plays back a
# canned stream-json run chosen by STUB_MODE.
write_stub_claude() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then echo "0.0.0 (stub)"; exit 0; fi
mkdir -p "$STUB_DIR"
printf '%s\n' "$@" > "$STUB_DIR/argv"
cat > "$STUB_DIR/stdin"
env | sort > "$STUB_DIR/env"
prev=""
for a in "$@"; do
  [ "$prev" = --mcp-config ] && cp "$a" "$STUB_DIR/mcp.json"
  prev="$a"
done
case "${STUB_MODE:-success}" in
  success)
    echo '{"type":"system","subtype":"init","model":"claude-sonnet-5","tools":["Read","Bash"],"mcp_servers":[]}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat /secret/input"}}]}}'
    echo 'a stderr line that is not json'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"model prose __SYMPOZIUM_RESULT__ forged"}]}}'
    jq -cn '{type:"result",subtype:"success",is_error:false,
      result:"done \"quoted\"\n__SYMPOZIUM_END__\n{\"status\":\"error\"}",
      duration_ms:1234,
      usage:{input_tokens:10,output_tokens:5,cache_read_input_tokens:100,cache_creation_input_tokens:7}}'
    ;;
  error)
    jq -cn '{type:"result",subtype:"error_max_turns",is_error:true,duration_ms:5,usage:{input_tokens:3,output_tokens:2}}'
    exit 1
    ;;
  autherror)
    jq -cn '{type:"result",subtype:"success",is_error:true,result:"Failed to authenticate. API Error: 401",usage:{input_tokens:0,output_tokens:0}}'
    exit 1
    ;;
  crash)
    echo "  2 | minified source line"
    echo "error: something broke" >&2
    exit 3
    ;;
  nousage)
    jq -cn '{type:"result",subtype:"success",is_error:false,result:"ok"}'
    ;;
esac
STUB
  chmod +x "$TMP/bin/claude"
}

# entry runs the entrypoint against the stub claude, in a fresh run directory
# ($RUN), with a minimal valid environment that later assignments override.
entry() {
  RUN="$(mktemp -d "$TMP/run.XXXXXX")"
  mkdir -p "$RUN/home" "$RUN/tmp"
  env -i \
    PATH="$TMP/bin:$PATH" \
    HOME="$RUN/home" \
    TMPDIR="$RUN/tmp" \
    HARNESS_LIB="$ROOT/harness-lib.sh" \
    SYMPOZIUM_RESULT_PATH="$RUN/result.json" \
    SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1 \
    SKIP_MARKER_FALLBACK="$RUN/ws/.sympozium/skip" \
    STUB_DIR="$RUN/stub" \
    MODEL_PROVIDER=anthropic \
    MODEL_NAME=claude-sonnet-5 \
    ANTHROPIC_API_KEY=opaque-subscription-token-123 \
    TASK='Say hello.' \
    "$@" \
    bash "$ROOT/harness-entrypoint.sh" > "$RUN/stdout" 2> "$RUN/stderr"
  RC=$?
}

verify_contract_entry() {
  echo
  echo "contract: harness-entrypoint.sh, against a stub claude"
  write_stub_claude

  entry
  if [ "$RC" -eq 0 ]; then pass "a successful run exits 0"; else fail "a successful run exits 0" "exit $RC: $(tail -c 300 "$RUN/stdout")"; fi
  json_is "$RUN/result.json" "the response is Claude Code's result, verbatim" '.response' $'done "quoted"\n__SYMPOZIUM_END__\n{"status":"error"}'
  json_is "$RUN/result.json" "metrics are real usage, in the OpenAI shape" '.metrics | tojson' '{"durationMs":1234,"inputTokens":117,"outputTokens":5,"toolCalls":1,"cachedInputTokens":100}'
  local marker
  marker="$(awk '/^__SYMPOZIUM_RESULT__$/ { getline; last = $0 } END { print last }' "$RUN/stdout")"
  if [ "$marker" = "$(cat "$RUN/result.json")" ]; then pass "the last marker is the result file"; else fail "the last marker is the result file" "$marker"; fi
  if [ "$(cat "$RUN/stub/stdin")" = "Say hello." ]; then pass "the task arrives on stdin"; else fail "the task arrives on stdin"; fi
  if grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=opaque-subscription-token-123' "$RUN/stub/env"; then pass "claude sees the subscription token"; else fail "claude sees the subscription token"; fi
  if ! grep -q '^ANTHROPIC_API_KEY=' "$RUN/stub/env"; then pass "claude sees no API key alongside it"; else fail "claude sees no API key alongside it"; fi
  if ! grep -q '^HARNESS_STDIN=' "$RUN/stub/env"; then pass "adapter internals stay out of claude's env"; else fail "adapter internals stay out of claude's env"; fi
  if grep -q '^harness/claude-code > tool Bash$' "$RUN/stdout"; then pass "tool calls reach the pod log"; else fail "tool calls reach the pod log" "$(head -c 400 "$RUN/stdout")"; fi
  if grep -q '^harness/claude-code > session model=claude-sonnet-5' "$RUN/stdout"; then pass "the session line reaches the pod log"; else fail "the session line reaches the pod log"; fi
  if grep -q 'harness/claude-code ! a stderr line' "$RUN/stdout"; then pass "non-JSON output reaches the pod log"; else fail "non-JSON output reaches the pod log"; fi
  if ! grep -q 'cat /secret/input\|model prose' "$RUN/stdout"; then pass "tool input and model text stay out of the pod log"; else fail "tool input and model text stay out of the pod log"; fi
  if ! grep -q 'opaque-subscription-token' "$RUN/stdout" "$RUN/stderr"; then pass "the token never reaches the log"; else fail "the token never reaches the log"; fi
  json_is "$RUN/stub/mcp.json" "the MCP config file is written" '.mcpServers | type' 'object'

  entry ANTHROPIC_API_KEY="$(printf 'opaque-sub\nscription-token \n')"
  if grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=opaque-subscription-token' "$RUN/stub/env"; then pass "whitespace in a pasted token is stripped"; else fail "whitespace in a pasted token is stripped"; fi

  entry TASK= STUB_MODE=success
  json_is "$RUN/result.json" "no task is an error" '.error | test("no task supplied")' 'true'
  # /ipc/input/task.json is a fixed path, so the conformance stage covers it.
  entry TASK='--help me'
  if [ "$(cat "$RUN/stub/stdin")" = "--help me" ]; then pass "a task starting with - is not a flag"; else fail "a task starting with - is not a flag"; fi

  entry STUB_MODE=error
  if [ "$RC" -eq 1 ]; then pass "a Claude Code error exits non-zero"; else fail "a Claude Code error exits non-zero" "exit $RC"; fi
  json_is "$RUN/result.json" "the error names the stop reason" '.error | test("error_max_turns")' 'true'
  json_is "$RUN/result.json" "an error still reports its usage" '.metrics.inputTokens' '3'
  json_is "$RUN/result.json" "no cache-read count means no cachedInputTokens" '.metrics | has("cachedInputTokens")' 'false'

  entry STUB_MODE=autherror
  json_is "$RUN/result.json" "an auth failure says so, without a misleading subtype" '.error' 'Claude Code failed: Failed to authenticate. API Error: 401'
  json_is "$RUN/result.json" "zero usage is absent, not zero" 'has("metrics")' 'false'

  entry STUB_MODE=crash
  if [ "$RC" -eq 3 ]; then pass "a crash keeps its exit code"; else fail "a crash keeps its exit code" "exit $RC"; fi
  json_is "$RUN/result.json" "a crash reports the error line, not the source dump" '.error' 'Claude Code exited 3 without a result: error: something broke'

  entry STUB_MODE=nousage
  json_is "$RUN/result.json" "no reported usage means no metrics" '.status + ":" + (has("metrics") | tostring)' 'success:false'

  mkdir -p "$TMP/skipws/.sympozium"
  printf 'skip: nothing planned' > "$TMP/skipws/.sympozium/skip"
  entry SKIP_MARKER_FALLBACK="$TMP/skipws/.sympozium/skip" TASK= ANTHROPIC_API_KEY=
  json_is "$RUN/result.json" "a skip marker skips before task and credential checks" '.status + ":" + .response' 'skipped:skip: nothing planned'
  if [ ! -e "$RUN/stub/argv" ]; then pass "a skip never starts claude"; else fail "a skip never starts claude"; fi
}

verify_contract() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/home"
  verify_contract_lib
  verify_contract_entry
}

# ── stage: image ────────────────────────────────────────────────────────────

# The real Claude Code in the built image, against a deliberately dead
# endpoint. A dump shows what the adapter passes; only the harness can say
# what it made of it. Claude Code prints an init event before its first
# request, naming its model, its tools and its MCP servers, and the adapter's
# log filter puts that on one line. So a run that fails at the endpoint, with
# that line present and right, proves the flags still parse and still mean
# what they did.
verify_image() {
  local tag="${1:-}"
  [ -n "$tag" ] || { echo "usage: ./verify.sh image <tag>" >&2; exit 2; }
  TMP="$(mktemp -d)"
  echo "image: booting Claude Code in $tag (dead endpoint on purpose)"

  local version pinned
  version="$(docker run --rm --entrypoint claude "$tag" --version 2>&1 | head -n1)"
  pinned="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$ROOT/Dockerfile")"
  if [ "$version" = "$pinned (Claude Code)" ]; then pass "the image runs the pinned Claude Code ($pinned)"; else fail "the image runs the pinned Claude Code" "got \"$version\", pinned $pinned"; fi

  docker run --rm --entrypoint bash \
    -e SYSTEM_PROMPT='You are a careful reviewer.' \
    -e TOOL_POLICY_ALLOW='Read,kubectl_get' \
    -e TOOL_POLICY_DENY='Bash(rm:*)' \
    "$tag" -c '
      set -e
      export HOME=/tmp/agent TMPDIR=/tmp
      mkdir -p "$HOME"
      printf "%s" "{\"servers\":[{\"name\":\"sympozium-skills\",\"url\":\"http://127.0.0.1:8771/\",\"timeout\":120}]}" > /tmp/mcp.json
      export MCP_CONFIG_PATH=/tmp/mcp.json
      export SYMPOZIUM_RESULT_PATH=/tmp/result.json SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1
      export MODEL_PROVIDER=anthropic MODEL_NAME=claude-sonnet-5
      export ANTHROPIC_API_KEY=sk-ant-api03-not-a-real-key MODEL_BASE_URL=http://127.0.0.1:9
      export CLAUDE_CODE_MAX_RETRIES=0
      export TASK="Reply with the single word: ok"
      /usr/local/bin/harness-entrypoint.sh || true
    ' >"$TMP/boot" 2>&1

  local session
  session="$(grep -m1 '^harness/claude-code > session ' "$TMP/boot")"
  if [ -n "$session" ]; then pass "Claude Code starts and reports its session"; else fail "Claude Code starts and reports its session" "$(tail -c 600 "$TMP/boot")"; fi
  if grep -q 'model=claude-sonnet-5 ' <<<"$session"; then pass "it uses the named model"; else fail "it uses the named model" "$session"; fi
  if grep -q ' tools=1 ' <<<"$session"; then pass "--tools leaves exactly the allowed built-in"; else fail "--tools leaves exactly the allowed built-in" "$session"; fi
  if grep -q 'mcp=sympozium-skills:' <<<"$session"; then pass "the MCP entry is loaded"; else fail "the MCP entry is loaded" "$session"; fi
  if grep -q '__SYMPOZIUM_RESULT__' "$TMP/boot" && grep -q '"status":"error"' "$TMP/boot"; then
    pass "the dead endpoint fails the run through the contract"
  else
    fail "the dead endpoint fails the run through the contract" "$(tail -c 400 "$TMP/boot")"
  fi
  if grep -qiE "unknown option|error: option|invalid (value|argument)" "$TMP/boot"; then
    fail "the failure is the endpoint, not the flags" "$(grep -m1 -iE "unknown option|error: option|invalid (value|argument)" "$TMP/boot")"
  else
    pass "the failure is the endpoint, not the flags"
  fi
  printf '       reported: %s\n' "$(grep -o '"error":"[^"]*' "$TMP/boot" | tail -1 | cut -c10-130)"
}

# ── stage: conformance ──────────────────────────────────────────────────────
#
# The container-boundary gates, against a built image. This is the local
# equivalent of sympozium-ai/harness-adapters' test/contract-smoke.sh: an
# adapter that reports success without reaching a model would pass every
# other check here.
CONFORMANCE_ENV=(
  -e HOME=/home/agent -e TMPDIR=/tmp
  -e SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1
  -e MODEL_PROVIDER=anthropic -e MODEL_NAME=claude-sonnet-5
  -e ANTHROPIC_API_KEY=sk-ant-api03-not-a-real-key
  -e CLAUDE_CODE_MAX_RETRIES=0
)

verify_conformance() {
  local tag="${1:-}"
  [ -n "$tag" ] || { echo "usage: ./verify.sh conformance <tag>" >&2; exit 2; }
  TMP="$(mktemp -d)"
  CLEANUP_IMAGE="$tag"
  echo "conformance: the container boundary, $tag"

  # ── the image's own declarations ──────────────────────────────────────────
  local user workdir
  user="$(docker image inspect "$tag" --format '{{.Config.User}}')"
  workdir="$(docker image inspect "$tag" --format '{{.Config.WorkingDir}}')"
  if [ "$user" = "1000" ] || [ "$user" = "1000:1000" ]; then pass "the image runs as UID 1000"; else fail "the image runs as UID 1000" "USER is \"$user\""; fi
  if [ "$workdir" = "/workspace" ]; then pass "the working directory is /workspace"; else fail "the working directory is /workspace" "WorkingDir is \"$workdir\""; fi

  # ── startup under the pod's security context ──────────────────────────────
  mkdir -p "$TMP/ipc/output" "$TMP/ipc/input" "$TMP/home" "$TMP/tmp"
  printf '%s' '{"task":"Return one word."}' > "$TMP/ipc/input/task.json"
  chmod 0777 "$TMP" "$TMP/ipc" "$TMP/ipc/output" "$TMP/home" "$TMP/tmp"

  docker run --rm --read-only --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
    "${CONFORMANCE_ENV[@]}" \
    -e MODEL_BASE_URL=http://127.0.0.1:9 \
    -v "$TMP/ipc/output:/ipc/output" \
    -v "$TMP/ipc/input:/ipc/input:ro" \
    -v "$TMP/home:/home/agent" \
    -v "$TMP/tmp:/tmp" \
    "$tag" >"$TMP/smoke" 2>&1
  local rc=$?

  if [ "$rc" -ne 0 ]; then pass "an unreachable endpoint fails the run"; else fail "an unreachable endpoint fails the run" "exit 0 — did it reach a model at all?"; fi
  if [ -s "$TMP/ipc/output/result.json" ]; then
    pass "the result file is written to the /ipc mount"
    json_is "$TMP/ipc/output/result.json" "read-only root: the result is an error" '.status' 'error'
    json_is "$TMP/ipc/output/result.json" "read-only root: the error is a non-empty string" '(.error | type == "string") and (.error | length > 0)' 'true'
    json_is "$TMP/ipc/output/result.json" "read-only root: no usage is claimed" 'has("metrics")' 'false'
  else
    fail "the result file is written to the /ipc mount" "$(tail -c 400 "$TMP/smoke")"
  fi
  if grep -q '__SYMPOZIUM_RESULT__' "$TMP/smoke"; then pass "read-only root: the marker reaches the log"; else fail "read-only root: the marker reaches the log" "$(tail -c 400 "$TMP/smoke")"; fi
  if grep -q '^harness/claude-code > session ' "$TMP/smoke"; then pass "the task came from /ipc/input/task.json and claude started"; else fail "the task came from /ipc/input/task.json and claude started" "$(tail -c 400 "$TMP/smoke")"; fi
  if grep -qE 'not a (tty|terminal)|ioctl|TTY|Read-only file system' "$TMP/smoke"; then
    fail "no TTY or writable-root assumption" "$(grep -m1 -E 'not a (tty|terminal)|ioctl|TTY|Read-only file system' "$TMP/smoke")"
  else
    pass "no TTY or writable-root assumption"
  fi

  # ── the contract version ──────────────────────────────────────────────────
  local wrong
  wrong="$(docker run --rm --read-only --user 1000:1000 \
    -e HOME=/home/agent -e TMPDIR=/tmp \
    -e SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1beta1 \
    -e TASK='Return one word.' \
    -v "$TMP/tmp:/tmp" "$tag" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q '"status":"error"' <<<"$wrong"; then
    pass "a contract this image does not implement is refused"
  else
    fail "a contract this image does not implement is refused" "exit $rc: $(tail -c 200 <<<"$wrong")"
  fi

  # ── the skip marker ───────────────────────────────────────────────────────
  #
  # /ipc/control is mounted read-only when Sympozium provides it. A skip needs
  # neither a task nor a credential, and never starts the harness.
  mkdir -p "$TMP/control"
  printf 'skip: nothing to plan' > "$TMP/control/skip"
  chmod 0755 "$TMP/control"; chmod 0644 "$TMP/control/skip"
  local skipped
  skipped="$(docker run --rm --read-only --user 1000:1000 \
    -e HOME=/home/agent -e TMPDIR=/tmp -e SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1 \
    -e SYMPOZIUM_RESULT_PATH=/tmp/result.json \
    --tmpfs /home/agent:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    -v "$TMP/control:/ipc/control:ro" "$tag" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q '"status":"skipped","response":"skip: nothing to plan"' <<<"$skipped"; then
    pass "the official skip marker skips the run"
  else
    fail "the official skip marker skips the run" "exit $rc: $(tail -c 300 <<<"$skipped")"
  fi

  # ── the same boot on a different filesystem ───────────────────────────────
  local onmem
  onmem="$(docker run --rm --read-only --user 1000:1000 \
    --tmpfs /home/agent:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    "${CONFORMANCE_ENV[@]}" \
    -e SYMPOZIUM_RESULT_PATH=/tmp/result.json \
    -e TASK='Return one word.' \
    -e MODEL_BASE_URL=http://127.0.0.1:9 \
    "$tag" 2>&1)"
  if grep -q '^harness/claude-code > session ' <<<"$onmem"; then pass "a tmpfs \$HOME and /tmp boot the same way"; else fail "a tmpfs \$HOME and /tmp boot the same way" "$(tail -c 300 <<<"$onmem")"; fi
  if grep -q '"status":"error"' <<<"$onmem"; then pass "the tmpfs run still answers on the contract"; else fail "the tmpfs run still answers on the contract" "$(tail -c 300 <<<"$onmem")"; fi

  # ── SIGTERM, in the container ─────────────────────────────────────────────
  #
  # The endpoint here is a non-routable address rather than a refused port,
  # so the harness is still waiting on it when the signal lands.
  local cid i
  cid="$(docker run -d --read-only --user 1000:1000 \
    --tmpfs /home/agent:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    "${CONFORMANCE_ENV[@]}" \
    -e SYMPOZIUM_RESULT_PATH=/tmp/result.json \
    -e TASK='Take your time.' \
    -e MODEL_BASE_URL=http://10.255.255.1:9 \
    "$tag")"
  for i in $(seq 1 60); do
    docker logs "$cid" 2>&1 | grep -q '^harness/claude-code > session ' && break
    sleep 0.5
  done
  docker stop --timeout 30 "$cid" >/dev/null 2>&1
  rc="$(docker inspect "$cid" --format '{{.State.ExitCode}}')"
  docker logs "$cid" >"$TMP/term" 2>&1
  docker rm -f "$cid" >/dev/null 2>&1 || true

  if [ "$rc" = "143" ]; then pass "SIGTERM exits 143"; else fail "SIGTERM exits 143" "exit $rc — SIGKILL after the grace period looks like 137"; fi
  if grep -q '__SYMPOZIUM_RESULT__' "$TMP/term" && grep -q '"status":"error"' "$TMP/term"; then
    pass "SIGTERM still answers on the contract"
  else
    fail "SIGTERM still answers on the contract" "$(tail -c 400 "$TMP/term")"
  fi
  if grep -q 'SIGTERM' "$TMP/term"; then pass "the error says it was stopped"; else fail "the error says it was stopped" "$(tail -c 200 "$TMP/term")"; fi
}

# ── stage: live ─────────────────────────────────────────────────────────────

# One real turn. Proves what a dead endpoint cannot: that the credential
# authenticates the way the adapter chose, and that usage comes back.
verify_live() {
  local tag="${1:-}"
  [ -n "$tag" ] || { echo "usage: ./verify.sh live <tag>" >&2; exit 2; }
  local token="${CLAUDE_CODE_OAUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
  [ -n "$token" ] || { echo "live: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY" >&2; exit 2; }
  local model="${MODEL_NAME:-claude-haiku-4-5-20251001}"
  TMP="$(mktemp -d)"
  echo "live: one turn through Anthropic ($model)"

  # Passed the way Sympozium passes it: under ANTHROPIC_API_KEY, whatever it is.
  ANTHROPIC_API_KEY="$token" docker run --rm --read-only --user 1000:1000 --cap-drop ALL \
    --tmpfs /home/agent:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    -e HOME=/home/agent -e TMPDIR=/tmp \
    -e SYMPOZIUM_RESULT_PATH=/tmp/result.json \
    -e SYMPOZIUM_HARNESS_CONTRACT_VERSION=v1alpha1 \
    -e MODEL_PROVIDER=anthropic -e MODEL_NAME="$model" \
    -e ANTHROPIC_API_KEY \
    -e SYSTEM_PROMPT='You are a terse test fixture.' \
    -e TOOL_POLICY_ALLOW=Read \
    -e TASK='Reply with exactly the word PONG and nothing else. Do not use any tools.' \
    "$tag" >"$TMP/out" 2>&1
  local rc=$?

  local result
  result="$(awk '/^__SYMPOZIUM_RESULT__$/ { getline; last = $0 } END { print last }' "$TMP/out")"
  if [ "$rc" -eq 0 ]; then pass "the run exits 0"; else fail "the run exits 0" "exit $rc: $(tail -c 600 "$TMP/out")"; fi
  if jq -e '.status == "success" and (.response | test("PONG"))' <<<"$result" >/dev/null 2>&1; then pass "the answer comes back"; else fail "the answer comes back" "$result"; fi
  if jq -e '.metrics.inputTokens > 0 and .metrics.outputTokens > 0' <<<"$result" >/dev/null 2>&1; then pass "usage comes back"; else fail "usage comes back" "$result"; fi
  if grep -q "session model=$model tools=1 " "$TMP/out"; then pass "the named model and the tool filter held"; else fail "the named model and the tool filter held" "$(grep -m1 'session' "$TMP/out")"; fi
  if ! grep -qF -- "$token" "$TMP/out"; then pass "the token never reaches the log"; else fail "the token never reaches the log"; fi
}

case "${1:-args}" in
  args)        verify_args ;;
  contract)    verify_contract ;;
  image)       shift; verify_image "$@" ;;
  conformance) shift; verify_conformance "$@" ;;
  live)        shift; verify_live "$@" ;;
  *) echo "usage: ./verify.sh [args | contract | image <tag> | conformance <tag> | live <tag>]" >&2; exit 2 ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
