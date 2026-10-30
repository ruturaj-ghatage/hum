#!/bin/bash
# Adds Hum's hooks to ~/.claude/settings.json so the notch shows what Claude Code is doing.
# Keeps any hooks you already have, makes a backup first, and is safe to run twice.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-hum"

/usr/bin/python3 -I - "$SETTINGS" <<'EOF'
import json, sys
path = sys.argv[1]
settings = json.load(open(path))
script = '"$HOME/Applications/Hum.app/Contents/Resources/claude-hook.sh"'
events = {
    "UserPromptSubmit": ("start", None),
    "Stop": ("stop", None),
    "StopFailure": ("fail", None),
    "PermissionRequest": ("attention", "*"),
    "PostToolUse": ("resume", "*"),
    "SessionEnd": ("end", None),
}
hooks = settings.setdefault("hooks", {})
for name, (event, matcher) in events.items():
    groups = hooks.setdefault(name, [])
    if any("claude-hook.sh" in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        continue
    group = {"hooks": [{"type": "command", "command": f"[ -x {script} ] && {script} {event} || true"}]}
    if matcher:
        group = {"matcher": matcher, **group}
    groups.append(group)
json.dump(settings, open(path, "w"), indent=2)
EOF

echo "Hum hooks added to $SETTINGS (backup: $SETTINGS.bak-hum)"
