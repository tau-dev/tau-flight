const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const lib = b.addSharedLibrary("taufs1", "src/main.zig", .unversioned);

    lib.setBuildMode(mode);
    lib.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    lib.import_memory = true;
    lib.initial_memory = 65536;
    lib.max_memory = 65536;
    lib.stack_size = 14752;

    // Export WASM-4 symbols
    lib.export_symbol_names = &[_][]const u8{ "start", "update" };

    lib.install();

//     const dest = b.pathJoin(&.{ b.install_path, "lib", lib.out_filename });
//     const compress = b.addSystemCommand(&.{"wasm-opt", "-Os", dest, "-o", dest});
//     compress.step.dependOn(&lib.step);

//     b.getInstallStep().dependOn(&compress.step);
}
