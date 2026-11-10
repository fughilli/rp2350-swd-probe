#!/usr/bin/env bash
# Run a pyOCD GDB server over the CMSIS-DAP probe and expose it to a remote
# (e.g. a container or another machine) for remote firmware load/debug.
#
# Runs on the HOST the probe is plugged into. pyOCD is @firmware's hermetic
# //tools/pyocd (Nix libusb backend), driven via `bazel run` — nothing to
# install but Nix + Bazel, same toolchain the sibling firmware repos use.
#
# Usage:
#   tools/gdbserver.sh --target <pyocd-target> [--port N] [--frequency HZ] [pyocd args...]
#
# Examples:
#   tools/gdbserver.sh --target gd32e230k8          # GD32E230 (Rd-03E host MCU)
#   tools/gdbserver.sh --target stm32g0b1xx --port 3333 --frequency 4000000
#
# Then from the remote, connect arm-none-eabi-gdb to <HOST-IP>:<port>:
#   (gdb) target remote <HOST-IP>:3333
#   (gdb) load                # flash the ELF you opened gdb with
#   (gdb) monitor reset halt
#
# Notes:
#   * --allow-remote and --persist are added automatically (remote connects;
#     server survives a client disconnect so you can reconnect).
#   * A pyOCD target outside its built-ins needs its CMSIS pack first:
#       bazel run @firmware//tools/pyocd -- pack install <target>
#     (GD32E230 ships in GigaDevice's pack: `... pyocd pack find gd32e230`.)
set -euo pipefail

# Run from the repo root so `bazel run @firmware//...` resolves this workspace.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Default GDB port (pyOCD's default); parse the user's -p/--port only to print
# the right connect hint — all args are still forwarded to pyocd verbatim.
PORT=3333
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -p | --port) PORT="${args[$((i + 1))]:-3333}" ;;
    --port=*) PORT="${args[$i]#*=}" ;;
  esac
done

# Best-effort LAN IP for the connect hint (macOS + Linux).
host_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(n=1;n<=NF;n++) if($n=="src"){print $(n+1); exit}}'
  fi
}
IP="$(host_ip | head -n1)"; IP="${IP:-<HOST-IP>}"

cat >&2 <<EOF
[gdbserver] starting pyOCD GDB server on 0.0.0.0:${PORT} (remote connections allowed)
[gdbserver] connect from the remote with:
[gdbserver]     arm-none-eabi-gdb <your.elf> -ex 'target remote ${IP}:${PORT}'
[gdbserver]   then:  (gdb) load   (gdb) monitor reset halt   (gdb) continue
[gdbserver] if the remote can't route to ${IP}, tunnel instead:
[gdbserver]     ssh -N -L ${PORT}:localhost:${PORT} <user>@${IP}   # drop --allow-remote below
[gdbserver] first build of //tools/pyocd fetches the hermetic toolchain; Ctrl-C to stop.
EOF

# --persist: survive client disconnects.  --allow-remote: accept non-local TCP.
exec bazel run @firmware//tools/pyocd -- \
  gdbserver --persist --allow-remote --port "${PORT}" "$@"
