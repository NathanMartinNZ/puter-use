#!/usr/bin/env bash
# Start PuterUseProbe, a test window that logs every event it receives, in the background.
# Prints "probe pid <pid> window <id> log <path>". Stop it with: kill <pid>
# The log goes to $PROBE_LOG (default ~/Library/Caches/puter-use/probe.jsonl, truncated on start).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --package-path "$root/helper" --product PuterUseProbe >&2
bin="$(swift build -c release --package-path "$root/helper" --show-bin-path)/PuterUseProbe"
out="$(mktemp)"
nohup "$bin" >"$out" 2>&1 &
for _ in $(seq 50); do
  if grep -q "^probe pid" "$out"; then grep "^probe pid" "$out"; exit 0; fi
  sleep 0.1
done
echo "probe did not start; output:" >&2
cat "$out" >&2
exit 1
