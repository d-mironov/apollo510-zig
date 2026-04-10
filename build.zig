const std = @import("std");
const microzig = @import("microzig");

// We don't use any built-in port — we define our own target.
const MicroBuild = microzig.MicroBuild(.{});

pub fn build(b: *std.Build) void {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const optimize = b.standardOptimizeOption(.{});

    // ── Apollo510 chip target ──────────────────────────────────
    // The Target struct requires two non-optional fields:
    //   .dep  = the *Build.Dependency that owns this target (microzig dep)
    //   .zig_target = the std.Target.Query for cross-compilation
    const apollo510_target: microzig.Target = .{
        // Required: the dependency that provides build tools (regz, linker script gen, etc.)
        .dep = mz_dep,

        // Required: Cortex-M55 with Helium MVE (float + integer)
        .zig_target = .{
            .cpu_arch = .thumb,
            .os_tag = .freestanding,
            .abi = .eabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m55 },
            .cpu_features_add = std.Target.arm.featureSet(&.{
                .mve,
                .mve_fp,
            }),
        },

        .chip = .{
            .name = "apollo510",
            .url = "https://ambiq.com/apollo510/",
            .register_definition = .{ .svd = b.path("svd/apollo510.svd") },
            .memory_regions = &.{
                // MRAM Bank 0 — application code (1.94 MB)
                .{ .tag = .flash, .offset = 0x00410000, .length = 0x005FFFFF - 0x00410000 + 1, .access = .rx },
                // MRAM Bank 1 — additional application space (2 MB)
                .{ .tag = .flash, .offset = 0x00600000, .length = 2 * 1024 * 1024, .access = .rx },
                // DTCM — fast tightly-coupled data memory (512 KB)
                .{ .tag = .ram, .offset = 0x20000000, .length = 512 * 1024, .access = .rwx },
                // System SRAM (3 MB, shared with DMA + GPU)
                .{ .tag = .ram, .offset = 0x20080000, .length = 3 * 1024 * 1024, .access = .rwx },
            },
        },

        .linker_script = .{
            .generate = .{ .memory_regions_and_sections = .{
                .rodata_location = .flash,
            } },
        },

        .preferred_binary_format = .elf,
    };

    // ── Example firmware: blinky ───────────────────────────────
    const blinky = mb.add_firmware(.{
        .name = "blinky",
        .target = &apollo510_target,
        .optimize = optimize,
        .root_source_file = b.path("examples/blinky.zig"),
    });

    mb.install_firmware(blinky, .{});
}
