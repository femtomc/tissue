const std = @import("std");
const sqlite = @import("sqlite.zig");
const ids = @import("ids.zig");

pub const StoreError = error{
    StoreNotFound,
    IssueNotFound,
    IssueIdAmbiguous,
    InvalidIdPrefix,
    InvalidPrefix,
    InvalidDepKind,
    SelfDependency,
    IssueIdCollision,
    DatabaseBusy,
} || sqlite.Error;

pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    status: []const u8,
    priority: i32,
    created_at: i64,
    updated_at: i64,
    rev: []const u8,
    tags: []const []const u8,

    pub fn deinit(self: *Issue, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.status);
        allocator.free(self.rev);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
    }
};

pub const Comment = struct {
    id: []const u8,
    issue_id: []const u8,
    body: []const u8,
    created_at: i64,

    pub fn deinit(self: *Comment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.issue_id);
        allocator.free(self.body);
    }
};

pub const Dep = struct {
    src_id: []const u8,
    dst_id: []const u8,
    kind: []const u8,
    state: []const u8,
    created_at: i64,
    rev: []const u8,

    pub fn deinit(self: *Dep, allocator: std.mem.Allocator) void {
        allocator.free(self.src_id);
        allocator.free(self.dst_id);
        allocator.free(self.kind);
        allocator.free(self.state);
        allocator.free(self.rev);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.c.sqlite3,
    store_dir: []const u8,
    db_path: []const u8,
    jsonl_path: []const u8,
    ulid: ids.Generator,
    id_prefix: []const u8,
    lock_file: ?std.fs.File = null,

    pub fn open(allocator: std.mem.Allocator, store_dir: []const u8) !Store {
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "issues.db" });
        errdefer allocator.free(db_path);
        const jsonl_path = try std.fs.path.join(allocator, &.{ store_dir, "issues.jsonl" });
        errdefer allocator.free(jsonl_path);

        const db = try sqlite.open(db_path);
        errdefer sqlite.close(db);

        var store = Store{
            .allocator = allocator,
            .db = db,
            .store_dir = try allocator.dupe(u8, store_dir),
            .db_path = db_path,
            .jsonl_path = jsonl_path,
            .ulid = ids.Generator.init(seedFromTime()),
            .id_prefix = &.{},
            .lock_file = null,
        };
        errdefer allocator.free(store.store_dir);

        try store.setPragmas();
        try store.ensureSchema();
        try store.loadIdPrefix();
        try store.initLock();
        return store;
    }

    pub fn deinit(self: *Store) void {
        sqlite.close(self.db);
        self.allocator.free(self.store_dir);
        self.allocator.free(self.db_path);
        self.allocator.free(self.jsonl_path);
        if (self.id_prefix.len > 0) self.allocator.free(self.id_prefix);
        if (self.lock_file) |*lf| lf.close();
    }

    fn initLock(self: *Store) !void {
        const lock_path = try std.fs.path.join(self.allocator, &.{ self.store_dir, "lock" });
        defer self.allocator.free(lock_path);
        const file = try std.fs.createFileAbsolute(lock_path, .{
            .truncate = false,
            .read = true,
            .mode = 0o600,
        });
        self.lock_file = file;
    }

    fn loadIdPrefix(self: *Store) !void {
        if (try self.getMetaText("id_prefix")) |prefix| {
            defer self.allocator.free(prefix);
            if (normalizePrefix(self.allocator, prefix)) |normalized| {
                errdefer self.allocator.free(normalized);
                if (!std.mem.eql(u8, normalized, prefix)) {
                    try self.setMetaText("id_prefix", normalized);
                }
                self.id_prefix = normalized;
                return;
            } else |_| {}
        }
        const derived = try deriveDefaultPrefix(self.allocator, self.store_dir);
        errdefer self.allocator.free(derived);
        try self.setMetaText("id_prefix", derived);
        self.id_prefix = derived;
    }

    pub fn setIdPrefix(self: *Store, prefix: []const u8) !void {
        const normalized = try normalizePrefix(self.allocator, prefix);
        errdefer self.allocator.free(normalized);
        try self.setMetaText("id_prefix", normalized);
        if (self.id_prefix.len > 0) self.allocator.free(self.id_prefix);
        self.id_prefix = normalized;
    }

    pub fn ensureSchema(self: *Store) !void {
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS issues (
            \\  id TEXT PRIMARY KEY,
            \\  title TEXT NOT NULL,
            \\  body TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  priority INTEGER NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL,
            \\  rev TEXT NOT NULL
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS tags (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL UNIQUE
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS issue_tags (
            \\  issue_id TEXT NOT NULL,
            \\  tag_id INTEGER NOT NULL,
            \\  UNIQUE(issue_id, tag_id),
            \\  FOREIGN KEY(issue_id) REFERENCES issues(id) ON DELETE CASCADE,
            \\  FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS comments (
            \\  id TEXT PRIMARY KEY,
            \\  issue_id TEXT NOT NULL,
            \\  body TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  FOREIGN KEY(issue_id) REFERENCES issues(id) ON DELETE CASCADE
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS deps (
            \\  src_id TEXT NOT NULL,
            \\  dst_id TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  state TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  rev TEXT NOT NULL,
            \\  PRIMARY KEY(src_id, dst_id, kind)
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS meta (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL
            \\);
        );
        try sqlite.exec(self.db,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS issues_fts USING fts5(title, body);
        );
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_issues_status_updated ON issues(status, updated_at);
        );
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_issue_tags_issue ON issue_tags(issue_id);
        );
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_issue_tags_tag ON issue_tags(tag_id);
        );
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_deps_src ON deps(src_id);
        );
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_deps_dst ON deps(dst_id);
        );
    }

    pub fn setPragmas(self: *Store) !void {
        try sqlite.exec(self.db, "PRAGMA journal_mode=WAL;");
        try sqlite.exec(self.db, "PRAGMA synchronous=NORMAL;");
        try sqlite.exec(self.db, "PRAGMA busy_timeout=300000;");
        try sqlite.exec(self.db, "PRAGMA temp_store=MEMORY;");
        try sqlite.exec(self.db, "PRAGMA foreign_keys=ON;");
    }

    pub fn ensureJsonl(self: *Store) !void {
        if (fileExists(self.jsonl_path)) return;
        var file = try std.fs.createFileAbsolute(self.jsonl_path, .{});
        file.close();
        try self.setMetaInt("jsonl_offset", 0);
        try self.setMetaInt("jsonl_inode", 0);
        try self.setMetaInt("jsonl_mtime", 0);
    }

    pub fn importIfNeeded(self: *Store) !void {
        try self.ensureJsonl();
        const stat = try statFile(self.jsonl_path);
        const inode = @as(u64, @intCast(stat.inode));
        const mtime = @as(u64, @intCast(stat.mtime));
        const size = stat.size;

        const stored_inode = (try self.getMetaInt("jsonl_inode")) orelse 0;
        const stored_offset = (try self.getMetaInt("jsonl_offset")) orelse 0;
        const stored_mtime = (try self.getMetaInt("jsonl_mtime")) orelse 0;

        if (inode != stored_inode or size < stored_offset or mtime < stored_mtime) {
            try self.fullReimport();
            return;
        }
        if (size == stored_offset) return;
        try self.importFromOffset(stored_offset);
    }

    pub fn createIssue(
        self: *Store,
        title: []const u8,
        body: []const u8,
        priority: i32,
        tags: []const []const u8,
    ) ![]u8 {
        return retryWrite([]u8, createIssueOnce, .{ self, title, body, priority, tags });
    }

    fn createIssueOnce(
        self: *Store,
        title: []const u8,
        body: []const u8,
        priority: i32,
        tags: []const []const u8,
    ) ![]u8 {
        const now_ms = @as(i64, @intCast(std.time.milliTimestamp()));
        const rev = try self.ulid.nextNow(self.allocator);
        defer self.allocator.free(rev);

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        const id = try self.generateIssueId(title, body, now_ms);
        errdefer self.allocator.free(id);
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO issues(id, title, body, status, priority, created_at, updated_at, rev)
            \\VALUES (?, ?, ?, 'open', ?, ?, ?, ?);
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        try sqlite.bindText(stmt, 2, title);
        try sqlite.bindText(stmt, 3, body);
        try sqlite.bindInt(stmt, 4, priority);
        try sqlite.bindInt64(stmt, 5, now_ms);
        try sqlite.bindInt64(stmt, 6, now_ms);
        try sqlite.bindText(stmt, 7, rev);
        _ = try sqlite.step(stmt);

        try self.replaceTags(id, tags);
        const rowid = sqlite.lastInsertRowId(self.db);
        try self.updateFtsRow(rowid, title, body);

        try self.appendIssueJsonl(id, rev, title, body, "open", priority, tags, now_ms, now_ms);
        try self.commit();
        return id;
    }

    pub fn updateIssue(
        self: *Store,
        id: []const u8,
        title: ?[]const u8,
        body: ?[]const u8,
        status: ?[]const u8,
        priority: ?i32,
        add_tags: []const []const u8,
        rm_tags: []const []const u8,
    ) !void {
        return retryWrite(void, updateIssueOnce, .{ self, id, title, body, status, priority, add_tags, rm_tags });
    }

    fn updateIssueOnce(
        self: *Store,
        id: []const u8,
        title: ?[]const u8,
        body: ?[]const u8,
        status: ?[]const u8,
        priority: ?i32,
        add_tags: []const []const u8,
        rm_tags: []const []const u8,
    ) !void {
        var issue = try self.fetchIssue(id);
        defer issue.deinit(self.allocator);

        const new_title = title orelse issue.title;
        const new_body = body orelse issue.body;
        const new_status = status orelse issue.status;
        const new_priority = priority orelse issue.priority;

        var tags = std.StringHashMap(void).init(self.allocator);
        defer tags.deinit();
        for (issue.tags) |tag| {
            _ = try tags.put(tag, {});
        }
        for (add_tags) |tag| {
            _ = try tags.put(tag, {});
        }
        for (rm_tags) |tag| {
            _ = tags.remove(tag);
        }
        const merged_tags = try collectKeys(self.allocator, &tags);
        defer {
            for (merged_tags) |tag| self.allocator.free(tag);
            self.allocator.free(merged_tags);
        }

        const now_ms = @as(i64, @intCast(std.time.milliTimestamp()));
        const rev = try self.ulid.nextNow(self.allocator);
        defer self.allocator.free(rev);

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        const stmt = try sqlite.prepare(self.db,
            \\UPDATE issues
            \\SET title = ?, body = ?, status = ?, priority = ?, updated_at = ?, rev = ?
            \\WHERE id = ?;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, new_title);
        try sqlite.bindText(stmt, 2, new_body);
        try sqlite.bindText(stmt, 3, new_status);
        try sqlite.bindInt(stmt, 4, new_priority);
        try sqlite.bindInt64(stmt, 5, now_ms);
        try sqlite.bindText(stmt, 6, rev);
        try sqlite.bindText(stmt, 7, id);
        _ = try sqlite.step(stmt);

        try self.replaceTags(id, merged_tags);
        const rowid = try self.issueRowId(id);
        try self.updateFtsRow(rowid, new_title, new_body);

        try self.appendIssueJsonl(id, rev, new_title, new_body, new_status, new_priority, merged_tags, issue.created_at, now_ms);
        try self.commit();
    }

    pub fn addComment(self: *Store, issue_id: []const u8, body: []const u8) ![]u8 {
        return retryWrite([]u8, addCommentOnce, .{ self, issue_id, body });
    }

    fn addCommentOnce(self: *Store, issue_id: []const u8, body: []const u8) ![]u8 {
        const now_ms = @as(i64, @intCast(std.time.milliTimestamp()));
        const id = try self.ulid.nextNow(self.allocator);
        errdefer self.allocator.free(id);

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO comments(id, issue_id, body, created_at)
            \\VALUES (?, ?, ?, ?);
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        try sqlite.bindText(stmt, 2, issue_id);
        try sqlite.bindText(stmt, 3, body);
        try sqlite.bindInt64(stmt, 4, now_ms);
        _ = try sqlite.step(stmt);

        try self.appendCommentJsonl(id, issue_id, body, now_ms);
        try self.commit();
        return id;
    }

    pub fn addDep(self: *Store, src_id: []const u8, kind: []const u8, dst_id: []const u8) !void {
        return retryWrite(void, addDepOnce, .{ self, src_id, kind, dst_id });
    }

    fn addDepOnce(self: *Store, src_id: []const u8, kind: []const u8, dst_id: []const u8) !void {
        const normalized = try normalizeDep(kind, src_id, dst_id, self.allocator);
        defer normalized.deinit(self.allocator);
        const now_ms = @as(i64, @intCast(std.time.milliTimestamp()));
        const rev = try self.ulid.nextNow(self.allocator);
        defer self.allocator.free(rev);

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO deps(src_id, dst_id, kind, state, created_at, rev)
            \\VALUES (?, ?, ?, 'active', ?, ?)
            \\ON CONFLICT(src_id, dst_id, kind) DO UPDATE SET
            \\  state = 'active',
            \\  created_at = excluded.created_at,
            \\  rev = excluded.rev
            \\WHERE excluded.rev > deps.rev;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, normalized.src);
        try sqlite.bindText(stmt, 2, normalized.dst);
        try sqlite.bindText(stmt, 3, normalized.kind);
        try sqlite.bindInt64(stmt, 4, now_ms);
        try sqlite.bindText(stmt, 5, rev);
        _ = try sqlite.step(stmt);

        try self.appendDepJsonl(normalized.src, normalized.dst, normalized.kind, "active", now_ms, rev);
        try self.commit();
    }

    pub fn removeDep(self: *Store, src_id: []const u8, kind: []const u8, dst_id: []const u8) !void {
        return retryWrite(void, removeDepOnce, .{ self, src_id, kind, dst_id });
    }

    fn removeDepOnce(self: *Store, src_id: []const u8, kind: []const u8, dst_id: []const u8) !void {
        const normalized = try normalizeDep(kind, src_id, dst_id, self.allocator);
        defer normalized.deinit(self.allocator);
        const now_ms = @as(i64, @intCast(std.time.milliTimestamp()));
        const rev = try self.ulid.nextNow(self.allocator);
        defer self.allocator.free(rev);

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO deps(src_id, dst_id, kind, state, created_at, rev)
            \\VALUES (?, ?, ?, 'removed', ?, ?)
            \\ON CONFLICT(src_id, dst_id, kind) DO UPDATE SET
            \\  state = 'removed',
            \\  created_at = excluded.created_at,
            \\  rev = excluded.rev
            \\WHERE excluded.rev > deps.rev;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, normalized.src);
        try sqlite.bindText(stmt, 2, normalized.dst);
        try sqlite.bindText(stmt, 3, normalized.kind);
        try sqlite.bindInt64(stmt, 4, now_ms);
        try sqlite.bindText(stmt, 5, rev);
        _ = try sqlite.step(stmt);

        try self.appendDepJsonl(normalized.src, normalized.dst, normalized.kind, "removed", now_ms, rev);
        try self.commit();
    }

    pub fn resolveIssueId(self: *Store, input: []const u8) ![]u8 {
        if (input.len == 0) return StoreError.InvalidIdPrefix;
        if (!isValidIdInput(input)) return StoreError.InvalidIdPrefix;

        if (try self.issueExists(input)) {
            return try self.allocator.dupe(u8, input);
        }

        if (try self.findIssueIdByPrefix(input)) |match| {
            return match;
        }

        if (std.mem.indexOfScalar(u8, input, '-') == null) {
            if (try self.findIssueIdByHashPrefix(input)) |match| {
                return match;
            }
        }

        return StoreError.IssueNotFound;
    }

    fn findIssueIdByPrefix(self: *Store, input: []const u8) !?[]u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id FROM issues WHERE id LIKE ? || '%';
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, input);

        var match: ?[]u8 = null;
        while (try sqlite.step(stmt)) {
            const id = sqlite.columnText(stmt, 0);
            if (match != null) {
                self.allocator.free(match.?);
                return StoreError.IssueIdAmbiguous;
            }
            match = try self.allocator.dupe(u8, id);
        }
        return match;
    }

    fn findIssueIdByHashPrefix(self: *Store, input: []const u8) !?[]u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id FROM issues WHERE id LIKE '%-' || ? || '%';
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, input);

        var match: ?[]u8 = null;
        while (try sqlite.step(stmt)) {
            const id = sqlite.columnText(stmt, 0);
            if (!hashPrefixMatch(id, input)) continue;
            if (match != null) {
                self.allocator.free(match.?);
                return StoreError.IssueIdAmbiguous;
            }
            match = try self.allocator.dupe(u8, id);
        }
        return match;
    }

    pub fn fetchIssue(self: *Store, id: []const u8) !Issue {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, body, status, priority, created_at, updated_at, rev
            \\FROM issues WHERE id = ?;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        if (!try sqlite.step(stmt)) return StoreError.IssueNotFound;

        const issue_id = try dupColumn(self.allocator, stmt, 0);
        const title = try dupColumn(self.allocator, stmt, 1);
        const body = try dupColumn(self.allocator, stmt, 2);
        const status = try dupColumn(self.allocator, stmt, 3);
        const priority = sqlite.columnInt(stmt, 4);
        const created_at = sqlite.columnInt64(stmt, 5);
        const updated_at = sqlite.columnInt64(stmt, 6);
        const rev = try dupColumn(self.allocator, stmt, 7);

        const tags = try self.fetchTags(issue_id);
        return Issue{
            .id = issue_id,
            .title = title,
            .body = body,
            .status = status,
            .priority = priority,
            .created_at = created_at,
            .updated_at = updated_at,
            .rev = rev,
            .tags = tags,
        };
    }

    pub fn fetchComments(self: *Store, id: []const u8) ![]Comment {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, issue_id, body, created_at
            \\FROM comments WHERE issue_id = ? ORDER BY created_at ASC;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);

        var list: std.ArrayList(Comment) = .empty;
        errdefer {
            for (list.items) |*cmt| cmt.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        while (try sqlite.step(stmt)) {
            const item = Comment{
                .id = try dupColumn(self.allocator, stmt, 0),
                .issue_id = try dupColumn(self.allocator, stmt, 1),
                .body = try dupColumn(self.allocator, stmt, 2),
                .created_at = sqlite.columnInt64(stmt, 3),
            };
            try list.append(self.allocator, item);
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn fetchDeps(self: *Store, id: []const u8) ![]Dep {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT src_id, dst_id, kind, state, created_at, rev
            \\FROM deps
            \\WHERE state = 'active' AND (src_id = ? OR dst_id = ?)
            \\ORDER BY kind ASC, created_at ASC;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        try sqlite.bindText(stmt, 2, id);

        var list: std.ArrayList(Dep) = .empty;
        errdefer {
            for (list.items) |*dep| dep.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        while (try sqlite.step(stmt)) {
            const item = Dep{
                .src_id = try dupColumn(self.allocator, stmt, 0),
                .dst_id = try dupColumn(self.allocator, stmt, 1),
                .kind = try dupColumn(self.allocator, stmt, 2),
                .state = try dupColumn(self.allocator, stmt, 3),
                .created_at = sqlite.columnInt64(stmt, 4),
                .rev = try dupColumn(self.allocator, stmt, 5),
            };
            try list.append(self.allocator, item);
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn fetchTags(self: *Store, id: []const u8) ![]const []const u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.name
            \\FROM tags t
            \\JOIN issue_tags it ON it.tag_id = t.id
            \\WHERE it.issue_id = ?
            \\ORDER BY t.name ASC;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |tag| self.allocator.free(tag);
            list.deinit(self.allocator);
        }
        while (try sqlite.step(stmt)) {
            const tag = try dupColumn(self.allocator, stmt, 0);
            try list.append(self.allocator, tag);
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn issueExists(self: *Store, id: []const u8) !bool {
        const stmt = try sqlite.prepare(self.db, "SELECT 1 FROM issues WHERE id = ? LIMIT 1;");
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        return try sqlite.step(stmt);
    }

    fn generateIssueId(self: *Store, title: []const u8, body: []const u8, created_at: i64) ![]u8 {
        const length: usize = 8;
        const max_nonce: usize = 10;
        var nonce: usize = 0;
        while (nonce < max_nonce) : (nonce += 1) {
            const candidate = try buildIssueId(self.allocator, self.id_prefix, title, body, created_at, length, nonce);
            if (!try self.issueExists(candidate)) {
                return candidate;
            }
            self.allocator.free(candidate);
        }
        return StoreError.IssueIdCollision;
    }

    fn issueRowId(self: *Store, id: []const u8) !i64 {
        const stmt = try sqlite.prepare(self.db, "SELECT rowid FROM issues WHERE id = ?;");
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        if (!try sqlite.step(stmt)) return StoreError.IssueNotFound;
        return sqlite.columnInt64(stmt, 0);
    }

    fn updateFtsRow(self: *Store, rowid: i64, title: []const u8, body: []const u8) !void {
        const del = try sqlite.prepare(self.db, "DELETE FROM issues_fts WHERE rowid = ?;");
        defer sqlite.finalize(del);
        try sqlite.bindInt64(del, 1, rowid);
        _ = try sqlite.step(del);

        const ins = try sqlite.prepare(self.db, "INSERT INTO issues_fts(rowid, title, body) VALUES (?, ?, ?);");
        defer sqlite.finalize(ins);
        try sqlite.bindInt64(ins, 1, rowid);
        try sqlite.bindText(ins, 2, title);
        try sqlite.bindText(ins, 3, body);
        _ = try sqlite.step(ins);
    }

    fn replaceTags(self: *Store, issue_id: []const u8, tags: []const []const u8) !void {
        const del = try sqlite.prepare(self.db, "DELETE FROM issue_tags WHERE issue_id = ?;");
        defer sqlite.finalize(del);
        try sqlite.bindText(del, 1, issue_id);
        _ = try sqlite.step(del);

        const insert_tag = try sqlite.prepare(self.db, "INSERT OR IGNORE INTO tags(name) VALUES (?);");
        defer sqlite.finalize(insert_tag);
        const insert_link = try sqlite.prepare(self.db,
            \\INSERT OR IGNORE INTO issue_tags(issue_id, tag_id)
            \\SELECT ?, id FROM tags WHERE name = ?;
        );
        defer sqlite.finalize(insert_link);

        for (tags) |tag| {
            _ = sqlite.c.sqlite3_reset(insert_tag);
            _ = sqlite.c.sqlite3_reset(insert_link);
            _ = sqlite.c.sqlite3_clear_bindings(insert_tag);
            _ = sqlite.c.sqlite3_clear_bindings(insert_link);

            try sqlite.bindText(insert_tag, 1, tag);
            _ = try sqlite.step(insert_tag);

            try sqlite.bindText(insert_link, 1, issue_id);
            try sqlite.bindText(insert_link, 2, tag);
            _ = try sqlite.step(insert_link);
        }
    }

    fn appendIssueJsonl(
        self: *Store,
        id: []const u8,
        rev: []const u8,
        title: []const u8,
        body: []const u8,
        status: []const u8,
        priority: i32,
        tags: []const []const u8,
        created_at: i64,
        updated_at: i64,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const record = struct {
            type: []const u8,
            id: []const u8,
            rev: []const u8,
            title: []const u8,
            body: []const u8,
            status: []const u8,
            priority: i32,
            tags: []const []const u8,
            created_at: i64,
            updated_at: i64,
        }{
            .type = "issue",
            .id = id,
            .rev = rev,
            .title = title,
            .body = body,
            .status = status,
            .priority = priority,
            .tags = tags,
            .created_at = created_at,
            .updated_at = updated_at,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, &out.writer);
        try out.writer.writeByte('\n');
        const payload = out.written();
        try self.appendJsonlAtomic(payload);
    }

    fn appendCommentJsonl(self: *Store, id: []const u8, issue_id: []const u8, body: []const u8, created_at: i64) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const record = struct {
            type: []const u8,
            id: []const u8,
            issue_id: []const u8,
            body: []const u8,
            created_at: i64,
        }{
            .type = "comment",
            .id = id,
            .issue_id = issue_id,
            .body = body,
            .created_at = created_at,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, &out.writer);
        try out.writer.writeByte('\n');
        const payload = out.written();
        try self.appendJsonlAtomic(payload);
    }

    fn appendDepJsonl(self: *Store, src_id: []const u8, dst_id: []const u8, kind: []const u8, state: []const u8, created_at: i64, rev: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const record = struct {
            type: []const u8,
            src_id: []const u8,
            dst_id: []const u8,
            kind: []const u8,
            state: []const u8,
            created_at: i64,
            rev: []const u8,
        }{
            .type = "dep",
            .src_id = src_id,
            .dst_id = dst_id,
            .kind = kind,
            .state = state,
            .created_at = created_at,
            .rev = rev,
        };
        try std.json.Stringify.value(record, .{ .whitespace = .minified }, &out.writer);
        try out.writer.writeByte('\n');
        const payload = out.written();
        try self.appendJsonlAtomic(payload);
    }

    fn appendJsonlAtomic(self: *Store, payload: []const u8) !void {
        // Acquire lock file (blocking)
        if (self.lock_file) |*lf| {
            try lf.lock(.exclusive);
            defer lf.unlock();
        }

        // Open and write to JSONL file
        var file = try std.fs.openFileAbsolute(self.jsonl_path, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(payload);
        try file.sync();
        try self.updateJsonlMeta();
    }

    fn beginImmediate(self: *Store) !void {
        try self.execWithRetry("BEGIN IMMEDIATE;");
    }

    fn commit(self: *Store) !void {
        try self.execWithRetry("COMMIT;");
    }

    fn execWithRetry(self: *Store, sql: []const u8) !void {
        // SQLite's busy_timeout provides primary waiting; manual retries provide backup
        var attempt: u32 = 0;
        const max_attempts: u32 = 10;
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        const random = prng.random();

        while (true) {
            sqlite.exec(self.db, sql) catch |err| switch (err) {
                sqlite.Error.SqliteBusy => {
                    if (attempt >= max_attempts) return StoreError.DatabaseBusy;
                    const delay_ms = random.intRangeAtMost(u64, 50, 500);
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    attempt += 1;
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    fn updateJsonlMeta(self: *Store) !void {
        const stat = try statFile(self.jsonl_path);
        try self.updateJsonlMetaForStat(stat, stat.size);
    }

    fn updateJsonlMetaForStat(self: *Store, stat: std.fs.File.Stat, offset: u64) !void {
        try self.setMetaInt("jsonl_offset", offset);
        try self.setMetaInt("jsonl_inode", @as(u64, @intCast(stat.inode)));
        try self.setMetaInt("jsonl_mtime", @as(u64, @intCast(stat.mtime)));
    }

    fn importFromOffset(self: *Store, offset: u64) !void {
        var file = try std.fs.openFileAbsolute(self.jsonl_path, .{ .mode = .read_only, .lock = .shared });
        defer file.close();
        var stat: std.fs.File.Stat = undefined;
        var data: []u8 = &.{};
        var read_len: usize = 0;

        if (self.lock_file) |*lf| {
            try lf.lock(.shared);
            defer lf.unlock();
            stat = try file.stat();
            if (stat.size <= offset) {
                try self.updateJsonlMetaForStat(stat, stat.size);
                return;
            }
            try file.seekTo(offset);
            const to_read = @as(usize, @intCast(stat.size - offset));
            data = try self.allocator.alloc(u8, to_read);
            read_len = try file.readAll(data);
        } else {
            stat = try file.stat();
            if (stat.size <= offset) {
                try self.updateJsonlMetaForStat(stat, stat.size);
                return;
            }
            try file.seekTo(offset);
            const to_read = @as(usize, @intCast(stat.size - offset));
            data = try self.allocator.alloc(u8, to_read);
            read_len = try file.readAll(data);
        }
        defer if (data.len > 0) self.allocator.free(data);
        const slice = data[0..read_len];

        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        var comment_lines: std.ArrayList([]const u8) = .empty;
        defer comment_lines.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, slice, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r\n\t ");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
                std.debug.print("warning: skipping invalid JSONL line ({s})\n", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const type_val = obj.get("type") orelse continue;
            if (type_val != .string) continue;
            const type_str = type_val.string;

            if (std.mem.eql(u8, type_str, "issue")) {
                self.applyIssueRecord(obj) catch |err| {
                    std.debug.print("warning: failed to apply issue record: {s}\n", .{@errorName(err)});
                };
            } else if (std.mem.eql(u8, type_str, "dep")) {
                self.applyDepRecord(obj) catch |err| {
                    std.debug.print("warning: failed to apply dep record: {s}\n", .{@errorName(err)});
                };
            } else if (std.mem.eql(u8, type_str, "comment")) {
                try comment_lines.append(self.allocator, line);
            }
        }

        // Apply comments after issues/deps so foreign keys succeed.
        for (comment_lines.items) |line| {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
                std.debug.print("warning: skipping invalid comment line ({s})\n", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            self.applyCommentRecord(obj) catch |err| {
                std.debug.print("warning: failed to apply comment record: {s}\n", .{@errorName(err)});
            };
        }

        try self.commit();
        const new_offset = offset + @as(u64, @intCast(read_len));
        try self.updateJsonlMetaForStat(stat, new_offset);
    }

    pub fn forceReimport(self: *Store) !void {
        try self.fullReimport();
    }

    fn fullReimport(self: *Store) !void {
        try self.beginImmediate();
        errdefer sqlite.exec(self.db, "ROLLBACK;") catch {};

        try sqlite.exec(self.db, "DELETE FROM issue_tags;");
        try sqlite.exec(self.db, "DELETE FROM tags;");
        try sqlite.exec(self.db, "DELETE FROM comments;");
        try sqlite.exec(self.db, "DELETE FROM deps;");
        try sqlite.exec(self.db, "DELETE FROM issues;");
        try sqlite.exec(self.db, "DELETE FROM issues_fts;");

        try self.commit();
        try self.importFromOffset(0);
    }

    fn applyJsonlLine(self: *Store, line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const type_val = obj.get("type") orelse return;
        if (type_val != .string) return;
        const type_str = type_val.string;

        if (std.mem.eql(u8, type_str, "issue")) {
            try self.applyIssueRecord(obj);
        } else if (std.mem.eql(u8, type_str, "comment")) {
            try self.applyCommentRecord(obj);
        } else if (std.mem.eql(u8, type_str, "dep")) {
            try self.applyDepRecord(obj);
        }
    }

    fn applyIssueRecord(self: *Store, obj: std.json.ObjectMap) !void {
        const id = obj.get("id").?.string;
        const rev = obj.get("rev").?.string;
        const title = obj.get("title").?.string;
        const body = obj.get("body").?.string;
        const status = obj.get("status").?.string;
        const priority = @as(i32, @intCast(obj.get("priority").?.integer));
        const created_at = @as(i64, @intCast(obj.get("created_at").?.integer));
        const updated_at = @as(i64, @intCast(obj.get("updated_at").?.integer));
        const tags_val = obj.get("tags");

        const stmt = try sqlite.prepare(self.db, "SELECT rev, updated_at, rowid FROM issues WHERE id = ?;");
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        var should_apply = false;
        var rowid: i64 = 0;
        if (try sqlite.step(stmt)) {
            const existing_rev = sqlite.columnText(stmt, 0);
            const existing_updated = sqlite.columnInt64(stmt, 1);
            rowid = sqlite.columnInt64(stmt, 2);
            if (std.mem.order(u8, rev, existing_rev) == .gt) {
                should_apply = true;
            } else if (std.mem.eql(u8, rev, existing_rev) and updated_at > existing_updated) {
                should_apply = true;
            }
        } else {
            should_apply = true;
        }
        if (!should_apply) return;

        if (rowid == 0) {
            const ins = try sqlite.prepare(self.db,
                \\INSERT INTO issues(id, title, body, status, priority, created_at, updated_at, rev)
                \\VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            );
            defer sqlite.finalize(ins);
            try sqlite.bindText(ins, 1, id);
            try sqlite.bindText(ins, 2, title);
            try sqlite.bindText(ins, 3, body);
            try sqlite.bindText(ins, 4, status);
            try sqlite.bindInt(ins, 5, priority);
            try sqlite.bindInt64(ins, 6, created_at);
            try sqlite.bindInt64(ins, 7, updated_at);
            try sqlite.bindText(ins, 8, rev);
            _ = try sqlite.step(ins);
            rowid = sqlite.lastInsertRowId(self.db);
        } else {
            const upd = try sqlite.prepare(self.db,
                \\UPDATE issues
                \\SET title = ?, body = ?, status = ?, priority = ?, created_at = ?, updated_at = ?, rev = ?
                \\WHERE id = ?;
            );
            defer sqlite.finalize(upd);
            try sqlite.bindText(upd, 1, title);
            try sqlite.bindText(upd, 2, body);
            try sqlite.bindText(upd, 3, status);
            try sqlite.bindInt(upd, 4, priority);
            try sqlite.bindInt64(upd, 5, created_at);
            try sqlite.bindInt64(upd, 6, updated_at);
            try sqlite.bindText(upd, 7, rev);
            try sqlite.bindText(upd, 8, id);
            _ = try sqlite.step(upd);
        }

        const tags = if (tags_val) |val| try parseTags(self.allocator, val) else &.{};
        defer {
            if (tags.len > 0) {
                for (tags) |tag| self.allocator.free(tag);
                self.allocator.free(tags);
            }
        }
        try self.replaceTags(id, tags);
        try self.updateFtsRow(rowid, title, body);
    }

    fn applyCommentRecord(self: *Store, obj: std.json.ObjectMap) !void {
        const id = obj.get("id").?.string;
        const issue_id = obj.get("issue_id").?.string;
        const body = obj.get("body").?.string;
        const created_at = @as(i64, @intCast(obj.get("created_at").?.integer));

        if (!try self.issueExists(issue_id)) return StoreError.IssueNotFound;

        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR IGNORE INTO comments(id, issue_id, body, created_at)
            \\VALUES (?, ?, ?, ?);
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, id);
        try sqlite.bindText(stmt, 2, issue_id);
        try sqlite.bindText(stmt, 3, body);
        try sqlite.bindInt64(stmt, 4, created_at);
        _ = try sqlite.step(stmt);
    }

    fn applyDepRecord(self: *Store, obj: std.json.ObjectMap) !void {
        const src_id = obj.get("src_id").?.string;
        const dst_id = obj.get("dst_id").?.string;
        const kind = obj.get("kind").?.string;
        const state = obj.get("state").?.string;
        const created_at = @as(i64, @intCast(obj.get("created_at").?.integer));
        const rev = obj.get("rev").?.string;

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO deps(src_id, dst_id, kind, state, created_at, rev)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(src_id, dst_id, kind) DO UPDATE SET
            \\  state = excluded.state,
            \\  created_at = excluded.created_at,
            \\  rev = excluded.rev
            \\WHERE excluded.rev > deps.rev;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, src_id);
        try sqlite.bindText(stmt, 2, dst_id);
        try sqlite.bindText(stmt, 3, kind);
        try sqlite.bindText(stmt, 4, state);
        try sqlite.bindInt64(stmt, 5, created_at);
        try sqlite.bindText(stmt, 6, rev);
        _ = try sqlite.step(stmt);
    }

    fn getMetaInt(self: *Store, key: []const u8) !?u64 {
        const stmt = try sqlite.prepare(self.db, "SELECT value FROM meta WHERE key = ?;");
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, key);
        if (!try sqlite.step(stmt)) return null;
        const value = sqlite.columnText(stmt, 0);
        return std.fmt.parseInt(u64, value, 10) catch null;
    }

    fn setMetaInt(self: *Store, key: []const u8, value: u64) !void {
        var buf: [64]u8 = undefined;
        const val_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO meta(key, value) VALUES(?, ?)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, key);
        try sqlite.bindText(stmt, 2, val_str);
        _ = try sqlite.step(stmt);
    }

    fn getMetaText(self: *Store, key: []const u8) !?[]u8 {
        const stmt = try sqlite.prepare(self.db, "SELECT value FROM meta WHERE key = ?;");
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, key);
        if (!try sqlite.step(stmt)) return null;
        const value = sqlite.columnText(stmt, 0);
        return try self.allocator.dupe(u8, value);
    }

    fn setMetaText(self: *Store, key: []const u8, value: []const u8) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO meta(key, value) VALUES(?, ?)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        );
        defer sqlite.finalize(stmt);
        try sqlite.bindText(stmt, 1, key);
        try sqlite.bindText(stmt, 2, value);
        _ = try sqlite.step(stmt);
    }

};

const base36_alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

fn buildIssueId(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    title: []const u8,
    body: []const u8,
    created_at: i64,
    length: usize,
    nonce: usize,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(title);
    hasher.update("|");
    hasher.update(body);
    hasher.update("|");
    var ts_buf: [32]u8 = undefined;
    const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{created_at});
    hasher.update(ts);
    hasher.update("|");
    var nonce_buf: [32]u8 = undefined;
    const nonce_str = try std.fmt.bufPrint(&nonce_buf, "{d}", .{nonce});
    hasher.update(nonce_str);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const out_len = prefix.len + 1 + length;
    var out = try allocator.alloc(u8, out_len);
    std.mem.copyForwards(u8, out[0..prefix.len], prefix);
    out[prefix.len] = '-';
    hashToBase36(digest, length, out[prefix.len + 1 ..]);
    return out;
}

fn hashToBase36(hash: [32]u8, length: usize, dest: []u8) void {
    const num_bytes = numBytesForLength(length);
    var value: u64 = 0;
    var i: usize = 0;
    while (i < num_bytes) : (i += 1) {
        value = (value << 8) | @as(u64, hash[i]);
    }
    writeBase36Fixed(value, length, dest);
}

fn numBytesForLength(length: usize) usize {
    return switch (length) {
        3 => 2,
        4 => 3,
        5, 6 => 4,
        7, 8 => 5,
        else => 3,
    };
}

fn writeBase36Fixed(value: u64, length: usize, dest: []u8) void {
    var v = value;
    var idx = length;
    while (idx > 0) {
        idx -= 1;
        const digit = @as(usize, @intCast(v % 36));
        dest[idx] = base36_alphabet[digit];
        v /= 36;
    }
}

fn normalizePrefix(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return StoreError.InvalidPrefix;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_dash = false;

    for (trimmed) |ch| {
        var c = ch;
        if (c >= 'A' and c <= 'Z') c = c + 32;
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            try out.append(allocator, c);
            last_dash = false;
            continue;
        }
        if (c == '-' or c == '_' or c == ' ' or c == '.') {
            if (!last_dash and out.items.len > 0) {
                try out.append(allocator, '-');
                last_dash = true;
            }
            continue;
        }
        if (!last_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) return StoreError.InvalidPrefix;

    const max_len: usize = 32;
    while (out.items.len > max_len) {
        _ = out.pop();
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) return StoreError.InvalidPrefix;

    return out.toOwnedSlice(allocator);
}

fn deriveDefaultPrefix(allocator: std.mem.Allocator, store_dir: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(store_dir) orelse store_dir;
    const base = std.fs.path.basename(parent);
    if (base.len > 0) {
        if (normalizePrefix(allocator, base)) |prefix| {
            return prefix;
        } else |_| {}
    }
    return normalizePrefix(allocator, "tissue");
}

fn isValidIdInput(input: []const u8) bool {
    for (input) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '.') {
            continue;
        }
        return false;
    }
    return true;
}

fn hashPrefixMatch(id: []const u8, prefix: []const u8) bool {
    const idx = std.mem.lastIndexOfScalar(u8, id, '-') orelse return false;
    const hash_part = id[idx + 1 ..];
    return startsWithFold(hash_part, prefix);
}

fn startsWithFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |ch, i| {
        if (asciiLower(haystack[i]) != asciiLower(ch)) return false;
    }
    return true;
}

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

const DepNormalized = struct {
    src: []const u8,
    dst: []const u8,
    kind: []const u8,

    fn deinit(self: *const DepNormalized, allocator: std.mem.Allocator) void {
        allocator.free(self.src);
        allocator.free(self.dst);
        allocator.free(self.kind);
    }
};

fn normalizeDep(kind: []const u8, src_id: []const u8, dst_id: []const u8, allocator: std.mem.Allocator) !DepNormalized {
    // Reject self-dependencies
    if (std.mem.eql(u8, src_id, dst_id)) {
        return StoreError.SelfDependency;
    }

    if (std.mem.eql(u8, kind, "blocks") or std.mem.eql(u8, kind, "parent")) {
        return .{
            .src = try allocator.dupe(u8, src_id),
            .dst = try allocator.dupe(u8, dst_id),
            .kind = try allocator.dupe(u8, kind),
        };
    }
    if (std.mem.eql(u8, kind, "relates")) {
        const order = std.mem.order(u8, src_id, dst_id);
        if (order == .gt) {
            return .{
                .src = try allocator.dupe(u8, dst_id),
                .dst = try allocator.dupe(u8, src_id),
                .kind = try allocator.dupe(u8, kind),
            };
        }
        return .{
            .src = try allocator.dupe(u8, src_id),
            .dst = try allocator.dupe(u8, dst_id),
            .kind = try allocator.dupe(u8, kind),
        };
    }
    return StoreError.InvalidDepKind;
}

fn parseTags(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |tag| allocator.free(tag);
        list.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .string) continue;
        try list.append(allocator, try allocator.dupe(u8, item.string));
    }
    return list.toOwnedSlice(allocator);
}

fn collectKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |key| allocator.free(key);
        list.deinit(allocator);
    }
    var it = map.keyIterator();
    while (it.next()) |key_ptr| {
        try list.append(allocator, try allocator.dupe(u8, key_ptr.*));
    }
    const out = try list.toOwnedSlice(allocator);
    std.sort.heap([]const u8, out, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return out;
}

fn dupColumn(allocator: std.mem.Allocator, stmt: *sqlite.c.sqlite3_stmt, idx: c_int) ![]const u8 {
    const text = sqlite.columnText(stmt, idx);
    return allocator.dupe(u8, text);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn retryWrite(comptime T: type, func: anytype, args: anytype) !T {
    // Full operation retry with random delay between attempts
    var attempt: u32 = 0;
    const max_attempts: u32 = 50;
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    const random = prng.random();

    if (comptime T == void) {
        while (true) {
            @call(.auto, func, args) catch |err| {
                if (err == StoreError.DatabaseBusy or err == sqlite.Error.SqliteBusy) {
                    if (attempt >= max_attempts) return StoreError.DatabaseBusy;
                    const delay_ms = random.intRangeAtMost(u64, 10, 200);
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    attempt += 1;
                    continue;
                }
                return err;
            };
            return;
        }
    }

    while (true) {
        const result = @call(.auto, func, args) catch |err| {
            if (err == StoreError.DatabaseBusy or err == sqlite.Error.SqliteBusy) {
                if (attempt >= max_attempts) return StoreError.DatabaseBusy;
                const delay_ms = random.intRangeAtMost(u64, 10, 200);
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                attempt += 1;
                continue;
            }
            return err;
        };
        return result;
    }
}

fn seedFromTime() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn statFile(path: []const u8) !std.fs.File.Stat {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.stat();
}
