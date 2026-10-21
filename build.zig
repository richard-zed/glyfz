const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: pure Zig, no libc, no C, no allocator.
    const cedar_mod = b.addModule("cedar", .{
        .root_source_file = b.path("src/cedar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = cedar_mod });
    const test_step = b.step("test", "run the unit tests (no font file needed)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The differential oracle: stb_truetype compiled in alongside, never part
    // of what a consumer imports. Separate test binary, separate step.
    const oracle_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cedar", .module = cedar_mod }},
        .link_libc = true,
    });
    oracle_mod.addCSourceFile(.{ .file = b.path("oracle/stb_impl.c"), .flags = &.{} });
    oracle_mod.addIncludePath(b.path("oracle"));

    const oracle_tests = b.addTest(.{ .root_module = oracle_mod });
    const run_oracle = b.addRunArtifact(oracle_tests);
    run_oracle.has_side_effects = true;
    if (b.option([]const u8, "font", "path to a TTF/OTF for the oracle run")) |f| {
        run_oracle.setEnvironmentVariable("CEDAR_TEST_FONT", f);
    }

    const oracle_step = b.step("oracle", "differential against stb_truetype (-Dfont=path, or CEDAR_TEST_FONT)");
    oracle_step.dependOn(&run_oracle.step);
}
