const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const lib = b.addSharedLibrary(.{
        .name = "taufl1",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = .ReleaseSmall,
        .target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    });

    lib.import_memory = true;
    lib.initial_memory = 65536;
    lib.max_memory = 65536;
    lib.stack_size = 14752;

    // Export WASM-4 symbols
    lib.export_symbol_names = &[_][]const u8{ "start", "update" };

    b.installArtifact(lib);

    const dest = b.pathJoin(&.{ b.install_path, "lib", lib.out_filename });
    const compress = b.addSystemCommand(&.{"wasm-opt", "-Os", dest, "-o", dest});
    compress.step.dependOn(&lib.step);

    b.getInstallStep().dependOn(&compress.step);
}
