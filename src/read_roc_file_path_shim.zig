//! A shim to read the filepath for our app.roc from shared memory for the interpreter

const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

const RocStr = builtins.str.RocStr;

// Platform-specific shared memory implementation
const is_windows = builtin.target.os.tag == .windows;

// POSIX shared memory functions
const posix = if (!is_windows) struct {
    extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: std.c.mode_t) c_int;
    extern "c" fn shm_unlink(name: [*:0]const u8) c_int;
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: std.c.off_t) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int;
    extern "c" fn close(fd: c_int) c_int;
} else struct {};

// Windows shared memory functions
const windows = if (is_windows) struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = c_int;
    const LPVOID = ?*anyopaque;
    const LPCWSTR = [*:0]const u16;
    const SIZE_T = usize;

    extern "kernel32" fn OpenFileMappingW(dwDesiredAccess: DWORD, bInheritHandle: BOOL, lpName: LPCWSTR) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: DWORD, dwFileOffsetHigh: DWORD, dwFileOffsetLow: DWORD, dwNumberOfBytesToMap: SIZE_T) LPVOID;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: LPVOID) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) BOOL;
    extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) BOOL;

    const FILE_MAP_READ = 0x0004;
} else struct {};

/// Exported symbol that reads a string from shared memory ROC_FILE_TO_INTERPRET
/// Returns a RocStr to the caller
/// Expected format in shared memory: [usize length][u8... data]
export fn roc_entrypoint(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque) callconv(.C) void {
    const result = if (comptime is_windows)
        readFromWindowsSharedMemory(ops)
    else
        readFromPosixSharedMemory(ops);

    const roc_str_ptr: *RocStr = @ptrCast(@alignCast(ret_ptr));
    roc_str_ptr.* = result;
}

fn readFromWindowsSharedMemory(ops: *builtins.host_abi.RocOps) RocStr {
    // Convert to wide string for Windows API
    const shm_name_wide = std.unicode.utf8ToUtf16LeStringLiteral("ROC_FILE_TO_INTERPRET");

    // Open the shared memory object
    const shm_handle = windows.OpenFileMappingW(windows.FILE_MAP_READ, 0, shm_name_wide) orelse {
        return RocStr.empty();
    };
    defer _ = windows.CloseHandle(shm_handle);

    // Map the shared memory
    const mapped_ptr = windows.MapViewOfFile(shm_handle, windows.FILE_MAP_READ, 0, 0, 0) orelse {
        return RocStr.empty();
    };
    defer _ = windows.UnmapViewOfFile(mapped_ptr);

    // Read the length from the beginning of shared memory
    const length_ptr: *align(1) const usize = @ptrCast(mapped_ptr);
    const string_length = length_ptr.*;

    // Get pointer to string data
    const string_data = @as([*]u8, @ptrCast(mapped_ptr)) + @sizeOf(usize);

    return createRocStrFromData(ops, string_data, string_length);
}

fn readFromPosixSharedMemory(ops: *builtins.host_abi.RocOps) RocStr {
    const shm_name = "/ROC_FILE_TO_INTERPRET";

    // Open the shared memory object
    const shm_fd = posix.shm_open(shm_name, 0, 0); // O_RDONLY = 0
    if (shm_fd < 0) {
        return RocStr.empty();
    }
    defer _ = posix.close(shm_fd);

    // Get shared memory size
    var stat_buf: std.c.Stat = undefined;
    if (posix.fstat(shm_fd, &stat_buf) != 0) {
        return RocStr.empty();
    }

    if (stat_buf.size < @sizeOf(usize)) {
        return RocStr.empty();
    }

    // Map the shared memory
    const mapped_ptr = posix.mmap(
        null,
        @intCast(stat_buf.size),
        0x01, // PROT_READ
        0x0001, // MAP_SHARED
        shm_fd,
        0,
    ) orelse {
        return RocStr.empty();
    };
    const mapped_memory = @as([*]u8, @ptrCast(mapped_ptr))[0..@intCast(stat_buf.size)];
    defer _ = posix.munmap(mapped_ptr, @intCast(stat_buf.size));

    // Read the length from the beginning of shared memory
    const length_ptr: *align(1) const usize = @ptrCast(mapped_memory.ptr);
    const string_length = length_ptr.*;

    // Check if we have enough data
    if (stat_buf.size < @sizeOf(usize) + string_length) {
        return RocStr.empty();
    }

    // Get pointer to string data
    const string_data = mapped_memory.ptr + @sizeOf(usize);

    return createRocStrFromData(ops, string_data, string_length);
}

fn createRocStrFromData(ops: *builtins.host_abi.RocOps, string_data: [*]u8, string_length: usize) RocStr {
    // For small strings, we can create them directly
    if (string_length <= @sizeOf(RocStr) - 1) {
        var result = RocStr.empty();
        @memcpy(result.asU8ptrMut()[0..string_length], string_data[0..string_length]);
        result.setLen(string_length);
        return result;
    }

    // For larger strings, allocate memory using RocOps
    const alignment = @alignOf(usize);
    var roc_alloc = builtins.host_abi.RocAlloc{
        .alignment = alignment,
        .length = string_length,
        .answer = undefined,
    };
    ops.roc_alloc(&roc_alloc, ops.env);
    const alloc_ptr = roc_alloc.answer;

    // Create a RocStr with the allocated memory
    const result = RocStr{
        .bytes = @ptrCast(alloc_ptr),
        .length = string_length,
        .capacity_or_alloc_ptr = string_length,
    };

    // Copy the data into the allocated memory
    @memcpy(@as([*]u8, @ptrCast(alloc_ptr)), string_data[0..string_length]);

    return result;
}
