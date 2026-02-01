// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2025 Jonathan D.A. Jewell (@hyperpolymath)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build shared library
    const lib = b.addSharedLibrary(.{
        .name = "fbqldt",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link against proven library (Idris2 output)
    // TODO: Add proven library linking once it's built
    // lib.linkSystemLibrary("proven");

    // Export C symbols for FFI
    lib.linkLibC();

    b.installArtifact(lib);

    // Build tests
    const tests = b.addTest(.{
        .root_source_file = b.path("test/ffi_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.linkLibrary(lib);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    integration_tests.linkLibrary(lib);

    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("integration", "Run integration tests");
    integration_step.dependOn(&run_integration.step);
}
