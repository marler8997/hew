fn usage() !void {
    var stderr_buf: [1000]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    stderr.interface.print(
        \\Usage: hew COMMAND [OPTIONS] ARGS...
        \\Version: {[version]s}
        \\Commands:
        \\--------------------------------------------------------------------------------
        \\  install PKGs...           | Install the given PKGs.
        \\  new-bin-path PATH         | Set path cli exes are installed to.
        \\
        \\Install options:
        \\  --app-data PATH           | Override app data directory.
        \\  --non-interactive         | Don't prompt for input.
        \\  --keep-archives           | Keep downloaded archives after install.
        \\  --allow-overwrite         | Overwrite existing executables without prompting.
        \\
        \\
    ,
        .{
            .version = @embedFile("version"),
        },
    ) catch return stderr.err.?;
    stderr.interface.flush() catch return stderr.err.?;
}

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var arg_it = switch (builtin.os.tag) {
        .windows => try std.process.argsWithAllocator(arena),
        else => std.process.args(),
    };
    _ = arg_it.next();
    const cmd = blk: {
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) break :blk arg;
            errExit("unknown option '{s}'", .{arg});
        }
        try usage();
        return 0xff;
    };
    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) return try install(arena, &arg_it);
    if (std.mem.eql(u8, cmd, "new-bin-path")) return try setBinPath(arena, &arg_it, .require_new);
    if (std.mem.eql(u8, cmd, "version")) {
        var writer = std.fs.File.stdout().writer(&.{});
        writer.interface.writeAll(@embedFile("version") ++ "\n") catch return writer.err.?;
        return 0;
    }
    log.err("unknown command '{s}'", .{cmd});
    return 0xff;
}

fn install(arena: std.mem.Allocator, arg_it: *std.process.ArgIterator) !u8 {
    const Config = struct {
        pkgs: []const Pkg,
        interactive: bool,
        keep_archives: bool,
        allow_overwrite: bool,
        allow_shadow: bool,
        maybe_app_data: ?[:0]const u8,
    };
    const config: Config = blk_config: {
        var pkgs: std.ArrayListUnmanaged(Pkg) = .{};
        var interactive: bool = true;
        var keep_archives: bool = false;
        var allow_overwrite: bool = false;
        var allow_shadow: bool = false;
        var maybe_app_data: ?[:0]const u8 = null;
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                switch (Pkg.parse(arg)) {
                    .ok => |pkg| try pkgs.append(arena, pkg),
                    .err => |e| errExit("invalid package '{s}': {f}", .{ arg, e }),
                }
            } else if (std.mem.eql(u8, arg, "--non-interactive")) {
                interactive = false;
            } else if (std.mem.eql(u8, arg, "--keep-archives")) {
                keep_archives = true;
            } else if (std.mem.eql(u8, arg, "--allow-overwrite")) {
                allow_overwrite = true;
            } else if (std.mem.eql(u8, arg, "--allow-shadow")) {
                allow_shadow = true;
            } else if (std.mem.eql(u8, arg, "--app-data")) {
                const val = arg_it.next();
                if (val == null or std.mem.startsWith(u8, val.?, "-"))
                    errExit("--app-data requires a path argument", .{});
                maybe_app_data = val.?;
            } else errExit("unknown cmdline argument '{s}'", .{arg});
        }

        break :blk_config .{
            .pkgs = pkgs.toOwnedSlice(arena) catch |e| oom(e),
            .interactive = interactive,
            .keep_archives = keep_archives,
            .allow_overwrite = allow_overwrite,
            .allow_shadow = allow_shadow,
            .maybe_app_data = maybe_app_data,
        };
    };

    if (config.pkgs.len == 0) errExit("no packages given to install", .{});

    const app_data_path = config.maybe_app_data orelse allocAppDataPath(arena);
    std.debug.assert(std.fs.path.isAbsolute(app_data_path));
    var scratch: Scratch = .init(std.heap.page_allocator);
    const install_config: InstallConfig = .{
        .interactive = config.interactive,
        .keep_archives = config.keep_archives,
        .allow_overwrite = config.allow_overwrite,
        .allow_shadow = config.allow_shadow,
        .app_data_path = app_data_path,
        .cache_path = allocCachePath(arena, app_data_path),
        .bin_path = try allocBinPath(arena, &scratch, config.interactive, app_data_path),
    };
    std.debug.assert(std.fs.path.isAbsolute(install_config.cache_path));
    std.debug.assert(std.fs.path.isAbsolute(install_config.bin_path));

    for (config.pkgs) |pkg| {
        try installPkg(&scratch, &install_config, pkg);
    }
    return 0;
}

fn binPathEql(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            const an: u8 = if (ac == '/') '\\' else ac;
            const bn: u8 = if (bc == '/') '\\' else bc;
            if (an != bn) return false;
        }
        return true;
    }
    return std.mem.eql(u8, a, b);
}

const BinFileKind = enum { exe, pdb };
fn binFileKind(name: []const u8) ?BinFileKind {
    // if (std.ascii.endsWithIgnoreCase(name, ".zip")) return .data;
    if (builtin.os.tag == .windows) {
        if (std.ascii.endsWithIgnoreCase(name, ".exe")) return .exe;
        if (std.ascii.endsWithIgnoreCase(name, ".pdb")) return .pdb;
        return null;
    }
    return .exe;
}

fn isBinPathNormalized(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return std.mem.indexOfScalar(u8, path, '/') == null;
    }
    return true;
}

fn normalizeBinPath(arena: std.mem.Allocator, path: [:0]const u8) [:0]const u8 {
    if (isBinPathNormalized(path)) return path;
    const duped = arena.dupeZ(u8, path) catch |e| oom(e);
    std.mem.replaceScalar(u8, duped, '/', '\\');
    // sanity check that isBinPathNormalized wasn't lying
    std.debug.assert(isBinPathNormalized(duped));
    std.debug.assert(!std.mem.eql(u8, path, duped));
    std.debug.assert(binPathEql(path, duped));
    return duped;
}

fn setBinPath(arena: std.mem.Allocator, arg_it: *std.process.ArgIterator, mode: enum { require_new, update }) !u8 {
    var maybe_app_data: ?[:0]const u8 = null;
    const bin_path = blk: {
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (arg_it.next() != null) errExit("too many cmdline args", .{});
                break :blk normalizeBinPath(arena, arg);
            }
            if (std.mem.eql(u8, arg, "--app-data")) {
                const val = arg_it.next();
                if (val == null or std.mem.startsWith(u8, val.?, "-"))
                    errExit("--app-data requires a path argument", .{});
                maybe_app_data = val.?;
            } else errExit("unknown option '{s}'", .{arg});
        }
        errExit("new-bin-path requires a PATH argument", .{});
    };

    const app_data_path = maybe_app_data orelse allocAppDataPath(arena);

    var bin_setting_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_setting_path = std.fmt.bufPrint(
        &bin_setting_path_buf,
        "{s}{c}{s}",
        .{ app_data_path, std.fs.path.sep, "binpath" },
    ) catch @panic("app data path too long");

    switch (mode) {
        .update => @panic("todo"),
        .require_new => {
            var val_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try readBinPath(bin_setting_path, &val_buf)) |stored| {
                if (std.mem.eql(u8, stored, bin_path)) {
                    log.info("bin path is already set to '{s}'", .{bin_path});
                    return 0;
                }
                std.debug.assert(!binPathEql(stored, bin_path));
                errExit("bin path is already configured as '{s}' in '{s}'", .{ stored, bin_setting_path });
            }
        },
    }

    const path_env = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(arena, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => errExit("PATH environment variable not found", .{}),
            error.OutOfMemory => |e| oom(e),
            error.InvalidWtf8 => errExit("PATH is invalid wtf8", .{}),
        }
    else
        std.posix.getenv("PATH") orelse "";

    const in_path = blk_in_path: {
        var it = std.mem.tokenizeScalar(u8, path_env, if (builtin.os.tag == .windows) ';' else ':');
        while (it.next()) |entry| {
            const expanded = try pathenv.expand(arena, entry);
            if (binPathEql(expanded, bin_path)) break :blk_in_path true;
        }
        break :blk_in_path false;
    };
    if (!in_path) errExit("'{s}' is not in the PATH environment variable", .{bin_path});

    // Validate the path is writable.
    switch (try checkBinPath(bin_path)) {
        .ok => {},
        .bad => |reason| errExit("'{s}' is not a valid bin path: {t}", .{ bin_path, reason }),
    }

    try writeBinPath(bin_setting_path, bin_path);
    log.info("bin path set to '{s}'", .{bin_path});
    return 0;
}

const InstallConfig = struct {
    interactive: bool,
    keep_archives: bool,
    allow_overwrite: bool,
    allow_shadow: bool,
    app_data_path: [:0]const u8,
    cache_path: [:0]const u8,
    bin_path: [:0]const u8,
};

fn installPkg(scratch: *Scratch, config: *const InstallConfig, pkg: Pkg) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);
    switch (pkg) {
        .github => |p| try installPkgGithub(scratch, config, p),
        .path => |p| try installPkgPath(scratch, config, @panic("todo: manifest path"), p),
    }
}

const anyzig_version: *const [11]u8 = "v2025_10_15";

fn allocAnyzigPath(allocator: std.mem.Allocator, app_data_path: []const u8, version: *const [11]u8) error{OutOfMemory}![]u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(
        allocator,
        "{s}{c}anyzig-{s}{s}",
        .{
            app_data_path,
            std.fs.path.sep,
            version,
            ext,
        },
    );
}

fn fileExistsAbsolute(path: []const u8) !bool {
    return if (std.fs.accessAbsolute(path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| e,
    };
}

fn versionFromAnyzigExe(anyzig_exe: []const u8) [11]u8 {
    const basename = std.fs.path.basename(anyzig_exe);
    const anyzig_prefix = "anyzig-";
    std.debug.assert(std.mem.startsWith(u8, basename, anyzig_prefix));
    const no_prefix = basename[anyzig_prefix.len..];
    const v = blk: {
        if (builtin.os.tag == .windows) {
            std.debug.assert(std.mem.endsWith(u8, no_prefix, ".exe"));
            break :blk no_prefix[0 .. no_prefix.len - 4];
        }
        break :blk no_prefix;
    };
    std.debug.assert(v.len == 11);
    return v[0..11].*;
}

// Download anyzig if not already present. Uses a lock file to prevent races.
fn ensureAnyzig(
    scratch: *Scratch,
    cache_path: [:0]const u8,
    anyzig_exe: []const u8,
) !void {
    const version = versionFromAnyzigExe(anyzig_exe);
    if (try fileExistsAbsolute(anyzig_exe)) {
        log.info("using existing anyzig at {s}", .{anyzig_exe});
        return;
    }

    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);

    const lock_path = std.fmt.allocPrint(scratch.allocator(), "{s}.lock", .{anyzig_exe}) catch |e| oom(e);
    defer scratch.free(lock_path);

    var lock_file = LockFile.lock(
        lock_path,
    ) catch |err| return reportError("lock '{s}' failed with {t}", .{ lock_path, err });
    defer lock_file.unlock();

    // Re-check after acquiring lock (another process may have completed)
    if (try fileExistsAbsolute(anyzig_exe)) {
        log.info("using existing anyzig at {s}", .{anyzig_exe});
        return;
    }
    errdefer std.fs.deleteFileAbsolute(anyzig_exe) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.err("clean up '{s}' failed with {t}", .{ anyzig_exe, err }),
    };

    const arch = @tagName(builtin.cpu.arch);
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @compileError("unsupported OS for anyzig"),
    };
    const ext = if (builtin.os.tag == .windows) ".zip" else ".tar.gz";

    const asset_url = std.fmt.allocPrint(
        scratch.allocator(),
        "https://github.com/marler8997/anyzig/releases/download/{s}/anyzig-{s}-{s}{s}",
        .{ version, arch, os, ext },
    ) catch |e| oom(e);
    defer scratch.free(asset_url);

    const pkg_cache_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}anyzig-{s}-{s}-{s}",
        .{ cache_path, std.fs.path.sep, version, arch, os },
    ) catch |e| oom(e);
    defer scratch.free(pkg_cache_path);

    var client: std.http.Client = .{ .allocator = scratch.allocator() };
    defer client.deinit();

    try downloadToCache(scratch, &client, asset_url, pkg_cache_path);

    const dest_dir_path = std.fs.path.dirname(anyzig_exe) orelse ".";
    std.fs.cwd().makePath(dest_dir_path) catch |err| return reportError(
        "makePath '{s}' failed with {t}",
        .{ dest_dir_path, err },
    );

    const extract_dir_path = allocTmpPath(scratch.allocator(), "hew-anyzig-{s}", .{version});
    defer scratch.free(extract_dir_path);

    std.fs.deleteTreeAbsolute(extract_dir_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err }),
    };
    std.fs.cwd().makePath(extract_dir_path) catch |err| return reportError(
        "makePath '{s}' failed with {t}",
        .{ extract_dir_path, err },
    );

    const archive_data = std.fs.cwd().readFileAlloc(
        scratch.allocator(),
        pkg_cache_path,
        std.math.maxInt(usize),
    ) catch |err| return reportError("read '{s}' failed with {t}", .{ pkg_cache_path, err });
    defer scratch.free(archive_data);

    {
        var extract_dir = std.fs.openDirAbsolute(extract_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ extract_dir_path, err },
        );
        defer extract_dir.close();

        if (builtin.os.tag == .windows) {
            const zip_file = std.fs.cwd().openFile(pkg_cache_path, .{}) catch |err| return reportError(
                "open '{s}' failed with {t}",
                .{ pkg_cache_path, err },
            );
            defer zip_file.close();
            var zip_read_buf: [4096]u8 = undefined;
            var file_reader: std.fs.File.Reader = .init(zip_file, &zip_read_buf);
            var diagnostics: std.zip.Diagnostics = .{ .allocator = scratch.allocator() };
            defer diagnostics.deinit();
            std.zip.extract(extract_dir, &file_reader, .{ .diagnostics = &diagnostics }) catch |err| return reportError(
                "extract anyzig zip failed with {t}",
                .{err},
            );
            if (diagnostics.root_dir.len > 0) {
                extract_dir.close();
                extract_dir = std.fs.openDirAbsolute(
                    std.fmt.allocPrint(scratch.allocator(), "{s}/{s}", .{ extract_dir_path, diagnostics.root_dir }) catch |e| oom(e),
                    .{},
                ) catch |err| return reportError(
                    "open extracted root dir failed with {t}",
                    .{err},
                );
            }
        } else {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var tar_reader: std.Io.Reader = .fixed(archive_data);
            var decompressor: std.compress.flate.Decompress = .init(&tar_reader, .gzip, &decompress_buf);
            std.tar.pipeToFileSystem(extract_dir, &decompressor.reader, .{}) catch |err| return reportError(
                "extract anyzig failed with {t}",
                .{err},
            );
        }

        var dest_dir = std.fs.openDirAbsolute(dest_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ dest_dir_path, err },
        );
        defer dest_dir.close();
        const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
        const anyzig_basename = std.fs.path.basename(anyzig_exe);
        extract_dir.copyFile(zig_name, dest_dir, anyzig_basename, .{}) catch |err| return reportError(
            "copy anyzig to '{s}' failed with {t}",
            .{ anyzig_exe, err },
        );
        std.debug.assert(try fileExistsAbsolute(anyzig_exe));
    }

    log.info("installed anyzig to {s}", .{anyzig_exe});
    log.info("clean source: rm -rf {s}", .{extract_dir_path});
    std.fs.deleteTreeAbsolute(extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    log.info("clean archive: rm {s}", .{pkg_cache_path});
    std.fs.deleteFileAbsolute(pkg_cache_path) catch |err|
        return reportError("delete '{s}' failed with {t}", .{ pkg_cache_path, err });
}

const GithubArchive = union(enum) {
    rev: struct {
        json: std.ArrayListUnmanaged(u8),
        rev_name: []const u8,
        tarball_url: []const u8,
    },
    tip: struct {
        json: std.ArrayListUnmanaged(u8),
        sha: GitSha,
        tarball_url: []const u8,
    },
    pub fn deinit(archive: *GithubArchive, allocator: std.mem.Allocator) void {
        switch (archive.*) {
            .rev => |*r| r.json.deinit(allocator),
            .tip => |*t| {
                allocator.free(t.tarball_url);
                t.json.deinit(allocator);
            },
        }
        archive.* = undefined;
    }

    pub fn url(archive: *const GithubArchive) []const u8 {
        return switch (archive.*) {
            .rev => |*r| r.tarball_url,
            .tip => |*t| t.tarball_url,
        };
    }
    pub fn fmtUniqueName(archive: *const GithubArchive) FmtUniqueName {
        return FmtUniqueName{ .archive = archive };
    }
    const FmtUniqueName = struct {
        archive: *const GithubArchive,
        pub fn format(n: FmtUniqueName, w: *std.Io.Writer) error{WriteFailed}!void {
            switch (n.archive.*) {
                .rev => |*r| try w.writeAll(r.rev_name),
                .tip => |*t| try t.sha.format(w),
            }
        }
    };
};

fn fetchTip(scratch: *Scratch, allocator: std.mem.Allocator, owner_repo: []const u8, client: *std.http.Client) GithubArchive {
    log.info("fetching tip commit for github:{s}...", .{owner_repo});
    const commit_url = std.fmt.allocPrint(
        scratch.allocator(),
        "https://api.github.com/repos/{s}/commits/HEAD",
        .{owner_repo},
    ) catch |e| oom(e);
    defer scratch.allocator().free(commit_url);
    var timer = timerStart();
    const commit_result = fetchGithubJson(commit_url, client, allocator);
    if (commit_result.status != .ok)
        fetchErrExit(commit_url, commit_result);
    const elapsed: f64 = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    log.info("fetched tip commit JSON in {d:.2} seconds", .{elapsed});
    const sha = switch (parseCommitSha(commit_result.body.items)) {
        .ok => |sha| sha,
        .err => |*err| {
            reportJsonError(scratch, commit_url, commit_result.body.items, err);
            std.process.exit(0xff);
        },
    };
    const tarball_url = std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/tarball/{f}",
        .{ owner_repo, &sha },
    ) catch |e| oom(e);
    errdefer allocator.free(tarball_url);
    return .{ .tip = .{
        .json = commit_result.body,
        .sha = sha,
        .tarball_url = tarball_url,
    } };
}

fn installPkgGithub(scratch: *Scratch, config: *const InstallConfig, pkg: PkgGithub) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);
    var client: std.http.Client = .{ .allocator = scratch.allocator() };
    defer client.deinit();

    var archive: GithubArchive = blk: switch (pkg.commit) {
        .latest_release => {
            log.info("fetching latest release for github:{s}...", .{pkg.owner_repo});
            const release_url = std.fmt.allocPrint(
                scratch.allocator(),
                "https://api.github.com/repos/{s}/releases/latest",
                .{pkg.owner_repo},
            ) catch |e| oom(e);
            defer scratch.allocator().free(release_url);
            var timer = timerStart();
            var fetch_result = fetchGithubJson(release_url, &client, scratch.allocator());
            errdefer fetch_result.body.deinit(scratch.allocator());
            if (fetch_result.status == .ok) {
                const elapsed: f64 = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
                log.info("fetched latest release JSON in {d:.2} seconds", .{elapsed});
                const release = switch (parseRelease(fetch_result.body.items)) {
                    .ok => |release| release,
                    .err => |*err| {
                        reportJsonError(scratch, release_url, fetch_result.body.items, err);
                        std.process.exit(0xff);
                    },
                };
                log.info("latest release is tag {s}", .{release.tag_name});
                break :blk .{ .rev = .{
                    .json = fetch_result.body,
                    .rev_name = release.tag_name,
                    .tarball_url = release.tarball_url,
                } };
            }
            // Only fall back to tags if the releases endpoint returned "Not Found".
            // Other 404s (e.g. repo doesn't exist) should still be fatal.
            const is_no_releases = fetch_result.status == .not_found and
                if (parseMessage(fetch_result.body.items)) |msg| std.mem.eql(u8, msg, "Not Found") else false;
            if (!is_no_releases)
                fetchErrExit(release_url, fetch_result);
            fetch_result.body.deinit(scratch.allocator());

            // No releases found, fall back to latest tag.
            log.info("no releases found, fetching latest tag for github:{s}...", .{pkg.owner_repo});
            const tags_url = std.fmt.allocPrint(
                scratch.allocator(),
                "https://api.github.com/repos/{s}/tags?per_page=1",
                .{pkg.owner_repo},
            ) catch |e| oom(e);
            defer scratch.allocator().free(tags_url);
            timer = timerStart();
            var tags_result = fetchGithubJson(tags_url, &client, scratch.allocator());
            errdefer tags_result.body.deinit(scratch.allocator());
            if (tags_result.status != .ok)
                fetchErrExit(tags_url, tags_result);
            const tags_elapsed: f64 = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
            log.info("fetched latest tag JSON in {d:.2} seconds", .{tags_elapsed});
            const tag_name = switch (parseLatestTag(tags_result.body.items)) {
                .ok => |name| name,
                .empty => {
                    log.info("no tags found either, falling back to tip for github:{s}...", .{pkg.owner_repo});
                    tags_result.body.deinit(scratch.allocator());
                    const tip_archive = fetchTip(scratch, scratch.allocator(), pkg.owner_repo, &client);
                    log.info("tip is commit {f}", .{&tip_archive.tip.sha});
                    break :blk tip_archive;
                },
                .err => |*err| {
                    reportJsonError(scratch, tags_url, tags_result.body.items, err);
                    std.process.exit(0xff);
                },
            };
            log.info("latest tag is {s}", .{tag_name});
            const tarball_url = std.fmt.allocPrint(
                scratch.allocator(),
                "https://api.github.com/repos/{s}/tarball/{s}",
                .{ pkg.owner_repo, tag_name },
            ) catch |e| oom(e);
            break :blk .{ .rev = .{
                .json = tags_result.body,
                .rev_name = tag_name,
                .tarball_url = tarball_url,
            } };
        },
        .rev => |rev| {
            const tarball_url = std.fmt.allocPrint(
                scratch.allocator(),
                "https://api.github.com/repos/{s}/tarball/{s}",
                .{ pkg.owner_repo, rev },
            ) catch |e| oom(e);
            errdefer scratch.allocator().free(tarball_url);
            break :blk .{ .rev = .{
                .json = .{},
                .rev_name = rev,
                .tarball_url = tarball_url,
            } };
        },
        .tip => break :blk fetchTip(scratch, scratch.allocator(), pkg.owner_repo, &client),
    };
    defer archive.deinit(scratch.allocator());

    const manifest_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}manifests{1c}github-{s}-{s}-{f}",
        .{ config.app_data_path, std.fs.path.sep, pkg.owner(), pkg.repo(), archive.fmtUniqueName() },
    ) catch |e| oom(e);
    defer scratch.allocator().free(manifest_path);
    if (std.fs.cwd().readFileAlloc(scratch.allocator(), manifest_path, std.math.maxInt(usize))) |manifest| {
        defer scratch.freeLifo(manifest);
        var line_it = std.mem.tokenizeScalar(u8, manifest, '\n');

        var installed: bool = true;
        while (line_it.next()) |line| {
            switch (parseManifestLine(line)) {
                .bin => |bin| if (!try binInstalled(scratch, config, bin.name, bin.sha256, bin.pdb_sha256)) {
                    installed = false;
                },
            }
        }
        if (installed) {
            std.log.info("{f}: already installed", .{pkg});
            return;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return reportError("read '{s}' failed with {t}", .{ manifest_path, err }),
    }

    const pkg_cache_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}github-{s}-{s}-{f}.tar.gz",
        .{ config.cache_path, std.fs.path.sep, pkg.owner(), pkg.repo(), archive.fmtUniqueName() },
    ) catch |e| oom(e);
    defer scratch.free(pkg_cache_path);

    try downloadToCache(scratch, &client, archive.url(), pkg_cache_path);

    const tarball_data = std.fs.cwd().readFileAlloc(
        scratch.allocator(),
        pkg_cache_path,
        std.math.maxInt(usize),
    ) catch |err| return reportError("read '{s}' failed with {t}", .{ pkg_cache_path, err });
    defer scratch.free(tarball_data);

    const extract_dir_path = allocTmpPath(
        scratch.allocator(),
        "hew-github-{s}-{s}-{f}",
        .{ pkg.owner(), pkg.repo(), archive.fmtUniqueName() },
    );
    defer scratch.free(extract_dir_path);

    std.fs.deleteTreeAbsolute(extract_dir_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, e }),
    };
    std.fs.makeDirAbsolute(extract_dir_path) catch |err| return reportError(
        "create '{s}' failed with {t}",
        .{ extract_dir_path, err },
    );
    {
        var extract_dir = std.fs.openDirAbsolute(extract_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ extract_dir_path, err },
        );
        defer extract_dir.close();

        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var tar_reader: std.Io.Reader = .fixed(tarball_data);
        var decompressor: std.compress.flate.Decompress = .init(&tar_reader, .gzip, &decompress_buf);

        std.tar.pipeToFileSystem(
            extract_dir,
            &decompressor.reader,
            .{ .strip_components = 1 },
        ) catch |err| return reportError("extract tarball failed with {t}", .{err});
        log.info("extracted to {s}", .{extract_dir_path});
        try installPkgPath(scratch, config, manifest_path, extract_dir_path);
    }
    log.info("clean source: rm -rf {s}", .{extract_dir_path});
    std.fs.deleteTreeAbsolute(extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    if (config.keep_archives) {
        log.info("keeping archive: {s}", .{pkg_cache_path});
    } else {
        log.info("clean archive: rm {s}", .{pkg_cache_path});
        std.fs.deleteFileAbsolute(pkg_cache_path) catch |err|
            return reportError("delete '{s}' failed with {t}", .{ pkg_cache_path, err });
    }
}

fn binInstalled(
    scratch: *Scratch,
    config: *const InstallConfig,
    name: []const u8,
    sha256: *const [32]u8,
    pdb_sha256: ?*const [32]u8,
) !bool {
    const expected = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}{s}",
        .{ config.bin_path, std.fs.path.sep, name },
    ) catch |e| oom(e);
    defer scratch.freeLifo(expected);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var which_it = which.Iterator.fromEnv(&path_buf);
    while (try which_it.next(name)) |which_path| {
        if (std.mem.eql(u8, which_path, expected))
            break;
        if (!config.allow_shadow) return reportError(
            "{s} is shadowed by {s} (use --allow-shadow to allow this)",
            .{ expected, which_path },
        );
        std.log.info("{s} is shadowed by {s}", .{ expected, which_path });
    } else {
        std.log.info("{s}: not installed", .{name});
        return false;
    }
    const which_sha256 = try hashFile(std.fs.cwd(), expected);
    if (!std.mem.eql(u8, &which_sha256, sha256)) {
        std.log.info("{s}: installed but with different hash", .{name});
        return false;
    }
    if (pdb_sha256) |expected_pdb| {
        if (!std.ascii.endsWithIgnoreCase(name, ".exe"))
            return reportError("manifest has pdb hash for non-.exe file '{s}'", .{name});
        const stem = name[0 .. name.len - 4];
        const pdb_path = std.fmt.allocPrint(
            scratch.allocator(),
            "{s}{c}{s}.pdb",
            .{ config.bin_path, std.fs.path.sep, stem },
        ) catch |e| oom(e);
        defer scratch.freeLifo(pdb_path);
        const actual_pdb = hashFile(std.fs.cwd(), pdb_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("{s}: pdb not installed", .{pdb_path});
                return false;
            },
            else => return reportError("hash '{s}' failed with {t}", .{ pdb_path, err }),
        };
        if (!std.mem.eql(u8, &actual_pdb, expected_pdb)) {
            std.log.info("{s}: installed but with different hash", .{pdb_path});
            return false;
        }
    }
    return true;
}

fn hashFile(dir: std.fs.Dir, name: []const u8) ![32]u8 {
    var file = try dir.openFile(name, .{});
    defer file.close();
    var hasher = Sha256.init(.{});
    while (true) {
        var read_buf: [4096]u8 = undefined;
        const n = try file.read(&read_buf);
        if (n == 0) break;
        hasher.update(read_buf[0..n]);
    }
    return hasher.finalResult();
}

fn runZigBuild(
    scratch: *Scratch,
    zig_path: []const u8,
    path: []const u8,
    dir: std.fs.Dir,
    mode: enum { fetch, build },
) error{Reported}!void {
    const position = scratch.position();
    defer scratch.restorePosition(position);

    const optimize = "-Doptimize=ReleaseFast";
    const argv: []const []const u8 = switch (mode) {
        .fetch => &.{ zig_path, "build", "install", optimize, "--fetch" },
        .build => &.{ zig_path, "build", "install", optimize },
    };
    const label: []const u8 = switch (mode) {
        .fetch => "zig build install --fetch",
        .build => "zig build install",
    };
    log.info(
        "cd {s} && {s} build install {s}{s}",
        .{ path, zig_path, optimize, switch (mode) {
            .fetch => " --fetch",
            .build => "",
        } },
    );

    var timer = timerStart();
    var child = std.process.Child.init(argv, scratch.allocator());
    child.cwd = path;
    child.cwd_dir = dir;
    child.spawn() catch |err| return reportError("run {s} failed with {t}", .{ label, err });
    const term = child.wait() catch |err| return reportError("{s} wait failed with {t}", .{ label, err });
    const elapsed: f64 = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    log.info("{s} completed in {d:.2} seconds", .{ label, elapsed });
    switch (term) {
        .Exited => |code| if (code != 0) {
            errExit("{s} exited with code {d}", .{ label, code });
        },
        .Signal => |sig| errExit("{s} killed by signal {d}", .{ label, sig }),
        .Stopped => |sig| errExit("{s} stopped by signal {d}", .{ label, sig }),
        .Unknown => |val| errExit("{s} terminated with unknown status {d}", .{ label, val }),
    }
}

fn writeManifest(scratch: *Scratch, manifest_path: []const u8, source_dir: std.fs.Dir) !void {
    var zig_out = source_dir.openDir("zig-out", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => errExit("zig build did not install any files to zig-out", .{}),
        else => return reportError("open zig-out failed with {t}", .{err}),
    };
    defer zig_out.close();

    // Verify only bin/ exists in zig-out
    var zig_out_it = zig_out.iterate();
    while (zig_out_it.next() catch |err| return reportError(
        "iterate zig-out failed with {t}",
        .{err},
    )) |entry| {
        if (std.mem.eql(u8, entry.name, "bin")) {
            if (entry.kind != .directory) return reportError("zig-out/bin is not a directory", .{});
        } else {
            errExit("unexpected entry in zig-out: '{s}' - only bin/ is currently supported", .{entry.name});
        }
    }

    var bin_dir = zig_out.openDir("bin", .{ .iterate = true }) catch |err|
        return reportError("open zig-out/bin failed with {t}", .{err});
    defer bin_dir.close();

    const manifest_dir_path = std.fs.path.dirname(manifest_path) orelse ".";
    std.fs.makeDirAbsolute(manifest_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return reportError("create '{s}' failed with {t}", .{ manifest_dir_path, err }),
    };
    var manifest_dir = std.fs.openDirAbsolute(manifest_dir_path, .{}) catch |err|
        return reportError("open '{s}' failed with {t}", .{ manifest_dir_path, err });
    defer manifest_dir.close();

    const manifest_name = std.fs.path.basename(manifest_path);
    const tmp_name = std.fmt.allocPrint(scratch.allocator(), "{s}.tmp", .{manifest_name}) catch |e| oom(e);
    defer scratch.freeLifo(tmp_name);
    const file = manifest_dir.createFile(tmp_name, .{}) catch |err|
        return reportError("create '{s}/{s}' failed with {t}", .{ manifest_dir_path, tmp_name, err });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);

    var bin_count: usize = 0;
    var bin_it = bin_dir.iterate();
    while (bin_it.next() catch |err| return reportError(
        "iterate zig-out/bin failed with {t}",
        .{err},
    )) |entry| {
        if (entry.kind != .file) continue;
        // PDB files are written as options on their .exe line
        if (std.ascii.endsWithIgnoreCase(entry.name, ".pdb")) continue;
        const hash = hashFile(bin_dir, entry.name) catch |err|
            return reportError("hash zig-out/bin/{s} failed with {t}", .{ entry.name, err });
        writer.interface.print("bin/{s} {x}", .{ entry.name, hash }) catch return writer.err.?;
        if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(entry.name, ".exe")) {
            const stem = entry.name[0 .. entry.name.len - 4];
            var pdb_name_buf: [std.fs.max_name_bytes]u8 = undefined;
            const pdb_name = std.fmt.bufPrint(&pdb_name_buf, "{s}.pdb", .{stem}) catch
                errExit("binary name too long: '{s}'", .{entry.name});
            if (hashFile(bin_dir, pdb_name)) |pdb_hash| {
                writer.interface.print(" pdb={x}", .{pdb_hash}) catch return writer.err.?;
            } else |err| return reportError(
                "hash zig-out/bin/{s} failed with {t}",
                .{ pdb_name, err },
            );
        }
        writer.interface.print("\n", .{}) catch return writer.err.?;
        bin_count += 1;
    }
    writer.interface.flush() catch return writer.err.?;
    if (bin_count == 0) {
        errExit("zig build produced no binaries in zig-out/bin/", .{});
    }

    manifest_dir.rename(tmp_name, manifest_name) catch |err|
        return reportError("rename '{s}' to '{s}' failed with {t}", .{ tmp_name, manifest_name, err });
}

fn installPkgPath(
    scratch: *Scratch,
    config: *const InstallConfig,
    manifest_path: []const u8,
    path: []const u8,
) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);

    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| return reportError(
        "open '{s}' failed with {t}",
        .{ path, err },
    );
    defer dir.close();

    dir.access("build.zig", .{}) catch |err| switch (err) {
        error.FileNotFound => errExit("package at '{s}' has no build.zig", .{path}),
        else => return reportError(
            "access build.zig in '{s}' failed with {t}",
            .{ path, err },
        ),
    };

    const zig_path = allocAnyzigPath(
        scratch.allocator(),
        config.app_data_path,
        anyzig_version,
    ) catch |e| oom(e);
    defer scratch.free(zig_path);
    try ensureAnyzig(scratch, config.cache_path, zig_path);

    try runZigBuild(scratch, zig_path, path, dir, .fetch);
    try runZigBuild(scratch, zig_path, path, dir, .build);

    try writeManifest(scratch, manifest_path, dir);
    std.log.info("wrote manifest to '{s}'", .{manifest_path});

    {
        const manifest = try std.fs.cwd().readFileAlloc(
            scratch.allocator(),
            manifest_path,
            std.math.maxInt(usize),
        );
        defer scratch.freeLifo(manifest);
        var line_it = std.mem.tokenizeScalar(u8, manifest, '\n');
        while (line_it.next()) |line| {
            switch (parseManifestLine(line)) {
                .bin => {},
            }
        }
    }

    std.fs.makeDirAbsolute(config.bin_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return reportError("create '{s}' failed with {t}", .{ config.bin_path, err }),
    };

    // Copy executables from zig-out/bin/ to bin_path
    var zig_out_bin = dir.openDir("zig-out/bin", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn("zig build produced no binaries in zig-out/bin/", .{});
            return;
        },
        else => return reportError("open zig-out/bin failed with {t}", .{err}),
    };
    defer zig_out_bin.close();

    var dest_dir = std.fs.openDirAbsolute(config.bin_path, .{}) catch |err| return reportError(
        "open '{s}' failed with {t}",
        .{ config.bin_path, err },
    );
    defer dest_dir.close();

    var it = zig_out_bin.iterate();
    var install_bin_count: usize = 0;
    while (it.next() catch |err| return reportError(
        "iterate zig-out/bin failed with {t}",
        .{err},
    )) |entry| {
        if (entry.kind != .file) return reportError(
            "unexpected {t} at zig-out/bin/{s}",
            .{ entry.kind, entry.name },
        );
        const kind = binFileKind(entry.name) orelse return reportError(
            "unexpected file '{s}' in zig-out/bin/",
            .{entry.name},
        );
        const kind2: enum { exe } = blk: switch (kind) {
            .pdb => continue, // handled alongside the .exe below
            .exe => break :blk .exe,
            // .data => break :blk .data,
        };

        if (!config.allow_overwrite) {
            const exists: bool = if (dest_dir.access(entry.name, .{})) true else |err| switch (err) {
                error.FileNotFound => false,
                else => return reportError(
                    "access '{s}{c}{s}' failed with {t}",
                    .{ config.bin_path, std.fs.path.sep, entry.name, err },
                ),
            };
            if (exists) {
                if (!config.interactive) return reportError(
                    "'{s}{c}{s}' already exists (use --allow-overwrite or invoke hew interactively)",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                );
                var stderr_buf: [4096]u8 = undefined;
                var stderr = std.fs.File.stderr().writer(&stderr_buf);
                const overwrite = promptYesNo(
                    &stderr.interface,
                    "'{s}{c}{s}' already exists. Overwrite?",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                ) catch |err| switch (err) {
                    error.WriteFailed => return stderr.err.?,
                    else => |e| return e,
                };
                if (!overwrite) {
                    log.info("skipping {s}", .{entry.name});
                    continue;
                }
            }
        }

        copyOverwriteMaybeRunning(scratch, config.interactive, zig_out_bin, entry.name, dest_dir, config.bin_path, entry.name) catch |err| return reportError(
            "copy '{s}' to '{s}' failed with {t}",
            .{ entry.name, config.bin_path, err },
        );
        log.info("installed {s}{c}{s}", .{ config.bin_path, std.fs.path.sep, entry.name });
        install_bin_count += 1;

        // Handle the pdb alongside its exe
        if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(entry.name, ".exe")) {
            const stem = entry.name[0 .. entry.name.len - 4];
            var pdb_name_buf: [std.fs.max_name_bytes]u8 = undefined;
            const pdb_name = std.fmt.bufPrint(&pdb_name_buf, "{s}.pdb", .{stem}) catch errExit(
                "binary name too long: '{s}'",
                .{entry.name},
            );
            if (zig_out_bin.access(pdb_name, .{})) {
                copyOverwriteMaybeRunning(scratch, config.interactive, zig_out_bin, pdb_name, dest_dir, config.bin_path, pdb_name) catch |err| return reportError(
                    "copy '{s}' to '{s}' failed with {t}",
                    .{ pdb_name, config.bin_path, err },
                );
                log.info("installed {s}{c}{s}", .{ config.bin_path, std.fs.path.sep, pdb_name });
                install_bin_count += 1;
            } else |_| {
                // No pdb in source — delete stale pdb in dest if present
                dest_dir.deleteFile(pdb_name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return reportError(
                        "delete '{s}{c}{s}' failed with {t}",
                        .{ config.bin_path, std.fs.path.sep, pdb_name, err },
                    ),
                };
            }
        }

        switch (kind2) {
            // .data => {},
            .exe => {
                const expected = std.fmt.allocPrint(
                    scratch.allocator(),
                    "{s}{c}{s}",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                ) catch |e| oom(e);
                defer scratch.freeLifo(expected);
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                var which_it = which.Iterator.fromEnv(&path_buf);
                while (try which_it.next(entry.name)) |which_path| {
                    if (std.mem.eql(u8, which_path, expected))
                        break;
                    if (!config.allow_shadow) return reportError(
                        "{s} is shadowed by {s} (use --allow-shadow to allow this)",
                        .{ expected, which_path },
                    );
                    std.log.info("{s} is shadowed by {s}", .{ expected, which_path });
                } else return reportError(
                    "installed {s} to {s} but it is not in PATH",
                    .{ entry.name, config.bin_path },
                );
            },
        }
    }
    std.log.info("installed {} file{s} to {s}", .{
        install_bin_count,
        @as([]const u8, if (install_bin_count == 1) "" else "s"),
        config.bin_path,
    });
}

// On Windows you cannot overwrite a file while it's open for execution. If the
// target is our own running executable, try to rename it out of the way
// automatically (TMPDIR first, then same-dir); otherwise prompt the user.
fn copyOverwriteMaybeRunning(
    scratch: *Scratch,
    interactive: bool,
    src_dir: std.fs.Dir,
    src_name: []const u8,
    dest_dir: std.fs.Dir,
    dest_dir_path: []const u8,
    dest_name: []const u8,
) !void {
    while (true) {
        src_dir.copyFile(src_name, dest_dir, dest_name, .{}) catch |err| switch (err) {
            error.AccessDenied => |copy_file_error| if (builtin.os.tag != .windows) return err else {
                const scratch_pos = scratch.position();
                defer scratch.restorePosition(scratch_pos);
                const abs_dest_path = std.fmt.allocPrint(
                    scratch.allocator(),
                    "{s}{c}{s}",
                    .{ dest_dir_path, std.fs.path.sep, dest_name },
                ) catch |e| oom(e);
                if (try isSelfExe(abs_dest_path)) {
                    if (try tryRenameOutOfWay(scratch, dest_dir, abs_dest_path, dest_dir_path, dest_name)) continue;
                    // Auto-fallback exhausted; fall through to prompt.
                }
                if (!interactive) return copy_file_error;
                switch (try promptRunningFileConflict(dest_dir_path, dest_name)) {
                    .cancel => errExit("install cancelled", .{}),
                    .rename => {
                        var backup_buf: [std.fs.max_name_bytes]u8 = undefined;
                        const backup_name = std.fmt.bufPrint(&backup_buf, "{s}.deleteme", .{dest_name}) catch
                            errExit("name too long: '{s}.deleteme'", .{dest_name});
                        dest_dir.deleteFile(backup_name) catch |e| switch (e) {
                            error.FileNotFound => {},
                            error.AccessDenied => {
                                log.err("delete existing '{s}{c}{s}' failed with {t}", .{ dest_dir_path, std.fs.path.sep, backup_name, e });
                                continue;
                            },
                            else => return e,
                        };
                        dest_dir.rename(dest_name, backup_name) catch |e| switch (e) {
                            error.AccessDenied => {
                                log.err("rename '{s}{c}{s}' to '{s}' failed with {t}", .{ dest_dir_path, std.fs.path.sep, dest_name, backup_name, e });
                                continue;
                            },
                            else => return e,
                        };
                        continue;
                    },
                    .retry => continue,
                }
            },
            else => return err,
        };
        return;
    }
}

fn isSelfExe(abs_target_path: []const u8) !bool {
    var self_raw_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_raw = try std.fs.selfExePath(&self_raw_buf);
    var self_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_real = try std.posix.realpath(self_raw, &self_real_buf);

    var target_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_real = std.posix.realpath(abs_target_path, &target_real_buf) catch |err| switch (err) {
        // Target vanished between copy attempt and now — definitely not us.
        error.FileNotFound => return false,
        else => |e| return e,
    };

    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(self_real, target_real);
    return std.mem.eql(u8, self_real, target_real);
}

/// Try TMPDIR rename, then same-dir `.deleteme` rename. Returns true if the
/// file was moved out of the way (caller should retry the copy).
fn tryRenameOutOfWay(
    scratch: *Scratch,
    dest_dir: std.fs.Dir,
    abs_src_path: []const u8,
    dest_dir_path: []const u8,
    dest_name: []const u8,
) !bool {
    const tmp_path = allocTmpPath(scratch.allocator(), "hew-{s}.deleteme", .{dest_name});
    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {}, // stale copy still locked; rename will fall through below
    };
    if (std.fs.renameAbsolute(abs_src_path, tmp_path)) {
        log.info("renamed '{s}' to '{s}'", .{ abs_src_path, tmp_path });
        return true;
    } else |err| switch (err) {
        error.RenameAcrossMountPoints => {}, // fall through to same-dir
        else => return err,
    }

    var backup_buf: [std.fs.max_name_bytes]u8 = undefined;
    const backup_name = std.fmt.bufPrint(&backup_buf, "{s}.deleteme", .{dest_name}) catch
        errExit("name too long: '{s}.deleteme'", .{dest_name});
    dest_dir.deleteFile(backup_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return false, // existing backup can't be cleared; let prompt handle it
    };
    dest_dir.rename(dest_name, backup_name) catch return false;
    log.info("renamed '{s}' to '{s}{c}{s}'", .{ abs_src_path, dest_dir_path, std.fs.path.sep, backup_name });
    return true;
}

const RunningFileChoice = enum { cancel, rename, retry };

fn promptRunningFileConflict(dest_dir_path: []const u8, dest_name: []const u8) !RunningFileChoice {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    const w = &stderr.interface;
    w.print(
        \\'{s}{c}{s}' cannot be overwritten (file is in use, e.g. a running executable).
        \\  0) cancel
        \\  1) rename existing file to '{s}.deleteme' and install new file
        \\  2) retry (choose after you've removed/stopped the blocker yourself)
        \\
    , .{ dest_dir_path, std.fs.path.sep, dest_name, dest_name }) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
    };
    const choice = promptNumber(w, "choose", 2) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
        else => |e| return e,
    };
    return switch (choice) {
        0 => .cancel,
        1 => .rename,
        2 => .retry,
        else => unreachable,
    };
}

const ManifestLine = union(enum) {
    bin: struct {
        name: []const u8,
        sha256: *const [32]u8,
        pdb_sha256: ?*const [32]u8,
    },
};
fn parseManifestLine(line: []const u8) ManifestLine {
    if (std.mem.startsWith(u8, line, "bin/")) {
        const rest = line["bin/".len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse
            errExit("malformed manifest line, missing hash: '{s}'", .{line});
        const name = rest[0..space];
        const after_name = rest[space + 1 ..];

        // Parse the hex hash (64 hex chars = 32 bytes)
        if (after_name.len < 64)
            errExit("malformed manifest line, bad hash length: '{s}'", .{line});
        const hash_hex = after_name[0..64];
        const dest: *[32]u8 = @constCast(hash_hex[0..32]);
        _ = std.fmt.hexToBytes(dest, hash_hex) catch
            errExit("malformed manifest line, invalid hex: '{s}'", .{line});

        // Parse optional key=value pairs
        var pdb_sha256: ?*const [32]u8 = null;
        var opts = after_name[64..];
        while (opts.len > 0 and opts[0] == ' ') {
            opts = opts[1..];
            const eq = std.mem.indexOfScalar(u8, opts, '=') orelse
                errExit("malformed manifest option, missing '=': '{s}'", .{line});
            const key = opts[0..eq];
            const val_start = opts[eq + 1 ..];
            if (std.mem.eql(u8, key, "pdb")) {
                if (val_start.len < 64)
                    errExit("malformed manifest line, bad pdb hash length: '{s}'", .{line});
                const pdb_hex = val_start[0..64];
                const pdb_dest: *[32]u8 = @constCast(pdb_hex[0..32]);
                _ = std.fmt.hexToBytes(pdb_dest, pdb_hex) catch
                    errExit("malformed manifest line, invalid pdb hex: '{s}'", .{line});
                pdb_sha256 = pdb_dest;
                opts = val_start[64..];
            } else {
                errExit("unknown manifest option '{s}': '{s}'", .{ key, line });
            }
        }

        return .{ .bin = .{ .name = name, .sha256 = dest, .pdb_sha256 = pdb_sha256 } };
    }
    errExit("malformed manifest line: '{s}'", .{line});
}

const Release = struct {
    tag_name: []const u8,
    tarball_url: []const u8,
};

const bearer_prefix = "Bearer ";
const github_auth_buf_len = bearer_prefix.len + 256;

fn isGithubUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = (uri.host orelse return false).percent_encoded;
    return std.mem.eql(u8, host, "github.com") or
        std.mem.endsWith(u8, host, ".github.com");
}

var github_auth_logged: std.atomic.Value(bool) = .init(false);

fn githubAuthHeader(buf: *[github_auth_buf_len]u8, url: []const u8) std.http.Client.Request.Headers.Value {
    if (!isGithubUrl(url)) return .default;
    const dest = buf[bearer_prefix.len..];
    const token_len, const env_name = if (builtin.os.tag == .windows) blk: {
        if (getEnvWindows(L("GH_TOKEN"), dest)) |len| break :blk .{ len, "GH_TOKEN" };
        if (getEnvWindows(L("GITHUB_TOKEN"), dest)) |len| break :blk .{ len, "GITHUB_TOKEN" };
        break :blk .{ @as(usize, 0), @as([]const u8, "none") };
    } else blk: {
        if (std.posix.getenv("GH_TOKEN")) |token| {
            if (token.len > dest.len) errExit("GH_TOKEN too long", .{});
            @memcpy(dest[0..token.len], token);
            break :blk .{ token.len, "GH_TOKEN" };
        }
        if (std.posix.getenv("GITHUB_TOKEN")) |token| {
            if (token.len > dest.len) errExit("GITHUB_TOKEN too long", .{});
            @memcpy(dest[0..token.len], token);
            break :blk .{ token.len, "GITHUB_TOKEN" };
        }
        break :blk .{ @as(usize, 0), @as([]const u8, "none") };
    };
    if (!github_auth_logged.swap(true, .monotonic))
        log.info("github auth: {s}", .{env_name});
    if (token_len == 0) return .default;
    @memcpy(buf[0..bearer_prefix.len], bearer_prefix);
    return .{ .override = buf[0 .. bearer_prefix.len + token_len] };
}

const FetchResult = struct {
    status: std.http.Status,
    body: std.ArrayListUnmanaged(u8),
};

fn fetchGithubJson(url: []const u8, client: *std.http.Client, allocator: std.mem.Allocator) FetchResult {
    var github_auth_buf: [github_auth_buf_len]u8 = undefined;

    var attempt_counter: u8 = 0;
    while (true) : (attempt_counter += 1) {
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .headers = .{
                .user_agent = .{ .override = "hew/0.0.1" },
                .authorization = githubAuthHeader(&github_auth_buf, url),
            },
            .response_writer = &response_body.writer,
        }) catch |err| {
            errExit("fetch '{s}' failed with {t}", .{ url, err });
        };
        if (result.status == .too_many_requests and attempt_counter < rate_limit_retries) {
            retryAfterRateLimit(url, attempt_counter);
            continue;
        }
        return .{ .status = result.status, .body = response_body.toArrayList() };
    }
}

const rate_limit_retries = 3;
const rate_limit_delays_s = [rate_limit_retries]u64{ 5, 30, 60 };

fn retryAfterRateLimit(url: []const u8, attempt_counter: u8) void {
    const delay_s = rate_limit_delays_s[attempt_counter];
    log.warn("GET {s} returned 429 Too Many Requests, retrying in {d} seconds...", .{ url, delay_s });
    std.Thread.sleep(delay_s * std.time.ns_per_s);
}

fn fetchErrExit(url: []const u8, result: FetchResult) noreturn {
    if (result.body.items.len > 0) {
        const dashes = "-" ** 40;
        log.err("GET {s} returned status {d} and the following {d}-byte response:\n" ++ dashes ++ "\n{s}\n" ++ dashes, .{ url, @intFromEnum(result.status), result.body.items.len, result.body.items });
    } else {
        log.err("GET {s} returned status {d} with no response body", .{ url, @intFromEnum(result.status) });
    }
    std.process.exit(0xff);
}

const ParseJsonError = struct {
    at: usize,
    why: Why,
    const Why = union(enum) {
        unexpected_token: struct { expected: [:0]const u8, got: json.Token.Tag },
        invalid_value,
        invalid_git_sha: []const u8,
        missing_field: [:0]const u8,
    };

    pub fn fmt(err: *const ParseJsonError, text: []const u8) Fmt {
        return .{ .err = err, .text = text };
    }
    pub const Fmt = struct {
        err: *const ParseJsonError,
        text: []const u8,
        pub fn format(f: Fmt, writer: *std.Io.Writer) error{WriteFailed}!void {
            const lc = getLineCol(f.text, f.err.at);
            try writer.print("{d}:{d}: ", .{ lc[0], lc[1] });
            switch (f.err.why) {
                .unexpected_token => |u| try writer.print("expected {s}, got {s}", .{ u.expected, u.got.desc() }),
                .invalid_value => try writer.writeAll("invalid JSON value"),
                .invalid_git_sha => |v| try writer.print("invalid git sha: \"{s}\"", .{v}),
                .missing_field => |name| try writer.print("missing required field \"{s}\"", .{name}),
            }
        }
    };
};

fn getLineCol(text: []const u8, offset: usize) struct { usize, usize } {
    std.debug.assert(offset <= text.len);
    var line: usize = 1;
    var col: usize = 1;
    for (text[0..offset]) |char| switch (char) {
        '\n' => {
            line += 1;
            col = 1;
        },
        else => col += 1,
    };
    return .{ line, col };
}

fn reportJsonError(
    scratch: *Scratch,
    url: []const u8,
    json_content: []const u8,
    err: *const ParseJsonError,
) void {
    const position = scratch.position();
    defer std.debug.assert(position == scratch.position());

    log.err("parse JSON from '{s}' failed", .{url});

    const url_path = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const ext = ".json";
    const tmp_path = allocTmpPath(scratch.allocator(), "hew-{s}{s}", .{ url_path, ext });
    defer scratch.freeLifo(tmp_path);

    const name_start = tmp_path.len - ext.len - url_path.len;
    for (tmp_path[name_start..]) |*c| {
        if (c.* == '/') c.* = '-';
    }

    const saved = blk: {
        const f = std.fs.createFileAbsolute(tmp_path, .{}) catch |save_err| {
            log.warn("save JSON to '{s}' failed with {t}", .{ tmp_path, save_err });
            break :blk false;
        };
        defer f.close();
        f.writeAll(json_content) catch |save_err| {
            log.warn("write JSON to '{s}' failed with {t}", .{ tmp_path, save_err });
            break :blk false;
        };
        break :blk true;
    };

    const file_path: []const u8 = if (saved) tmp_path else "";
    const file_sep: []const u8 = if (saved) ":" else "";
    var buffer: [200]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    stderr.print("{s}{s}{f}\n", .{ file_path, file_sep, err.fmt(json_content) }) catch @panic("print to stderr failed");
}

/// Parse the "message" field from a JSON object like {"message":"Not Found",...}
fn parseMessage(text: []const u8) ?[]const u8 {
    const open = json.lex(text, 0);
    if (open.tag != .@"{") return null;
    var next_field = open.end;
    while (true) {
        const after_sep = blk: {
            const token = json.lex(text, next_field);
            if (token.tag == .@"}") break;
            if (next_field != open.end) {
                if (token.tag != .@",") return null;
                break :blk token.end;
            }
            break :blk next_field;
        };
        const key_token = json.lex(text, after_sep);
        if (key_token.tag != .string) return null;
        const key = text[key_token.start + 1 .. key_token.end - 1];
        const colon = json.lex(text, key_token.end);
        if (colon.tag != .@":") return null;
        if (std.mem.eql(u8, key, "message")) {
            const val = json.lex(text, colon.end);
            if (val.tag != .string) return null;
            return text[val.start + 1 .. val.end - 1];
        }
        next_field = json.skipValue(text, colon.end) orelse return null;
    }
    return null;
}

const ParseLatestTagResult = union(enum) {
    ok: []const u8,
    empty,
    err: ParseJsonError,
    pub fn unexpected(got: json.Token, expected: [:0]const u8) ParseLatestTagResult {
        return .{ .err = .{ .at = got.start, .why = .{ .unexpected_token = .{ .expected = expected, .got = got.tag } } } };
    }
};

/// Parse the "name" field from the first element of a JSON array: [{"name":"tag",...},...]
fn parseLatestTag(text: []const u8) ParseLatestTagResult {
    const open = json.lex(text, 0);
    if (open.tag != .@"[") return .unexpected(open, "\"[\"");

    // Check for empty array.
    const first = json.lex(text, open.end);
    if (first.tag == .@"]") return .empty;

    // Expect first element to be an object.
    if (first.tag != .@"{") return .unexpected(first, "\"{\"");

    var next_field = first.end;
    while (true) {
        const after_sep = blk: {
            const token = json.lex(text, next_field);
            if (token.tag == .@"}") break;
            if (next_field != first.end) {
                if (token.tag != .@",") return .unexpected(token, "\",\" or \"}\"");
                break :blk token.end;
            }
            break :blk next_field;
        };

        const key_token = json.lex(text, after_sep);
        if (key_token.tag != .string) return .unexpected(key_token, "field key string");
        const key = text[key_token.start + 1 .. key_token.end - 1];

        const colon_end = blk: {
            const colon = json.lex(text, key_token.end);
            if (colon.tag != .@":") return .unexpected(colon, "\":\"");
            break :blk colon.end;
        };

        if (std.mem.eql(u8, key, "name")) {
            const val = json.lex(text, colon_end);
            if (val.tag != .string) return .unexpected(val, "string value");
            return .{ .ok = text[val.start + 1 .. val.end - 1] };
        }
        next_field = json.skipValue(text, colon_end) orelse return .{ .err = .{ .at = colon_end, .why = .invalid_value } };
    }

    return .{ .err = .{ .at = 0, .why = .{ .missing_field = "name" } } };
}

const ParseResult = union(enum) {
    ok: Release,
    err: ParseJsonError,
    pub fn unexpected(got: json.Token, expected: [:0]const u8) ParseResult {
        return .{ .err = .{ .at = got.start, .why = .{ .unexpected_token = .{ .expected = expected, .got = got.tag } } } };
    }
};
fn parseRelease(text: []const u8) ParseResult {
    const open_end = blk: {
        const open = json.lex(text, 0);
        if (open.tag != .@"{") return .{ .err = .{ .at = open.start, .why = .{ .unexpected_token = .{ .expected = "\"{\"", .got = open.tag } } } };
        break :blk open.end;
    };

    var tag_name: ?[]const u8 = null;
    var tarball_url: ?[]const u8 = null;

    var next_field = open_end;
    while (true) {
        const after_sep = blk: {
            const token = json.lex(text, next_field);
            if (token.tag == .@"}") break;
            if (next_field != open_end) {
                if (token.tag != .@",") return .unexpected(token, "\",\" or \"}\"");
                break :blk token.end;
            }
            break :blk next_field;
        };

        const key_token = json.lex(text, after_sep);
        if (key_token.tag != .string) return .unexpected(key_token, "field key string");
        const key = text[key_token.start + 1 .. key_token.end - 1];

        const colon_end = blk: {
            const colon = json.lex(text, key_token.end);
            if (colon.tag != .@":") return .unexpected(colon, "\":\"");
            break :blk colon.end;
        };

        const target = if (std.mem.eql(u8, key, "tag_name"))
            &tag_name
        else if (std.mem.eql(u8, key, "tarball_url"))
            &tarball_url
        else
            null;

        if (target) |t| {
            const val = json.lex(text, colon_end);
            if (val.tag != .string) return .unexpected(val, "string value");
            t.* = text[val.start + 1 .. val.end - 1];
            next_field = val.end;
        } else {
            next_field = json.skipValue(text, colon_end) orelse return .{ .err = .{ .at = colon_end, .why = .invalid_value } };
        }
    }

    return .{ .ok = .{
        .tag_name = tag_name orelse return .{ .err = .{ .at = 0, .why = .{ .missing_field = "tag_name" } } },
        .tarball_url = tarball_url orelse return .{ .err = .{ .at = 0, .why = .{ .missing_field = "tarball_url" } } },
    } };
}

const ParseCommitShaResult = union(enum) {
    ok: GitSha,
    err: ParseJsonError,
    pub fn unexpected(got: json.Token, expected: [:0]const u8) ParseCommitShaResult {
        return .{ .err = .{ .at = got.start, .why = .{ .unexpected_token = .{ .expected = expected, .got = got.tag } } } };
    }
};

fn parseCommitSha(text: []const u8) ParseCommitShaResult {
    const open_end = blk: {
        const open = json.lex(text, 0);
        if (open.tag != .@"{") return .{ .err = .{ .at = open.start, .why = .{ .unexpected_token = .{ .expected = "\"{\"", .got = open.tag } } } };
        break :blk open.end;
    };

    var sha: ?GitSha = null;

    var next_field = open_end;
    while (true) {
        const after_sep = blk: {
            const token = json.lex(text, next_field);
            if (token.tag == .@"}") break;
            if (next_field != open_end) {
                if (token.tag != .@",") return .unexpected(token, "\",\" or \"}\"");
                break :blk token.end;
            }
            break :blk next_field;
        };

        const key_token = json.lex(text, after_sep);
        if (key_token.tag != .string) return .unexpected(key_token, "field key string");
        const key = text[key_token.start + 1 .. key_token.end - 1];

        const colon_end = blk: {
            const colon = json.lex(text, key_token.end);
            if (colon.tag != .@":") return .unexpected(colon, "\":\"");
            break :blk colon.end;
        };

        if (std.mem.eql(u8, key, "sha")) {
            const val = json.lex(text, colon_end);
            if (val.tag != .string) return .unexpected(val, "string value");
            const hex = text[val.start + 1 .. val.end - 1];
            if (hex.len != 40) return .{ .err = .{ .at = val.start, .why = .{ .invalid_git_sha = hex } } };
            sha = GitSha.fromHex(hex[0..40]) orelse return .{ .err = .{ .at = val.start, .why = .{ .invalid_git_sha = hex } } };
            next_field = val.end;
        } else {
            next_field = json.skipValue(text, colon_end) orelse return .{ .err = .{ .at = colon_end, .why = .invalid_value } };
        }
    }

    return .{ .ok = sha orelse return .{ .err = .{ .at = 0, .why = .{ .missing_field = "sha" } } } };
}

fn downloadToCache(scratch: *Scratch, client: *std.http.Client, url: []const u8, pkg_cache_path: []const u8) error{Reported}!void {
    const lock_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}.lock",
        .{pkg_cache_path},
    ) catch |e| oom(e);
    defer scratch.free(lock_path);

    var lock_file = LockFile.lock(lock_path) catch |err| return reportError(
        "lock '{s}' failed with {t}",
        .{ lock_path, err },
    );
    defer lock_file.unlock();

    const cached: bool = if (std.fs.accessAbsolute(pkg_cache_path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => return reportError("access '{s}' failed with {t}", .{ pkg_cache_path, err }),
    };
    if (cached) {
        log.info("using cached {s}", .{pkg_cache_path});
    } else {
        log.info("downloading {s}...", .{url});
        const downloading_path = std.fmt.allocPrint(
            scratch.allocator(),
            "{s}.downloading",
            .{pkg_cache_path},
        ) catch |e| oom(e);
        defer scratch.free(downloading_path);

        errdefer std.fs.deleteFileAbsolute(downloading_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("clean up '{s}' failed with {t}", .{ downloading_path, err }),
        };
        {
            const download_file = std.fs.createFileAbsolute(downloading_path, .{}) catch |err| return reportError(
                "create '{s}' failed with {t}",
                .{ downloading_path, err },
            );
            defer download_file.close();
            var download_buf: [4096]u8 = undefined;
            var file_writer = download_file.writer(&download_buf);
            var auth_buf: [github_auth_buf_len]u8 = undefined;
            const result = client.fetch(.{
                .location = .{ .url = url },
                .headers = .{
                    .user_agent = .{ .override = "hew/0.0.1" },
                    .authorization = githubAuthHeader(&auth_buf, url),
                },
                .response_writer = &file_writer.interface,
            }) catch |err| switch (err) {
                error.WriteFailed => return reportError(
                    "write '{s}' failed with {t}",
                    .{ downloading_path, file_writer.err.? },
                ),
                else => errExit("download '{s}' failed with {t}", .{ url, err }),
            };
            file_writer.interface.flush() catch return reportError(
                "flush '{s}' failed with {t}",
                .{ downloading_path, file_writer.err.? },
            );
            if (result.status != .ok) {
                download_file.close();
                const body: ?[]const u8 = blk: {
                    const f = std.fs.openFileAbsolute(downloading_path, .{}) catch |err| {
                        log.warn("failed to open error response file '{s}': {t}", .{ downloading_path, err });
                        break :blk null;
                    };
                    defer f.close();
                    break :blk f.readToEndAlloc(scratch.allocator(), 100 * 1024 * 1024) catch |err| {
                        log.warn("failed to read error response file '{s}': {t}", .{ downloading_path, err });
                        break :blk null;
                    };
                };
                const dashes = "-" ** 40;
                if (body) |b| {
                    log.err("GET {s} returned status {d} and the following {d}-byte response:\n" ++ dashes ++ "\n{s}\n" ++ dashes, .{ url, @intFromEnum(result.status), b.len, b });
                } else {
                    log.err("GET {s} returned status {d}", .{ url, @intFromEnum(result.status) });
                }
                std.process.exit(0xff);
            }
        }

        std.fs.renameAbsolute(downloading_path, pkg_cache_path) catch |err| return reportError(
            "rename '{s}' to '{s}' failed with {t}",
            .{ downloading_path, pkg_cache_path, err },
        );
        log.info("cached to {s}", .{pkg_cache_path});
    }
}

fn allocTmpPath(allocator: std.mem.Allocator, comptime sub_path_fmt: []const u8, sub_path_args: anytype) []u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_len = blk: {
        if (builtin.os.tag == .windows) {
            if (getEnvWindows(L("TEMP"), &buf)) |len| break :blk len;
            if (getEnvWindows(L("TMP"), &buf)) |len| break :blk len;
        }

        const str = if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else (std.posix.getenv("TMPDIR") orelse "/tmp");
        if (str.len > buf.len) std.debug.panic("TMPDIR environment variable too long (cannot exceed {d})", .{buf.len});
        @memcpy(buf[0..str.len], str);
        break :blk str.len;
    };
    const trimmed = blk: {
        var trimmed = prefix_len;
        while (trimmed > 0 and std.fs.path.isSep(buf[trimmed - 1])) {
            trimmed -= 1;
        }
        break :blk trimmed;
    };
    var fbs: std.io.FixedBufferStream([]u8) = .{ .buffer = &buf, .pos = trimmed };
    const writer = fbs.writer();
    writer.print(std.fs.path.sep_str ++ sub_path_fmt, sub_path_args) catch @panic("tmp path too long");
    return allocator.dupe(u8, fbs.getWritten()) catch |e| oom(e);
}

fn getEnvWindows(comptime key: [:0]const u16, buf: []u8) ?usize {
    const value_w = std.process.getenvW(key) orelse return null;
    const required = std.unicode.calcWtf8Len(value_w);
    if (required > buf.len) std.debug.panic(
        "environment variable '{f}' too long (cannot exceed {d} but is {d})",
        .{ std.unicode.fmtUtf16Le(key), buf.len, required },
    );
    return std.unicode.wtf16LeToWtf8(buf, value_w);
}

// A scratch allocator backed by an arena. Supports save/restore of position
// so it doesn't permanently grow.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(a: std.mem.Allocator) Scratch {
        return .{ .arena = .init(a) };
    }

    pub fn allocator(scratch: *Scratch) std.mem.Allocator {
        return scratch.arena.allocator();
    }

    pub fn position(scratch: *Scratch) usize {
        return scratch.arena.state.end_index;
    }

    pub fn restorePosition(scratch: *Scratch, p: usize) void {
        scratch.arena.state.end_index = p;
    }

    pub fn freeLifo(scratch: *Scratch, memory: anytype) void {
        const p = scratch.position();
        scratch.arena.allocator().free(memory);
        std.debug.assert(p != scratch.position());
    }
    pub fn free(scratch: *Scratch, memory: anytype) void {
        scratch.arena.allocator().free(memory);
    }
};

fn allocAppDataPath(allocator: std.mem.Allocator) [:0]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home_dir = std.posix.getenv("HOME") orelse errExit("no HOME", .{});
            return std.fs.path.joinZ(
                allocator,
                &[_][]const u8{ home_dir, "Library", "Application Support", "hew" },
            ) catch |e| oom(e);
        },
        .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos, .serenity => {
            if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
                if (xdg.len > 0) return std.fs.path.joinZ(allocator, &.{ xdg, "hew" }) catch |e| oom(e);
            }
            if (std.posix.getenv("HOME")) |home| return std.fs.path.joinZ(
                allocator,
                &.{ home, ".local", "share", "hew" },
            ) catch |e| oom(e);
            errExit("no HOME nor XDG_DATA_HOME", .{});
        },
        .windows => {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const app_data_len = getEnvWindows(L("LOCALAPPDATA"), &path_buf) orelse errExit("missing LOCALAPPDATA environment variable", .{});
            const trimmed = blk: {
                var trimmed = app_data_len;
                while (trimmed > 0 and std.fs.path.isSep(path_buf[trimmed - 1])) {
                    trimmed -= 1;
                }
                break :blk trimmed;
            };
            return std.mem.concatWithSentinel(
                allocator,
                u8,
                &.{ path_buf[0..trimmed], "\\hew" },
                0,
            ) catch |e| oom(e);
        },
        else => |os| @compileError("unsupported os " ++ @tagName(os)),
    }
}

fn allocCachePath(allocator: std.mem.Allocator, app_data_path: [:0]const u8) [:0]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.path.joinZ(allocator, &.{ app_data_path, "cache", "p" }) catch |e| oom(e);
    }
    if (std.posix.getenv("XDG_CACHE_HOME")) |xdg| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/hew/p", .{xdg}, 0) catch |e| oom(e);
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/.cache/hew/p", .{home}, 0) catch |e| oom(e);
    }
    errExit("neither XDG_CACHE_HOME nor HOME is set", .{});
}

fn allocBinPath(
    allocator: std.mem.Allocator,
    scratch: *Scratch,
    interactive: bool,
    app_data_path: []const u8,
) ![:0]const u8 {
    const scratch_pos = scratch.position();
    defer std.debug.assert(scratch_pos == scratch.position());

    var bin_setting_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_setting_path = std.fmt.bufPrint(
        &bin_setting_path_buf,
        "{s}{c}{s}",
        .{ app_data_path, std.fs.path.sep, "binpath" },
    ) catch @panic("app data path too long");

    var bin_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try readBinPath(bin_setting_path, &bin_path_buf)) |stored|
        return allocator.dupeZ(u8, stored) catch |e| oom(e);

    if (!interactive) errExit("install bin path is not configured and --non-interactive has been set", .{});

    const path_env = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => errExit("no valid install directory (PATH is empty)", .{}),
            error.OutOfMemory => |e| oom(e),
            error.InvalidWtf8 => errExit("PATH is invalid wtf8", .{}),
        }
    else
        std.posix.getenv("PATH") orelse "";

    const path_env_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const path_env_count = blk: {
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path_env, path_env_sep);
        while (it.next()) |_| {
            count += 1;
        }
        break :blk count;
    };

    if (path_env_count == 0) errExit("no valid install directory (PATH is empty)", .{});

    var entries: std.ArrayList([]const u8) = .{};
    defer {
        var it = std.mem.reverseIterator(entries.items);
        while (it.next()) |entry| {
            scratch.freeLifo(entry);
        }
        entries.deinit(scratch.allocator());
    }
    try entries.ensureTotalCapacity(scratch.allocator(), path_env_count);

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    const w = &stderr.interface;

    w.print("checking PATH for potential install directories...\n", .{}) catch return stderr.err.?;

    {
        var it = std.mem.tokenizeScalar(u8, path_env, if (builtin.os.tag == .windows) ';' else ':');
        while (it.next()) |entry| {
            const expanded = try pathenv.expand(scratch.allocator(), entry);
            var expanded_owned = true;
            defer if (expanded_owned) scratch.allocator().free(expanded);

            const is_duplicate = blk: {
                for (entries.items) |existing| {
                    if (std.mem.eql(u8, existing, expanded)) break :blk true;
                }
                break :blk false;
            };
            if (is_duplicate) continue;

            switch (try checkBinPath(expanded)) {
                .ok => {
                    entries.appendAssumeCapacity(expanded);
                    expanded_owned = false;
                },
                .bad => |reason| w.print("ignoring '{s}'{f} ({t})\n", .{
                    expanded, fmtExpanded(entry, expanded), reason,
                }) catch return stderr.err.?,
            }
        }
    }

    if (entries.items.len == 0) errExit("none of the directories in PATH can be used to install hew cli tools.  Add one and try again.", .{});

    w.writeAll("0: [cancel]\n") catch return stderr.err.?;
    for (entries.items, 0..) |entry, i| {
        w.print("{d}: {s}\n", .{ i + 1, entry }) catch return stderr.err.?;
    }
    const selection = promptNumber(
        &stderr.interface,
        "Where should hew install cli tools?",
        entries.items.len,
    ) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
        else => |e| return e,
    };
    if (selection == 0) errExit("user cancelled", .{});
    const selected_path = entries.items[selection - 1];

    try writeBinPath(bin_setting_path, selected_path);

    {
        // Read it back to verify.
        var verify_buf: [std.fs.max_path_bytes]u8 = undefined;
        const readback = (try readBinPath(bin_setting_path, &verify_buf)) orelse
            return reportError("verification failed: bin setting file '{s}' not found after writing", .{bin_setting_path});
        if (!std.mem.eql(u8, readback, selected_path))
            return reportError("verification failed: wrote '{s}' but read back '{s}'", .{ selected_path, readback });
    }

    return allocator.dupeZ(u8, selected_path) catch |e| oom(e);
}

fn readBinPath(bin_setting_path: []const u8, buf: *[std.fs.max_path_bytes]u8) error{Reported}!?[:0]const u8 {
    const file = std.fs.openFileAbsolute(bin_setting_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return reportError("open '{s}' failed with {t}", .{ bin_setting_path, e }),
    };
    defer file.close();
    const len = file.readAll(buf) catch |e| return reportError(
        "read '{s}' failed with {t}",
        .{ bin_setting_path, e },
    );
    if (len == 0) return reportError("bin setting file '{s}' is empty", .{bin_setting_path});
    if (len >= buf.len) return reportError("bin path in '{s}' is too long", .{bin_setting_path});
    buf[len] = 0;
    const stored = buf[0..len :0];
    if (!isBinPathNormalized(stored))
        return reportError("stored bin path '{s}' in '{s}' contains forward slashes", .{ stored, bin_setting_path });
    return stored;
}

fn writeBinPath(bin_setting_path: []const u8, bin_path: []const u8) error{Reported}!void {
    if (std.fs.path.dirname(bin_setting_path)) |d| std.fs.cwd().makePath(d) catch |e| return reportError(
        "make path '{s}' failed with {t}",
        .{ d, e },
    );
    // TODO: should we write it to a temp file first and then rename?
    const file = std.fs.createFileAbsolute(bin_setting_path, .{}) catch |e| return reportError(
        "create '{s}' failed with {t}",
        .{ bin_setting_path, e },
    );
    defer file.close();
    file.writeAll(bin_path) catch |e| return reportError(
        "write {} bytes '{s}' to '{s}' failed with {t}",
        .{ bin_path.len, bin_path, bin_setting_path, e },
    );
}

fn fmtExpanded(original: []const u8, expanded: []const u8) FmtExpanded {
    return FmtExpanded{ .original = original, .expanded = expanded };
}
const FmtExpanded = struct {
    original: []const u8,
    expanded: []const u8,
    pub fn format(f: FmtExpanded, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (std.mem.eql(u8, f.original, f.expanded)) return;
        try writer.print(" (expanded from '{s}')", .{f.original});
    }
};

fn promptYesNo(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !bool {
    const stdin = std.fs.File.stdin();
    var read_buf: [100]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    try w.print(fmt ++ " [y/n]: ", args);
    try w.flush();
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y")) return true;
        if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "N")) return false;
        try w.print("please enter 'y' or 'n': ", .{});
        try w.flush();
    }
}

fn promptNumber(w: *std.Io.Writer, str: []const u8, max: usize) !usize {
    const stdin = std.fs.File.stdin();

    var read_buf: [100]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    while (true) {
        try w.print("{s} [0-{d}]: ", .{ str, max });
        try w.flush();

        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.fmt.parseInt(usize, trimmed, 10)) |i| {
            if (i <= max) return i;
        } else |_| {}
        try w.print("\nerror: invalid response '{f}'\n", .{std.zig.fmtString(trimmed)});
    }
}

const BadBinPath = enum {
    @"not an absolute path",
    @"open dir access denied",
    @"open dir permission denied",
    @"read only file system",
    @"not found",
    @"not a directory",
    @"symlink loop",
    @"bad path name",
    @"write file access denied",
    @"write file permission denied",
};
const BinPath = union(enum) {
    ok,
    bad: BadBinPath,
};
fn checkBinPath(path: []const u8) error{Reported}!BinPath {
    if (!std.fs.path.isAbsolute(path)) return .{ .bad = .@"not an absolute path" };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| return switch (err) {
        error.AccessDenied => .{ .bad = .@"open dir access denied" },
        error.PermissionDenied => .{ .bad = .@"open dir permission denied" },
        error.NotDir => .{ .bad = .@"not a directory" },
        error.SymLinkLoop => .{ .bad = .@"symlink loop" },
        error.BadPathName => .{ .bad = .@"bad path name" },
        error.FileNotFound => .{ .bad = .@"not found" },
        else => |e| return reportError("open dir '{s}' failed with {t}", .{ path, e }),
    };
    defer dir.close();

    const pid = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => std.os.linux.getpid(),
        .macos => std.c.getpid(),
        else => |os| @compileError("unsupported os: " ++ @tagName(os)),
    };
    var test_name_buf: [64]u8 = undefined;
    const test_name = std.fmt.bufPrint(&test_name_buf, "hew-bin-test-{d}", .{pid}) catch unreachable;
    const test_file = dir.createFile(test_name, .{ .mode = 0o755 }) catch |err| return switch (err) {
        error.AccessDenied => .{ .bad = .@"write file access denied" },
        error.PermissionDenied => .{ .bad = .@"write file permission denied" },
        // workaround issue on macos, fix at codeberg pull #31615
        error.Unexpected => if (builtin.os.tag == .macos) {
            std.log.warn("workaround macos not handling errno 30 EROFS", .{});
            return .{ .bad = .@"read only file system" };
        } else return reportError("create bin test file in '{s}' failed with unexpected error", .{path}),
        else => |e| return reportError("create bin test file in '{s}' failed with {t}", .{ path, e }),
    };
    test_file.close();
    dir.deleteFile(test_name) catch |e| return reportError("delete bin test file '{s}' failed with {t}", .{ path, e });
    return .ok;
}

fn timerStart() std.time.Timer {
    return std.time.Timer.start() catch @panic("no timer support");
}

fn reportError(comptime fmt: []const u8, args: anytype) error{Reported} {
    log.err(fmt, args);
    return error.Reported;
}
fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(0xff);
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

comptime {
    _ = @import("pathenv.zig");
}

const log = std.log.scoped(.hew);

const builtin = @import("builtin");
const std = @import("std");
const json = @import("json.zig");
const pathenv = @import("pathenv.zig");
const which = @import("which.zig");
const GitSha = @import("GitSha.zig");
const LockFile = @import("LockFile.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const Pkg = @import("pkg.zig").Pkg;
const PkgGithub = @import("pkg.zig").PkgGithub;
const Sha256 = std.crypto.hash.sha2.Sha256;
