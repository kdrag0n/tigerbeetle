//! Orchestrates building and publishing a distribution of tigerbeetle --- a collection of (source
//! and binary) artifacts which constitutes a release and which we upload to various registries.
//!
//! Concretely, the artifacts are:
//!
//! - TigerBeetle binary build for all supported architectures
//! - TigerBeetle clients build for all supported languages
//!
//! This is implemented as a standalone zig script, rather as a step in build.zig, because this is
//! a "meta" build system --- we need to orchestrate `zig build`, `go build`, `npm publish` and
//! friends, and treat them as peers.
//!
//! Note on verbosity: to ease debugging, try to keep the output to O(1) lines per command. The idea
//! here is that, if something goes wrong, you can see _what_ goes wrong and easily copy-paste
//! specific commands to your local terminal, but, at the same time, you don't want to sift through
//! megabytes of info-level noise first.

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");
const flags = @import("../flags.zig");
const fatal = flags.fatal;
const Shell = @import("../shell.zig");
const multiversioning = @import("../multiversioning.zig");
const multiversion_binary_size_max = multiversioning.multiversion_binary_size_max;

const Language = enum { dotnet, go, java, node, zig, docker };
const LanguageSet = std.enums.EnumSet(Language);
pub const CliArgs = struct {
    run_number: u32,
    sha: []const u8,
    language: ?Language = null,
    build: bool = false,
    publish: bool = false,
};

const VersionInfo = struct {
    release_triple: []const u8,
    release_triple_client_min: []const u8,
    sha: []const u8,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CliArgs) !void {
    _ = gpa;

    const languages = if (cli_args.language) |language|
        LanguageSet.initOne(language)
    else
        LanguageSet.initFull();

    // Run number is a monotonically incremented integer. Map it to a three-component version
    // number.
    // If you change this, make sure to change the validation code in release_validate.zig!
    const release_triple = .{
        .major = 0,
        .minor = 15,
        .patch = cli_args.run_number - 185,
    };

    // The minimum client version allowed to connect. This has implications for backwards
    // compatibility and the upgrade path for replicas and clients. If there's no overlap
    // between a replica version and minimum client version - eg, replica 0.15.4 requires
    // client 0.15.4 - it means that upgrading requires coordination with clients, which
    // will be very inconvenient for operators.
    const release_triple_client_min = .{
        .major = 0,
        .minor = 15,
        .patch = 3,
    };

    const version_info = VersionInfo{
        .release_triple = try std.fmt.allocPrint(
            shell.arena.allocator(),
            "{[major]}.{[minor]}.{[patch]}",
            release_triple,
        ),
        .release_triple_client_min = try std.fmt.allocPrint(
            shell.arena.allocator(),
            "{[major]}.{[minor]}.{[patch]}",
            release_triple_client_min,
        ),
        .sha = cli_args.sha,
    };
    log.info("release={s} sha={s}", .{ version_info.release_triple, version_info.sha });

    if (cli_args.build) {
        try build(shell, languages, version_info);
    }

    if (cli_args.publish) {
        try publish(shell, languages, version_info);
    }
}

fn build(shell: *Shell, languages: LanguageSet, info: VersionInfo) !void {
    var section = try shell.open_section("build all");
    defer section.close();

    try shell.project_root.deleteTree("dist");
    var dist_dir = try shell.project_root.makeOpenPath("dist", .{});
    defer dist_dir.close();

    log.info("building TigerBeetle distribution into {s}", .{
        try dist_dir.realpathAlloc(shell.arena.allocator(), "."),
    });

    if (languages.contains(.zig)) {
        var dist_dir_tigerbeetle = try dist_dir.makeOpenPath("tigerbeetle", .{});
        defer dist_dir_tigerbeetle.close();

        try build_tigerbeetle(shell, info, dist_dir_tigerbeetle);
    }

    if (languages.contains(.dotnet)) {
        var dist_dir_dotnet = try dist_dir.makeOpenPath("dotnet", .{});
        defer dist_dir_dotnet.close();

        try build_dotnet(shell, info, dist_dir_dotnet);
    }

    if (languages.contains(.go)) {
        var dist_dir_go = try dist_dir.makeOpenPath("go", .{});
        defer dist_dir_go.close();

        try build_go(shell, info, dist_dir_go);
    }

    if (languages.contains(.java)) {
        var dist_dir_java = try dist_dir.makeOpenPath("java", .{});
        defer dist_dir_java.close();

        try build_java(shell, info, dist_dir_java);
    }

    if (languages.contains(.node)) {
        var dist_dir_node = try dist_dir.makeOpenPath("node", .{});
        defer dist_dir_node.close();

        try build_node(shell, info, dist_dir_node);
    }
}

/// Does the same thing as llvm-lipo (builds a universal binary) but allows building binaries
/// that have deprecated architectures. This is used by multiversioning on macOS, where these
/// deprecated architectures hold the metadata and version packs.
/// It's much easier to embed and read them here, then to do it in the inner MachO binary, like
/// we do with ELF or PE.
fn build_macos_universal_binary(
    shell: *Shell,
    dst: []const u8,
    binaries: []const struct { cpu_type: i32, cpu_subtype: i32, path: []const u8 },
) !void {
    var section = try shell.open_section("build macos universal binary");
    defer section.close();

    // The offset start is relative to the end of the headers, rounded up to the alignment.
    // Use alignment of 2^14 == 16384 to match macOS.
    const alignment = 2 ** 14;

    // Ensure our total header size is less than our binary_read_buffer_size, so we can read
    // everything in one go.
    const headers_size = @sizeOf(std.macho.fat_header) + @sizeOf(std.macho.fat_arch) *
        binaries.len;
    assert(headers_size < multiversioning.binary_read_buffer_size);
    assert(headers_size < alignment);

    var binary_headers = try shell.arena.allocator().alloc(std.macho.fat_arch, binaries.len);

    var current_offset: u32 = alignment;
    for (binaries, binary_headers) |binary, *binary_header| {
        const binary_file = try std.fs.cwd().openFile(binary.path, .{ .mode = .read_only });
        defer binary_file.close();

        const binary_size: u32 = @intCast((try binary_file.stat()).size);

        // The Mach-O header is big-endian...
        binary_header.* = std.macho.fat_arch{
            .cputype = @byteSwap(binary.cpu_type),
            .cpusubtype = @byteSwap(binary.cpu_subtype),
            .offset = @byteSwap(current_offset),
            .size = @byteSwap(binary_size),
            .@"align" = @byteSwap(@as(u32, @intCast(14))),
        };

        current_offset += binary_size;
        current_offset = stdx.div_ceil(current_offset, alignment) * alignment;
    }

    var output_file = try std.fs.cwd().createFile(dst, .{ .truncate = false });
    defer output_file.close();

    const fat_header = std.macho.fat_header{
        .magic = std.macho.FAT_CIGAM,
        .nfat_arch = @byteSwap(@as(u32, @intCast(binaries.len))),
    };
    assert(@sizeOf(std.macho.fat_header) == 8);
    try output_file.writeAll(std.mem.asBytes(&fat_header));

    assert(@sizeOf(std.macho.fat_arch) == 20);
    try output_file.writeAll(std.mem.sliceAsBytes(binary_headers));

    try output_file.seekTo(alignment);

    for (binaries, binary_headers) |binary, binary_header| {
        const binary_file = try std.fs.cwd().openFile(binary.path, .{ .mode = .read_only });
        defer binary_file.close();

        try output_file.seekTo(@byteSwap(binary_header.offset));

        const binary_contents = try binary_file.readToEndAlloc(
            shell.arena.allocator(),
            multiversion_binary_size_max,
        );
        assert(binary_contents.len == @byteSwap(binary_header.size));

        try output_file.writeAll(binary_contents);
    }
}

/// Builds a multi-version pack for the `target` specified, returns the metadata and writes the
/// output pack to `pack_dst`.
fn build_past_version_pack(
    shell: *Shell,
    comptime target: []const u8,
    debug: bool,
    pack_dst: []const u8,
) !multiversioning.MultiVersionMetadata.PastVersionPack {
    assert(std.mem.indexOf(u8, target, "-linux") != null);

    var section = try shell.open_section("build multiversion pack");
    defer section.close();

    try shell.project_root.deleteTree("dist/tigerbeetle-past-pack");

    // TODO: This code should be removed once the first multi-version release is bootstrapped!
    const multiversion_epoch = "0.15.3";
    const is_multiversion_epoch = std.mem.eql(
        u8,
        try shell.exec_stdout("gh release view --json tagName --template {template}", .{
            .template = "{{.tagName}}", // Static, but shell.zig is not happy with '{'.
        }),
        multiversion_epoch,
    );

    if (is_multiversion_epoch) {
        log.info("past release is multiversion epoch ({s})", .{multiversion_epoch});

        // Downloads and extract the last published release of TigerBeetle.
        try shell.exec("gh release download -D dist/tigerbeetle-past-pack -p tigerbeetle-{target}{debug}.zip", .{
            .target = target,
            .debug = if (debug) "-debug" else "",
        });
        try shell.exec("unzip -d dist/tigerbeetle-past-pack dist/tigerbeetle-past-pack/tigerbeetle-{target}{debug}.zip", .{
            .target = target,
            .debug = if (debug) "-debug" else "",
        });

        const past_binary = try std.fs.cwd().openFile("./dist/tigerbeetle-past-pack/tigerbeetle", .{ .mode = .read_only });
        defer past_binary.close();

        const past_binary_contents = try past_binary.readToEndAlloc(shell.arena.allocator(), multiversion_binary_size_max);

        const checksum: u128 = multiversioning.checksum(past_binary_contents);

        const past_pack = try std.fs.cwd().createFile(pack_dst, .{ .truncate = true });
        defer past_pack.close();

        try past_pack.writeAll(past_binary_contents);

        return multiversioning.MultiVersionMetadata.PastVersionPack.init(.{
            .count = 1,
            .versions = &.{
                multiversioning.Release.from(
                    try multiversioning.ReleaseTriple.parse(multiversion_epoch),
                ).value,
            },
            .checksums = &.{checksum},
            .offsets = &.{0},
            .sizes = &.{@as(u32, @intCast(past_binary_contents.len))},
        });
    } else {
        // TODO :)
        @panic("non-epoch builds unsupported");
    }

    unreachable;
}

fn build_tigerbeetle(shell: *Shell, info: VersionInfo, dist_dir: std.fs.Dir) !void {
    var section = try shell.open_section("build tigerbeetle");
    defer section.close();

    const llvm_objcopy = for (@as([2][]const u8, .{ "llvm-objcopy-16", "llvm-objcopy" })) |llvm_objcopy| {
        if (shell.exec_stdout("{llvm_objcopy} --version", .{
            .llvm_objcopy = llvm_objcopy,
        })) |llvm_objcopy_version| {
            log.info("llvm-objcopy version {s}", .{llvm_objcopy_version});
            break llvm_objcopy;
        } else |_| {}
    } else {
        fatal("can't find llvm-objcopy", .{});
    };

    // We shell out to `zip` for creating archives, so we need an absolute path here.
    const dist_dir_path = try dist_dir.realpathAlloc(shell.arena.allocator(), ".");

    const targets = .{
        "aarch64-linux",
        "x86_64-linux",
        "x86_64-windows",
    };

    // Build tigerbeetle binary for all OS/CPU combinations we support and copy the result to
    // `dist`. MacOS is special cased below --- we use an extra step to merge x86 and arm binaries
    // into one.
    //TODO: use std.Target here
    inline for (.{ true, false }) |debug| {
        const debug_suffix = if (debug) "-debug" else "";
        inline for (targets) |target| {
            try shell.zig(
                \\build
                \\    -Dtarget={target}
                \\    -Drelease={release}
                \\    -Dgit-commit={commit}
                \\    -Dconfig-release={release_triple}
                \\    -Dconfig-release-client-min={release_triple_client_min}
            , .{
                .target = target,
                .release = if (debug) "false" else "true",
                .commit = info.sha,
                .release_triple = info.release_triple,
                .release_triple_client_min = info.release_triple_client_min,
            });

            const windows = comptime std.mem.indexOf(u8, target, "windows") != null;
            const exe_name = "tigerbeetle" ++ if (windows) ".exe" else "";

            // Copy the object using llvm-objcopy before taking our hash. This is to ensure we're
            // round trip deterministic between adding and removing sections:
            // `llvm-objcopy --add-section ... src dst_added` followed by
            // `llvm-objcopy --remove-section ... dst_added src_back` means
            // checksum(src) == checksum(src_back)
            // Note: actually don't think this is needed, we could assert it?
            try shell.exec("{llvm_objcopy} --enable-deterministic-archives {exe_name} {exe_name}", .{
                .llvm_objcopy = llvm_objcopy,
                .exe_name = exe_name,
            });

            if (!windows) {
                const current_checksum: u128 = blk: {
                    const current_binary = try std.fs.cwd().openFile(exe_name, .{ .mode = .read_only });
                    defer current_binary.close();

                    const current_binary_contents = try current_binary.readToEndAlloc(shell.arena.allocator(), multiversion_binary_size_max);
                    break :blk multiversioning.checksum(current_binary_contents);
                };

                const past_version_pack = try build_past_version_pack(shell, target, debug, "tigerbeetle-pack");

                // Explicitly write out zeros for the metadata, to compute the checksum.
                var mvf = std.mem.zeroes(multiversioning.MultiVersionMetadata);

                var mvf_file = try std.fs.cwd().createFile("tigerbeetle-pack.metadata", .{ .truncate = true });
                try mvf_file.writeAll(std.mem.asBytes(&mvf));
                mvf_file.close();

                // Use objcopy to add in our new pack, as well as its metadata - even though the metadata is still zero!
                try shell.exec("{llvm_objcopy} --enable-deterministic-archives --keep-undefined --add-section .tbmvp=tigerbeetle-pack --set-section-flags .tbmvp=contents,noload,readonly --add-section .tbmvm=tigerbeetle-pack.metadata --set-section-flags .tbmvm=contents,noload,readonly {exe_name}", .{
                    .llvm_objcopy = llvm_objcopy,
                    .exe_name = exe_name,
                });

                // Take the checksum of the binary, with the zero'd metadata.
                const checksum_without_metadata: u128 = blk: {
                    const current_binary = try std.fs.cwd().openFile(exe_name, .{ .mode = .read_only });
                    defer current_binary.close();

                    const current_binary_contents = try current_binary.readToEndAlloc(shell.arena.allocator(), multiversion_binary_size_max);
                    break :blk multiversioning.checksum(current_binary_contents);
                };

                mvf = multiversioning.MultiVersionMetadata{
                    .current_version = multiversioning.Release.from(try multiversioning.ReleaseTriple.parse(info.release_triple)).value,
                    .current_checksum = current_checksum,
                    .past = past_version_pack,
                    .checksum_without_metadata = checksum_without_metadata,
                };
                mvf.checksum_metadata = mvf.calculate_metadata_checksum();

                mvf_file = try std.fs.cwd().createFile("tigerbeetle-pack.metadata", .{ .truncate = true });
                try mvf_file.writeAll(std.mem.asBytes(&mvf));
                mvf_file.close();

                // Replace the metadata with the final version.
                try shell.exec("{llvm_objcopy} --enable-deterministic-archives --keep-undefined --remove-section .tbmvm --add-section .tbmvm=tigerbeetle-pack.metadata --set-section-flags .tbmvm=contents,noload,readonly {exe_name}", .{
                    .llvm_objcopy = llvm_objcopy,
                    .exe_name = exe_name,
                });

                // Finally, check the binary produced using both the old and new versions.
                // FIXME: Do check with old binary downloaded, if it wasn't epoch
                // const absolute_exe_name = try std.fs.cwd().realpathAlloc(shell.arena.allocator(), exe_name);
                // const multiversion = try multiversioning.MultiVersion.from_elf(absolute_exe_name);
                // try multiversion.validate(absolute_exe_name, shell.arena.allocator());

                // return error.Foo;
            }

            const zip_name = "tigerbeetle-" ++ target ++ debug_suffix ++ ".zip";
            try shell.exec("zip -9 {zip_path} {exe_name}", .{
                .zip_path = try shell.fmt("{s}/{s}", .{ dist_dir_path, zip_name }),
                .exe_name = "tigerbeetle" ++ if (windows) ".exe" else "",
            });
        }
    }

    // macOS handling.
    inline for (.{ true, false }) |debug| {
        const debug_suffix = if (debug) "-debug" else "";
        inline for (.{ "aarch64-macos", "x86_64-macos" }) |target| {
            try shell.zig(
                \\build install
                \\    -Dtarget={target}
                \\    -Drelease={release}
                \\    -Dgit-commit={commit}
                \\    -Dconfig-release={release_triple}
                \\    -Dconfig-release-client-min={release_triple_client_min}
            , .{
                .target = target,
                .release = if (debug) "false" else "true",
                .commit = info.sha,
                .release_triple = info.release_triple,
                .release_triple_client_min = info.release_triple_client_min,
            });

            try Shell.copy_path(
                shell.project_root,
                "tigerbeetle",
                shell.project_root,
                "tigerbeetle-" ++ target,
            );
        }

        try build_macos_universal_binary(shell, "tigerbeetle", &.{
            .{
                .cpu_type = std.macho.CPU_TYPE_ARM64,
                .cpu_subtype = std.macho.CPU_SUBTYPE_ARM_ALL,
                .path = "tigerbeetle-aarch64-macos",
            },
            .{
                .cpu_type = std.macho.CPU_TYPE_X86_64,
                .cpu_subtype = std.macho.CPU_SUBTYPE_X86_64_ALL,
                .path = "tigerbeetle-x86_64-macos",
            },
        });

        try shell.project_root.deleteFile("tigerbeetle-aarch64-macos");
        try shell.project_root.deleteFile("tigerbeetle-x86_64-macos");
        const zip_name = "tigerbeetle-universal-macos" ++ debug_suffix ++ ".zip";
        try shell.exec("touch -d 1970-01-01T00:00:00Z {exe_name}", .{
            .exe_name = "tigerbeetle",
        });
        try shell.exec("zip -9 -oX {zip_path} {exe_name}", .{
            .zip_path = try shell.fmt("{s}/{s}", .{ dist_dir_path, zip_name }),
            .exe_name = "tigerbeetle",
        });
    }
}

fn build_dotnet(shell: *Shell, info: VersionInfo, dist_dir: std.fs.Dir) !void {
    var section = try shell.open_section("build dotnet");
    defer section.close();

    try shell.pushd("./src/clients/dotnet");
    defer shell.popd();

    const dotnet_version = shell.exec_stdout("dotnet --version", .{}) catch {
        fatal("can't find dotnet", .{});
    };
    log.info("dotnet version {s}", .{dotnet_version});

    try shell.zig(
        \\build dotnet_client -Drelease -Dconfig=production -Dconfig-release={release_triple}
        \\ -Dconfig-release-client-min={release_triple_client_min}
    , .{
        .release_triple = info.release_triple,
        .release_triple_client_min = info.release_triple_client_min,
    });
    try shell.exec(
        \\dotnet pack TigerBeetle --configuration Release
        \\/p:AssemblyVersion={release_triple} /p:Version={release_triple}
    , .{ .release_triple = info.release_triple });

    try Shell.copy_path(
        shell.cwd,
        try shell.fmt("TigerBeetle/bin/Release/tigerbeetle.{s}.nupkg", .{info.release_triple}),
        dist_dir,
        try shell.fmt("tigerbeetle.{s}.nupkg", .{info.release_triple}),
    );
}

fn build_go(shell: *Shell, info: VersionInfo, dist_dir: std.fs.Dir) !void {
    var section = try shell.open_section("build go");
    defer section.close();

    try shell.pushd("./src/clients/go");
    defer shell.popd();

    try shell.zig(
        \\build go_client -Drelease -Dconfig=production -Dconfig-release={release_triple}
        \\ -Dconfig-release-client-min={release_triple_client_min}
    , .{
        .release_triple = info.release_triple,
        .release_triple_client_min = info.release_triple_client_min,
    });

    const files = try shell.exec_stdout("git ls-files", .{});
    var files_lines = std.mem.tokenize(u8, files, "\n");
    var copied_count: u32 = 0;
    while (files_lines.next()) |file| {
        assert(file.len > 3);
        try Shell.copy_path(shell.cwd, file, dist_dir, file);
        copied_count += 1;
    }
    assert(copied_count >= 10);

    const native_files = try shell.find(.{ .where = &.{"."}, .extensions = &.{ ".a", ".lib" } });
    copied_count = 0;
    for (native_files) |native_file| {
        try Shell.copy_path(shell.cwd, native_file, dist_dir, native_file);
        copied_count += 1;
    }
    // 5 = 3 + 2
    //     3 = x86_64 for mac, windows and linux
    //         2 = aarch64 for mac and linux
    assert(copied_count == 5);

    const readme = try shell.fmt(
        \\# tigerbeetle-go
        \\This repo has been automatically generated from
        \\[tigerbeetle/tigerbeetle@{[sha]s}](https://github.com/tigerbeetle/tigerbeetle/commit/{[sha]s})
        \\to keep binary blobs out of the monorepo.
        \\
        \\Please see
        \\<https://github.com/tigerbeetle/tigerbeetle/tree/main/src/clients/go>
        \\for documentation and contributions.
    , .{ .sha = info.sha });
    try dist_dir.writeFile("README.md", readme);
}

fn build_java(shell: *Shell, info: VersionInfo, dist_dir: std.fs.Dir) !void {
    var section = try shell.open_section("build java");
    defer section.close();

    try shell.pushd("./src/clients/java");
    defer shell.popd();

    const java_version = shell.exec_stdout("java --version", .{}) catch {
        fatal("can't find java", .{});
    };
    log.info("java version {s}", .{java_version});

    try shell.zig(
        \\build java_client -Drelease -Dconfig=production -Dconfig-release={release_triple}
        \\ -Dconfig-release-client-min={release_triple_client_min}
    , .{
        .release_triple = info.release_triple,
        .release_triple_client_min = info.release_triple_client_min,
    });

    try backup_create(shell.cwd, "pom.xml");
    defer backup_restore(shell.cwd, "pom.xml");

    try shell.exec(
        \\mvn --batch-mode --quiet --file pom.xml
        \\versions:set -DnewVersion={release_triple}
    , .{ .release_triple = info.release_triple });

    try shell.exec(
        \\mvn --batch-mode --quiet --file pom.xml
        \\  -Dmaven.test.skip -Djacoco.skip
        \\  package
    , .{});

    try Shell.copy_path(
        shell.cwd,
        try shell.fmt("target/tigerbeetle-java-{s}.jar", .{info.release_triple}),
        dist_dir,
        try shell.fmt("tigerbeetle-java-{s}.jar", .{info.release_triple}),
    );
}

fn build_node(shell: *Shell, info: VersionInfo, dist_dir: std.fs.Dir) !void {
    var section = try shell.open_section("build node");
    defer section.close();

    try shell.pushd("./src/clients/node");
    defer shell.popd();

    const node_version = shell.exec_stdout("node --version", .{}) catch {
        fatal("can't find nodejs", .{});
    };
    log.info("node version {s}", .{node_version});

    try shell.zig(
        \\build node_client -Drelease -Dconfig=production -Dconfig-release={release_triple}
        \\ -Dconfig-release-client-min={release_triple_client_min}
    , .{
        .release_triple = info.release_triple,
        .release_triple_client_min = info.release_triple_client_min,
    });

    try backup_create(shell.cwd, "package.json");
    defer backup_restore(shell.cwd, "package.json");

    try backup_create(shell.cwd, "package-lock.json");
    defer backup_restore(shell.cwd, "package-lock.json");

    try shell.exec(
        "npm version --no-git-tag-version {release_triple}",
        .{ .release_triple = info.release_triple },
    );
    try shell.exec("npm install", .{});
    try shell.exec("npm pack --quiet", .{});

    try Shell.copy_path(
        shell.cwd,
        try shell.fmt("tigerbeetle-node-{s}.tgz", .{info.release_triple}),
        dist_dir,
        try shell.fmt("tigerbeetle-node-{s}.tgz", .{info.release_triple}),
    );
}

fn publish(shell: *Shell, languages: LanguageSet, info: VersionInfo) !void {
    var section = try shell.open_section("publish all");
    defer section.close();

    assert(try shell.dir_exists("dist"));

    if (languages.contains(.zig)) {
        _ = try shell.env_get("GITHUB_TOKEN");
        const gh_version = shell.exec_stdout("gh --version", .{}) catch {
            fatal("can't find gh", .{});
        };
        log.info("gh version {s}", .{gh_version});

        const full_changelog = try shell.project_root.readFileAlloc(
            shell.arena.allocator(),
            "CHANGELOG.md",
            1024 * 1024,
        );

        const notes = try shell.fmt(
            \\{[release_triple]s}
            \\
            \\**NOTE**: You must run the same version of server and client. We do
            \\not yet follow semantic versioning where all patch releases are
            \\interchangeable.
            \\
            \\## Server
            \\
            \\* Binary: Download the zip for your OS and architecture from this page and unzip.
            \\* Docker: `docker pull ghcr.io/tigerbeetle/tigerbeetle:{[release_triple]s}`
            \\* Docker (debug image): `docker pull ghcr.io/tigerbeetle/tigerbeetle:{[release_triple]s}-debug`
            \\
            \\## Clients
            \\
            \\**NOTE**: Because of package manager caching, it may take a few
            \\minutes after the release for this version to appear in the package
            \\manager.
            \\
            \\* .NET: `dotnet add package tigerbeetle --version {[release_triple]s}`
            \\* Go: `go mod edit -require github.com/tigerbeetle/tigerbeetle-go@v{[release_triple]s}`
            \\* Java: Update the version of `com.tigerbeetle.tigerbeetle-java` in `pom.xml`
            \\  to `{[release_triple]s}`.
            \\* Node.js: `npm install tigerbeetle-node@{[release_triple]s}`
            \\
            \\## Changelog
            \\
            \\{[changelog]s}
        , .{
            .release_triple = info.release_triple,
            .changelog = latest_changelog_entry(full_changelog),
        });

        try shell.exec(
            \\gh release create --draft
            \\  --target {sha}
            \\  --notes {notes}
            \\  {tag}
        , .{
            .sha = info.sha,
            .notes = notes,
            .tag = info.release_triple,
        });

        // Here and elsewhere for publishing we explicitly spell out the files we are uploading
        // instead of using a for loop to double-check the logic in `build`.
        const artifacts: []const []const u8 = &.{
            "dist/tigerbeetle/tigerbeetle-aarch64-linux-debug.zip",
            "dist/tigerbeetle/tigerbeetle-aarch64-linux.zip",
            "dist/tigerbeetle/tigerbeetle-universal-macos-debug.zip",
            "dist/tigerbeetle/tigerbeetle-universal-macos.zip",
            "dist/tigerbeetle/tigerbeetle-x86_64-linux-debug.zip",
            "dist/tigerbeetle/tigerbeetle-x86_64-linux.zip",
            "dist/tigerbeetle/tigerbeetle-x86_64-windows-debug.zip",
            "dist/tigerbeetle/tigerbeetle-x86_64-windows.zip",
        };
        try shell.exec("gh release upload {tag} {artifacts}", .{
            .tag = info.release_triple,
            .artifacts = artifacts,
        });
    }

    if (languages.contains(.docker)) try publish_docker(shell, info);
    if (languages.contains(.dotnet)) try publish_dotnet(shell, info);
    if (languages.contains(.go)) try publish_go(shell, info);
    if (languages.contains(.java)) try publish_java(shell, info);
    if (languages.contains(.node)) {
        try publish_node(shell, info);
        // Our docs are build with node, so publish the docs together with the node package.
        try publish_docs(shell, info);
    }

    if (languages.contains(.zig)) {
        try shell.exec(
            \\gh release edit --draft=false --latest=true
            \\  {tag}
        , .{ .tag = info.release_triple });
    }
}

fn latest_changelog_entry(changelog: []const u8) []const u8 {
    // Extract the first entry between two `## ` headers, excluding the header itself
    const changelog_with_header = stdx.cut(stdx.cut(changelog, "\n## ").?.suffix, "\n## ").?.prefix;
    return stdx.cut(changelog_with_header, "\n\n").?.suffix;
}

test latest_changelog_entry {
    const changelog =
        \\# TigerBeetle Changelog
        \\
        \\## 2023-10-23
        \\
        \\This is the start of the changelog.
        \\
        \\### Features
        \\
        \\
        \\## 1970-01-01
        \\
        \\ The beginning.
        \\
    ;
    try std.testing.expectEqualStrings(latest_changelog_entry(changelog),
        \\This is the start of the changelog.
        \\
        \\### Features
        \\
        \\
    );
}

fn publish_dotnet(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish dotnet");
    defer section.close();

    assert(try shell.dir_exists("dist/dotnet"));

    const nuget_key = try shell.env_get("NUGET_KEY");
    try shell.exec(
        \\dotnet nuget push
        \\    --api-key {nuget_key}
        \\    --source https://api.nuget.org/v3/index.json
        \\    {package}
    , .{
        .nuget_key = nuget_key,
        .package = try shell.fmt("dist/dotnet/tigerbeetle.{s}.nupkg", .{info.release_triple}),
    });
}

fn publish_go(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish go");
    defer section.close();

    assert(try shell.dir_exists("dist/go"));

    const token = try shell.env_get("TIGERBEETLE_GO_PAT");
    try shell.exec(
        \\git clone --no-checkout --depth 1
        \\  https://oauth2:{token}@github.com/tigerbeetle/tigerbeetle-go.git tigerbeetle-go
    , .{ .token = token });
    defer {
        shell.project_root.deleteTree("tigerbeetle-go") catch {};
    }

    const dist_files = try shell.find(.{ .where = &.{"dist/go"} });
    assert(dist_files.len > 10);
    for (dist_files) |file| {
        try Shell.copy_path(
            shell.project_root,
            file,
            shell.project_root,
            try std.mem.replaceOwned(
                u8,
                shell.arena.allocator(),
                file,
                "dist/go",
                "tigerbeetle-go",
            ),
        );
    }

    try shell.pushd("./tigerbeetle-go");
    defer shell.popd();

    try shell.exec("git add .", .{});
    // Native libraries are ignored in this repository, but we want to push them to the
    // tigerbeetle-go one!
    try shell.exec("git add --force pkg/native", .{});

    try shell.git_env_setup();
    try shell.exec("git commit --message {message}", .{
        .message = try shell.fmt(
            "Autogenerated commit from tigerbeetle/tigerbeetle@{s}",
            .{info.sha},
        ),
    });

    try shell.exec("git tag tigerbeetle-{sha}", .{ .sha = info.sha });
    try shell.exec("git tag v{release_triple}", .{ .release_triple = info.release_triple });

    try shell.exec("git push origin main", .{});
    try shell.exec("git push origin tigerbeetle-{sha}", .{ .sha = info.sha });
    try shell.exec("git push origin v{release_triple}", .{ .release_triple = info.release_triple });
}

fn publish_java(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish java");
    defer section.close();

    assert(try shell.dir_exists("dist/java"));

    // These variables don't have a special meaning in maven, and instead are a part of
    // settings.xml generated by GitHub actions.
    _ = try shell.env_get("MAVEN_USERNAME");
    _ = try shell.env_get("MAVEN_CENTRAL_TOKEN");
    _ = try shell.env_get("MAVEN_GPG_PASSPHRASE");

    // TODO: Maven uniquely doesn't support uploading pre-build package, so here we just rebuild
    // from source and upload a _different_ artifact. This is wrong.
    //
    // As far as I can tell, there isn't a great solution here. See, for example:
    //
    // <https://users.maven.apache.narkive.com/jQ3WocgT/mvn-deploy-without-rebuilding>
    //
    // I think what we should do here is for `build` to deploy to the local repo, and then use
    //
    // <https://gist.github.com/rishabh9/183cc0c4c3ada4f8df94d65fcd73a502>
    //
    // to move the contents of that local repo to maven central. But this is todo, just rebuild now.
    try backup_create(shell.project_root, "src/clients/java/pom.xml");
    defer backup_restore(shell.project_root, "src/clients/java/pom.xml");

    try shell.exec(
        \\mvn --batch-mode --quiet --file src/clients/java/pom.xml
        \\  versions:set -DnewVersion={release_triple}
    , .{ .release_triple = info.release_triple });

    try shell.exec(
        \\mvn --batch-mode --quiet --file src/clients/java/pom.xml
        \\  -Dmaven.test.skip -Djacoco.skip
        \\  deploy
    , .{});
}

fn publish_node(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish node");
    defer section.close();

    assert(try shell.dir_exists("dist/node"));

    // `NODE_AUTH_TOKEN` env var doesn't have a special meaning in npm. It does have special meaning
    // in GitHub Actions, which adds a literal
    //
    //    //registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}
    //
    // to the .npmrc file (that is, node config file itself supports env variables).
    _ = try shell.env_get("NODE_AUTH_TOKEN");
    try shell.exec("npm publish {package}", .{
        .package = try shell.fmt("dist/node/tigerbeetle-node-{s}.tgz", .{info.release_triple}),
    });
}

fn publish_docker(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish docker");
    defer section.close();

    assert(try shell.dir_exists("dist/tigerbeetle"));

    try shell.exec(
        \\docker login --username tigerbeetle --password {password} ghcr.io
    , .{
        .password = try shell.env_get("GITHUB_TOKEN"),
    });

    try shell.exec(
        \\docker buildx create --use
    , .{});

    for ([_]bool{ true, false }) |debug| {
        const triples = [_][]const u8{ "aarch64-linux", "x86_64-linux" };
        const docker_arches = [_][]const u8{ "arm64", "amd64" };
        for (triples, docker_arches) |triple, docker_arch| {
            // We need to unzip binaries from dist. For simplicity, don't bother with a temporary
            // directory.
            shell.project_root.deleteFile("tigerbeetle") catch {};
            try shell.exec("unzip ./dist/tigerbeetle/tigerbeetle-{triple}{debug}.zip", .{
                .triple = triple,
                .debug = if (debug) "-debug" else "",
            });
            try shell.project_root.rename(
                "tigerbeetle",
                try shell.fmt("tigerbeetle-{s}", .{docker_arch}),
            );
        }
        try shell.exec(
            \\docker buildx build --file tools/docker/Dockerfile . --platform linux/amd64,linux/arm64
            \\   --tag ghcr.io/tigerbeetle/tigerbeetle:{release_triple}{debug}
            \\   {tag_latest}
            \\   --push
        , .{
            .release_triple = info.release_triple,
            .debug = if (debug) "-debug" else "",
            .tag_latest = @as(
                []const []const u8,
                if (debug) &.{} else &.{ "--tag", "ghcr.io/tigerbeetle/tigerbeetle:latest" },
            ),
        });

        // Sadly, there isn't an easy way to locally build & test a multiplatform image without
        // pushing it out to the registry first. As docker testing isn't covered under not rocket
        // science rule, let's do a best effort after-the-fact testing here.
        const version_verbose = try shell.exec_stdout(
            \\docker run ghcr.io/tigerbeetle/tigerbeetle:{release_triple}{debug} version --verbose
        , .{
            .release_triple = info.release_triple,
            .debug = if (debug) "-debug" else "",
        });
        const mode = if (debug) "Debug" else "ReleaseSafe";
        assert(std.mem.indexOf(u8, version_verbose, mode) != null);
        assert(std.mem.indexOf(u8, version_verbose, info.release_triple) != null);
    }
}

fn publish_docs(shell: *Shell, info: VersionInfo) !void {
    var section = try shell.open_section("publish docs");
    defer section.close();

    {
        try shell.pushd("./src/docs_website");
        defer shell.popd();

        try shell.exec("npm install", .{});
        try shell.exec("npm run build", .{});
    }

    const token = try shell.env_get("TIGERBEETLE_DOCS_PAT");
    try shell.exec(
        \\git clone --no-checkout --depth 1
        \\  https://oauth2:{token}@github.com/tigerbeetle/docs.git tigerbeetle-docs
    , .{ .token = token });
    defer {
        shell.project_root.deleteTree("tigerbeetle-docs") catch {};
    }

    const docs_files = try shell.find(.{ .where = &.{"src/docs_website/build"} });
    assert(docs_files.len > 10);
    for (docs_files) |file| {
        try Shell.copy_path(
            shell.project_root,
            file,
            shell.project_root,
            try std.mem.replaceOwned(
                u8,
                shell.arena.allocator(),
                file,
                "src/docs_website/build",
                "tigerbeetle-docs/",
            ),
        );
    }

    try shell.pushd("./tigerbeetle-docs");
    defer shell.popd();

    try shell.exec("git add .", .{});
    try shell.env.put("GIT_AUTHOR_NAME", "TigerBeetle Bot");
    try shell.env.put("GIT_AUTHOR_EMAIL", "bot@tigerbeetle.com");
    try shell.env.put("GIT_COMMITTER_NAME", "TigerBeetle Bot");
    try shell.env.put("GIT_COMMITTER_EMAIL", "bot@tigerbeetle.com");
    // We want to push a commit even if there are no changes to the docs, to make sure
    // that the latest commit message on the docs repo points to the latest tigerbeetle
    // release.
    try shell.exec("git commit --allow-empty --message {message}", .{
        .message = try shell.fmt(
            "Autogenerated commit from tigerbeetle/tigerbeetle@{s}",
            .{info.sha},
        ),
    });

    try shell.exec("git push origin main", .{});
}

fn backup_create(dir: std.fs.Dir, comptime file: []const u8) !void {
    try Shell.copy_path(dir, file, dir, file ++ ".backup");
}

fn backup_restore(dir: std.fs.Dir, comptime file: []const u8) void {
    dir.deleteFile(file) catch {};
    Shell.copy_path(dir, file ++ ".backup", dir, file) catch {};
    dir.deleteFile(file ++ ".backup") catch {};
}
