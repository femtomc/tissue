const std = @import("std");
const tissue = @import("tissue");

const Store = tissue.store.Store;

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

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        cmdInit(allocator, stdout, args[2..]) catch |err| {
            dieOnError(err);
        };
        return;
    }

    const store_dir = discoverStoreDir(allocator) catch |err| {
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
        if (std.mem.eql(u8, cmd, "new")) {
            break :blk cmdNew(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "list")) {
            break :blk cmdList(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "show")) {
            break :blk cmdShow(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "edit")) {
            break :blk cmdEdit(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "status")) {
            break :blk cmdStatus(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "comment")) {
            break :blk cmdComment(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "tag")) {
            break :blk cmdTag(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "dep")) {
            break :blk cmdDep(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "deps")) {
            break :blk cmdDeps(allocator, stdout, &store, args[2..]);
        } else if (std.mem.eql(u8, cmd, "ready")) {
            break :blk cmdReady(allocator, stdout, &store, args[2..]);
        } else {
            die("unknown command: {s}", .{cmd});
        }
    };

    result catch |err| {
        dieOnError(err);
    };
}

fn cmdInit(allocator: std.mem.Allocator, stdout: *std.Io.Writer, args: []const []const u8) !void {
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

    const store_dir = try initStoreDir(allocator);
    defer allocator.free(store_dir);
    std.fs.makeDirAbsolute(store_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
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

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
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

    try listIssues(allocator, stdout, store, status, tag, search, limit, json);
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

    if (id_input == null or status == null) die("usage: tissue status <id> <open|closed>", .{});
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
        } else {
            die("unknown flag: {s}", .{args[i]});
        }
    }
    try listReady(allocator, stdout, store, json);
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
) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    var binds: std.ArrayList(Bind) = .empty;
    defer binds.deinit(allocator);

    const tags_expr =
        "(SELECT group_concat(t.name, ',') FROM tags t JOIN issue_tags it ON it.tag_id = t.id WHERE it.issue_id = i.id)";
    try sql.appendSlice(allocator, "SELECT i.id, i.status, i.title, i.updated_at, i.priority, ");
    try sql.appendSlice(allocator, tags_expr);
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
        try sql.appendSlice(allocator, "ORDER BY bm25(issues_fts, 1.0, 0.5), i.updated_at DESC ");
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
            }{
                .id = tissue.sqlite.columnText(stmt, 0),
                .status = tissue.sqlite.columnText(stmt, 1),
                .title = tissue.sqlite.columnText(stmt, 2),
                .updated_at = tissue.sqlite.columnInt64(stmt, 3),
            };
            if (!first) try stdout.writeByte(',');
            first = false;
            try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        }
        try stdout.writeByte(']');
        try stdout.writeByte('\n');
        return;
    }

    try stdout.print("{s:10} {s:7} {s:3} {s} {s}\n", .{ "ID", "Status", "Pri", "Title", "Tags" });
    while (try tissue.sqlite.step(stmt)) {
        const id = tissue.sqlite.columnText(stmt, 0);
        const status_val = tissue.sqlite.columnText(stmt, 1);
        const title_val = tissue.sqlite.columnText(stmt, 2);
        const priority_val = tissue.sqlite.columnInt(stmt, 4);
        const tags_val = tissue.sqlite.columnText(stmt, 5);
        const tags_display = if (tags_val.len == 0) "-" else tags_val;
        try stdout.print("{s:10} {s:7} {d:3} {s} {s}\n", .{ shortId(id), status_val, priority_val, title_val, tags_display });
    }
}

fn listReady(allocator: std.mem.Allocator, stdout: *std.Io.Writer, store: *Store, json: bool) !void {
    _ = allocator;
    const sql =
        \\WITH RECURSIVE blockers(src, dst) AS (
        \\  SELECT d.src_id, d.dst_id
        \\  FROM deps d
        \\  JOIN issues si ON si.id = d.src_id
        \\  WHERE d.kind = 'blocks' AND d.state = 'active' AND si.status = 'open'
        \\  UNION
        \\  SELECT b.src, d.dst_id
        \\  FROM blockers b
        \\  JOIN deps d ON d.src_id = b.dst AND d.kind = 'blocks' AND d.state = 'active'
        \\  JOIN issues si ON si.id = d.src_id
        \\  WHERE si.status = 'open'
        \\)
        \\SELECT i.id, i.status, i.title, i.updated_at
        \\FROM issues i
        \\WHERE i.status = 'open'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM blockers b
        \\  JOIN issues bi ON bi.id = b.src
        \\  WHERE b.dst = i.id AND bi.status = 'open'
        \\)
        \\ORDER BY i.updated_at DESC
    ;
    const stmt = try tissue.sqlite.prepare(store.db, sql);
    defer tissue.sqlite.finalize(stmt);

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
            }{
                .id = tissue.sqlite.columnText(stmt, 0),
                .status = tissue.sqlite.columnText(stmt, 1),
                .title = tissue.sqlite.columnText(stmt, 2),
                .updated_at = tissue.sqlite.columnInt64(stmt, 3),
                .priority = tissue.sqlite.columnInt(stmt, 4),
                .tags = tissue.sqlite.columnText(stmt, 5),
            };
            if (!first) try stdout.writeByte(',');
            first = false;
            try std.json.Stringify.value(record, .{ .whitespace = .minified }, stdout);
        }
        try stdout.writeByte(']');
        try stdout.writeByte('\n');
        return;
    }

    try stdout.print("{s:16} {s:1} {s:7} {s} {s}\n", .{ "ID", "P", "Status", "Title", "Tags" });
    while (try tissue.sqlite.step(stmt)) {
        const id = tissue.sqlite.columnText(stmt, 0);
        const status_val = tissue.sqlite.columnText(stmt, 1);
        const title_val = tissue.sqlite.columnText(stmt, 2);
        const priority_val = tissue.sqlite.columnInt(stmt, 4);
        const tags_val = tissue.sqlite.columnText(stmt, 5);
        try stdout.print("{s:16} {d:1} {s:7} {s}", .{ shortId(id), priority_val, status_val, title_val });
        if (tags_val.len > 0) {
            try stdout.print(" {s}", .{tags_val});
        }
        try stdout.writeByte('\n');
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
    if (std.mem.eql(u8, status, "open") or std.mem.eql(u8, status, "closed")) return;
    die("invalid status: {s}", .{status});
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

fn discoverStoreDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "TISSUE_STORE")) |env| {
        defer allocator.free(env);
        return resolvePath(allocator, env);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
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
    return tissue.store.StoreError.StoreNotFound;
}

fn initStoreDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "TISSUE_STORE")) |env| {
        defer allocator.free(env);
        return resolvePath(allocator, env);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".tissue" });
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
        \\  tissue init [--json] [--prefix prefix]
        \\  tissue new "title" [-b body] [-t tag] [-p 1-5] [--json|--quiet]
        \\  tissue list [--status open|closed] [--tag tag] [--search query] [--limit N] [--json]
        \\  tissue show <id> [--json]
        \\  tissue edit <id> [--title t] [--body b] [--status open|closed] [--priority 1-5] [--add-tag t] [--rm-tag t] [--json|--quiet]
        \\  tissue status <id> <open|closed> [--json|--quiet]
        \\  tissue comment <id> -m "text" [--json|--quiet]
        \\  tissue tag <add|rm> <id> <tag> [--json|--quiet]
        \\  tissue dep <add|rm> <id> <blocks|relates|parent> <target> [--json|--quiet]
        \\  tissue deps <id> [--json]
        \\  tissue ready [--json]
        \\
    , .{});
}
