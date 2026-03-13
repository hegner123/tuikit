const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the tuikit MCP server / CLI");
    const test_step = b.step("test", "Run all unit tests");

    // -- Library module --
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -- Executable module --
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add ghostty-vt dependency to both modules.
    if (b.lazyDependency("ghostty", .{})) |dep| {
        const ghostty_mod = dep.module("ghostty-vt");
        lib_mod.addImport("ghostty-vt", ghostty_mod);
        exe_mod.addImport("ghostty-vt", ghostty_mod);
    } else {
        @panic("ghostty dependency not found — check build.zig.zon and run 'zig build --fetch'");
    }

    // -- Executable --
    const exe = b.addExecutable(.{
        .name = "tuikit",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // -- Install to /usr/local/bin + ad-hoc codesign --
    const install_step = b.step("install-bin", "Copy tuikit to /usr/local/bin and codesign");
    const install_cmd = b.addSystemCommand(&.{
        "/bin/cp",
        "-f",
    });
    install_cmd.addArtifactArg(exe);
    install_cmd.addArg("/usr/local/bin/tuikit");
    const codesign_cmd = b.addSystemCommand(&.{
        "codesign",
        "-s",
        "-",
        "/usr/local/bin/tuikit",
    });
    codesign_cmd.step.dependOn(&install_cmd.step);
    install_step.dependOn(&codesign_cmd.step);

    // -- Run --
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // -- Library tests --
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // -- Executable tests --
    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
