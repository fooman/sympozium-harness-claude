# shellcheck shell=bash
# harness-lib.sh — the half of the harness adapter that is the same for every
# backend: read the task Sympozium supplied, and hand the answer back on the
# result contract.
#
# Sourced by images/harness-*/harness-entrypoint.sh. A backend adapter adds
# only its own argv: which flags carry the system prompt and the tool policy,
# and how the harness is invoked.
#
# The contract in both directions is the one agent-runner already uses, which
# is why gates, cost estimation, retries, memory extraction and the run-detail
# UI keep working for a run they never drove:
#
#   in   TASK env, or /ipc/input/task.json
#   out  /ipc/output/result.json  (ipc.AgentResult — the ipc-bridge watches
#        this file and publishes the completion event)
#        plus the __SYMPOZIUM_RESULT__ marker on stdout, which the controller
#        parses out of the agent container's logs
#
# Copied from fooman/sympozium-harness-dsh (harness-lib.sh as of dd5aeb2) and
# extended so that copy could take it back unchanged: a backend that defines
# none of the new hooks and passes none of the new arguments behaves exactly
# as before, except that the pod-log copy of the harness output now has its
# result markers neutralised.
# The additions, each documented where it is defined:
#
#   harness::emit ... [metrics]   real token usage, validated, never zeros
#   harness::check_skip           the preRun hook's skip marker
#   harness::drop_credentials     unset the platform keys a harness does not use
#   harness::mcp_registry         MCP_CONFIG_PATH, validated, or an empty one
#   HARNESS_STDIN                 feed the harness a file on stdin
#   harness::log_filter           hook: shape the pod-log copy of the output
#   harness::parse_output         hook: build the result from structured output

RESULT_PATH="${SYMPOZIUM_RESULT_PATH:-/ipc/output/result.json}"

# The adapter contract this library implements, as Sympozium names it in
# SYMPOZIUM_HARNESS_CONTRACT_VERSION.
#
# Deliberately a constant and not an environment variable. The version says
# where the result goes and what is mounted under /ipc; if the answer could be
# supplied on the run, the platform could hand this adapter a contract it does
# not implement and tell it to accept it, which is worth nothing. A new
# contract version is a change here and a rebuild.
HARNESS_CONTRACT_VERSION=v1alpha1

# harness::require_contract refuses to run against a contract this adapter was
# not written for.
#
# The failure this prevents is not a crash. A future v1beta1 that moves the
# result path or narrows /ipc further would leave this adapter writing its
# answer somewhere nothing reads, and the run would look like a harness that
# simply produced nothing — so the check has to happen before any work, and has
# to fail loudly through the result contract rather than exit quietly.
#
# Unset is refused too, not warned about. "Assume v1alpha1 when nobody said"
# is the same guess this function exists to prevent, and it is the guess that
# would be wrong on exactly the platform worth catching: one whose harness mode
# predates the contract version and does not set it. Sympozium sets it on every
# harness run, so an empty value means no Sympozium, and running an adapter
# against no contract at all is not a thing this image does.
#
# The cost is that a bare `docker run` and HARNESS_DUMP_PATCH=1 must now name
# the contract themselves. verify.sh does, at every site that starts the
# entrypoint.
harness::require_contract() {
  local have="${SYMPOZIUM_HARNESS_CONTRACT_VERSION:-}"

  if [ "$have" = "$HARNESS_CONTRACT_VERSION" ]; then
    return 0
  fi

  if [ -z "$have" ]; then
    harness::fail "harness: SYMPOZIUM_HARNESS_CONTRACT_VERSION is unset. This image implements the ${HARNESS_CONTRACT_VERSION} adapter contract and runs under no other; Sympozium v0.10.49 and later set it on every harness run. Outside a run, set it explicitly."
  fi

  harness::fail "harness: this adapter implements the ${HARNESS_CONTRACT_VERSION} adapter contract, but Sympozium offers ${have}. Upgrade the adapter image rather than running it against a contract it does not understand."
}

# harness::task echoes the task text: TASK env first, then the orchestrator's
# /ipc/input/task.json. Empty output means neither was supplied.
harness::task() {
  if [ -n "${TASK:-}" ]; then
    printf '%s' "$TASK"
    return 0
  fi
  if [ -r /ipc/input/task.json ]; then
    jq -r '.task // ""' /ipc/input/task.json
    return 0
  fi
  printf ''
}

# harness::split_csv prints one entry per line from a comma-separated list,
# trimming whitespace and dropping empties. Used for TOOL_POLICY_ALLOW/DENY.
harness::split_csv() {
  printf '%s' "${1:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# HARNESS_PLATFORM_AUTH_KEYS is Sympozium's allowedAuthSecretKeys, in the
# controller's order (internal/controller/agentrun_controller.go): the only
# Secret keys it ever injects into a harness container. A backend's own
# preference order is a separate list; this one is the platform's.
HARNESS_PLATFORM_AUTH_KEYS=(
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
  AZURE_OPENAI_API_KEY
  AZURE_OPENAI_ENDPOINT
  OLLAMA_HOST
  GOOGLE_API_KEY
  MISTRAL_API_KEY
  GROQ_API_KEY
  DEEPSEEK_API_KEY
  OPENROUTER_API_KEY
  API_KEY
)

# harness::drop_credentials unsets every platform credential and every
# MCP_AUTH_* variable except the names given.
#
# A harness that runs model-authored commands hands its environment to them.
# Sympozium injects each allowlisted key the Secret happens to contain, so a
# Secret holding two providers' keys puts both on a run that uses one. Call
# this once the backend knows which credential it routes with, and before the
# harness starts.
harness::drop_credentials() {
  local name keep
  for name in "${HARNESS_PLATFORM_AUTH_KEYS[@]}" $(compgen -e | grep '^MCP_AUTH_' || true); do
    for keep in "$@"; do
      [ "$name" = "$keep" ] && continue 2
    done
    unset "$name"
  done
}

# harness::mcp_registry echoes the MCP registry at MCP_CONFIG_PATH as compact
# JSON, or an empty registry when there is none. It returns non-zero, with the
# reason on stderr, when the file is not a JSON object; the caller fails the
# run, because an agent quietly missing the tools the AgentRun asked for still
# succeeds.
#
# The registry is the JSON rendering of the ConfigMap the controller generates
# (buildMCPServersJSON): {"servers":[{name,url,toolsPrefix,timeout,auth?,
# headers?,toolsAllow?,toolsDeny?}]}.
harness::mcp_registry() {
  if [ -z "${MCP_CONFIG_PATH:-}" ] || [ ! -r "${MCP_CONFIG_PATH}" ]; then
    printf '%s' '{"servers":[]}'
    return 0
  fi
  jq -ce 'if type == "object" then . else error("not an object") end' "$MCP_CONFIG_PATH" 2>/dev/null && return 0
  echo "harness: MCP_CONFIG_PATH ($MCP_CONFIG_PATH) is not a JSON object" >&2
  return 1
}

# harness::check_skip answers a preRun hook that found no work.
#
# The hook writes a skip marker. agent-runner reads it and never calls the
# model; Sympozium then marks the run Skipped. A harness container gets only
# /ipc/input and /ipc/output, so it cannot see agent-runner's marker. Two
# places are checked, first match wins:
#
#   /ipc/control/skip — the official marker, once Sympozium mounts
#     /ipc/control here (read-only). Nothing else lives under /ipc/control.
#   $SKIP_MARKER_FALLBACK (default /workspace/.sympozium/skip) — a copy the
#     hook also writes, for releases that do not mount /ipc/control. The
#     workspace can be durable across runs, so this one is removed once read;
#     a leftover must never skip the next run.
#
# The file's content is the skip reason. The result is {status: "skipped"},
# which the controller turns into the Skipped phase. No credential or task is
# needed to skip, so a backend calls this straight after require_contract.
harness::check_skip() {
  local fallback="${SKIP_MARKER_FALLBACK:-/workspace/.sympozium/skip}" path reason
  for path in /ipc/control/skip "$fallback"; do
    [ -f "$path" ] || continue
    reason="$(head -c 4096 "$path" 2>/dev/null || true)"
    if [ "$path" != /ipc/control/skip ]; then
      rm -f "$path" 2>/dev/null || echo "harness: could not remove $path; the next run may skip wrongly" >&2
    fi
    echo "harness: skip marker $path found; not starting ${HARNESS_BACKEND:-the harness}" >&2
    harness::emit skipped "${reason:-preRun hook requested skip}"
    exit 0
  done
}

# harness::emit writes the result contract. $1 is "success", "error" or
# "skipped", $2 is the response (success), the message (error) or the reason
# (skipped). $3, optional, is the run's metrics as a JSON object.
#
# The payload is assembled with jq --arg so the harness's output is encoded as
# a JSON string and cannot forge a result structure. It cannot forge the
# marker either: an agent that prints __SYMPOZIUM_RESULT__ mid-run is
# overtaken by this one, because the controller parses the LAST marker in the
# log (parseAgentResultFromLogs uses strings.LastIndex).
#
# metrics are deliberately omitted. An external harness reports token usage
# differently or not at all, and the controller treats absent as absent —
# reporting zeros here would claim a run cost nothing.
#
# That omission is what makes this an unmetered adapter, and Sympozium v0.10.51
# and later refuses to run one by accident: the backing policy has to say
# `harnessPolicy.allowUnmetered: true` as well as `enabled: true`, or the run is
# denied at admission. Emitting fabricated metrics to get past that check would
# defeat the check.
#
# A backend whose harness does report real usage passes it as $3, and only
# then: {durationMs, inputTokens, outputTokens, toolCalls}, plus any breakdown
# the controller may read later (cachedInputTokens, in the OpenAI shape: a
# part of inputTokens, not an addition). Every value must be a non-negative
# integer. Anything else is dropped with a warning rather than emitted, because
# the controller budgets on these numbers. Absent stays absent: a backend with
# no usage to report passes nothing.
harness::emit() {
  local status="$1" body="$2" metrics="${3:-}" payload
  if [ -n "$metrics" ] && [ "$metrics" != null ]; then
    metrics="$(jq -ce '
        if type == "object" and length > 0
           and ([.[] | type == "number" and . >= 0 and . == floor] | all)
        then . else error("malformed") end' <<<"$metrics" 2>/dev/null)" || {
      echo "harness: dropping malformed metrics; the run reports none" >&2
      metrics=""
    }
  fi
  payload="$(jq -cn --arg status "$status" --arg body "$body" --argjson metrics "${metrics:-null}" \
    '(if $status == "error"
      then {status: $status, error: $body}
      else {status: $status, response: $body}
      end)
     + (if $metrics == null then {} else {metrics: $metrics} end)')"

  mkdir -p "$(dirname "$RESULT_PATH")" 2>/dev/null || true
  printf '%s' "$payload" > "$RESULT_PATH" || echo "harness: could not write $RESULT_PATH" >&2

  printf '__SYMPOZIUM_RESULT__\n%s\n__SYMPOZIUM_END__\n' "$payload"
}

# harness::fail emits an error result and exits non-zero, so the controller
# marks the run Failed with a message rather than an empty result.
harness::fail() {
  harness::emit error "$1"
  exit 1
}

# harness::_stopped answers a SIGTERM or SIGINT that arrives mid-run.
#
# Sympozium sends SIGTERM when a run hits its `spec.timeout`, when someone
# cancels it, or when the pod is evicted, and SIGKILLs whatever is left after
# the grace period. Without a handler the harness never sees that signal —
# only PID 1 does — so the run is killed with no result on either channel and
# reaches the UI as a harness that produced nothing, rather than as a run that
# was stopped. Turning the signal into the ordinary error contract is what
# makes those two distinguishable.
#
# 143 and 130 are the conventional 128+signal exit codes, so the container's
# exit status says the same thing the result does.
harness::_stopped() {
  local sig="$1" code="$2" detail=""

  # No re-entry: this handler is about to write the result, and a second
  # signal landing inside it would race that write.
  trap '' TERM INT

  # The harness first, so it stops producing; then the tee that copies its
  # output to the pod log, so nothing can still be writing to stdout when the
  # result marker goes out. The controller parses the LAST marker in the log.
  if [ -n "${HARNESS_CHILD_PID:-}" ]; then
    kill -TERM "$HARNESS_CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "${HARNESS_TEE_PID:-}" ]; then
    kill -TERM "$HARNESS_TEE_PID" 2>/dev/null || true
  fi
  if [ -n "${HARNESS_LOG_PID:-}" ]; then
    kill -TERM "$HARNESS_LOG_PID" 2>/dev/null || true
  fi

  if declare -F harness::pre_emit >/dev/null 2>&1; then
    harness::pre_emit
  fi

  if [ -n "${HARNESS_OUT:-}" ] && [ -s "${HARNESS_OUT:-}" ]; then
    detail=": $(tail -c 500 "$HARNESS_OUT")"
  fi

  harness::emit error "harness ${HARNESS_BACKEND:-unknown} was stopped by SIG${sig} before it answered${detail}"
  exit "$code"
}

# harness::neutralise_markers copies stdin to stdout line by line, with the
# result markers rewritten so nothing in the pod-log copy of the harness output
# can read as a result block. The controller already takes the LAST marker in
# the log, so a forged one is overtaken; this keeps the log itself unambiguous
# as well. A shell loop rather than sed or awk, because both buffer a pipe on
# one platform or another, and a progress line that arrives a buffer late is
# not progress.
harness::neutralise_markers() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//__SYMPOZIUM_RESULT__/__SYMPOZIUM_RESULT_ESCAPED__}"
    printf '%s\n' "${line//__SYMPOZIUM_END__/__SYMPOZIUM_END_ESCAPED__}"
  done
}

# harness::_log_view is the pod-log copy of the harness output. A backend may
# define harness::log_filter, which reads the raw output on stdin and prints
# what the pod log should show instead: a structured stream reduced to one
# progress line per event, say. It must not print the answer or tool inputs
# unless the backend means them to be in the log.
#
# Whatever the filter leaves unread is drained, because tee writes this copy
# and the capture together: a filter that exited early would stop tee with
# SIGPIPE, then the harness writing into tee, and lose the capture with it.
harness::_log_view() {
  if declare -F harness::log_filter >/dev/null 2>&1; then
    { harness::log_filter; cat > /dev/null; } | harness::neutralise_markers
  else
    harness::neutralise_markers
  fi
}

# harness::run executes the harness argv, streaming its output to the pod log
# while capturing it, then emits the captured output as the run's result.
# A non-zero exit becomes an error result carrying the tail of that output.
#
# The harness runs in the background with the adapter waiting on it, rather
# than in the foreground, because bash defers every trap until a foreground
# external command returns — and a handler that only runs once the harness has
# finished is no handler at all for a run being timed out. `wait` is
# interruptible, so the signal is answered while the harness is still going.
#
# The capture is a FIFO into tee rather than a pipeline, so the recorded PID is
# the harness itself and not the last stage of a pipeline: a TERM sent to the
# wrong end of a pipeline stops the copy and leaves the agent running. tee is
# started first because opening a FIFO for writing blocks until a reader opens
# it. The pod-log copy goes through a second FIFO for the same reason, and its
# reader starts before tee.
#
# HARNESS_STDIN, when set, names a file the harness reads on stdin. Otherwise
# stdin is /dev/null, as it is for any background job in a non-interactive
# shell. A task passed as a file cannot be mistaken for a flag and is not
# bounded by the kernel's per-argument limit (128KiB on Linux), which an
# argv-borne task is.
#
# A backend whose harness writes structured output may define
# harness::parse_output instead of taking the captured text as the answer. It
# is called with the capture file and the exit code, and prints one JSON object:
#
#   {"status": "success", "response": "...", "metrics": {...}}   or
#   {"status": "error",   "error": "...",    "metrics": {...}}
#
# metrics optional, as for harness::emit. The library still owns the exit code:
# a harness that exited non-zero is never reported as a success, and output the
# hook cannot read becomes an error carrying its tail.
harness::run() {
  local out fifo logfifo rc
  out="$(mktemp "${TMPDIR:-/tmp}/harness-out.XXXXXX")" || harness::fail "harness: could not create a capture file"
  fifo="${out}.fifo"
  logfifo="${out}.log.fifo"
  mkfifo "$fifo" "$logfifo" || harness::fail "harness: could not create a capture pipe"
  HARNESS_OUT="$out"

  echo "harness: running ${HARNESS_BACKEND:-unknown}: $*" >&2
  set +e

  harness::_log_view < "$logfifo" &
  HARNESS_LOG_PID=$!

  tee "$out" < "$fifo" > "$logfifo" &
  HARNESS_TEE_PID=$!

  if [ -n "${HARNESS_STDIN:-}" ]; then
    "$@" < "$HARNESS_STDIN" > "$fifo" 2>&1 &
  else
    "$@" > "$fifo" 2>&1 &
  fi
  HARNESS_CHILD_PID=$!

  trap 'harness::_stopped TERM 143' TERM
  trap 'harness::_stopped INT 130' INT
  wait "$HARNESS_CHILD_PID"
  rc=$?
  trap - TERM INT
  HARNESS_CHILD_PID=""

  # tee may still be draining the pipe. Waiting for it is what makes the
  # capture file complete before it is read; waiting for the log view is what
  # keeps it from printing after the result marker.
  wait "$HARNESS_TEE_PID" 2>/dev/null
  HARNESS_TEE_PID=""
  wait "$HARNESS_LOG_PID" 2>/dev/null
  HARNESS_LOG_PID=""
  rm -f "$fifo" "$logfifo" 2>/dev/null || true
  set -e

  # A backend may define harness::pre_emit to run between the harness exiting
  # and the result being written — the dsh adapter stops its progress streamer
  # there. It matters that this happens *before* the marker is printed: the
  # controller parses the last marker in the log, so nothing may still be
  # writing to stdout once the real one goes out.
  if declare -F harness::pre_emit >/dev/null 2>&1; then
    harness::pre_emit
  fi

  if declare -F harness::parse_output >/dev/null 2>&1; then
    harness::_emit_parsed "$out" "$rc"
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    local tail_out
    tail_out="$(tail -c 2000 "$out")"
    harness::emit error "harness ${HARNESS_BACKEND:-unknown} exited ${rc}: ${tail_out}"
    exit "$rc"
  fi

  harness::emit success "$(cat "$out")"
}

# harness::_emit_parsed emits what harness::parse_output made of the capture,
# and exits non-zero for anything but a success.
harness::_emit_parsed() {
  local out="$1" rc="$2" parsed status body metrics
  parsed="$(harness::parse_output "$out" "$rc")" || parsed=""

  if ! jq -e 'type == "object"
              and ((.status == "success" and (.response | type == "string"))
                or (.status == "error" and (.error | type == "string")))' \
       <<<"$parsed" >/dev/null 2>&1; then
    harness::emit error "harness ${HARNESS_BACKEND:-unknown} exited ${rc}, and its output could not be read: $(tail -c 2000 "$out")"
    exit "$(( rc == 0 ? 1 : rc ))"
  fi

  status="$(jq -r '.status' <<<"$parsed")"
  body="$(jq -r 'if .status == "error" then .error else .response end' <<<"$parsed")"
  metrics="$(jq -c '.metrics // null' <<<"$parsed")"

  if [ "$status" = success ] && [ "$rc" -ne 0 ]; then
    harness::emit error "harness ${HARNESS_BACKEND:-unknown} exited ${rc} after answering: ${body}" "$metrics"
    exit "$rc"
  fi
  if [ "$status" = error ]; then
    harness::emit error "$body" "$metrics"
    exit "$(( rc == 0 ? 1 : rc ))"
  fi
  harness::emit success "$body" "$metrics"
}
