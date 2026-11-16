const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zgit",
        .root_module = root,
    });
    b.installArtifact(exe);

    // zig build run -- <args>
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run zgit").dependOn(&run.step);

    // zig build test
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
