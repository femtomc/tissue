//! Command-line interface for the tissue issue tracker.
//!
//! This module provides the main entry point and command dispatch for the
//! tissue CLI. It handles argument parsing, store discovery, and formatting
//! of output (both human-readable and JSON).
//!
//! Commands: init, post (new), list, search, show, edit, status, reply (comment), tag, dep, deps, ready, clean, migrate
//!
//! Store discovery priority: --store flag > directory walk > TISSUE_STORE env

const std = @import("std");
const tissue = @import("tissue");
const build_options = @import("build_options");

const Store = tissue.store.Store;

/// Global options parsed before the command.
const GlobalOptions = struct {
    store_path: ?[]const u8 = null,
};

/// Result of parsing global options from arguments.
const ParsedArgs = struct {
    global: GlobalOptions,
    command_start: usize,
};

/// Parses global options (--store) before the command.
/// Returns the global options and the index where the command starts.
fn parseGlobalOptions(args: []const []const u8) ParsedArgs {
    var result = ParsedArgs{
        .global = .{},
        .command_start = 1, // Skip program name
    };

    const store_eq_prefix = "--store=";

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--store")) {
            if (i + 1 >= args.len) {
                die("missing value for --store", .{});
            }
            const path = args[i + 1];
            if (path.len == 0) {
                die("--store path cannot be empty", .{});
            }
            result.global.store_path = path;
            i += 2;
            result.command_start = i;
        } else if (std.mem.startsWith(u8, arg, store_eq_prefix)) {
            // Support --store=path syntax
            const path = arg[store_eq_prefix.len..];
            if (path.len == 0) {
                die("--store path cannot be empty", .{});
            }
            result.global.store_path = path;
            i += 1;
            result.command_start = i;
        } else if (std.mem.eql(u8, arg, "--")) {
            // End of global options marker; command follows
            i += 1;
            result.command_start = i;
            break;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Unknown long global flag
            die("unknown global option: {s}\nGlobal options must come before the command. Use 'tissue --help' for usage.", .{arg});
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Short flags like -h belong to commands, not global options
            // Let them pass through to be handled as commands (will error appropriately)
            break;
        } else {
            // First positional argument is the command
            break;
        }
    }

    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_z = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_z);

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    for (args_z) |arg_z| {
        try args_list.append(allocator, arg_z[0..arg_z.len]);
    }
    const args = try args_list.toOwnedSlice(allocator);
    defer allocator.free(args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Parse global options (--store) before the command
    const parsed = parseGlobalOptions(args);
    const cmd_start = parsed.command_start;

    if (cmd_start >= args.len) {
        printUsage();
        return;
    }

    const cmd = args[cmd_start];
    const cmd_args = args[cmd_start + 1 ..];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        try stdout.print("tissue {s}\n", .{build_options.version});
        return;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        if (cmd_args.len >= 1) {
            const topic = cmd_args[0];
            if (topic.len == 0 or topic[0] == '-') {
                printUsage();
                return;
            }
            if (!printCommandHelp(topic)) {
                die("unknown command: {s}", .{topic});
            }
            return;
        }
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        cmdInit(allocator, stdout, cmd_args, parsed.global.store_path) catch |err| {
            dieOnError(err);
        };
        return;
    }

    const store_dir = discoverStoreDir(allocator, parsed.global.store_path) catch |err| {
        dieOnError(err);
    };
    defer allocator.free(store_dir);

    var store = Store.open(allocator, store_dir) catch |err| {
        dieOnError(err);
    };
    defer store.deinit();
    store.importIfNeeded() catch |err| {
        dieOnError(err);
    };

    const result: anyerror!void = blk: {
        if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "post")) {
            break :blk cmdNew(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "list")) {
            break :blk cmdList(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "search")) {
            break :blk cmdSearch(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "show")) {
            break :blk cmdShow(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "edit")) {
            break :blk cmdEdit(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "status")) {
            break :blk cmdStatus(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "comment") or std.mem.eql(u8, cmd, "reply")) {
            break :blk cmdComment(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "tag")) {
            break :blk cmdTag(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "dep")) {
            break :blk cmdDep(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "deps")) {
            break :blk cmdDeps(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "ready")) {
            break :blk cmdReady(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "clean")) {
            break :blk cmdClean(allocator, stdout, &store, cmd_args);
        } else if (std.mem.eql(u8, cmd, "migrate")) {
            break :blk cmdMigrate(allocator, stdout, &store, cmd_args);
        } else {
            die("unknown command: {s}", .{cmd});
        }
    };

    result catch |err| {
        dieOnError(err);
    };
}

fn cmdInit(allocator: std.mem.Allocator, stdout: *std.Io.Writer, args: []const []const u8, store_override: ?[]const u8) !void {
    var json = false;
    var prefix: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, args[i], "--prefix")) {
            prefix = nextValue(args, &i, "prefix");
        } else {
            die("unexpected argument: {s}", .{args[i]});
        }
    }

    const store_dir = try initStoreDir(allocator, store_override);
    defer allocator.free(store_dir);

    // Create parent directories recursively if needed (for --store paths like a/b/.tissue)
    std.fs.makeDirAbsolute(store_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Parent doesn't exist; create full path recursively
            const parent = std.fs.path.dirname(store_dir) orelse return err;
            try std.fs.cwd().makePath(parent);
            try std.fs.makeDirAbsolute(store_dir);
        },
        else => return err,
    };

    const jsonl_path = try std.fs.path.join(allocator, &.{ store_dir, "issues.jsonl" });
    defer allocator.free(jsonl_path);
    const already_init = fileExists(jsonl_path);
    if (!already_init) {
        var file = try std.fs.createFileAbsolute(jsonl_path, .{ .truncate = false });
        file.close();
    }

    const gitignore_path = try std.fs.path.join(allocator, &.{ store_dir, ".gitignore" });
    defer allocator.free(gitignore_path);
    if (!fileExists(gitignore_path)) {
        var file = try std.fs.createFileAbsolute(gitignore_path, .{ .truncate = false });
        defer file.close();
        var buf: [256]u8 = undefined;
        var writer = file.writer(&buf);
        const out = &writer.interface;
        try out.writeAll("issues.db\nissues.db-shm\nissues.db-wal\nlock\n");
        try out.flush();
    }

    var store = try Store.open(allocator, store_dir);
    defer store.deinit();
    try store.ensureJsonl();
    try store.importIfNeeded();
    if (prefix) |value| {
        try store.setIdPrefix(value);
    }

    if (json) {
        if (already_init) {
            std.debug.print("store already exists at {s}\n", .{store_dir});
        }
        const record = struct {
            store: []const u8,
            prefix: []const u8,
        }{ .store = store_dir, .prefix = store.id_prefix };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
    } else {
        if (already_init) {
            try stdout.print("already initialized {s} (prefix: {s})\n", .{ store_dir, store.id_prefix });
        } else {
            try stdout.print("initialized {s} (prefix: {s})\n", .{ store_dir, store.id_prefix });
        }
    }
}

fn cmdNew(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var title: ?[]const u8 = null;
    var body: []const u8 = "";
    var priority: i32 = 2;
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);
    var json = false;
    var quiet = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--body")) {
            body = nextValue(args, &i, "body");
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--priority")) {
            const val = nextValue(args, &i, "priority");
            priority = parseInt(i32, val, "priority");
            validatePriority(priority);
            continue;
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tag")) {
            const tag = nextValue(args, &i, "tag");
            try tags.append(allocator, tag);
            continue;
        }
        if (arg.len == 0) {
            die("empty title not allowed", .{});
        }
        if (arg[0] != '-') {
            if (title != null) die("multiple titles provided", .{});
            title = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (title == null) die("title required", .{});
    const processed_body = try processEscapes(allocator, body);
    defer allocator.free(processed_body);
    const id = try store.createIssue(title.?, processed_body, priority, tags.items);
    defer allocator.free(id);

    if (quiet) {
        try stdout.writeAll(id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        var issue = try store.fetchIssue(id);
        defer issue.deinit(allocator);
        try std.json.Stringify.value(issue, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{id});
}

fn cmdList(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var status: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var search: ?[]const u8 = null;
    var limit: ?i64 = null;
    var json = false;
    var summary = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "-s")) {
            summary = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            status = nextValue(args, &i, "status");
            validateStatus(status.?);
            continue;
        }
        if (std.mem.eql(u8, arg, "--tag")) {
            tag = nextValue(args, &i, "tag");
            continue;
        }
        if (std.mem.eql(u8, arg, "--search")) {
            search = nextValue(args, &i, "search");
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            const val = nextValue(args, &i, "limit");
            limit = parseInt(i64, val, "limit");
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    try listIssues(allocator, stdout, store, status, tag, search, limit, json, summary);
}

fn cmdSearch(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var query: ?[]const u8 = null;
    var limit: ?i64 = null;
    var json = false;
    var summary = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "-s")) {
            summary = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            const val = nextValue(args, &i, "limit");
            limit = parseInt(i64, val, "limit");
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (query != null) die("multiple queries provided", .{});
            query = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (query == null) die("query required", .{});
    try listIssues(allocator, stdout, store, null, null, query, limit, json, summary);
}

fn cmdShow(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var json = false;
    var id_input: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (id_input != null) die("multiple ids provided", .{});
            id_input = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (id_input == null) die("id required", .{});
    const id = try store.resolveIssueId(id_input.?);
    defer allocator.free(id);

    var issue = try store.fetchIssue(id);
    defer issue.deinit(allocator);
    const comments = try store.fetchComments(id);
    defer {
        for (comments) |*cmt| cmt.deinit(allocator);
        allocator.free(comments);
    }
    const deps = try store.fetchDeps(id);
    defer {
        for (deps) |*dep| dep.deinit(allocator);
        allocator.free(deps);
    }

    if (json) {
        const record = struct {
            issue: tissue.store.Issue,
            comments: []tissue.store.Comment,
            deps: []tissue.store.Dep,
        }{
            .issue = issue,
            .comments = comments,
            .deps = deps,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }

    try printIssueDetails(stdout, &issue, comments, deps);
}

fn cmdEdit(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var id_input: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var priority: ?i32 = null;
    var add_tags: std.ArrayList([]const u8) = .empty;
    defer add_tags.deinit(allocator);
    var rm_tags: std.ArrayList([]const u8) = .empty;
    defer rm_tags.deinit(allocator);
    var json = false;
    var quiet = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--title")) {
            title = nextValue(args, &i, "title");
            continue;
        }
        if (std.mem.eql(u8, arg, "--body")) {
            body = nextValue(args, &i, "body");
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            status = nextValue(args, &i, "status");
            validateStatus(status.?);
            continue;
        }
        if (std.mem.eql(u8, arg, "--priority")) {
            const val = nextValue(args, &i, "priority");
            priority = parseInt(i32, val, "priority");
            validatePriority(priority.?);
            continue;
        }
        if (std.mem.eql(u8, arg, "--add-tag")) {
            const tag = nextValue(args, &i, "add-tag");
            try add_tags.append(allocator, tag);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rm-tag")) {
            const tag = nextValue(args, &i, "rm-tag");
            try rm_tags.append(allocator, tag);
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (id_input != null) die("multiple ids provided", .{});
            id_input = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (id_input == null) die("id required", .{});
    const id = try store.resolveIssueId(id_input.?);
    defer allocator.free(id);
    if (title == null and body == null and status == null and priority == null and add_tags.items.len == 0 and rm_tags.items.len == 0) {
        die("no changes specified", .{});
    }

    var processed_body: ?[]u8 = null;
    defer if (processed_body) |pb| allocator.free(pb);
    if (body) |b| {
        processed_body = try processEscapes(allocator, b);
    }
    const final_body: ?[]const u8 = processed_body;

    try store.updateIssue(id, title, final_body, status, priority, add_tags.items, rm_tags.items);

    if (quiet) {
        try stdout.writeAll(id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        var issue = try store.fetchIssue(id);
        defer issue.deinit(allocator);
        try std.json.Stringify.value(issue, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{id});
}

fn cmdStatus(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var id_input: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var json = false;
    var quiet = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (id_input == null) {
                id_input = arg;
                i += 1;
                continue;
            }
            if (status == null) {
                status = arg;
                i += 1;
                continue;
            }
            die("too many arguments", .{});
        }
        die("unknown flag: {s}", .{arg});
    }

    if (id_input == null or status == null) die("usage: tissue status <id> <open|in_progress|paused|duplicate|closed>", .{});
    validateStatus(status.?);
    const id = try store.resolveIssueId(id_input.?);
    defer allocator.free(id);
    try store.updateIssue(id, null, null, status, null, &.{}, &.{});

    if (quiet) {
        try stdout.writeAll(id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        var issue = try store.fetchIssue(id);
        defer issue.deinit(allocator);
        try std.json.Stringify.value(issue, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{id});
}

fn cmdComment(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var id_input: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var json = false;
    var quiet = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            body = nextValue(args, &i, "message");
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (id_input != null) die("unexpected argument: {s}\nDid you forget -m? Usage: tissue comment <id> -m <text>", .{arg});
            id_input = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (id_input == null) die("id required. Usage: tissue comment <id> -m <text>", .{});
    if (body == null) die("message required. Usage: tissue comment <id> -m <text>", .{});
    const id = try store.resolveIssueId(id_input.?);
    defer allocator.free(id);
    const processed_body = try processEscapes(allocator, body.?);
    defer allocator.free(processed_body);
    const comment_id = try store.addComment(id, processed_body);
    defer allocator.free(comment_id);

    if (quiet) {
        try stdout.writeAll(comment_id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        const record = struct {
            id: []const u8,
            issue_id: []const u8,
            body: []const u8,
        }{
            .id = comment_id,
            .issue_id = id,
            .body = body.?,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{comment_id});
}

fn cmdTag(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    if (args.len < 3) die("usage: tissue tag <add|rm> <id> <tag>", .{});
    const action = args[0];
    const id_input = args[1];
    const tag = args[2];
    var json = false;
    var quiet = false;

    if (args.len > 3) {
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--quiet")) {
                quiet = true;
            } else {
                die("unknown flag: {s}", .{args[i]});
            }
        }
    }

    const id = try store.resolveIssueId(id_input);
    defer allocator.free(id);

    if (std.mem.eql(u8, action, "add")) {
        try store.updateIssue(id, null, null, null, null, &.{tag}, &.{});
    } else if (std.mem.eql(u8, action, "rm")) {
        try store.updateIssue(id, null, null, null, null, &.{}, &.{tag});
    } else {
        die("unknown tag action: {s}", .{action});
    }

    if (quiet) {
        try stdout.writeAll(id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        var issue = try store.fetchIssue(id);
        defer issue.deinit(allocator);
        try std.json.Stringify.value(issue, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{id});
}

fn cmdDep(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    if (args.len < 4) die("usage: tissue dep <add|rm> <id> <kind> <target>", .{});
    const action = args[0];
    const id_input = args[1];
    const kind = args[2];
    const target_input = args[3];
    var json = false;
    var quiet = false;

    if (args.len > 4) {
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--quiet")) {
                quiet = true;
            } else {
                die("unknown flag: {s}", .{args[i]});
            }
        }
    }

    const id = try store.resolveIssueId(id_input);
    defer allocator.free(id);
    const target = try store.resolveIssueId(target_input);
    defer allocator.free(target);

    if (std.mem.eql(u8, action, "add")) {
        try store.addDep(id, kind, target);
    } else if (std.mem.eql(u8, action, "rm")) {
        try store.removeDep(id, kind, target);
    } else {
        die("unknown dep action: {s}", .{action});
    }

    if (quiet) {
        try stdout.writeAll(id);
        try stdout.writeByte('\n');
        return;
    }
    if (json) {
        const record = struct {
            action: []const u8,
            src_id: []const u8,
            dst_id: []const u8,
            kind: []const u8,
        }{
            .action = action,
            .src_id = id,
            .dst_id = target,
            .kind = kind,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.print("{s}\n", .{id});
}

fn cmdDeps(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var json = false;
    var id_input: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (id_input != null) die("multiple ids provided", .{});
            id_input = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }
    if (id_input == null) die("id required", .{});

    const id = try store.resolveIssueId(id_input.?);
    defer allocator.free(id);
    const deps = try store.fetchDeps(id);
    defer {
        for (deps) |*dep| dep.deinit(allocator);
        allocator.free(deps);
    }

    if (json) {
        try std.json.Stringify.value(deps, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
        return;
    }

    for (deps) |dep| {
        try stdout.print("{s} {s} -> {s}\n", .{ dep.kind, shortId(dep.src_id), shortId(dep.dst_id) });
    }
}

fn cmdReady(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var json = false;
    var limit: ?i64 = null;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            const val = nextValue(args, &i, "limit");
            limit = parseInt(i64, val, "limit");
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }
    try listReady(allocator, stdout, store, limit, json);
}

fn cmdClean(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var force = false;
    var older_than_days: ?u32 = null;
    var json = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--older-than")) {
            const val = nextValue(args, &i, "older-than");
            older_than_days = parseDays(val);
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    // Find closed issues to clean
    const closed_issues = try findClosedIssues(allocator, store, older_than_days);
    defer {
        for (closed_issues) |id| allocator.free(id);
        allocator.free(closed_issues);
    }

    if (closed_issues.len == 0) {
        if (json) {
            try stdout.writeAll("{\"removed\":0,\"issues\":[]}\n");
        } else {
            try stdout.writeAll("No closed issues to clean.\n");
        }
        return;
    }

    if (json) {
        try stdout.writeAll("{\"dry_run\":");
        try stdout.writeAll(if (force) "false" else "true");
        try stdout.writeAll(",\"count\":");
        try stdout.print("{d}", .{closed_issues.len});
        try stdout.writeAll(",\"issues\":[");
        for (closed_issues, 0..) |id, idx| {
            if (idx > 0) try stdout.writeByte(',');
            try stdout.print("\"{s}\"", .{id});
        }
        try stdout.writeAll("]}\n");
    } else {
        if (force) {
            try stdout.print("Removing {d} closed issue(s):\n", .{closed_issues.len});
        } else {
            try stdout.print("Would remove {d} closed issue(s) (use --force to execute):\n", .{closed_issues.len});
        }
        for (closed_issues) |id| {
            // Fetch issue details for display
            var issue = store.fetchIssue(id) catch {
                try stdout.print("  {s}\n", .{id});
                continue;
            };
            defer issue.deinit(allocator);
            var title_buf: [30]u8 = undefined;
            const title_display = truncateTitle(issue.title, &title_buf);
            try stdout.print("  {s} {s}\n", .{ shortId(id), title_display });
        }
    }

    if (!force) return;

    // Actually remove the issues by rewriting JSONL
    try rewriteJsonlWithoutIssues(allocator, store, closed_issues);
    try store.forceReimport();

    if (!json) {
        try stdout.print("Cleaned {d} issue(s).\n", .{closed_issues.len});
    }
}

fn findClosedIssues(allocator: std.mem.Allocator, store: *Store, older_than_days: ?u32) ![][]u8 {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    try sql.appendSlice(allocator, "SELECT id FROM issues WHERE status IN ('closed','duplicate')");
    if (older_than_days) |days| {
        const cutoff_ms = std.time.milliTimestamp() - (@as(i64, days) * 24 * 60 * 60 * 1000);
        var buf: [32]u8 = undefined;
        const cutoff_str = std.fmt.bufPrint(&buf, "{d}", .{cutoff_ms}) catch unreachable;
        try sql.appendSlice(allocator, " AND updated_at < ");
        try sql.appendSlice(allocator, cutoff_str);
    }

    const stmt = try tissue.sqlite.prepare(store.db, sql.items);
    defer tissue.sqlite.finalize(stmt);

    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    while (try tissue.sqlite.step(stmt)) {
        const id = tissue.sqlite.columnText(stmt, 0);
        try ids.append(allocator, try allocator.dupe(u8, id));
    }

    return ids.toOwnedSlice(allocator);
}

fn rewriteJsonlWithoutIssues(allocator: std.mem.Allocator, store: *Store, ids_to_remove: []const []const u8) !void {
    // Build a set of IDs to remove for fast lookup
    var remove_set = std.StringHashMap(void).init(allocator);
    defer remove_set.deinit();
    for (ids_to_remove) |id| {
        try remove_set.put(id, {});
    }

    // Read original JSONL
    var jsonl_file = try std.fs.openFileAbsolute(store.jsonl_path, .{});
    defer jsonl_file.close();
    const stat = try jsonl_file.stat();
    const jsonl_content = try allocator.alloc(u8, stat.size);
    defer allocator.free(jsonl_content);
    const bytes_read = try jsonl_file.readAll(jsonl_content);
    // Use only the portion that was actually read
    const actual_content = jsonl_content[0..bytes_read];

    // Create new JSONL content
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, actual_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse to check if this line should be removed
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            // Keep malformed lines (they'll be skipped on import anyway)
            try new_content.appendSlice(allocator, line);
            try new_content.append(allocator, '\n');
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try new_content.appendSlice(allocator, line);
            try new_content.append(allocator, '\n');
            continue;
        }

        const obj = parsed.value.object;

        // Check if this record should be removed
        var should_remove = false;

        // Get the ID field based on record type
        const type_val = obj.get("type");
        if (type_val) |tv| {
            if (tv == .string) {
                const type_str = tv.string;
                if (std.mem.eql(u8, type_str, "issue")) {
                    if (obj.get("id")) |id_val| {
                        if (id_val == .string) {
                            should_remove = remove_set.contains(id_val.string);
                        }
                    }
                } else if (std.mem.eql(u8, type_str, "comment")) {
                    if (obj.get("issue_id")) |id_val| {
                        if (id_val == .string) {
                            should_remove = remove_set.contains(id_val.string);
                        }
                    }
                } else if (std.mem.eql(u8, type_str, "dep")) {
                    // Remove deps where either src or dst is being removed
                    if (obj.get("src_id")) |src_val| {
                        if (src_val == .string and remove_set.contains(src_val.string)) {
                            should_remove = true;
                        }
                    }
                    if (!should_remove) {
                        if (obj.get("dst_id")) |dst_val| {
                            if (dst_val == .string and remove_set.contains(dst_val.string)) {
                                should_remove = true;
                            }
                        }
                    }
                }
            }
        }

        if (!should_remove) {
            try new_content.appendSlice(allocator, line);
            try new_content.append(allocator, '\n');
        }
    }

    // Write new JSONL (atomic via temp file)
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{store.jsonl_path});
    defer allocator.free(tmp_path);

    var tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    errdefer {
        tmp_file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
    }

    var write_buf: [4096]u8 = undefined;
    var writer = tmp_file.writer(&write_buf);
    try writer.interface.writeAll(new_content.items);
    try writer.interface.flush();
    tmp_file.close();

    // Rename temp file to original
    try std.fs.renameAbsolute(tmp_path, store.jsonl_path);
}

fn cmdMigrate(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, args: []const []const u8) !void {
    var source_path: ?[]const u8 = null;
    var json = false;
    var dry_run = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] != '-') {
            if (source_path != null) die("multiple source paths provided", .{});
            source_path = arg;
            i += 1;
            continue;
        }
        die("unknown flag: {s}", .{arg});
    }

    if (source_path == null) die("usage: tissue migrate <source-store> [--dry-run] [--json]", .{});

    // Resolve source path
    const resolved_source = try resolvePath(allocator, source_path.?);
    defer allocator.free(resolved_source);

    // Check source jsonl exists
    const source_jsonl = try std.fs.path.join(allocator, &.{ resolved_source, "issues.jsonl" });
    defer allocator.free(source_jsonl);

    if (!fileExists(source_jsonl)) {
        die("source store not found: {s}", .{resolved_source});
    }

    // Read source jsonl
    var source_file = try std.fs.openFileAbsolute(source_jsonl, .{});
    defer source_file.close();
    const stat = try source_file.stat();
    const source_content = try allocator.alloc(u8, stat.size);
    defer allocator.free(source_content);
    const bytes_read = try source_file.readAll(source_content);
    const actual_content = source_content[0..bytes_read];

    // Build set of existing issue IDs in destination
    var existing_ids = std.StringHashMap(void).init(allocator);
    defer existing_ids.deinit();
    {
        const stmt = try tissue.sqlite.prepare(store.db, "SELECT id FROM issues;");
        defer tissue.sqlite.finalize(stmt);
        while (try tissue.sqlite.step(stmt)) {
            const id = tissue.sqlite.columnText(stmt, 0);
            const id_copy = try allocator.dupe(u8, id);
            try existing_ids.put(id_copy, {});
        }
    }
    // Also track existing comment IDs
    var existing_comment_ids = std.StringHashMap(void).init(allocator);
    defer existing_comment_ids.deinit();
    {
        const stmt = try tissue.sqlite.prepare(store.db, "SELECT id FROM comments;");
        defer tissue.sqlite.finalize(stmt);
        while (try tissue.sqlite.step(stmt)) {
            const id = tissue.sqlite.columnText(stmt, 0);
            const id_copy = try allocator.dupe(u8, id);
            try existing_comment_ids.put(id_copy, {});
        }
    }

    // Also track existing deps (by src_id|dst_id|kind composite key)
    var existing_deps = std.StringHashMap(void).init(allocator);
    defer existing_deps.deinit();
    {
        const stmt = try tissue.sqlite.prepare(store.db, "SELECT src_id, dst_id, kind FROM deps WHERE state = 'active';");
        defer tissue.sqlite.finalize(stmt);
        while (try tissue.sqlite.step(stmt)) {
            const src_id = tissue.sqlite.columnText(stmt, 0);
            const dst_id = tissue.sqlite.columnText(stmt, 1);
            const kind = tissue.sqlite.columnText(stmt, 2);
            const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ src_id, dst_id, kind });
            try existing_deps.put(key, {});
        }
    }

    // Free all keys when done
    defer {
        var key_iter = existing_ids.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
    }
    defer {
        var key_iter = existing_comment_ids.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
    }
    defer {
        var key_iter = existing_deps.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
    }

    // Collect lines to migrate (issues first, then comments, then deps)
    var issue_lines: std.ArrayList([]const u8) = .empty;
    defer issue_lines.deinit(allocator);
    var comment_lines: std.ArrayList([]const u8) = .empty;
    defer comment_lines.deinit(allocator);
    var dep_lines: std.ArrayList([]const u8) = .empty;
    defer dep_lines.deinit(allocator);

    var migrated_issue_ids = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = migrated_issue_ids.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        migrated_issue_ids.deinit();
    }

    var lines = std.mem.splitScalar(u8, actual_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n\t ");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse continue;
        if (type_val != .string) continue;
        const type_str = type_val.string;

        if (std.mem.eql(u8, type_str, "issue")) {
            const id_val = obj.get("id") orelse continue;
            if (id_val != .string) continue;
            const issue_id = id_val.string;

            // Skip if already exists in destination
            if (existing_ids.contains(issue_id)) continue;
            // Skip if already seen in this migration
            if (migrated_issue_ids.contains(issue_id)) continue;

            // Track that we're migrating this issue (dupe since parsed will be freed)
            const id_copy = try allocator.dupe(u8, issue_id);
            try migrated_issue_ids.put(id_copy, {});
            try issue_lines.append(allocator, line);
        } else if (std.mem.eql(u8, type_str, "comment")) {
            const id_val = obj.get("id") orelse continue;
            if (id_val != .string) continue;
            const comment_id = id_val.string;

            // Skip if comment already exists
            if (existing_comment_ids.contains(comment_id)) continue;

            // Only migrate if the parent issue is being migrated or exists
            const issue_id_val = obj.get("issue_id") orelse continue;
            if (issue_id_val != .string) continue;
            const issue_id = issue_id_val.string;

            if (existing_ids.contains(issue_id) or migrated_issue_ids.contains(issue_id)) {
                try comment_lines.append(allocator, line);
            }
        } else if (std.mem.eql(u8, type_str, "dep")) {
            // Only migrate deps if both issues exist or are being migrated
            const src_val = obj.get("src_id") orelse continue;
            const dst_val = obj.get("dst_id") orelse continue;
            const kind_val = obj.get("kind") orelse continue;
            if (src_val != .string or dst_val != .string or kind_val != .string) continue;
            const src_id = src_val.string;
            const dst_id = dst_val.string;
            const kind = kind_val.string;

            // Skip if dep already exists
            const dep_key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ src_id, dst_id, kind });
            defer allocator.free(dep_key);
            if (existing_deps.contains(dep_key)) continue;

            const src_exists = existing_ids.contains(src_id) or migrated_issue_ids.contains(src_id);
            const dst_exists = existing_ids.contains(dst_id) or migrated_issue_ids.contains(dst_id);

            if (src_exists and dst_exists) {
                try dep_lines.append(allocator, line);
            }
        }
    }

    const total_migrated = issue_lines.items.len;
    const comments_migrated = comment_lines.items.len;
    const deps_migrated = dep_lines.items.len;

    if (json) {
        const record = struct {
            dry_run: bool,
            issues: usize,
            comments: usize,
            deps: usize,
        }{
            .dry_run = dry_run,
            .issues = total_migrated,
            .comments = comments_migrated,
            .deps = deps_migrated,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        try stdout.writeByte('\n');
    } else {
        if (dry_run) {
            try stdout.print("Would migrate {d} issue(s), {d} comment(s), {d} dep(s) from {s}\n", .{ total_migrated, comments_migrated, deps_migrated, resolved_source });
        } else {
            try stdout.print("Migrating {d} issue(s), {d} comment(s), {d} dep(s) from {s}\n", .{ total_migrated, comments_migrated, deps_migrated, resolved_source });
        }
    }

    if (dry_run or (total_migrated == 0 and comments_migrated == 0 and deps_migrated == 0)) return;

    // Append to destination jsonl (issues first, then deps, then comments)
    var dest_file = try std.fs.openFileAbsolute(store.jsonl_path, .{ .mode = .read_write });
    defer dest_file.close();
    try dest_file.seekFromEnd(0);

    var write_buf: [4096]u8 = undefined;
    var writer = dest_file.writer(&write_buf);

    for (issue_lines.items) |line| {
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
    }
    for (dep_lines.items) |line| {
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
    }
    for (comment_lines.items) |line| {
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    try dest_file.sync();

    // Force reimport to rebuild SQLite
    try store.forceReimport();

    if (!json) {
        try stdout.print("Migration complete.\n", .{});
    }
}

fn parseDays(val: []const u8) u32 {
    // Parse "30d" or "30" format
    var num_end: usize = val.len;
    if (val.len > 0 and (val[val.len - 1] == 'd' or val[val.len - 1] == 'D')) {
        num_end = val.len - 1;
    }
    return std.fmt.parseInt(u32, val[0..num_end], 10) catch {
        die("invalid days value: {s}", .{val});
    };
}

fn listIssues(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    store: *Store,
    status: ?[]const u8,
    tag: ?[]const u8,
    search: ?[]const u8,
    limit: ?i64,
    json: bool,
    summary: bool,
) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    var binds: std.ArrayList(Bind) = .empty;
    defer binds.deinit(allocator);

    const tags_expr =
        "(SELECT group_concat(t.name, ',') FROM tags t JOIN issue_tags it ON it.tag_id = t.id WHERE it.issue_id = i.id)";
    try sql.appendSlice(allocator, "SELECT i.id, i.status, i.title, i.updated_at, i.priority, ");
    try sql.appendSlice(allocator, tags_expr);
    try sql.appendSlice(allocator, ", i.body");
    if (search != null) {
        try sql.appendSlice(allocator, " FROM issues_fts JOIN issues i ON i.rowid = issues_fts.rowid ");
    } else {
        try sql.appendSlice(allocator, " FROM issues i ");
    }
    if (tag != null) {
        try sql.appendSlice(allocator, "JOIN issue_tags it ON it.issue_id = i.id JOIN tags t ON t.id = it.tag_id ");
    }

    var has_where = false;
    if (search != null) {
        try sql.appendSlice(allocator, "WHERE issues_fts MATCH ? ");
        try binds.append(allocator, .{ .text = search.? });
        has_where = true;
    }
    if (status != null) {
        try sql.appendSlice(allocator, if (has_where) "AND i.status = ? " else "WHERE i.status = ? ");
        try binds.append(allocator, .{ .text = status.? });
        has_where = true;
    }
    if (tag != null) {
        try sql.appendSlice(allocator, if (has_where) "AND t.name = ? " else "WHERE t.name = ? ");
        try binds.append(allocator, .{ .text = tag.? });
        has_where = true;
    }

    if (search != null) {
        try sql.appendSlice(allocator, "ORDER BY bm25(issues_fts, 1.0, 0.5, 0.25), i.updated_at DESC ");
    } else {
        try sql.appendSlice(allocator, "ORDER BY i.updated_at DESC ");
    }
    if (limit != null) {
        try sql.appendSlice(allocator, "LIMIT ? ");
        try binds.append(allocator, .{ .int = limit.? });
    }

    const stmt = try tissue.sqlite.prepare(store.db, sql.items);
    defer tissue.sqlite.finalize(stmt);

    var bind_index: c_int = 1;
    for (binds.items) |bind| {
        switch (bind) {
            .text => |text| {
                try tissue.sqlite.bindText(stmt, bind_index, text);
            },
            .int => |value| {
                try tissue.sqlite.bindInt64(stmt, bind_index, value);
            },
        }
        bind_index += 1;
    }

    if (json) {
        try stdout.writeByte('[');
        var first = true;
        while (try tissue.sqlite.step(stmt)) {
            const record = struct {
                id: []const u8,
                status: []const u8,
                title: []const u8,
                updated_at: i64,
                priority: i32,
                tags: []const u8,
                body: []const u8,
            }{
                .id = tissue.sqlite.columnText(stmt, 0),
                .status = tissue.sqlite.columnText(stmt, 1),
                .title = tissue.sqlite.columnText(stmt, 2),
                .updated_at = tissue.sqlite.columnInt64(stmt, 3),
                .priority = tissue.sqlite.columnInt(stmt, 4),
                .tags = tissue.sqlite.columnText(stmt, 5),
                .body = tissue.sqlite.columnText(stmt, 6),
            };
            if (!first) try stdout.writeByte(',');
            first = false;
            try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        }
        try stdout.writeByte(']');
        try stdout.writeByte('\n');
        return;
    }

    if (summary) {
        try stdout.print("{s:10} {s:11} {s:3} {s:30} {s}\n", .{ "ID", "Status", "Pri", "Title", "Tags" });
    } else {
        try stdout.print("{s:10} {s:11} {s:3} {s:30} {s:43} {s}\n", .{ "ID", "Status", "Pri", "Title", "Description", "Tags" });
    }
    while (try tissue.sqlite.step(stmt)) {
        const id = tissue.sqlite.columnText(stmt, 0);
        const status_val = tissue.sqlite.columnText(stmt, 1);
        const title_val = tissue.sqlite.columnText(stmt, 2);
        const priority_val: u32 = @intCast(tissue.sqlite.columnInt(stmt, 4));
        const tags_val = tissue.sqlite.columnText(stmt, 5);
        const body_val = tissue.sqlite.columnText(stmt, 6);
        const tags_display = if (tags_val.len == 0) "-" else tags_val;
        var title_buf: [30]u8 = undefined;
        const title_display = truncateTitle(title_val, &title_buf);
        if (summary) {
            try stdout.print("{s:10} {s:11} {d:>3} {s:30} {s}\n", .{ shortId(id), status_val, priority_val, title_display, tags_display });
        } else {
            var desc_buf: [48]u8 = undefined;
            const desc = truncateDesc(body_val, &desc_buf);
            try stdout.print("{s:10} {s:11} {d:>3} {s:30} {s:43} {s}\n", .{ shortId(id), status_val, priority_val, title_display, desc, tags_display });
        }
    }
}

fn listReady(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, limit: ?i64, json: bool) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    try sql.appendSlice(allocator,
        \\WITH RECURSIVE blockers(src, dst) AS (
        \\  SELECT d.src_id, d.dst_id
        \\  FROM deps d
        \\  JOIN issues si ON si.id = d.src_id
        \\  WHERE d.kind = 'blocks' AND d.state = 'active' AND si.status IN ('open','in_progress','paused')
        \\  UNION
        \\  SELECT b.src, d.dst_id
        \\  FROM blockers b
        \\  JOIN deps d ON d.src_id = b.dst AND d.kind = 'blocks' AND d.state = 'active'
        \\  JOIN issues si ON si.id = d.src_id
        \\  WHERE si.status IN ('open','in_progress','paused')
        \\)
        \\SELECT i.id, i.status, i.title, i.updated_at, i.priority,
        \\  (SELECT group_concat(t.name, ',') FROM tags t JOIN issue_tags it ON it.tag_id = t.id WHERE it.issue_id = i.id),
        \\  i.body
        \\FROM issues i
        \\WHERE i.status = 'open'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM blockers b
        \\  JOIN issues bi ON bi.id = b.src
        \\  WHERE b.dst = i.id AND bi.status IN ('open','in_progress','paused')
        \\)
        \\ORDER BY i.priority ASC, i.updated_at DESC
    );
    if (limit != null) {
        try sql.appendSlice(allocator, " LIMIT ?");
    }

    const stmt = try tissue.sqlite.prepare(store.db, sql.items);
    defer tissue.sqlite.finalize(stmt);

    if (limit != null) {
        try tissue.sqlite.bindInt64(stmt, 1, limit.?);
    }

    if (json) {
        try stdout.writeByte('[');
        var first = true;
        while (try tissue.sqlite.step(stmt)) {
            const record = struct {
                id: []const u8,
                status: []const u8,
                title: []const u8,
                updated_at: i64,
                priority: i32,
                tags: []const u8,
                body: []const u8,
            }{
                .id = tissue.sqlite.columnText(stmt, 0),
                .status = tissue.sqlite.columnText(stmt, 1),
                .title = tissue.sqlite.columnText(stmt, 2),
                .updated_at = tissue.sqlite.columnInt64(stmt, 3),
                .priority = tissue.sqlite.columnInt(stmt, 4),
                .tags = tissue.sqlite.columnText(stmt, 5),
                .body = tissue.sqlite.columnText(stmt, 6),
            };
            if (!first) try stdout.writeByte(',');
            first = false;
            try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        }
        try stdout.writeByte(']');
        try stdout.writeByte('\n');
        return;
    }

    try stdout.print("{s:10} {s:1} {s:7} {s:30} {s:43} {s}\n", .{ "ID", "P", "Status", "Title", "Description", "Tags" });
    while (try tissue.sqlite.step(stmt)) {
        const id = tissue.sqlite.columnText(stmt, 0);
        const status_val = tissue.sqlite.columnText(stmt, 1);
        const title_val = tissue.sqlite.columnText(stmt, 2);
        const priority_val: u32 = @intCast(tissue.sqlite.columnInt(stmt, 4));
        const tags_val = tissue.sqlite.columnText(stmt, 5);
        const body_val = tissue.sqlite.columnText(stmt, 6);
        const tags_display = if (tags_val.len == 0) "-" else tags_val;
        var desc_buf: [48]u8 = undefined;
        const desc = truncateDesc(body_val, &desc_buf);
        var title_buf: [30]u8 = undefined;
        const title_display = truncateTitle(title_val, &title_buf);
        try stdout.print("{s:10} {d} {s:7} {s:30} {s:43} {s}\n", .{ shortId(id), priority_val, status_val, title_display, desc, tags_display });
    }
}

fn printIssueDetails(writer: *std.Io.Writer, issue: *const tissue.store.Issue, comments: []tissue.store.Comment, deps: []tissue.store.Dep) !void {
    try writer.print("ID: {s}\n", .{issue.id});
    try writer.print("Title: {s}\n", .{issue.title});
    try writer.print("Status: {s}\n", .{issue.status});
    try writer.print("Priority: {d}\n", .{issue.priority});
    try writer.print("Tags:", .{});
    if (issue.tags.len == 0) {
        try writer.print(" (none)\n", .{});
    } else {
        for (issue.tags, 0..) |tag, idx| {
            if (idx == 0) {
                try writer.print(" {s}", .{tag});
            } else {
                try writer.print(", {s}", .{tag});
            }
        }
        try writer.print("\n", .{});
    }
    var created_buf: [32]u8 = undefined;
    var updated_buf: [32]u8 = undefined;
    const created_str = formatTimestamp(issue.created_at, &created_buf);
    const updated_str = formatTimestamp(issue.updated_at, &updated_buf);
    try writer.print("Created: {s}\n", .{created_str});
    try writer.print("Updated: {s}\n", .{updated_str});
    if (issue.body.len > 0) {
        try writer.print("\n{s}\n", .{issue.body});
    }
    if (deps.len > 0) {
        try writer.print("\nDeps:\n", .{});
        for (deps) |dep| {
            try writer.print("- {s} {s} -> {s}\n", .{ dep.kind, shortId(dep.src_id), shortId(dep.dst_id) });
        }
    }
    if (comments.len > 0) {
        try writer.print("\nComments:\n", .{});
        for (comments) |comment| {
            try writer.print("- {s}\n", .{comment.body});
        }
    }
}

fn shortId(id: []const u8) []const u8 {
    const len = if (id.len > 16) 16 else id.len;
    return id[0..len];
}

fn truncateDesc(body: []const u8, buf: *[48]u8) []const u8 {
    if (body.len == 0) return "-";
    // Find first line (stop at newline)
    var end: usize = 0;
    for (body) |c| {
        if (c == '\n' or c == '\r') break;
        end += 1;
    }
    const first_line = body[0..end];
    const max_len: usize = 40;
    if (first_line.len <= max_len) {
        @memcpy(buf[0..first_line.len], first_line);
        return buf[0..first_line.len];
    }
    @memcpy(buf[0..max_len], first_line[0..max_len]);
    buf[max_len] = '.';
    buf[max_len + 1] = '.';
    buf[max_len + 2] = '.';
    return buf[0 .. max_len + 3];
}

fn truncateTitle(title: []const u8, buf: *[30]u8) []const u8 {
    const max_len: usize = 27;
    if (title.len <= max_len) return title;
    @memcpy(buf[0..max_len], title[0..max_len]);
    buf[max_len] = '.';
    buf[max_len + 1] = '.';
    buf[max_len + 2] = '.';
    return buf[0 .. max_len + 3];
}

fn formatTimestamp(millis: i64, buf: *[32]u8) []const u8 {
    const secs = @divFloor(millis, 1000);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(secs)) };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = @as(u8, @intFromEnum(month_day.month));
    const day = month_day.day_index + 1; // day_index is 0-indexed
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, month, day, hour, minute, second,
    }) catch "invalid date";
}

const Bind = union(enum) {
    text: []const u8,
    int: i64,
};

fn nextValue(args: []const []const u8, index: *usize, name: []const u8) []const u8 {
    const i = index.*;
    if (i + 1 >= args.len) die("missing value for {s}", .{name});
    index.* = i + 2;
    return args[i + 1];
}

fn parseInt(comptime T: type, value: []const u8, name: []const u8) T {
    return std.fmt.parseInt(T, value, 10) catch {
        die("invalid {s}: {s}", .{ name, value });
    };
}

fn validateStatus(status: []const u8) void {
    if (std.mem.eql(u8, status, "open") or
        std.mem.eql(u8, status, "in_progress") or
        std.mem.eql(u8, status, "paused") or
        std.mem.eql(u8, status, "duplicate") or
        std.mem.eql(u8, status, "closed")) return;
    die("invalid status: {s} (use open, in_progress, paused, duplicate, closed)", .{status});
}

fn validatePriority(priority: i32) void {
    if (priority >= 1 and priority <= 5) return;
    die("invalid priority: {d} (must be 1-5)", .{priority});
}

fn processEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                else => {
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Discovers an existing store directory.
/// Priority: override (--store) > directory walk > TISSUE_STORE env
fn discoverStoreDir(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    // Priority 1: --store flag
    if (override) |path| {
        return resolvePath(allocator, path);
    }

    // Priority 2: Walk up directory tree (local stores take precedence)
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    var current: []const u8 = cwd;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, ".tissue" });
        if (dirExists(candidate)) return candidate;
        allocator.free(candidate);
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    // Priority 3: TISSUE_STORE environment variable (fallback)
    if (std.process.getEnvVarOwned(allocator, "TISSUE_STORE")) |env| {
        defer allocator.free(env);
        return resolvePath(allocator, env);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    return tissue.store.StoreError.StoreNotFound;
}

/// Determines the store directory for initialization.
/// Priority: override (--store) > cwd/.tissue > TISSUE_STORE env
fn initStoreDir(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    // Priority 1: --store flag
    if (override) |path| {
        return resolvePath(allocator, path);
    }

    // Priority 2: Default to cwd/.tissue (local stores take precedence)
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const local_store = try std.fs.path.join(allocator, &.{ cwd, ".tissue" });

    // If local store exists, use it
    if (dirExists(local_store)) return local_store;

    // Priority 3: TISSUE_STORE environment variable (fallback for new stores)
    if (std.process.getEnvVarOwned(allocator, "TISSUE_STORE")) |env| {
        defer allocator.free(env);
        allocator.free(local_store);
        return resolvePath(allocator, env);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => {
            allocator.free(local_store);
            return err;
        },
    }

    // No env var set, use local cwd/.tissue
    return local_store;
}

fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn dieOnError(err: anyerror) noreturn {
    const msg: []const u8 = switch (err) {
        tissue.store.StoreError.StoreNotFound => "No tissue store found. Run 'tissue init' first.",
        tissue.store.StoreError.IssueNotFound => "Issue not found.",
        tissue.store.StoreError.IssueIdAmbiguous => "Ambiguous issue ID: matches multiple issues. Use more characters.",
        tissue.store.StoreError.InvalidIdPrefix => "Invalid issue ID.",
        tissue.store.StoreError.InvalidPrefix => "Invalid issue prefix. Use letters, numbers, and hyphens.",
        tissue.store.StoreError.InvalidDepKind => "Invalid dependency kind. Use: blocks, relates, or parent.",
        tissue.store.StoreError.SelfDependency => "An issue cannot depend on itself.",
        tissue.store.StoreError.IssueIdCollision => "Failed to generate a unique issue ID. Try again.",
        tissue.store.StoreError.DatabaseBusy => "Database busy. Please retry.",
        tissue.sqlite.Error.SqliteBusy => "Database busy. Please retry.",
        tissue.sqlite.Error.SqliteError => "Database error.",
        tissue.sqlite.Error.SqliteStepError => "Database query error.",
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\tissue - fast local issue tracker
        \\
        \\Usage:
        \\  tissue [--store <path>] <command> [args] [--json]
        \\
        \\Global options:
        \\  --store <path>  Use specified directory as the store (also --store=<path>)
        \\  --              End of global options (useful when path starts with -)
        \\
        \\Behavior (agent-friendly):
        \\  Exit codes: 0 success, 1 failure (errors on stderr)
        \\  Store discovery: --store wins; else walk up for .tissue; else TISSUE_STORE
        \\  --json outputs minified JSON with a trailing newline
        \\  --quiet outputs id only (new/edit/status/comment/tag/dep; overrides --json)
        \\  Body/message expands \n, \t, and \\
        \\  JSON shapes: see README.md (JSON output reference)
        \\  Status values: open, in_progress, paused, duplicate, closed
        \\
        \\ID input:
        \\  full id, unique leading prefix, or hash prefix (no dash)
        \\
        \\Commands:
        \\  help [command]
        \\      Show general help or command-specific help.
        \\
        \\  init [--prefix prefix] [--json]
        \\      Create the store directory and files.
        \\
        \\  post "title" [-b body] [-t tag] [-p 1-5] [--json|--quiet]
        \\      Create an issue. -t is repeatable. Default priority is 2. (alias: new)
        \\
        \\  list [--status s] [--tag t] [--search q] [--limit N] [-s|--summary] [--json]
        \\      List issues (newest first). --tag is exact match; --search uses FTS5.
        \\      -s/--summary omits description column for compact output.
        \\
        \\  search <query> [--limit N] [-s|--summary] [--json]
        \\      Search issues using FTS5 (standalone command for list --search).
        \\
        \\  show <id> [--json]
        \\      Show full issue details, deps, and comments.
        \\
        \\  edit <id> [--title t] [--body b] [--status open|in_progress|paused|duplicate|closed] [--priority 1-5]
        \\       [--add-tag t] [--rm-tag t] [--json|--quiet]
        \\      Update fields/tags. At least one change is required.
        \\
        \\  status <id> <open|in_progress|paused|duplicate|closed> [--json|--quiet]
        \\      Update status only.
        \\
        \\  reply <id> -m "text" [--json|--quiet]
        \\      Add a comment (-m/--message required). (alias: comment)
        \\
        \\  tag <add|rm> <id> <tag> [--json|--quiet]
        \\      Add or remove a single tag.
        \\
        \\  dep <add|rm> <id> <blocks|relates|parent> <target> [--json|--quiet]
        \\      Add or remove a dependency edge. relates is undirected.
        \\
        \\  deps <id> [--json]
        \\      List active deps that involve the issue.
        \\
        \\  ready [--limit N] [--json]
        \\      List open issues with no active blockers (open/in_progress/paused).
        \\
        \\  clean [--older-than Nd] [--force] [--json]
        \\      Remove closed/duplicate issues from the JSONL log (use --force to execute).
        \\
        \\  migrate <source-store> [--dry-run] [--json]
        \\      Import issues from another tissue store. Skips duplicates by ID.
        \\
        \\Examples:
        \\  tissue init --prefix acme
        \\  id=$(tissue new "Fix flaky tests" --quiet)
        \\  tissue list --search "flake" --json
        \\  tissue dep add $id blocks tissue-b19c2d
        \\  tissue clean --older-than 30d --force
        \\
    , .{});
}

fn printCommandHelp(cmd: []const u8) bool {
    if (std.mem.eql(u8, cmd, "help")) {
        std.debug.print(
            \\tissue help - show help
            \\
            \\Usage:
            \\  tissue help
            \\  tissue help <command>
            \\
            \\Description:
            \\  Shows general help or detailed help for a single command.
            \\
            \\Examples:
            \\  tissue help
            \\  tissue help new
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        std.debug.print(
            \\tissue init - create store
            \\
            \\Usage:
            \\  tissue init [--json] [--prefix prefix]
            \\
            \\Description:
            \\  Creates the .tissue store directory and files. If it already exists,
            \\  it is reused. Store discovery walks up for .tissue, then falls back to TISSUE_STORE.
            \\
            \\Options:
            \\  --prefix <p>  set or update the issue id prefix
            \\  --json        output {{"store": "...", "prefix": "..."}}
            \\
            \\Output:
            \\  Human: initialized/already initialized
            \\  JSON: object on stdout; if already exists, a note is printed to stderr
            \\
            \\Examples:
            \\  tissue init
            \\  tissue init --prefix acme --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "post")) {
        std.debug.print(
            \\tissue post - create issue (alias: new)
            \\
            \\Usage:
            \\  tissue post "title" [-b body] [-t tag] [-p 1-5] [--json|--quiet]
            \\
            \\Description:
            \\  Creates a new issue with status open. Tags are repeatable.
            \\  Body/message expands \n, \t, and \\.
            \\
            \\Options:
            \\  -b, --body <b>      optional body
            \\  -t, --tag <t>       add a tag (repeatable)
            \\  -p, --priority <n>  1 (highest) to 5 (lowest), default 2
            \\  --json              output Issue record
            \\  --quiet             output id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: issue id
            \\  JSON: Issue record (see README.md JSON output reference)
            \\
            \\Examples:
            \\  tissue post "Add caching" -b "Targets /v1/search" -t perf -p 1
            \\  tissue post "Follow up" --quiet
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        std.debug.print(
            \\tissue list - list issues
            \\
            \\Usage:
            \\  tissue list [--status s] [--tag t] [--search q] [--limit N] [-s|--summary] [--json]
            \\
            \\Description:
            \\  Lists issues, newest first. --tag is exact match. --search uses SQLite FTS5.
            \\
            \\Options:
            \\  --status <s>    open, in_progress, paused, duplicate, or closed
            \\  --tag <t>       filter by tag
            \\  --search <q>    FTS5 query (use quotes for phrases)
            \\  --limit <n>     max results
            \\  -s, --summary   omit description column for compact output
            \\  --json          output array of list rows
            \\
            \\Output:
            \\  Human: table with truncated title/body (or just title with -s)
            \\  JSON: rows with full body and comma-separated tags
            \\
            \\Examples:
            \\  tissue list --status open --limit 20
            \\  tissue list --tag build --search "flake" --json
            \\  tissue list -s
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "search")) {
        std.debug.print(
            \\tissue search - search issues
            \\
            \\Usage:
            \\  tissue search <query> [--limit N] [-s|--summary] [--json]
            \\
            \\Description:
            \\  Searches issues using SQLite FTS5. Standalone command equivalent to
            \\  'tissue list --search <query>'. Results ranked by BM25 relevance.
            \\
            \\Options:
            \\  --limit <n>     max results
            \\  -s, --summary   omit description column for compact output
            \\  --json          output array of list rows
            \\
            \\Output:
            \\  Human: table with truncated title/body (or just title with -s)
            \\  JSON: rows with full body and comma-separated tags
            \\
            \\Examples:
            \\  tissue search "authentication bug"
            \\  tissue search cache --limit 10 --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "show")) {
        std.debug.print(
            \\tissue show - show issue
            \\
            \\Usage:
            \\  tissue show <id> [--json]
            \\
            \\Description:
            \\  Shows the full issue details, dependencies, and comments.
            \\
            \\Options:
            \\  --json  output {{issue, comments, deps}}
            \\
            \\Output:
            \\  Human: formatted issue view
            \\  JSON: object with Issue, Comment[], Dep[]
            \\
            \\Example:
            \\  tissue show tissue-a3f8e9 --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "edit")) {
        std.debug.print(
            \\tissue edit - update issue
            \\
            \\Usage:
            \\  tissue edit <id> [--title t] [--body b] [--status open|in_progress|paused|duplicate|closed]
            \\       [--priority 1-5] [--add-tag t] [--rm-tag t] [--json|--quiet]
            \\
            \\Description:
            \\  Updates fields/tags. At least one change is required.
            \\  Body/message expands \n, \t, and \\.
            \\
            \\Options:
            \\  --title <t>      new title
            \\  --body <b>       new body
            \\  --status <s>     open, in_progress, paused, duplicate, or closed
            \\  --priority <n>   1 (highest) to 5 (lowest)
            \\  --add-tag <t>    add tag (repeatable)
            \\  --rm-tag <t>     remove tag (repeatable)
            \\  --json           output Issue record
            \\  --quiet          output id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: issue id
            \\  JSON: Issue record
            \\
            \\Examples:
            \\  tissue edit tissue-a3f8e9 --status closed --rm-tag build
            \\  tissue edit tissue-a3f8e9 --body "Line 1\nLine 2"
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        std.debug.print(
            \\tissue status - update status
            \\
            \\Usage:
            \\  tissue status <id> <open|in_progress|paused|duplicate|closed> [--json|--quiet]
            \\
            \\Description:
            \\  Shorthand for changing only the status field.
            \\  Allowed values: open, in_progress, paused, duplicate, closed.
            \\
            \\Options:
            \\  --json   output Issue record
            \\  --quiet  output id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: issue id
            \\  JSON: Issue record
            \\
            \\Example:
            \\  tissue status tissue-a3f8e9 closed
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "comment") or std.mem.eql(u8, cmd, "reply")) {
        std.debug.print(
            \\tissue reply - add comment (alias: comment)
            \\
            \\Usage:
            \\  tissue reply <id> -m "text" [--json|--quiet]
            \\
            \\Description:
            \\  Adds a comment to an issue. Body/message expands \n, \t, and \\.
            \\
            \\Options:
            \\  -m, --message <t>  required comment text
            \\  --json             output {{id, issue_id, body}}
            \\  --quiet            output comment id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: comment id (ULID)
            \\  JSON: {{id, issue_id, body}}
            \\
            \\Example:
            \\  tissue reply tissue-a3f8e9 -m "Investigating\nWorking on fix"
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "tag")) {
        std.debug.print(
            \\tissue tag - add/remove tag
            \\
            \\Usage:
            \\  tissue tag <add|rm> <id> <tag> [--json|--quiet]
            \\
            \\Description:
            \\  Adds or removes a single tag.
            \\
            \\Options:
            \\  --json   output Issue record
            \\  --quiet  output id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: issue id
            \\  JSON: Issue record
            \\
            \\Examples:
            \\  tissue tag add tissue-a3f8e9 backlog
            \\  tissue tag rm tissue-a3f8e9 backlog
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "dep")) {
        std.debug.print(
            \\tissue dep - add/remove dependency
            \\
            \\Usage:
            \\  tissue dep <add|rm> <id> <blocks|relates|parent> <target> [--json|--quiet]
            \\
            \\Description:
            \\  Adds or removes a dependency edge.
            \\  blocks/parent are directional (src -> dst); relates is undirected.
            \\
            \\Options:
            \\  --json   output {{action, src_id, dst_id, kind}}
            \\  --quiet  output id only (overrides --json)
            \\
            \\Output:
            \\  Default/quiet: source issue id
            \\  JSON: {{action, src_id, dst_id, kind}}
            \\
            \\Examples:
            \\  tissue dep add tissue-a3f8e9 blocks tissue-b19c2d
            \\  tissue dep rm tissue-a3f8e9 relates tissue-b19c2d
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "deps")) {
        std.debug.print(
            \\tissue deps - list dependencies
            \\
            \\Usage:
            \\  tissue deps <id> [--json]
            \\
            \\Description:
            \\  Lists active dependencies that involve the issue.
            \\
            \\Options:
            \\  --json  output array of Dep records
            \\
            \\Output:
            \\  Human: "kind src -> dst" per line
            \\  JSON: Dep records (state is active)
            \\
            \\Example:
            \\  tissue deps tissue-a3f8e9 --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "ready")) {
        std.debug.print(
            \\tissue ready - list unblocked issues
            \\
            \\Usage:
            \\  tissue ready [--limit N] [--json]
            \\
            \\Description:
            \\  Lists open issues with no active blockers (transitive blocks only).
            \\  Blockers include issues with status open, in_progress, or paused.
            \\  Results are sorted by priority (highest first), then by update time.
            \\
            \\Options:
            \\  --limit N  limit to N results
            \\  --json     output array of list rows
            \\
            \\Output:
            \\  Same shape as tissue list
            \\
            \\Example:
            \\  tissue ready --limit 10
            \\  tissue ready --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "clean")) {
        std.debug.print(
            \\tissue clean - remove closed issues
            \\
            \\Usage:
            \\  tissue clean [--older-than Nd] [--force] [--json]
            \\
            \\Description:
            \\  Removes closed or duplicate issues from the JSONL log and rebuilds the cache.
            \\  Without --force, this is a dry run.
            \\
            \\Options:
            \\  --older-than <n>  only remove issues updated more than N days ago (30 or 30d)
            \\  --force           perform the removal
            \\  --json            output summary object
            \\
            \\Output:
            \\  Human: list of issues to remove and a summary
            \\  JSON: {{"dry_run":true,"count":N,"issues":[...]}} or {{"removed":0,"issues":[]}}
            \\
            \\Examples:
            \\  tissue clean --older-than 30d
            \\  tissue clean --older-than 30 --force --json
            \\
        , .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "migrate")) {
        std.debug.print(
            \\tissue migrate - import issues from another store
            \\
            \\Usage:
            \\  tissue migrate <source-store> [--dry-run] [--json]
            \\
            \\Description:
            \\  Imports issues, comments, and dependencies from another tissue store.
            \\  Skips records that already exist in the destination (by ID).
            \\  Dependencies are only migrated if both referenced issues exist.
            \\
            \\Options:
            \\  --dry-run  preview what would be migrated without making changes
            \\  --json     output summary object
            \\
            \\Output:
            \\  Human: count of issues/comments/deps migrated
            \\  JSON: {{"dry_run":false,"issues":N,"comments":N,"deps":N}}
            \\
            \\Examples:
            \\  tissue migrate ~/Dev/project/.tissue --dry-run
            \\  tissue migrate /path/to/.tissue --json
            \\
        , .{});
        return true;
    }
    return false;
}
