const microzig = @import("microzig");

// Apollo510 GPIO Initialization Sequence:
// 1. Write PWRCTRL.DEVPWREN to enable power (e.g. IO Slave 0 since there's no GPIO bit)
// 2. Poll PWRCTRL.DEVPWRSTATUS until the bit is acknowledged
// 3. Configure GPIO.PINCFG10 - FNCSEL=GPIO (which is 3), OUTCFG=PUSHPULL (1)
// 4. Set GPIO.ENC0 (which covers pins 0-31) to enable the pin as output
// 5. Loop forever: set pin via GPIO.WTS0, delay, clear pin via GPIO.WTC0, delay

pub fn main() !void {
    const peripherals = microzig.chip.peripherals;

    // 1. Write PWRCTRL.DEVPWREN to enable power
    // GPIO is always-on on Apollo510, and DEVPWREN lacks a GPIO bit.
    // We power up IO Slave 0 here to follow the hardware power sequence pattern.
    peripherals.PWRCTRL.DEVPWREN.modify(.{ .PWRENIOS0 = .EN });

    // 2. Poll PWRCTRL.DEVPWRSTATUS until the bit is acknowledged
    while (peripherals.PWRCTRL.DEVPWRSTATUS.read().PWRSTIOS0 != .ON) {}

    // 3. Configure GPIO pad 10
    // FNCSEL10 = .GPIO (0x3 in SVD), OUTCFG10 = .PUSHPULL (0x1 in SVD)
    peripherals.GPIO.PINCFG10.modify(.{
        .FNCSEL10 = .GPIO,
        .OUTCFG10 = .PUSHPULL,
    });

    // 4. Enable pin 10 as output in ENC0 (covers pins 0-31)
    // Modify keeping other bits intact
    peripherals.GPIO.ENC0.modify(.{
        .ENC0 = peripherals.GPIO.ENC0.read().ENC0 | (1 << 10),
    });

    // 5. Loop forever
    while (true) {
        // Set pin 10 high via WTS0 (Write-To-Set)
        peripherals.GPIO.WTS0.modify(.{
            .WTS0 = (1 << 10),
        });

        // Delay
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            asm volatile ("nop");
        }

        // Clear pin 10 low via WTC0 (Write-To-Clear)
        peripherals.GPIO.WTC0.modify(.{
            .WTC0 = (1 << 10),
        });

        // Delay
        i = 0;
        while (i < 1_000_000) : (i += 1) {
            asm volatile ("nop");
        }
    }
}
