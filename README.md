# rp2350-swd-probe

Turn a bare **RP2350** board (Raspberry Pi Pico 2, or any RP2350 board) into a
**CMSIS-DAP SWD debug probe** by flashing Raspberry Pi's stock
[`debugprobe`](https://github.com/raspberrypi/debugprobe) firmware onto it over
USB — one `bazel run`.

Once flashed, the board is a standard CMSIS-DAP probe that pyOCD, OpenOCD and
`probe-rs` all speak to, plus a USB-serial port bridged to the target's UART.
This is the probe used to flash the STM32G0 in
[`fughilli/tentacle_lamp`](https://github.com/fughilli/tentacle_lamp) (via
`@firmware`'s pyOCD flash rule) and to drive SWD on the GD32E230 in the Rd-03E
radar RE work.

## Flash a fresh RP2350 as a probe

1. **Enter BOOTSEL:** hold the **BOOTSEL** button while plugging the RP2350 into
   USB. It mounts as a mass-storage device (`RP2350`/`RPI-RP2`).
2. **Flash:**

   ```sh
   bazel run //:flash_probe          # RP2350 / Pico 2   (debugprobe-v2.3.1)
   # or, for an original RP2040 Pico:
   bazel run //:flash_probe_pico
   ```

   `picotool load -x` writes the UF2 and reboots into it. The board
   re-enumerates as a CMSIS-DAP probe (plus a CDC serial). Done — no button
   dance needed again; it's a probe until you re-flash it.

> Run this on the machine the RP2350 is plugged into (USB is host-local). The
> firmware image is fetched, pinned by sha256, from the official debugprobe
> release — nothing is built from source.

## Wiring (debugprobe default pin map)

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
  Power the target board normally (its own USB/supply) and share only **GND**.
  If you deliberately want the probe to power a small target, run a separate
  3V3/VSYS wire — it is **not** part of the SWD connection above.

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

## Use it (pyOCD / probe-rs)

With the probe wired to a target, from a Bazel repo that reuses `@firmware`
(e.g. tentacle_lamp):

```sh
bazel run @firmware//tools/pyocd -- list          # enumerate probes; CMSIS-DAP shows up
bazel run //:flash_blink                           # pyocd_flash over the probe (per repo)
```

Or with probe-rs directly (the GD32/STM32 workflow):

```sh
probe-rs list                                      # CMSIS-DAP probe listed
probe-rs run --chip <CHIP> path/to/firmware.elf
```

## What's in here

| Path | What |
|------|------|
| `MODULE.bazel` | reuses `@firmware` for hermetic `picotool`; `http_file`-pins the debugprobe UF2s |
| `BUILD.bazel`  | `//:flash_probe` (RP2350) and `//:flash_probe_pico` (RP2040) via `picotool_flash` |

Firmware image: debugprobe **v2.3.1**, assets `debugprobe_on_pico2.uf2` /
`debugprobe_on_pico.uf2`. Bump the version + sha256 in `MODULE.bazel` to update.
