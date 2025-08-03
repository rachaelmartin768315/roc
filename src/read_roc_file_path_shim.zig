//! A shim to read the ModuleEnv from shared memory for the interpreter

const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");
const compile = @import("compile");
const eval_shim = @import("eval_shim");

const RocStr = builtins.str.RocStr;
const ModuleEnv = compile.ModuleEnv;

// Platform-specific shared memory implementation
const is_windows = builtin.target.os.tag == .windows;

// POSIX shared memory functions
const posix = if (!is_windows) struct {
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

/// Read the fd/handle from the filesystem-based communication mechanism
fn readFdFromFile() ![]u8 {
    // Get our own executable path
    const exe_path = try std.fs.selfExePathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(exe_path);

    // Get the directory containing our executable (should be "roc-tmp-<random>")
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExePath;
    const dir_basename = std.fs.path.basename(exe_dir);

    // Verify it has the expected prefix
    if (!std.mem.startsWith(u8, dir_basename, "roc-tmp-")) {
        return error.UnexpectedDirName;
    }

    // Construct the fd file path by appending .txt to the directory path
    // First, remove any trailing slashes from exe_dir
    var dir_path = exe_dir;
    while (dir_path.len > 0 and (dir_path[dir_path.len - 1] == '/' or dir_path[dir_path.len - 1] == '\\')) {
        dir_path = dir_path[0 .. dir_path.len - 1];
    }

    const fd_file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.txt", .{dir_path});
    defer std.heap.page_allocator.free(fd_file_path);

    // Check if file exists
    std.fs.cwd().access(fd_file_path, .{}) catch |err| {
        // Try without /private prefix
        if (std.mem.startsWith(u8, fd_file_path, "/private")) {
            const alt_path = fd_file_path[8..];
            std.fs.cwd().access(alt_path, .{}) catch |err2| {};
        }
    };

    // Read the fd from the file - try with and without /private prefix
    const fd_file = std.fs.cwd().openFile(fd_file_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                // Try without /private prefix if it starts with it
                if (std.mem.startsWith(u8, fd_file_path, "/private")) {
                    const alt_path = fd_file_path[8..]; // Skip "/private"
                    const alt_file = std.fs.cwd().openFile(alt_path, .{}) catch return error.FdFileNotFound;
                    defer alt_file.close();
                    const alt_content = try alt_file.readToEndAlloc(std.heap.page_allocator, 64);
                    const alt_trimmed = std.mem.trim(u8, alt_content, " \n\r\t");
                    const alt_result = try std.heap.page_allocator.dupe(u8, alt_trimmed);
                    std.heap.page_allocator.free(alt_content);
                    return alt_result;
                }
                return error.FdFileNotFound;
            },
            else => return err,
        }
    };
    defer fd_file.close();

    const fd_content = try fd_file.readToEndAlloc(std.heap.page_allocator, 64);

    // Don't delete the fd file yet - let the parent process clean it up
    // std.fs.cwd().deleteFile(fd_file_path) catch {};

    const trimmed = std.mem.trim(u8, fd_content, " \n\r\t");
    const result = try std.heap.page_allocator.dupe(u8, trimmed);
    std.heap.page_allocator.free(fd_content);
    return result;
}

/// Exported symbol that reads ModuleEnv from shared memory and evaluates it
/// Returns a RocStr to the caller
/// Expected format in shared memory: [u64 parent_address][ModuleEnv data]
export fn roc_entrypoint(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque) callconv(.C) void {
    // Use the appropriate evaluation function based on platform
    const result = if (is_windows)
        evaluateFromWindowsSharedMemory(ops)
    else
        evaluateFromPosixSharedMemory(ops);

    const roc_str_ptr: *RocStr = @ptrCast(@alignCast(ret_ptr));
    roc_str_ptr.* = result;
}

fn evaluateFromWindowsSharedMemory(ops: *builtins.host_abi.RocOps) RocStr {
    const handle_str = readFdFromFile() catch {
        return RocStr.empty();
    };
    defer std.heap.page_allocator.free(handle_str);

    const handle_int = std.fmt.parseInt(usize, handle_str, 10) catch {
        return RocStr.empty();
    };

    const shm_handle = @as(windows.HANDLE, @ptrFromInt(handle_int));

    // Map the shared memory
    const mapped_ptr = windows.MapViewOfFile(shm_handle, windows.FILE_MAP_READ, 0, 0, 0) orelse {
        return RocStr.empty();
    };
    defer _ = windows.UnmapViewOfFile(mapped_ptr);

    // Read the parent address from the beginning
    const parent_addr_ptr: *align(1) const u64 = @ptrCast(mapped_ptr);
    const parent_addr = parent_addr_ptr.*;

    // Read the expression index (after the u64)
    const expr_idx_ptr: *align(1) const u32 = @ptrCast(@as([*]u8, @ptrCast(mapped_ptr)) + @sizeOf(u64));
    const expr_idx = expr_idx_ptr.*;

    // Calculate relocation offset
    const child_addr = @intFromPtr(mapped_ptr);
    const offset = @as(isize, @intCast(child_addr)) - @as(isize, @intCast(parent_addr));

    // Get pointer to ModuleEnv (after the u64 and u32)
    const env_ptr = @as(*ModuleEnv, @ptrCast(@alignCast(@as([*]u8, @ptrCast(mapped_ptr)) + @sizeOf(u64) + @sizeOf(u32))));

    // Relocate the ModuleEnv
    env_ptr.relocate(offset);

    // Now actually evaluate the expression!
    const eval_result = eval_shim.evalExpr(env_ptr, expr_idx) catch |err| {
        var buf: [256]u8 = undefined;
        const err_str = std.fmt.bufPrint(&buf, "Evaluation error: {s}", .{@errorName(err)}) catch "Error formatting";
        return createRocStrFromData(ops, @as([*]u8, @ptrCast(&buf)), err_str.len);
    };

    // Format the result
    var buf: [256]u8 = undefined;
    const result_str = if (eval_result.is_error)
        std.fmt.bufPrint(&buf, "Evaluation failed", .{}) catch "Error"
    else blk: {
        break :blk std.fmt.bufPrint(&buf, "Expression '{s}' evaluated to: {}", .{ env_ptr.source, eval_result.value }) catch "Error formatting";
    };

    return createRocStrFromData(ops, @as([*]u8, @ptrCast(&buf)), result_str.len);
}

fn evaluateFromPosixSharedMemory(ops: *builtins.host_abi.RocOps) RocStr {
    // Read the fd from the file
    const fd_str = readFdFromFile() catch {
        return RocStr.empty();
    };
    defer std.heap.page_allocator.free(fd_str);

    const shm_fd = std.fmt.parseInt(c_int, fd_str, 10) catch {
        return RocStr.empty();
    };

    defer _ = posix.close(shm_fd);

    // Get shared memory size
    var stat_buf: std.c.Stat = undefined;
    if (posix.fstat(shm_fd, &stat_buf) != 0) {
        const errno = std.c._errno().*;
        return RocStr.empty();
    }

    if (stat_buf.size < @sizeOf(usize)) {
        return RocStr.empty();
    }

    // Map the shared memory with read/write permissions
    const mapped_ptr = posix.mmap(
        null,
        @intCast(stat_buf.size),
        0x01 | 0x02, // PROT_READ | PROT_WRITE
        0x0001, // MAP_SHARED
        shm_fd,
        0,
    ) orelse {
        return RocStr.empty();
    };
    const mapped_memory = @as([*]u8, @ptrCast(mapped_ptr))[0..@intCast(stat_buf.size)];
    defer _ = posix.munmap(mapped_ptr, @intCast(stat_buf.size));

    // The first allocation in SharedMemoryAllocator starts at offset 504 (0x1f8)
    // This is 8 bytes before the end of the 512-byte header, likely for alignment
    const first_alloc_offset = 504;
    const data_ptr = mapped_memory.ptr + first_alloc_offset;

    // Read the parent address from the first allocation
    const parent_addr_ptr: *align(1) const u64 = @ptrCast(data_ptr);
    const parent_addr = parent_addr_ptr.*;

    // Read the expression index (after the u64)
    const expr_idx_ptr: *align(1) const u32 = @ptrCast(data_ptr + @sizeOf(u64));
    const expr_idx = expr_idx_ptr.*;

    // Calculate relocation offset (both addresses should be for the data area, not the full mapping)
    const child_addr = @intFromPtr(data_ptr);
    const offset = @as(isize, @intCast(child_addr)) - @as(isize, @intCast(parent_addr));

    // The parent stored the ModuleEnv at offset 0x10 from the first allocation
    // (after the u64 parent address and u32 expr index)
    const module_env_offset = 0x10; // 8 bytes for u64, 4 bytes for u32, 4 bytes padding
    const env_addr = @intFromPtr(data_ptr) + module_env_offset;

    const env_ptr = @as(*ModuleEnv, @ptrFromInt(env_addr));

    // Let's verify what's at the ModuleEnv location before relocating

    // IMPORTANT: Before relocating, we need to set the gpa field to a valid allocator
    // The relocate function expects gpa to be valid and won't relocate it
    env_ptr.gpa = std.heap.page_allocator;

    // Relocate the ModuleEnv - this will adjust all the internal pointers
    env_ptr.relocate(offset);

    // Also relocate the source and module_name strings manually
    if (env_ptr.source.len > 0) {
        const old_source_ptr = @intFromPtr(env_ptr.source.ptr);
        const new_source_ptr = @as(isize, @intCast(old_source_ptr)) + offset;
        env_ptr.source.ptr = @ptrFromInt(@as(usize, @intCast(new_source_ptr)));
    }

    if (env_ptr.module_name.len > 0) {
        const old_module_ptr = @intFromPtr(env_ptr.module_name.ptr);
        const new_module_ptr = @as(isize, @intCast(old_module_ptr)) + offset;
        env_ptr.module_name.ptr = @ptrFromInt(@as(usize, @intCast(new_module_ptr)));
    }

    // Now actually evaluate the expression!
    const eval_result = eval_shim.evalExpr(env_ptr, expr_idx) catch |err| {
        var buf: [256]u8 = undefined;
        const err_str = std.fmt.bufPrint(&buf, "Evaluation error: {s}", .{@errorName(err)}) catch "Error formatting";
        return createRocStrFromData(ops, @as([*]u8, @ptrCast(&buf)), err_str.len);
    };

    // Format the result
    var buf: [256]u8 = undefined;
    const result_str = if (eval_result.is_error)
        std.fmt.bufPrint(&buf, "Evaluation failed", .{}) catch "Error"
    else blk: {
        break :blk std.fmt.bufPrint(&buf, "Expression '{s}' evaluated to: {}", .{ env_ptr.source, eval_result.value }) catch "Error formatting";
    };

    return createRocStrFromData(ops, @as([*]u8, @ptrCast(&buf)), result_str.len);
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
