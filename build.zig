const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Read once: b.option panics if the same name is declared twice.
    const font_opt = b.option([]const u8, "font", "path to a TTF/OTF for the bench and fuzz runs");

    // The library: pure Zig, no libc, no C, no allocator.
    const glyfz_mod = b.addModule("glyfz", .{
        .root_source_file = b.path("src/glyfz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = glyfz_mod });
    const test_step = b.step("test", "run the unit tests (no font file needed)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

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

    // Timing harness. Pure Zig, like the library itself.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glyfz", .module = glyfz_mod }},
        .link_libc = true,
    });
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true;
    if (font_opt) |f| {
        run_bench.setEnvironmentVariable("GLYFZ_BENCH_FONT", f);
    }
    const bench_step = b.step("bench", "time glyph rasterisation and cache hits (-Dfont=path)");
    bench_step.dependOn(&run_bench.step);

    const fuzz_step = b.step("fuzz", "mangle the face under -Dfont (or GLYFZ_TEST_FONT): truncations and bit flips");
    fuzz_step.dependOn(&run_fuzz.step);
}
