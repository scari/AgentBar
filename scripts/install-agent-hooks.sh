#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CODEX_CONFIG="${HOME}/.codex/config.toml"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CLAUDE_HOOKS_CONFIG="${HOME}/.claude/hooks/config.json"
GEMINI_SETTINGS="${HOME}/.gemini/settings.json"
OPENCODE_PLUGIN="${HOME}/.config/opencode/plugins/agentbar-notify.js"

CODEX_HOOK_SCRIPT="${ROOT_DIR}/scripts/agentbar-codex-hook.sh"
CLAUDE_HOOK_SCRIPT="${ROOT_DIR}/scripts/agentbar-hook.sh"
GEMINI_HOOK_SCRIPT="${ROOT_DIR}/scripts/agentbar-gemini-hook.sh"
OPENCODE_HOOK_SCRIPT="${ROOT_DIR}/scripts/agentbar-opencode-hook.sh"

BACKUP_ROOT=""
BACKUP_INDEX_FILE="$(mktemp "${TMPDIR:-/tmp}/agentbar-hook-backups.XXXXXX")"
trap 'rm -f "$BACKUP_INDEX_FILE"' EXIT

MODIFIED_COUNT=0
MODIFIED_PATHS=()

ensure_backup_root() {
  if [[ -n "$BACKUP_ROOT" ]]; then
    return
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_ROOT="${HOME}/.agentbar/backups/${timestamp}"
  mkdir -p "$BACKUP_ROOT"
}

backup_once() {
  local target="$1"
  if [[ ! -f "$target" ]]; then
    return
  fi

  if grep -Fxq "$target" "$BACKUP_INDEX_FILE"; then
    return
  fi

  ensure_backup_root

  local backup_target="${BACKUP_ROOT}/${target#/}"
  mkdir -p "$(dirname "$backup_target")"
  cp -p "$target" "$backup_target"
  printf '%s\n' "$target" >> "$BACKUP_INDEX_FILE"

  echo "Backed up: ${target} -> ${backup_target}"
}

write_if_changed() {
  local target="$1"
  local content="$2"

  local old_content=""
  if [[ -f "$target" ]]; then
    old_content="$(cat "$target")"
  fi

  if [[ "$old_content" == "$content" ]]; then
    return 0
  fi

  backup_once "$target"
  mkdir -p "$(dirname "$target")"
  printf '%s' "$content" > "$target"
  MODIFIED_COUNT=$((MODIFIED_COUNT + 1))
  MODIFIED_PATHS+=("$target")
  echo "Updated: ${target}"
}

render_codex_config() {
  local target="$1"
  local hook_script="$2"
  python3 - "$target" "$hook_script" <<'PY'
import os
import re
import sys

path = sys.argv[1]
hook = sys.argv[2]
notify_line = f'notify = ["{hook}"]'

text = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()

# Always keep notify at top-level:
# 1) Remove existing notify assignments (possibly nested in tables),
# 2) Insert once before the first table header.
cleaned = re.sub(r"(?m)^\s*notify\s*=.*$\n?", "", text)
lines = cleaned.splitlines()
insert_index = len(lines)
for i, line in enumerate(lines):
    if line.strip().startswith("["):
        insert_index = i
        break

lines.insert(insert_index, notify_line)
new_text = "\n".join(lines).rstrip("\n") + "\n"

sys.stdout.write(new_text)
PY
}

install_codex_hook() {
  local rendered
  rendered="$(render_codex_config "$CODEX_CONFIG" "$CODEX_HOOK_SCRIPT")"

  write_if_changed "$CODEX_CONFIG" "$rendered"
}

render_claude_settings() {
  local target="$1"
  python3 - "$target" "$CLAUDE_HOOK_SCRIPT" <<'PY'
import json
import os
import sys

path = sys.argv[1]
hook = sys.argv[2]

if os.path.exists(path):
    raw = open(path, "r", encoding="utf-8").read().strip()
    data = json.loads(raw) if raw else {}
else:
    data = {}

if not isinstance(data, dict):
    data = {}

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}

def has_hook_command(items):
    for item in items:
        if not isinstance(item, dict):
            continue
        nested = item.get("hooks")
        if not isinstance(nested, list):
            continue
        for hook_item in nested:
            if not isinstance(hook_item, dict):
                continue
            if hook_item.get("type") == "command" and hook_item.get("command") == hook:
                return True
    return False

for event_name in ["Notification", "Stop", "SubagentStop"]:
    event_hooks = hooks.get(event_name)
    if not isinstance(event_hooks, list):
        event_hooks = []

    if not has_hook_command(event_hooks):
        event_hooks.append({
            "description": "Forward events to AgentBar",
            "hooks": [
                {
                    "type": "command",
                    "command": hook,
                }
            ],
        })

    hooks[event_name] = event_hooks

data["hooks"] = hooks
sys.stdout.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

install_claude_hook() {
  local rendered

  rendered="$(render_claude_settings "$CLAUDE_SETTINGS")"
  write_if_changed "$CLAUDE_SETTINGS" "$rendered"

  rendered="$(render_claude_settings "$CLAUDE_HOOKS_CONFIG")"
  write_if_changed "$CLAUDE_HOOKS_CONFIG" "$rendered"
}

render_gemini_settings() {
  local target="$1"
  local hook_script="$2"
  python3 - "$target" "$hook_script" <<'PY'
import json
import os
import sys

path = sys.argv[1]
hook = sys.argv[2]

if os.path.exists(path):
    raw = open(path, "r", encoding="utf-8").read().strip()
    data = json.loads(raw) if raw else {}
else:
    data = {}

if not isinstance(data, dict):
    data = {}

hooks_config = data.get("hooksConfig")
if not isinstance(hooks_config, dict):
    hooks_config = {}
hooks_config["enabled"] = True
data["hooksConfig"] = hooks_config

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}

def has_hook_command(items):
    for item in items:
        if not isinstance(item, dict):
            continue
        nested = item.get("hooks")
        if not isinstance(nested, list):
            continue
        for hook_item in nested:
            if not isinstance(hook_item, dict):
                continue
            if hook_item.get("type") == "command" and hook_item.get("command") == hook:
                return True
    return False

after_agent = hooks.get("AfterAgent")
if not isinstance(after_agent, list):
    after_agent = []
if not has_hook_command(after_agent):
    after_agent.append({
        "description": "Forward completion events to AgentBar",
        "hooks": [
            {
                "type": "command",
                "command": hook,
            }
        ],
    })
hooks["AfterAgent"] = after_agent

notification = hooks.get("Notification")
if not isinstance(notification, list):
    notification = []
if not has_hook_command(notification):
    notification.append({
        "description": "Forward permission notifications to AgentBar",
        "matcher": "ToolPermission",
        "hooks": [
            {
                "type": "command",
                "command": hook,
            }
        ],
    })
hooks["Notification"] = notification

data["hooks"] = hooks
sys.stdout.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

install_gemini_hook() {
  local rendered
  rendered="$(render_gemini_settings "$GEMINI_SETTINGS" "$GEMINI_HOOK_SCRIPT")"

  write_if_changed "$GEMINI_SETTINGS" "$rendered"
}

render_opencode_plugin() {
  python3 - <<'PY'
content = '''import os from "node:os";
import { createConnection } from "node:net";

const SOCKET_PATH =
  process.env.AGENTBAR_SOCKET || `${os.homedir()}/.agentbar/events.sock`;

function coerceString(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }
  if (value === null || value === undefined) {
    return null;
  }
  const converted = String(value).trim();
  return converted.length > 0 ? converted : null;
}

function mapEventType(sourceType) {
  const normalized = (sourceType || "").toLowerCase();
  switch (normalized) {
    case "session.idle":
    case "session.completed":
    case "stop":
    case "done":
    case "task_complete":
      return "stop";
    case "permission.asked":
    case "permission":
    case "required_permission":
      return "decision";
    case "question.asked":
    case "question":
    case "required_input":
    case "decision":
    case "session.error":
    case "error":
      return "decision";
    default:
      return null;
  }
}

function extractSessionID(sourceEvent) {
  return (
    coerceString(sourceEvent?.properties?.sessionID) ||
    coerceString(sourceEvent?.properties?.sessionId) ||
    coerceString(sourceEvent?.sessionID) ||
    coerceString(sourceEvent?.sessionId) ||
    ""
  );
}

function extractMessage(sourceEvent) {
  const message =
    coerceString(sourceEvent?.properties?.message) ||
    coerceString(sourceEvent?.properties?.error?.message) ||
    coerceString(sourceEvent?.properties?.permission) ||
    coerceString(sourceEvent?.message) ||
    coerceString(sourceEvent?.error?.message);

  if (!message) {
    return null;
  }
  if (message.startsWith("Permission requested:")) {
    return message;
  }
  if (sourceEvent?.properties?.permission) {
    return `Permission requested: ${message}`;
  }
  return message;
}

function defaultMessage(eventType) {
  switch (eventType) {
    case "stop":
      return "OpenCode task completed.";
    case "decision":
      return "OpenCode is waiting for your input.";
    default:
      return "OpenCode event received.";
  }
}

function forwardToAgentBar(payload) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        socket.destroy();
      } catch (_error) {
        // no-op
      }
      resolve();
    };

    const socket = createConnection(SOCKET_PATH);
    socket.on("error", finish);
    socket.on("timeout", finish);
    socket.on("close", finish);
    socket.setTimeout(500);

    socket.on("connect", () => {
      try {
        socket.write(`${JSON.stringify(payload)}\\n`);
      } catch (_error) {
        // ignore serialization/socket write errors
      } finally {
        socket.end();
      }
    });
  });
}

export const AgentBarNotifyPlugin = async () => {
  return {
    event: async (input) => {
      const sourceEvent =
        input && typeof input.event === "object" ? input.event : input;
      if (!sourceEvent || typeof sourceEvent !== "object") {
        return;
      }

      const sourceType = coerceString(sourceEvent.type);
      const eventType = mapEventType(sourceType);
      if (!eventType) {
        return;
      }

      const payload = {
        agent: "opencode",
        event: eventType,
        session_id: extractSessionID(sourceEvent),
        message: extractMessage(sourceEvent) || defaultMessage(eventType),
        timestamp: new Date().toISOString(),
      };
      await forwardToAgentBar(payload);
    },
  };
};
'''

print(content, end="")
PY
}

install_opencode_hook() {
  local plugin_content
  plugin_content="$(render_opencode_plugin)"
  write_if_changed "$OPENCODE_PLUGIN" "$plugin_content"
}

ensure_scripts_executable() {
  chmod +x "$CODEX_HOOK_SCRIPT"
  chmod +x "$CLAUDE_HOOK_SCRIPT"
  chmod +x "$GEMINI_HOOK_SCRIPT"
  chmod +x "$OPENCODE_HOOK_SCRIPT"
}

main() {
  ensure_scripts_executable
  install_codex_hook
  install_claude_hook
  install_gemini_hook
  install_opencode_hook

  if [[ "$MODIFIED_COUNT" -eq 0 ]]; then
    echo "No changes needed. Hooks are already configured."
  else
    echo ""
    echo "Hook installation completed. Updated ${MODIFIED_COUNT} file(s):"
    for path in "${MODIFIED_PATHS[@]}"; do
      echo "- ${path}"
    done
  fi

  if [[ -n "$BACKUP_ROOT" ]]; then
    echo ""
    echo "Backups saved under: ${BACKUP_ROOT}"
  fi
}

main "$@"
