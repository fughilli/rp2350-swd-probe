#!/usr/bin/env bash
# Run a pyOCD GDB server over the CMSIS-DAP probe and forward it to a remote
# over SSH, so the port is NEVER exposed on this machine's network — pyOCD binds
# localhost only, and a reverse SSH tunnel (ssh -R) carries it to the remote
# where the debugging client (gdb) runs.
#
# Runs on the HOST the probe is plugged into. pyOCD is //tools/pyocd (@firmware's
# hermetic pyOCD, Nix libusb backend) carrying our vendored CMSIS packs, driven
# via `bazel run` — so `--target gd32e230k8` works with no manual pack install.
#
# Usage:
#   tools/gdbserver.sh --target <pyocd-target> --ssh <user@remote> \
#       [--port N] [--remote-port N] [pyocd args...]
#
#   --ssh         SSH destination where gdb will connect (the remote end of the
#                 tunnel). Defaults to $GDBSERVER_SSH. Required (no --ssh and no
#                 env => error: this script refuses to expose the port locally).
#   --port        local pyOCD GDB port on this machine (default 3333).
#   --remote-port port the tunnel lands on at the remote's loopback
#                 (default: same as --port).
#   everything else is forwarded to `pyocd gdbserver` (e.g. --frequency).
#
# Example:
#   tools/gdbserver.sh --target gd32e230k8 --ssh kevin@devbox --frequency 4000000
#
# Then on the remote (kevin@devbox), connect to localhost:<remote-port>:
#   arm-none-eabi-gdb firmware.elf -ex 'target remote localhost:3333'
#   (gdb) load ; monitor reset halt ; continue
#
# Targets come from the vendored CMSIS packs (tools/pyocd/packs.in -> packs.lock).
# To add one: append its pyOCD target name to packs.in and relock:
#   bazel run @firmware//tools/pyocd:update_packs -- \
#     --packs-in tools/pyocd/packs.in --lock tools/pyocd/packs.lock
set -euo pipefail

# Run from the repo root so `bazel run @firmware//...` resolves this workspace.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PORT=3333
REMOTE_PORT=""
SSH_DEST="${GDBSERVER_SSH:-}"
pyocd_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) SSH_DEST="$2"; shift 2 ;;
    --ssh=*) SSH_DEST="${1#*=}"; shift ;;
    --remote-port) REMOTE_PORT="$2"; shift 2 ;;
    --remote-port=*) REMOTE_PORT="${1#*=}"; shift ;;
    -p | --port) PORT="$2"; shift 2 ;;        # captured for the tunnel; re-added below
    --port=*) PORT="${1#*=}"; shift ;;
    *) pyocd_args+=("$1"); shift ;;
  esac
done
REMOTE_PORT="${REMOTE_PORT:-$PORT}"

if [ -z "$SSH_DEST" ]; then
  cat >&2 <<'EOF'
error: no SSH destination. This script does not expose the GDB port locally;
it forwards over SSH. Pass --ssh <user@remote> (or set $GDBSERVER_SSH) — the
remote is the machine where you run gdb.
EOF
  exit 2
fi

# Reverse tunnel: remote:loopback:REMOTE_PORT -> this machine's localhost:PORT.
# Bound to the remote's loopback (default sshd GatewayPorts=no), so the port is
# reachable only on the remote, through SSH. ExitOnForwardFailure => fail loudly
# if REMOTE_PORT is already taken on the remote.
echo "[gdbserver] opening reverse SSH tunnel: ${SSH_DEST} localhost:${REMOTE_PORT} -> here localhost:${PORT}" >&2
ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -R "${REMOTE_PORT}:localhost:${PORT}" \
  "$SSH_DEST" &
SSH_PID=$!
trap 'kill "$SSH_PID" 2>/dev/null || true' EXIT INT TERM

cat >&2 <<EOF
[gdbserver] pyOCD binds localhost:${PORT} only (no network exposure).
[gdbserver] on ${SSH_DEST}, connect gdb to the tunnel:
[gdbserver]     arm-none-eabi-gdb <your.elf> -ex 'target remote localhost:${REMOTE_PORT}'
[gdbserver]   then:  (gdb) load   (gdb) monitor reset halt   (gdb) continue
[gdbserver] first build of //tools/pyocd fetches the hermetic toolchain; Ctrl-C to stop.
EOF

# --persist: survive client disconnects. No --allow-remote: localhost bind only.
bazel run //tools/pyocd -- \
  gdbserver --persist --port "${PORT}" "${pyocd_args[@]}"
