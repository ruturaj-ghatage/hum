#!/bin/bash
# Claude Code hook → Hum. Reads the hook's JSON on stdin and tells the notch what Claude is doing.
# Usage (in ~/.claude/settings.json hooks): claude-hook.sh start|stop|attention|end

enc() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf %s "$out"
}

input=$(cat)
field() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
session=$(field session_id)
cwd=$(field cwd)
project=$(basename "${cwd:-$PWD}")

open -g "hum://claude?event=$1&session=$(enc "$session")&project=$(enc "$project")" >/dev/null 2>&1 &
exit 0
