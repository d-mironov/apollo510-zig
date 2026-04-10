# Apollo510 HAL Development Roadmap

This document is the definitive guide for building a full Zig HAL for the Ambiq Apollo510 SoC from scratch. Phases are ordered by hardware dependency, not complexity. Nothing here is arbitrary.

**Target audience**: Experienced embedded developer new to Apollo510 specifics.
**Pace**: 5-10 hours/week (evenings and weekends).
**Strategy**: You own architecture, errata handling, and hardware verification. AI generates register access wrappers, polling loops, and boilerplate. You review and test.

---

## How to Use This Roadmap

Work phase by phase. Don't skip ahead. Each phase unblocks the next at the hardware level, not just logically. Before touching any peripheral:

1. **Think**: study the relevant registers in the SVD, cross-reference the datasheet section, note any errata
2. **Implement**: write the HAL module (AI handles regz wrapper boilerplate, you handle architecture)
3. **Test**: verify on hardware with specific signals/measurements called out below

At 5-10 hours/week, a full HAL through Phase 5 is roughly a 12-month project. Phase 6 (GPU/Display) is open-ended.

---

## HAL Architecture Principles

These rules apply everywhere. They're recorded here so they don't get rediscovered phase by phase.

### Peripheral power gate pattern

Every non-always-on peripheral requires this sequence before any register access:

```
pwrctrl.enable(periph)   // set PWRCTRL.DEVPWREN bit
poll DEVPWRSTATUS         // wait for acknowledgement (offset 0x08)
configure GPIO PINCFG     // set pad function via FNCSEL
configure peripheral      // set clock source, mode, etc.
```

**Always-on (no PWRCTRL step required)**: CLKGEN, RSTGEN, MCUCTRL, PWRCTRL, GPIO, STIMER, WDT, RTC, TIMER.

Skipping the power gate step will produce silent failures or wrong reads. There's no error flag.

### Clock settle rule

After enabling any clock source, wait at least **30 microseconds** before using clock-dependent logic. This applies to HFRC, HFRC2, XTAL, and LFRC.

### IOM vs MSPI: never confuse these

These are **entirely separate peripherals** with different purposes, different register maps, and different base addresses.

| Peripheral | Base range | Purpose | Max speed | Instances |
|---|---|---|---|---|
| IOM | 0x40050000-0x40057000 | I2C/SPI for sensors, general use | 48 MHz SPI | 8 |
| MSPI | 0x40060000-0x40063000 | Multi-bit SPI for memory and display | 250 MT/s DDR | 4 |

IOM is what you think of as "normal" SPI and I2C. MSPI is a separate, high-bandwidth bus specifically for PSRAM, QSPI flash, and display interfaces. Connecting a sensor to MSPI is wrong. Using IOM for a framebuffer is wrong.

### No standalone DMA peripheral

The APBDMA is a bus fabric arbiter, not a configurable DMA controller. DMA is configured through per-peripheral registers. MSPI has its own AXI DMA. Other peripherals use the APBDMA fabric by writing to their own DMACFG, DMATOTCOUNT, and DMAADDR registers.

### Zig conventions

- All MMIO via microzig regz types. No raw `@intToPtr`, no volatile casting.
- Baud rates and PWM frequencies: use comptime where possible. Catch errors at compile time.
- Error handling: Zig error sets only. No errno-style integers.
- Enums for all multi-value fields (clock source, pin function, drive strength).

### Clock tree summary

| Source | Frequency | Mode |
|---|---|---|
| LFRC | ~900 Hz | Always available |
| XTAL | 32.768 kHz | Low-power RTC |
| HFRC | 96 MHz | LP mode (default) |
| HFRC2 | up to 250 MHz | HP mode (via SYSPLL) |

---

## Phase 0: Foundation (Reset, Clocks, Power)

**Estimated time**: 3-4 weeks

### Objective

Get the chip into a known state: valid clocks, all power domains accessible, a working microsecond timer. Everything that comes after depends on this phase being solid.

### Why this order

PWRCTRL must gate-enable every non-always-on peripheral before any configuration register can be written. CLKGEN must stabilize before clock-dependent peripherals are touched. STIMER gives you `delay_us()` which every subsequent phase will use during bring-up.

CLKGEN, RSTGEN, MCUCTRL, and PWRCTRL are always-on, so they can be configured immediately after reset without any DEVPWREN step.

### Key registers

- `CLKGEN.CLOCKEN`: enable/disable individual clock outputs
- `CLKGEN.HFRCCTRL`: HFRC fine trim
- `CLKGEN.HFRC2CTRL`: HFRC2 enable and configuration
- `PWRCTRL.DEVPWREN` (offset 0x04): power enable bitmask for all gated peripherals
- `PWRCTRL.DEVPWRSTATUS` (offset 0x08): power status, must be polled after enabling
- `STIMER.STCFG` / `STIMER.STCFGB`: system timer configuration
- `STIMER.STTMR`: 32-bit free-running counter read
- `RSTGEN.STAT`: reset cause flags
- `RSTGEN.CFG`: soft reset trigger

### Tasks

1. **`clkgen.zig`**: HFRC enable with 30 µs settle, HFRC2 enable for HP mode with pre-enable guard (see ERR024). Export `switchToHp()` and `switchToLp()`.
2. **`pwrctrl.zig`**: `enable(peripheral)` function that sets the correct DEVPWREN bit and polls DEVPWRSTATUS until acknowledged. Export a typed enum of peripheral names that maps to DEVPWREN bit positions.
3. **`stimer.zig`**: 32-bit free-running counter clocked at HFRC/16. Implement `delay_us(n: u32)` and `uptime_ms() u32`. Both use STTMR directly.
4. **`rstgen.zig`**: Read and return reset cause as an enum (POR, BOR, WDT, soft, etc.). Add `softReset()` that writes the trigger bit.

### Think loop

Before starting: read through CLKGEN's register map. Understand which CLOCKEN bits correspond to which internal enables. Map every DEVPWREN bit to a peripheral name from the SVD. Study STIMER's CFGB register for the COMPARE/FREEZE bits. Look up the HFRC2 startup sequence in the datasheet.

**AI generates**: Register access wrappers, polling loops with optional timeout, typed enums for clock sources and reset causes.

**You verify**: Read reset cause correctly after power-on vs after debug reset. STIMER counter is incrementing at the expected rate (oscilloscope or ITM). `delay_us(1000)` produces ~1 ms by logic analyzer.

### Apollo510-specific errata

**ERR024**: HFRC2 must already be running before calling `clkgen.switchToHp()`. If HFRC2 isn't running when you switch the PLL source, you'll get a glitched clock. Add a comptime or runtime assert in `switchToHp()` that checks HFRC2 status before proceeding.

**ERR029**: Back-to-back writes to STCFG require a minimum of 2 HFRC cycles between them. If you're reconfiguring STIMER in a tight loop (e.g., during timer restart), insert a 2-cycle NOP barrier. Failure mode is silent misconfiguration.

---

## Phase 1: GPIO

**Estimated time**: 2-3 weeks

### Objective

Type-safe pad configuration for all 128 GPIO pads, with interrupt support. Every peripheral that follows requires this.

### Why this order

GPIO is always-on (no PWRCTRL gate needed), but PINCFG must be written correctly before any peripheral is enabled on that pad. A UART that starts before its TX/RX pads are muxed will transmit garbage. Getting GPIO right first means you'll never have to debug "is this a GPIO problem or a peripheral problem."

### Key registers

- `GPIO.PINCFG0` through `GPIO.PINCFG127`: per-pad config (FNCSEL 4-bit mux, OUTCFG, DS, PULLUP, PULLDOWN, IESEL)
- `GPIO.WTS0` / `GPIO.WTS1`: write-to-set (set output high)
- `GPIO.WTC0` / `GPIO.WTC1`: write-to-clear (set output low)
- `GPIO.RD0` / `GPIO.RD1`: input read
- `GPIO.INTSET` / `GPIO.INTCLR` / `GPIO.INTSTAT` / `GPIO.INTEN`: interrupt control (one set per GPIO bank)
- `FPIO` base 0x40011000: fast GPIO, separate peripheral

### Tasks

1. **`gpio.zig`**: `configure(pad: Pad, cfg: PinConfig)` where `PinConfig` is a struct with `func`, `dir`, `drive`, `pull`. Map fields to PINCFG register bits. Use typed enums for each field.
2. **Output helpers**: `set(pad)`, `clear(pad)`, `toggle(pad)` via WTS/WTC. `read(pad) bool` via RD registers.
3. **Interrupt support**: `enableInterrupt(pad, edge: Edge)` and `clearInterrupt(pad)`. Wire to INTSET/INTCLR/INTEN. Add interrupt handler scaffolding that dispatches per-pad callbacks.
4. **`pinmux.zig`**: Named constants for all alternate functions. E.g., `Pad10.uart0_tx`, `Pad11.uart0_rx`, `Pad4.iom0_sda`. Generated from SVD FNCSEL values, not hand-written.

### Think loop

Before starting: read all 128 PINCFG register field definitions. The FNCSEL field is 4 bits (16 possible functions per pad). Not every pad supports every function. Map the useful ones to named constants in `pinmux.zig`. Study IESEL for input enable vs schmitt trigger options.

**AI generates**: PINCFG accessor helpers with field unions, interrupt handler dispatch table, pad name enum from SVD.

**You verify**: LED on/off with `set()`/`clear()`. Button interrupt fires on falling edge. Pin configured for IOM shows correct alternate function on oscilloscope before IOM is enabled.

### Apollo510-specific notes

Fast GPIO (FPIO) at base address 0x40011000 uses a different register layout than the main GPIO block. Keep it as a separate module (`fpio.zig`). Don't mix FPIO and GPIO register accesses in the same function.

No major errata for GPIO in the known list, but PINCFG default state after reset is input with no pull. Don't rely on pull resistors being enabled unless you set them explicitly.

---

## Phase 2: Core Communication and Timing

**Estimated time**: 3-4 weeks

### Objective

UART for `printf`-style debugging, hardware timers for PWM, watchdog for production hardening, RTC for wall-clock time.

### Why this order

UART comes before any other complex peripheral because it's your debug window into everything that follows. Without serial output, debugging Phase 3 and beyond is pain. WDT and RTC are simple but production-critical; doing them now while the chip is relatively clean makes them easier to verify.

### Key registers

- `UART0.CFG`: baud rate, parity, stop bits
- `UART0.FIFO`: FIFO level config
- `UART0.STATUS`: TX/RX empty flags
- `CTIMER.CTRL0` / `CTIMER.CTRL1`: timer A/B mode and clock source
- `CTIMER.CMPRAUXA0` etc.: compare match values for PWM
- `WDT.CFG`: timeout config
- `WDT.RSTRT`: feed/pet register
- `RTC.RTCTIME`: time in BCD
- `RTC.ALMTIME`: alarm match value
- `RTC.INTEN` / `RTC.INTSTAT`: alarm interrupt

### Tasks

1. **`uart.zig`**: Polling TX/RX, 8N1 framing, baud rate derived from CLKGEN. Implement `writeByte()`, `readByte()`, and a `Writer` compatible with `std.io`.
2. **UART FIFO + interrupts**: Add FIFO depth config, interrupt-driven RX with a ring buffer, non-blocking write path.
3. **`timer.zig`**: CTIMER in compare-match mode for one-shot and periodic callbacks. CTIMER in PWM output mode. `pwmSetDuty(timer, channel, duty_percent)` where frequency is comptime.
4. **`wdt.zig`**: Enable watchdog, configure timeout period, `pet()` function. Add `disable()` for debug builds only.
5. **`rtc.zig`**: Read and write BCD time fields. Configure alarm interrupt. `getTime()` returns a struct with year/month/day/hour/min/sec.

### Think loop

Before starting: study the UART CLKSEL and baud divider formula (baud = clock / (divider + 1) / 16, roughly). Understand CTIMER CTRL0/CTRL1: paired 32-bit mode vs two independent 16-bit timers. The PWM mode requires understanding compare A (period) vs compare B (duty). For WDT, check what happens if `pet()` is called from an ISR vs the main loop.

**AI generates**: Baud rate calculation with comptime verification, FIFO drain loops, CTIMER PWM config wrapper, BCD encode/decode for RTC.

**You verify**: `printf` output visible in serial terminal at correct baud. PWM waveform on oscilloscope at expected frequency and duty cycle. WDT reset fires after expected timeout without pet. RTC time reads correctly after a power cycle with XTAL backup.

---

## Phase 3: High-Speed Memory Interface (MSPI)

**Estimated time**: 3-4 weeks

### Objective

MSPI for external QSPI flash and PSRAM. This is the prerequisite for display framebuffers, large asset storage, and any XIP execution from external flash.

### Why before IOM

MSPI is not a faster version of IOM. They are completely different peripherals for completely different purposes. MSPI is done before IOM because framebuffer PSRAM (needed for Phase 6 GPU/display) must be working before the display pipeline. IOM sensors don't block anything; MSPI memory does.

MSPI strictly requires HFRC above 48 MHz (ERR016), so Phase 0's clock setup is a hard prerequisite.

### Key registers

- `MSPI0.MSPICFG`: IO mode (1/2/4/8-bit), DDR enable, turnaround clocks, device config
- `MSPI0.FLASH`: CE config, device size, XIP enable
- `MSPI0.CQCFG` / `MSPI0.CQADDR`: command queue for DMA
- `MSPI0.DMACFG`: DMA enable and mode
- `MSPI0.DMATOTCOUNT`: total byte count for DMA transfer
- `MSPI0.DMADEVADDR` / `MSPI0.DMATARGADDR`: device and memory addresses
- `MSPI0.INTEN` / `MSPI0.INTSTAT`: DMA completion interrupt

### Tasks

1. **`mspi.zig`**: Core init function. Configure CE, clock divider, IO mode (1/2/4/8-bit SDR or DDR). Expose `transfer(cmd, addr, buf)` for blocking PIO transfers.
2. **XIP mode**: Configure `MSPI0.FLASH` for memory-mapped execution. Add `enableXip()` and `disableXip()`. Test with a simple function placed in XIP-mapped flash.
3. **DMA transfers**: Set up DMACFG, DMATOTCOUNT, DMADEVADDR, DMATARGADDR. Non-blocking read/write with completion callback or polling. Handle the 64-byte boundary constraint (ERR018).
4. **`mspi_flash.zig`**: Wrapper for common QSPI flash commands (JEDEC ID read, sector erase, page program, status poll). Supports Winbond W25Q and compatible.
5. **`mspi_psram.zig`**: Wrapper for HyperRAM/QSPI PSRAM (e.g., APS6404). Init sequence, read/write transactions, DMA bulk transfer.

### Think loop

Before starting: read the MSPI MSPICFG register in full. The IOMTYPE field selects 1/2/4/8-bit mode. The TURNAROUND field is critical for PSRAM latency. Understand the MSPI DMA address alignment rule before writing any DMA code. Study the XIP enable sequence from the datasheet.

**AI generates**: SPI command sequences for W25Q flash and APS6404 PSRAM, DMA descriptor setup, alignment check wrapper.

**You verify**: Flash JEDEC ID returned correctly over MSPI. Erase/program/read cycle on a sector. PSRAM read-after-write matches. A function compiled to XIP runs correctly.

### Apollo510-specific errata

**ERR016**: MSPI clock frequency must be greater than 48 MHz. Add a comptime assert in `mspi.init()`:

```zig
comptime {
    if (config.clock_hz <= 48_000_000) @compileError("MSPI clock must exceed 48 MHz (ERR016)");
}
```

**ERR018**: MSPI DMA transfers must not cross 64-byte memory boundaries. Add a runtime assertion in the DMA setup path:

```zig
const end_addr = target_addr + byte_count;
assert((target_addr >> 6) == ((end_addr - 1) >> 6), "MSPI DMA crosses 64-byte boundary (ERR018)");
```

Split transfers that would cross this boundary into two separate DMA requests.

---

## Phase 4: Analog and Sensor Buses

**Estimated time**: 3-4 weeks

### Objective

IOM for I2C and SPI sensor communication, ADC for analog inputs, voltage comparator for threshold detection.

### Why IOM is in Phase 4 (not Phase 3)

IOM is the general-purpose sensor bus. It's in Phase 4 because it depends on Phase 1 (GPIO pin muxing) and Phase 0 (PWRCTRL enable). It could technically be Phase 3, but MSPI/memory is a harder dependency for display work. If your project has no display and lots of sensors, swap Phase 3 and Phase 4.

Do not confuse IOM and MSPI. IOM handles sensors, RTC chips, display controllers over SPI, anything using standard protocol. MSPI handles memory and raw high-bandwidth display interfaces.

### Key registers

- `IOM0.MSPICFG` / `IOM0.I2CCFG`: select mode (SPI or I2C) and configure
- `IOM0.CLKCFG`: clock divider for SPI frequency or I2C rate
- `IOM0.CMD`: write command with byte count to start a transaction
- `IOM0.FIFO` / `IOM0.FIFOPUSH` / `IOM0.FIFOPOP`: data FIFO
- `IOM0.DMATARGADDR` / `IOM0.DMACFG` / `IOM0.DMATOTCOUNT`: DMA for IOM
- `ADC.CFG`: clock source, power mode, trigger
- `ADC.SL0CFG` through `ADC.SL7CFG`: slot configuration (channel, gain, precision)
- `ADC.FIFO` / `ADC.FIFOREAD`: result FIFO
- `ADC.DMACFG` / `ADC.DMATOTCOUNT` / `ADC.DMATARGADDR`: ADC DMA
- `VCOMP.CFG`: reference and input selection
- `VCOMP.INTEN` / `VCOMP.INTSTAT`: threshold interrupt

### Tasks

1. **`iom.zig`**: I2C master mode at 100 kHz and 400 kHz. `write(addr, data)`, `read(addr, len)`, `writeRead(addr, reg, len)`. Error return on NACK.
2. **IOM SPI mode**: SPI master up to 48 MHz. `transfer(cs, tx_buf, rx_buf)`. CS controlled via GPIO.
3. **IOM DMA**: Add DMA-backed transfer path for larger transactions. Wire APBDMA through per-IOM registers.
4. **`adc.zig`**: Configure up to 8 slots, each with independent channel and gain. `readBlocking(slot)` returns raw count. `readDma(slots, buf, callback)` for continuous sampling.
5. **`vcomp.zig`**: Set reference voltage and input, enable interrupt, fire callback when threshold crossed.

### Think loop

Before starting: study IOM CMD register carefully. The byte count and direction bits in CMD control the transaction length. A common mistake is writing CMD before loading FIFO (SPI write) or after (SPI read). Read both IOM and I2CCFG carefully to understand which CLKCFG divider to use for each mode. For ADC: understand slot enable vs slot trigger order. The battery load resistor quirk mentioned in the datasheet notes means the internal battery channel has a specific settling time requirement.

**AI generates**: I2C transaction state machine, SPI transfer with per-transaction CS control, ADC slot configuration helper, DMA chain setup.

**You verify**: I2C scan finds known device at expected address. SPI loopback test (MISO tied to MOSI) returns what was sent. ADC reading of VDD/2 reference matches expected counts. VCOMP interrupt fires when threshold crossed.

---

## Phase 5: Storage and Advanced Interfaces

**Estimated time**: 4-5 weeks

### Objective

USB device, SD card storage, and IO Slave mode for when Apollo510 acts as a peripheral to another host.

### Why last in Phase 5

USB requires careful power sequencing (ERR046) and external regulator rails that may not be on your breakout board. SDIO is straightforward but less universally needed. IOS (IO Slave) is situational. These are done last because they have no downstream dependencies in this roadmap and each requires dedicated hardware validation.

### Key registers

**USB**:
- `USB.CFG`: FS device enable, PHY config
- `USBPHY.CTRL`: PHY power-on sequence
- `USB.IE` / `USB.IS`: endpoint interrupt enable/status
- `USB.EP0CS` through EP-specific CS registers: control and status per endpoint

**SDIO**:
- `SDIO.CTRL1`: clock enable, bus width
- `SDIO.BLKCNT` / `SDIO.BLKSIZE`: transfer config
- `SDIO.CMDARG` / `SDIO.CMD`: command issue
- `SDIO.RESP0` through `SDIO.RESP3`: response registers

**IOS**:
- `IOS.CFG`: SPI or I2C slave mode select
- `IOS.FIFOCFG` / `IOS.FIFOPTR`: FIFO configuration and pointer
- `IOS.IOINTCTL` / `IOS.IOINTSTAT`: interrupt-to-host signalling

### Tasks

1. **`usb.zig`**: USB FS device mode. PHY init sequence (VDDUSB0P9 first, then VDDUSB33, see ERR046). Control endpoint 0 handler. USB descriptor tables for device and configuration.
2. **USB CDC-ACM**: Virtual serial port class. Implement bulk endpoints, CDC management interface, `LineCoding` request handling. Produces a `/dev/ttyACMx` on the host.
3. **`sdio.zig`**: SD card initialization sequence (ACMD41, CMD2, CMD3, CMD7). Block read and write. Support SDHS cards. DMA-backed transfers.
4. **`ios.zig`**: IOS in SPI slave mode. FIFO-based data exchange with host. Interrupt-to-host signal via IOINTCTL.

### Think loop

Before starting: read the USB PHY initialization section of the datasheet thoroughly. The USBPHY register sequence is specific and order-dependent. For SDIO, study the SD physical specification's initialization flow (it's not fully in the Apollo510 datasheet). For IOS, understand the two FIFO modes (direct vs indirect access).

**AI generates**: USB descriptor tables (device, configuration, interface, endpoint), CDC-ACM class request handler, SD card CSD/CID parsing, IOS FIFO state machine.

**You verify**: USB device enumerates on host PC (shows in `lsusb` or Device Manager). CDC-ACM virtual port appears and accepts characters. SD card FAT volume mounts via a third-party library. IOS receives data from a host SPI master.

### Apollo510-specific errata

**ERR046**: USB PHY power sequencing is safety-critical. VDDUSB33 must never be enabled without VDDUSB0P9 already active. Enabling VDDUSB33 alone draws approximately 34 mA through the PHY and can cause permanent hardware damage.

Add a sequencing assertion in `usb.init()`:

```zig
// Check VDDUSB0P9 is already on before enabling VDDUSB33
assert(pwrctrl.isOn(.vddusb0p9), "Must enable VDDUSB0P9 before VDDUSB33 (ERR046)");
pwrctrl.enable(.vddusb33);
```

This is not just a software bug. On a custom PCB with no current limiting, ERR046 can destroy the PHY. Add a comment in the hardware design notes to ensure the 0.9V rail is populated.

---

## Phase 6: Audio and Display

**Estimated time**: 6+ weeks (open-ended)

### Objective

PDM microphone input, I2S audio streaming, the NemaGFX GPU pipeline, and MIPI DSI display output.

### Why last

These are the highest-complexity subsystems in the chip, most hardware-dependent, and they depend on nearly everything that came before. The GPU and display controller require framebuffer PSRAM (Phase 3), GPIO (Phase 1), and power sequencing (Phase 0). Audio works standalone but is lower priority for a sensor/compute breakout.

This phase is explicitly open-ended. The NemaGFX command list format and DC layer blending engine are complex enough that even a well-specified implementation will take many sessions. Treat this as ongoing work, not a fixed deliverable.

### Key registers

**PDM**:
- `PDM0.CFG0` / `PDM0.CFG1`: decimation ratio, gain, sample rate
- `PDM0.FIFOCNT` / `PDM0.FIFOREAD`: sample FIFO
- `PDM0.DMACFG` / `PDM0.DMATOTCOUNT` / `PDM0.DMATARGADDR`: DMA

**I2S**:
- `I2S0.I2SCFG`: master/slave, bit clock polarity, word size
- `I2S0.TXULVL` / `I2S0.RXULVL`: FIFO thresholds
- `I2S0.AMQCFG`: audio master queue for DMA

**AUDADC**:
- `AUDADC.CFG`: clock, gain, power
- `AUDADC.SL0CFG` through `AUDADC.SL7CFG`: slot configuration
- `AUDADC.GAINCFG` / `AUDADC.GAIN`: PGA gain registers

**GPU (NemaGFX)**:
- `GPU.CLID`: command list ID
- `GPU.CLBASE` / `GPU.CLSIZE`: command list buffer address and size
- `GPU.STATUS` / `GPU.INTEN`: completion and error status

**DC (Display Controller)**:
- `DC.LAYER0CFG` through `DC.LAYER3CFG`: layer blend config
- `DC.RESXY`: output resolution
- `DC.STARTXY` / `DC.SIZEXY`: layer position and size
- `DC.FORMAT`: pixel format

**DSI**:
- `DSI.CFG`: lane count, HS/LP mode
- `DSI.TIMING0` / `DSI.TIMING1`: DSI timing parameters

### Tasks

1. **`pdm.zig`**: PDM microphone input. Configure decimation filter and sample rate. DMA-backed FIFO readout into a ring buffer. Export `startCapture(buf, callback)`.
2. **`i2s.zig`**: I2S master and slave modes. Stereo 16-bit and 24-bit. DMA audio stream with double-buffering. `play(buf, len)` and `record(buf, len)`.
3. **`audadc.zig`**: Audio ADC with PGA gain control. Slot configuration for differential input. DMA readout.
4. **`gpu.zig` (scaffold)**: NemaGFX command list builder. Allocate a command list buffer, append draw commands, submit via `GPU.CLBASE`/`GPU.CLSIZE`. This is AI-heavy: the command list format is documented in the NemaGFX SDK, not the SoC datasheet.
5. **`display.zig` (scaffold)**: DC layer config for a single framebuffer layer. MIPI DSI output with timing parameters for a specific panel. `blit(framebuffer)` submits a frame.

### Think loop

Before starting audio: read PDM0.CFG0 decimation ratio fields carefully. The relationship between PDM clock, decimation ratio, and output sample rate is not obvious. For I2S, understand the AMQCFG audio master queue mode vs simple FIFO mode.

Before starting GPU/display: read the NemaGFX Programming Guide (separate from the Apollo510 datasheet). The command list format is a GPU-specific binary protocol. Understand DC layer blending registers before writing a line of display driver code.

**AI generates**: NemaGFX command list builder and draw primitive encoding, DSI timing parameter tables for common panels (720p, 1080p), I2S DMA ring buffer with underrun protection.

**You verify**: PDM audio captured to memory and decoded via offline tool. I2S playback audible on connected DAC/speaker. GPU renders a test pattern to PSRAM framebuffer. Display shows framebuffer content.

---

## Dependency Graph

```
Phase 0 (CLKGEN, PWRCTRL, STIMER)
    |
    +-- Phase 1 (GPIO)
            |
            +-- Phase 2 (UART, TIMER, WDT, RTC)
            |       |
            |       +-- Phase 3 (MSPI)
            |       |       |
            |       |       +-- Phase 6 (GPU, Display)
            |       |
            |       +-- Phase 4 (IOM, ADC, VCOMP)
            |
            +-- Phase 5 (USB, SDIO, IOS)
```

Phase 3 and Phase 4 can proceed in parallel after Phase 2. Phase 5 is independent of 3 and 4. Phase 6 requires Phase 3 for PSRAM framebuffer.

---

## Errata Quick Reference

| ID | Peripheral | Impact | Mitigation |
|---|---|---|---|
| ERR016 | MSPI | Clock must exceed 48 MHz | Comptime assert in `mspi.init()` |
| ERR018 | MSPI DMA | Transfers must not cross 64-byte boundaries | Runtime alignment check, split transfers |
| ERR024 | CLKGEN | HFRC2 must be pre-enabled before LP to HP switch | Assert HFRC2 running before `switchToHp()` |
| ERR029 | STIMER | Minimum 2 HFRC cycles between back-to-back STCFG writes | Insert NOP barrier in STIMER reconfiguration |
| ERR046 | USB PHY | VDDUSB33 without VDDUSB0P9 draws 34 mA, hardware damage risk | Assert 0.9V rail active before enabling 3.3V rail |

---

## Time Summary

| Phase | Peripherals | Estimated weeks |
|---|---|---|
| 0 | CLKGEN, PWRCTRL, STIMER, RSTGEN | 3-4 |
| 1 | GPIO (128 pads), FPIO | 2-3 |
| 2 | UART0-3, CTIMER, WDT, RTC | 3-4 |
| 3 | MSPI0-3, XIP, DMA | 3-4 |
| 4 | IOM0-7 (I2C+SPI), ADC, VCOMP | 3-4 |
| 5 | USB FS, SDIO, IOS | 4-5 |
| 6 | PDM, I2S, AUDADC, GPU, DC, DSI | 6+ |
| **Total** | | **~24-28 weeks (6-7 months)** |

At 5-10 hours/week, realistic calendar time is 12-18 months for Phases 0-5. Phase 6 is genuinely open-ended.
