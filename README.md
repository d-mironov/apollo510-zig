# apollo510-microzig

**Zig/MicroZig chip support package for the Ambiq Apollo510 (Cortex-M55) SoC**

![Zig](https://img.shields.io/badge/zig-0.15.x-orange?logo=zig)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-alpha%2FWIP-yellow)

---

## Chip Overview

| | |
|---|---|
| **CPU** | ARM Cortex-M55 with Helium (MVE) SIMD + DSP extensions |
| **Flash** | 2 MB MRAM (execute-in-place, no code copy needed) |
| **RAM** | 2 MB TCM (ITCM+DTCM) + 6 MB SRAM |
| **Clock** | HFRC up to 96 MHz (LP mode); HFRC2 up to 250 MHz (HP mode via SYSPLL) |
| **I/O buses** | 8x IOM (I2C/SPI), 4x MSPI (multi-bit SPI up to 250 MT/s) |
| **Other peripherals** | 4x UART, USB FS, 14-channel ADC, GPU, Display Controller |
| **Power** | Ultra-low-power design; PWRCTRL gates all peripheral power domains |

---

## Memory Map

| Region | Base | Size |
|---|---|---|
| MRAM (Flash) | `0x00018000` | 2 MB |
| DTCM | `0x20000000` | 384 KB |
| SRAM | `0x20060000` | 6 MB |
| Peripherals | `0x40000000` | — |
| GPIO | `0x40010000` | — |
| PWRCTRL | `0x40021000` | — |
| UART0-3 | `0x4001C000+` | — |
| IOM0-7 | `0x40050000+` | — |
| MSPI0-3 | `0x40060000+` | — |

---

## Getting Started

### Prerequisites

- Zig 0.15.x
- No external toolchain needed — Zig is self-contained

### Build

```bash
git clone <repo>
cd apollo510-microzig
zig build
```

### Run blinky (on hardware)

```bash
zig build
# Flash zig-out/firmware/blinky.elf to your Apollo510 board
```

Minimal example showing direct register access via the generated peripheral structs:

```zig
const microzig = @import("microzig");

pub fn main() !void {
    const peripherals = microzig.chip.peripherals;

    // Enable IOS0 power domain (GPIO is always-on; no DEVPWREN bit for it)
    peripherals.PWRCTRL.DEVPWREN.modify(.{ .PWRENIOS0 = .EN });
    while (peripherals.PWRCTRL.DEVPWRSTATUS.read().PWRSTIOS0 != .ON) {}

    // Configure pad 10: GPIO function, push-pull output
    peripherals.GPIO.PINCFG10.modify(.{
        .FNCSEL10 = .GPIO,
        .OUTCFG10 = .PUSHPULL,
    });
    peripherals.GPIO.ENC0.modify(.{
        .ENC0 = peripherals.GPIO.ENC0.read().ENC0 | (1 << 10),
    });

    while (true) {
        peripherals.GPIO.WTS0.modify(.{ .WTS0 = (1 << 10) }); // set
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) asm volatile ("nop");

        peripherals.GPIO.WTC0.modify(.{ .WTC0 = (1 << 10) }); // clear
        i = 0;
        while (i < 1_000_000) : (i += 1) asm volatile ("nop");
    }
}
```

Full source: [`examples/blinky.zig`](examples/blinky.zig)

---

## Register Generation

All register definitions are generated at build time from [`svd/apollo510.svd`](svd/apollo510.svd) using `regz`. There is no committed `registers.zig`. After running `zig build`, the generated chip module appears at:

```
.zig-cache/.../chips/apollo510.zig
```

The 30 SVD peripherals are fully described with typed field enums. Access them through `microzig.chip.peripherals.<PERIPHERAL>.<REGISTER>.read()` / `.modify()` / `.write()`.

---

## Peripheral Support Status

| Peripheral | Status |
|---|---|
| Register definitions (all 30) | ✅ Generated via regz |
| GPIO | 🔲 HAL TODO (Phase 1) |
| UART | 🔲 HAL TODO (Phase 2) |
| Timers (STIMER/CTIMER) | 🔲 HAL TODO (Phase 2) |
| MSPI | 🔲 HAL TODO (Phase 3) |
| IOM (I2C/SPI) | 🔲 HAL TODO (Phase 4) |
| ADC | 🔲 HAL TODO (Phase 4) |
| USB | 🔲 HAL TODO (Phase 5) |
| GPU/Display | 🔲 HAL TODO (Phase 6) |

---

## Roadmap

HAL development proceeds in dependency order: always-on peripherals first, gated peripherals after. See [docs/roadmap.md](docs/roadmap.md) for the full phased HAL development roadmap, including hardware dependency ordering, time estimates, and Apollo510-specific architectural notes.

---

## Contributing

Contributions welcome via GitLab MR or GitHub PR. Please keep PRs focused; one feature or fix per request.

## License

MIT. See [LICENSE](LICENSE).
