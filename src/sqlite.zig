const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteError,
    SqliteStepError,
    SqliteDone,
    SqliteBusy,
};

pub fn open(path: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
    if (rc != c.SQLITE_OK) {
        if (db) |handle| {
            _ = c.sqlite3_close_v2(handle);
        }
        return Error.SqliteError;
    }
    return db.?;
}

pub fn close(db: *c.sqlite3) void {
    _ = c.sqlite3_close_v2(db);
}

pub fn exec(db: *c.sqlite3, sql: []const u8) !void {
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);
    if (rc != c.SQLITE_OK) {
        if (isBusyCode(rc)) return Error.SqliteBusy;
        return Error.SqliteError;
    }
}

pub fn prepare(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null);
    if (rc != c.SQLITE_OK) {
        if (isBusyCode(rc)) return Error.SqliteBusy;
        return Error.SqliteError;
    }
    return stmt.?;
}

pub fn step(stmt: *c.sqlite3_stmt) !bool {
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) return true;
    if (rc == c.SQLITE_DONE) return false;
    if (isBusyCode(rc)) return Error.SqliteBusy;
    return Error.SqliteStepError;
}

pub fn finalize(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

pub fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) !void {
    const rc = c.sqlite3_bind_text(stmt, idx, text.ptr, @as(c_int, @intCast(text.len)), null);
    if (rc != c.SQLITE_OK) return Error.SqliteError;
}

pub fn bindInt64(stmt: *c.sqlite3_stmt, idx: c_int, value: i64) !void {
    const rc = c.sqlite3_bind_int64(stmt, idx, value);
    if (rc != c.SQLITE_OK) return Error.SqliteError;
}

pub fn bindInt(stmt: *c.sqlite3_stmt, idx: c_int, value: i32) !void {
    const rc = c.sqlite3_bind_int(stmt, idx, value);
    if (rc != c.SQLITE_OK) return Error.SqliteError;
}

pub fn bindNull(stmt: *c.sqlite3_stmt, idx: c_int) !void {
    const rc = c.sqlite3_bind_null(stmt, idx);
    if (rc != c.SQLITE_OK) return Error.SqliteError;
}

pub fn columnText(stmt: *c.sqlite3_stmt, idx: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return "";
    const len = c.sqlite3_column_bytes(stmt, idx);
    return @as([*]const u8, @ptrCast(ptr))[0..@as(usize, @intCast(len))];
}

pub fn columnInt64(stmt: *c.sqlite3_stmt, idx: c_int) i64 {
    return c.sqlite3_column_int64(stmt, idx);
}

pub fn columnInt(stmt: *c.sqlite3_stmt, idx: c_int) i32 {
    return c.sqlite3_column_int(stmt, idx);
}

pub fn lastInsertRowId(db: *c.sqlite3) i64 {
    return c.sqlite3_last_insert_rowid(db);
}

pub fn errmsg(db: *c.sqlite3) []const u8 {
    const ptr = c.sqlite3_errmsg(db);
    return std.mem.span(ptr);
}

fn isBusyCode(rc: c_int) bool {
    const primary: c_int = rc & @as(c_int, 0xff);
    return primary == c.SQLITE_BUSY or primary == c.SQLITE_LOCKED;
}
