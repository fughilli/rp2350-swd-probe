# rp2350-swd-probe

Turn a bare **RP2350** board (Raspberry Pi Pico 2, or any RP2350 board) into a
**CMSIS-DAP SWD debug probe** by flashing Raspberry Pi's stock
[`debugprobe`](https://github.com/raspberrypi/debugprobe) firmware onto it — one
`bazel run` — and then drive remote firmware load/debug through it over a
forwarded pyOCD GDB server.

Once flashed, the board is a standard CMSIS-DAP probe that pyOCD, OpenOCD and
`probe-rs` all speak to, plus a USB-serial port bridged to the target's UART.
This is the probe used to flash the STM32G0 in
[`fughilli/tentacle_lamp`](https://github.com/fughilli/tentacle_lamp) and to
drive SWD on the GD32E230 in the Rd-03E radar RE work.

Tooling is reused from [`fughilli/embedded`](https://github.com/fughilli/embedded)
(bzlmod module `firmware`): its hermetic Nix `picotool` for flashing and its
hermetic pyOCD (`//tools/pyocd`, with the Nix libusb backend) for the GDB
server — the same toolchain the sibling firmware repos use. Nothing to install
but Nix and Bazel.

## 1. Flash a fresh RP2350 as a probe

```sh
bazel run //:flash_probe          # RP2350 / Pico 2   (debugprobe-v2.3.1)
bazel run //:flash_probe_pico     # RP2040 / original Pico
```

- **Fresh board:** hold **BOOTSEL** while plugging into USB (it mounts as
  `RP2350`/`RPI-RP2`), then run the command above.
- **Re-flashing an existing probe** (already running firmware, so it shows a USB
  serial and *isn't* in BOOTSEL), force it into BOOTSEL first by passing `-f`:

  ```sh
  bazel run //:flash_probe -- -f
  ```

  (`picotool load -x <uf2> -f` — the `-f` reboots the running board into BOOTSEL,
  then loads. Pass-through args go after the UF2, which is where picotool's
  device-selection flags belong.)

`picotool load -x` writes the UF2 and reboots into it; the board re-enumerates as
a CMSIS-DAP probe (plus a CDC serial). Run this on the machine the board is
plugged into — USB is host-local. The firmware image is fetched, pinned by
sha256, from the official debugprobe release; nothing is built from source.

## 2. Wiring (debugprobe default pin map)

The debugprobe firmware uses this fixed pinout on the **probe** RP2350. Wire
these to the matching SWD pads on the **target** MCU:

| Probe RP2350 pin | Signal | Connect to target |
|------------------|--------|-------------------|
| **GP2**          | SWCLK  | target SWCLK / SWDCLK |
| **GP3**          | SWDIO  | target SWDIO / SWDAT  |
| **GND** (any)    | GND    | target GND            |
| GP4 *(optional)* | UART TX (probe → target) | target UART RX |
| GP5 *(optional)* | UART RX (probe ← target) | target UART TX |

- **SWD is just GP2 + GP3 + GND** — that's the whole debug connection. (This is
  the "pins 2, 3 and GND" setup.)
- **GP4/GP5 are optional**: a USB-serial bridge to the target's UART, exposed as
  a second CDC port on the probe. Skip them if you only need SWD.
- **Power:** the probe does *not* power the target through these three wires.
  Power the target board normally and share only **GND**. If you deliberately
  want the probe to power a small target, run a separate 3V3/VSYS wire — it is
  **not** part of the SWD connection above.

```
   RP2350 probe                         target MCU (SWD)
  ┌──────────────┐                     ┌──────────────┐
  │ GP2  SWCLK ──┼─────────────────────┼─ SWCLK       │
  │ GP3  SWDIO ──┼─────────────────────┼─ SWDIO       │
  │ GND        ──┼─────────────────────┼─ GND         │
  │ GP4  TX   ··········(optional)·····┼─ RX          │
  │ GP5  RX   ··········(optional)·····┼─ TX          │
  └──────┬───────┘                     └──────────────┘
      USB│ to host  → appears as CMSIS-DAP probe + serial
```

## 3. Remote firmware load / debug (forwarded GDB server)

Run a pyOCD GDB server over the probe on the **host** (where the probe is
plugged in) and expose it so a remote — a dev container, or another machine —
can flash and debug over the network:

```sh
# on the host (the probe's machine):
tools/gdbserver.sh --target gd32e230k8          # GD32E230 (Rd-03E host MCU)
# or: tools/gdbserver.sh --target stm32g0b1xx --port 3333 --frequency 4000000
```

It adds `--allow-remote --persist` and prints the connect address. Then from the
remote, point `arm-none-eabi-gdb` at it:

```sh
arm-none-eabi-gdb path/to/firmware.elf -ex 'target remote <HOST-IP>:3333'
# (gdb) load                 # program flash from the ELF
# (gdb) monitor reset halt
# (gdb) continue
```

If the remote can't route to the host's LAN IP, tunnel instead (and drop
`--allow-remote` — localhost-only is safer):

```sh
ssh -N -L 3333:localhost:3333 <user>@<HOST-IP>
```

A pyOCD target outside its built-ins needs its CMSIS pack installed once:

```sh
bazel run @firmware//tools/pyocd -- pack install <target>   # find it: ... pack find gd32e230
```

> Security: `--allow-remote` opens the GDB port to any host that can reach it.
> On an untrusted network, prefer the SSH tunnel.

## What's in here

| Path | What |
|------|------|
| `MODULE.bazel` | reuses `@firmware` for hermetic picotool + pyOCD; `http_file`-pins the debugprobe UF2s |
| `BUILD.bazel` | `//:flash_probe` (RP2350) + `//:flash_probe_pico` (RP2040) via `@firmware`'s `picotool_flash`; `-- -f` reaches picotool's device selection |
| `tools/gdbserver.sh` | host-side pyOCD GDB server (`@firmware//tools/pyocd`) over the probe, exposed to a remote |

Firmware image: debugprobe **v2.3.1**, assets `debugprobe_on_pico2.uf2` /
`debugprobe_on_pico.uf2`. Bump the version + sha256 in `MODULE.bazel` to update.
