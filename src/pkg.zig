pub const Pkg = union(enum) {
    git: PkgGit,
    path: []const u8,

    pub const ParseError = union(enum) {
        msg: []const u8,
        unknown_scheme: []const u8,
        unknown_option: []const u8,
        option_conflict: struct { []const u8, []const u8 },
        bad_git: GitHost,
        pub fn format(e: ParseError, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (e) {
                .msg => |m| try writer.writeAll(m),
                .unknown_scheme => |s| try writer.print("unknown scheme '{s}:'", .{s}),
                .unknown_option => |o| try writer.print("unknown option '{s}'", .{o}),
                .option_conflict => |o| try writer.print("conflicting options '{s}' and '{s}'", .{ o[0], o[1] }),
                .bad_git => |host| try writer.print("must be of the form '{t}:owner/repo[,options]'", .{host}),
            }
        }
    };
    pub fn parse(s: []const u8) union(enum) { ok: Pkg, err: ParseError } {
        const scheme_end = std.mem.indexOfScalar(u8, s, ':') orelse return .{ .err = .{
            .msg = "missing 'scheme:', expected 'github:' or 'path:'",
        } };
        const scheme = s[0..scheme_end];
        const value = s[scheme_end + 1 ..];

        const maybe_git_host: ?GitHost = blk: {
            if (std.mem.eql(u8, scheme, "github")) break :blk .github;
            if (std.mem.eql(u8, scheme, "gitlab")) break :blk .gitlab;
            break :blk null;
        };

        if (maybe_git_host) |git_host| {
            var iter = std.mem.splitScalar(u8, value, ',');
            const owner_repo: OwnerRepo = blk: {
                const string = iter.first();
                const slash_index = std.mem.indexOfScalar(u8, string, '/') orelse return .{ .err = .{
                    .bad_git = git_host,
                } };
                if (slash_index == 0 or slash_index == string.len - 1) return .{ .err = .{
                    .bad_git = git_host,
                } };
                if (std.mem.indexOfScalarPos(u8, string, slash_index + 1, '/') != null) return .{ .err = .{
                    .bad_git = git_host,
                } };
                break :blk .{ .string = string, .slash_index = slash_index };
            };
            var commit: PkgGit.Commit = .latest_release;
            while (iter.next()) |option| {
                if (std.mem.eql(u8, option, "tip")) {
                    if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "tip", @tagName(commit) } } };
                    commit = .tip;
                } else if (std.mem.startsWith(u8, option, "rev=")) {
                    if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "rev", @tagName(commit) } } };
                    const rev = option["rev=".len..];
                    if (rev.len == 0) return .{ .err = .{ .msg = "rev= requires a rev name" } };
                    commit = .{ .rev = rev };
                } else return .{ .err = .{ .unknown_option = option } };
            }
            return .{ .ok = .{ .git = .{ .host = git_host, .owner_repo = owner_repo, .commit = commit } } };
        }
        if (std.mem.eql(u8, scheme, "path")) {
            if (value.len == 0) return .{ .err = .{ .msg = "path package must be in 'path:PATH' format" } };
            return .{ .ok = .{ .path = value } };
        }
        return .{ .err = .{ .unknown_scheme = scheme } };
    }

    pub fn format(pkg: Pkg, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (pkg) {
            .github => |*gh| try gh.format(writer),
            .path => |p| try writer.print("path:{s}", .{p}),
        }
    }
};

pub const GitHost = enum { github, gitlab };

pub const OwnerRepo = struct {
    string: []const u8,
    slash_index: usize,
    pub fn owner(o: *const OwnerRepo) []const u8 {
        return o.string[0..o.slash_index];
    }
    pub fn repo(o: *const OwnerRepo) []const u8 {
        return o.string[o.slash_index + 1 ..];
    }
};

pub const PkgGit = struct {
    host: GitHost,
    owner_repo: OwnerRepo,
    commit: Commit,

    pub const Commit = union(enum) {
        latest_release,
        rev: []const u8,
        tip,
    };

    pub fn initStatic(host: GitHost, comptime owner_repo: [:0]const u8) PkgGit {
        const slash_index = comptime std.mem.indexOfScalar(u8, owner_repo, '/') orelse @compileError("owner_repo must contain '/' but got '" ++ owner_repo ++ "'");
        if (comptime slash_index == 0) @compileError("owner_repo may not lead with '/' but got '" ++ owner_repo ++ "'");
        if (comptime slash_index == owner_repo.len - 1) @compileError("owner_repo may not end with '/' but got '" ++ owner_repo ++ "'");
        if (comptime std.mem.indexOfScalarPos(u8, owner_repo, slash_index + 1, '/') != null) @compileError("owner_repo may only contain a single '/' but got '" ++ owner_repo ++ "'");
        return .{ .host = host, .owner_repo = owner_repo, .slash_index = slash_index };
    }
    pub fn owner(p: *const PkgGit) []const u8 {
        return p.owner_repo.owner();
    }
    pub fn repo(p: *const PkgGit) []const u8 {
        return p.owner_repo.repo();
    }
    pub fn ownerRepo(p: *const PkgGit) OwnerRepo {
        return .{ .owner_repo = p.owner_repo, .slash_index = p.slash_index };
    }

    pub fn format(pkg: PkgGit, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("{t}:{s}", .{ pkg.host, pkg.owner_repo.string });
    }
};

const std = @import("std");
