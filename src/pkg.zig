pub const Pkg = union(enum) {
    github: PkgGithub,
    path: []const u8,

    pub const ParseError = union(enum) {
        msg: []const u8,
        unknown_scheme: []const u8,
        unknown_option: []const u8,
        option_conflict: struct { []const u8, []const u8 },
        pub fn format(e: ParseError, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (e) {
                .msg => |m| try writer.writeAll(m),
                .unknown_scheme => |s| try writer.print("unknown scheme '{s}:'", .{s}),
                .unknown_option => |o| try writer.print("unknown option '{s}'", .{o}),
                .option_conflict => |o| try writer.print("conflicting options '{s}' and '{s}'", .{ o[0], o[1] }),
            }
        }
    };
    pub fn parse(s: []const u8) union(enum) { ok: Pkg, err: ParseError } {
        const scheme_end = std.mem.indexOfScalar(u8, s, ':') orelse return .{ .err = .{
            .msg = "missing 'scheme:', expected 'github:' or 'path:'",
        } };
        const scheme = s[0..scheme_end];
        const value = s[scheme_end + 1 ..];
        if (std.mem.eql(u8, scheme, "github")) {
            var iter = std.mem.splitScalar(u8, value, ',');
            const owner_repo = iter.first();
            const slash_index = std.mem.indexOfScalar(u8, owner_repo, '/') orelse return .{ .err = .{
                .msg = "must be of the form 'github:owner/repo[,options]'",
            } };
            if (slash_index == 0 or slash_index == owner_repo.len - 1) return .{ .err = .{
                .msg = "must be of the form 'github:owner/repo[,options]'",
            } };
            if (std.mem.indexOfScalarPos(u8, owner_repo, slash_index + 1, '/') != null) return .{ .err = .{
                .msg = "must be of the form 'github:owner/repo[,options]'",
            } };
            var commit: PkgGithub.Commit = .latest_release;
            while (iter.next()) |option| {
                if (std.mem.eql(u8, option, "tip")) {
                    if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "tip", @tagName(commit) } } };
                    commit = .tip;
                } else if (std.mem.startsWith(u8, option, "ref=")) {
                    if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "ref", @tagName(commit) } } };
                    const ref = option["ref=".len..];
                    if (ref.len == 0) return .{ .err = .{ .msg = "ref= requires a ref name" } };
                    commit = .{ .ref = ref };
                } else return .{ .err = .{ .unknown_option = option } };
            }
            return .{ .ok = .{ .github = .{ .owner_repo = owner_repo, .slash_index = slash_index, .commit = commit } } };
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

pub const PkgGithub = struct {
    owner_repo: []const u8,
    slash_index: usize,
    commit: Commit,

    pub const Commit = union(enum) {
        latest_release,
        ref: []const u8,
        tip,
    };

    pub fn initStatic(comptime owner_repo: [:0]const u8) PkgGithub {
        const slash_index = comptime std.mem.indexOfScalar(u8, owner_repo, '/') orelse @compileError("owner_repo must contain '/' but got '" ++ owner_repo ++ "'");
        if (comptime slash_index == 0) @compileError("owner_repo may not lead with '/' but got '" ++ owner_repo ++ "'");
        if (comptime slash_index == owner_repo.len - 1) @compileError("owner_repo may not end with '/' but got '" ++ owner_repo ++ "'");
        if (comptime std.mem.indexOfScalarPos(u8, owner_repo, slash_index + 1, '/') != null) @compileError("owner_repo may only contain a single '/' but got '" ++ owner_repo ++ "'");
        return .{ .owner_repo = owner_repo, .slash_index = slash_index };
    }
    pub fn owner(p: *const PkgGithub) []const u8 {
        return p.owner_repo[0..p.slash_index];
    }
    pub fn repo(p: *const PkgGithub) []const u8 {
        return p.owner_repo[p.slash_index + 1 ..];
    }

    pub fn format(pkg: PkgGithub, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("github:{s}", .{pkg.owner_repo});
    }
};

const std = @import("std");
