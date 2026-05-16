pub const Pkg = union(enum) {
    github: PkgRepo,
    gitlab: PkgRepo,
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
    pub const ParseResult = union(enum) { ok: Pkg, err: ParseError };

    pub fn parse(s: []const u8) ParseResult {
        const scheme_end = std.mem.indexOfScalar(u8, s, ':') orelse return .{ .err = .{
            .msg = "missing 'scheme:', expected 'github:', 'gitlab:', or 'path:'",
        } };
        const scheme = s[0..scheme_end];
        const value = s[scheme_end + 1 ..];
        if (std.mem.eql(u8, scheme, "github")) return parseRepo(value, .github);
        if (std.mem.eql(u8, scheme, "gitlab")) return parseRepo(value, .gitlab);
        if (std.mem.eql(u8, scheme, "path")) {
            if (value.len == 0) return .{ .err = .{ .msg = "path package must be in 'path:PATH' format" } };
            return .{ .ok = .{ .path = value } };
        }
        return .{ .err = .{ .unknown_scheme = scheme } };
    }

    fn parseRepo(value: []const u8, host: enum { github, gitlab }) ParseResult {
        const form_msg: []const u8 = switch (host) {
            .github => "must be of the form 'github:owner/repo[,options]'",
            .gitlab => "must be of the form 'gitlab:owner/repo[,options]'",
        };
        var iter = std.mem.splitScalar(u8, value, ',');
        const owner_repo = iter.first();
        const slash_index = std.mem.indexOfScalar(u8, owner_repo, '/') orelse return .{ .err = .{ .msg = form_msg } };
        if (slash_index == 0 or slash_index == owner_repo.len - 1) return .{ .err = .{ .msg = form_msg } };
        if (std.mem.indexOfScalarPos(u8, owner_repo, slash_index + 1, '/') != null) return .{ .err = .{ .msg = form_msg } };
        var commit: PkgRepo.Commit = .latest_release;
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
        const repo: PkgRepo = .{ .owner_repo = owner_repo, .slash_index = slash_index, .commit = commit };
        return switch (host) {
            .github => .{ .ok = .{ .github = repo } },
            .gitlab => .{ .ok = .{ .gitlab = repo } },
        };
    }

    pub fn format(pkg: Pkg, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (pkg) {
            .github => |*r| try writer.print("github:{s}", .{r.owner_repo}),
            .gitlab => |*r| try writer.print("gitlab:{s}", .{r.owner_repo}),
            .path => |p| try writer.print("path:{s}", .{p}),
        }
    }
};

pub const PkgRepo = struct {
    owner_repo: []const u8,
    slash_index: usize,
    commit: Commit,

    pub const Commit = union(enum) {
        latest_release,
        rev: []const u8,
        tip,
    };

    pub fn owner(p: *const PkgRepo) []const u8 {
        return p.owner_repo[0..p.slash_index];
    }
    pub fn repo(p: *const PkgRepo) []const u8 {
        return p.owner_repo[p.slash_index + 1 ..];
    }
};

const std = @import("std");
