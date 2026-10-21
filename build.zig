const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Read once: b.option panics if the same name is declared twice.
    const font_opt = b.option([]const u8, "font", "path to a TTF/OTF for the oracle and bench runs");

    // The library: pure Zig, no libc, no C, no allocator.
    const glyfz_mod = b.addModule("glyfz", .{
        .root_source_file = b.path("src/glyfz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = glyfz_mod });
    const test_step = b.step("test", "run the unit tests (no font file needed)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The differential oracle: stb_truetype compiled in alongside, never part
    // of what a consumer imports. Separate test binary, separate step.
    const oracle_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glyfz", .module = glyfz_mod }},
        .link_libc = true,
    });
    oracle_mod.addCSourceFile(.{ .file = b.path("oracle/stb_impl.c"), .flags = &.{} });
    oracle_mod.addIncludePath(b.path("oracle"));

    const oracle_tests = b.addTest(.{ .root_module = oracle_mod });
    const run_oracle = b.addRunArtifact(oracle_tests);
    run_oracle.has_side_effects = true;
    if (font_opt) |f| {
        run_oracle.setEnvironmentVariable("GLYFZ_TEST_FONT", f);
    }

    // Malformed input: truncate and flip bits, on a real face. Separate test
    // binary so the ordinary suite stays fast, and skipped when no font is
    // configured rather than silently passing.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glyfz", .module = glyfz_mod }},
        .link_libc = true,
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    run_fuzz.has_side_effects = true;
    if (font_opt) |f| {
        run_fuzz.setEnvironmentVariable("GLYFZ_TEST_FONT", f);
    }

    // Timing harness. stb is compiled in as the baseline, exactly as the
    // oracle does -- it is never part of what a consumer imports.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glyfz", .module = glyfz_mod }},
        .link_libc = true,
    });
    bench_mod.addCSourceFile(.{ .file = b.path("oracle/stb_impl.c"), .flags = &.{} });
    bench_mod.addIncludePath(b.path("oracle"));
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true;
    if (font_opt) |f| {
        run_bench.setEnvironmentVariable("GLYFZ_BENCH_FONT", f);
    }
    const bench_step = b.step("bench", "time glyfz against stb_truetype (-Dfont=path)");
    bench_step.dependOn(&run_bench.step);

    const fuzz_step = b.step("fuzz", "mangle the face under -Dfont (or GLYFZ_TEST_FONT): truncations and bit flips");
    fuzz_step.dependOn(&run_fuzz.step);

    const oracle_step = b.step("oracle", "differential against stb_truetype (-Dfont=path, or GLYFZ_TEST_FONT)");
    oracle_step.dependOn(&run_oracle.step);
}
