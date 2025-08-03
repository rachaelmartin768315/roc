//! Roc command line interface for the new compiler. Entrypoint of the Roc binary.
//! Build with `zig build -Dllvm -Dfuzz -Dsystem-afl=false`.
//! Result is at `./zig-out/bin/roc`

const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const base = @import("base");
const collections = @import("collections");
const reporting = @import("reporting");
const parse = @import("parse");
const tracy = @import("tracy");

const SharedMemoryAllocator = @import("./SharedMemoryAllocator.zig");
const fmt = @import("fmt.zig");
const coordinate_simple = @import("coordinate_simple.zig");
const Filesystem = @import("fs/Filesystem.zig");
const cli_args = @import("cli_args.zig");
const cache_mod = @import("cache/mod.zig");
const bench = @import("bench.zig");
const linker = @import("linker.zig");
const compile = @import("compile");
const can = @import("can");
const check = @import("check");

const ModuleEnv = compile.ModuleEnv;

const CacheManager = cache_mod.CacheManager;
const CacheConfig = cache_mod.CacheConfig;
const tokenize = parse.tokenize;

const read_roc_file_path_shim_lib = if (builtin.is_test) &[_]u8{} else @embedFile("libread_roc_file_path_shim.a");

// Workaround for Zig standard library compilation issue on macOS ARM64.
//
// The Problem:
// When importing std.c directly, Zig attempts to compile ALL C function declarations,
// including mremap which has this signature in std/c.zig:9562:
//   pub extern "c" fn mremap(addr: ?*align(page_size) const anyopaque, old_len: usize,
//                            new_len: usize, flags: MREMAP, ...) *anyopaque;
//
// The variadic arguments (...) at the end trigger this compiler error on macOS ARM64:
//   "parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_darwin'"
//
// This is because:
// 1. mremap is a Linux-specific syscall that doesn't exist on macOS
// 2. The variadic declaration is incompatible with ARM64 macOS calling conventions
// 3. Even though we never call mremap, just importing std.c triggers its compilation
//
// Related issues:
// - https://github.com/ziglang/zig/issues/6321 - Discussion about mremap platform support
// - mremap is only available on Linux/FreeBSD, not macOS/Darwin
//
// Solution:
// Instead of importing all of std.c, we create a minimal wrapper that only exposes
// the specific types and functions we actually need. This avoids triggering the
// compilation of the broken mremap declaration.
//
// TODO: This workaround can be removed once the upstream Zig issue is fixed.
/// Minimal wrapper around std.c types and functions to avoid mremap compilation issues.
/// Contains only the C types and functions we actually need.
pub const c = struct {
    pub const mode_t = std.c.mode_t;
    pub const off_t = std.c.off_t;

    pub const close = std.c.close;
    pub const link = std.c.link;
    pub const ftruncate = std.c.ftruncate;
    pub const _errno = std.c._errno;
};

// Platform-specific shared memory implementation
const is_windows = builtin.target.os.tag == .windows;

// POSIX shared memory functions
const posix = if (!is_windows) struct {
    extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: std.c.mode_t) c_int;
    extern "c" fn shm_unlink(name: [*:0]const u8) c_int;
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: std.c.off_t) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;

    // fcntl constants
    const F_GETFD = 1;
    const F_SETFD = 2;
    const FD_CLOEXEC = 1;
} else struct {};

// Windows shared memory functions
const windows = if (is_windows) struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = c_int;
    const LPVOID = ?*anyopaque;
    const LPCWSTR = [*:0]const u16;
    const SIZE_T = usize;

    extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpFileMappingAttributes: ?*anyopaque, flProtect: DWORD, dwMaximumSizeHigh: DWORD, dwMaximumSizeLow: DWORD, lpName: LPCWSTR) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: DWORD, dwFileOffsetHigh: DWORD, dwFileOffsetLow: DWORD, dwNumberOfBytesToMap: SIZE_T) LPVOID;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: LPVOID) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) BOOL;

    const PAGE_READWRITE = 0x04;
    const FILE_MAP_ALL_ACCESS = 0x001f;
    const INVALID_HANDLE_VALUE = @as(HANDLE, @ptrFromInt(std.math.maxInt(usize)));
} else struct {};

const benchTokenizer = bench.benchTokenizer;
const benchParse = bench.benchParse;

const Allocator = std.mem.Allocator;
const ColorPalette = reporting.ColorPalette;

const legalDetailsFileContent = @embedFile("legal_details");

/// Size for shared memory allocator - 8TB virtual address space
const SHARED_MEMORY_SIZE: usize = 8 * 1024 * 1024 * 1024 * 1024; // 8TB

/// Cross-platform hardlink creation
fn createHardlink(allocator: Allocator, source: []const u8, dest: []const u8) !void {
    if (comptime builtin.target.os.tag == .windows) {
        // On Windows, use CreateHardLinkW
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
        defer allocator.free(source_w);
        const dest_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dest);
        defer allocator.free(dest_w);

        // Declare CreateHardLinkW since it's not in all versions of std
        const kernel32 = struct {
            extern "kernel32" fn CreateHardLinkW(
                lpFileName: [*:0]const u16,
                lpExistingFileName: [*:0]const u16,
                lpSecurityAttributes: ?*anyopaque,
            ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
        };

        if (kernel32.CreateHardLinkW(dest_w, source_w, null) == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            switch (err) {
                .ALREADY_EXISTS => return error.PathAlreadyExists,
                else => return error.Unexpected,
            }
        }
    } else {
        // On POSIX systems, use the link system call
        const source_c = try allocator.dupeZ(u8, source);
        defer allocator.free(source_c);
        const dest_c = try allocator.dupeZ(u8, dest);
        defer allocator.free(dest_c);

        const result = c.link(source_c, dest_c);
        if (result != 0) {
            const errno = c._errno().*;
            switch (errno) {
                17 => return error.PathAlreadyExists, // EEXIST
                else => return error.Unexpected,
            }
        }
    }
}

/// Generate a cryptographically secure random ASCII string for directory names
fn generateRandomSuffix(allocator: Allocator) ![]u8 {
    // TODO: Consider switching to a library like https://github.com/abhinav/temp.zig
    // for more robust temporary file/directory handling
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    const suffix = try allocator.alloc(u8, 32);

    // Fill with cryptographically secure random bytes
    std.crypto.random.bytes(suffix);

    // Convert to ASCII characters from our charset
    for (suffix) |*byte| {
        byte.* = charset[byte.* % charset.len];
    }

    return suffix;
}

/// Create the temporary directory structure for fd communication.
/// Returns the path to the executable in the temp directory (caller must free).
/// If a cache directory is provided, it will be used for temporary files; otherwise
/// falls back to the system temp directory.
pub fn createTempDirStructure(allocator: Allocator, exe_path: []const u8, shm_handle: SharedMemoryHandle, cache_dir: ?[]const u8) ![]const u8 {
    // Use provided cache dir or fall back to system temp directory
    const temp_dir = if (cache_dir) |dir|
        try allocator.dupe(u8, dir)
    else if (comptime is_windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(temp_dir);

    // Try up to 10 times to create a unique directory
    var attempt: u8 = 0;
    while (attempt < 10) : (attempt += 1) {
        const random_suffix = try generateRandomSuffix(allocator);
        errdefer allocator.free(random_suffix);

        // Create the full path with .txt suffix first
        const normalized_temp_dir = std.mem.trimRight(u8, temp_dir, "/");
        const dir_name_with_txt = try std.fmt.allocPrint(allocator, "{s}/roc-tmp-{s}.txt", .{ normalized_temp_dir, random_suffix });
        errdefer allocator.free(dir_name_with_txt);

        // Get the directory path by slicing off the .txt suffix
        const dir_path_len = dir_name_with_txt.len - 4; // Remove ".txt"
        const temp_dir_path = dir_name_with_txt[0..dir_path_len];

        // Try to create the directory
        std.fs.cwd().makeDir(temp_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Directory already exists, try again with a new random suffix
                allocator.free(random_suffix);
                allocator.free(dir_name_with_txt);
                continue;
            },
            else => {
                allocator.free(random_suffix);
                allocator.free(dir_name_with_txt);
                return err;
            },
        };

        // Try to create the fd file
        const fd_file = std.fs.cwd().createFile(dir_name_with_txt, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // File already exists, remove the directory and try again
                std.fs.cwd().deleteDir(temp_dir_path) catch {};
                allocator.free(random_suffix);
                allocator.free(dir_name_with_txt);
                continue;
            },
            else => {
                // Clean up directory on other errors
                std.fs.cwd().deleteDir(temp_dir_path) catch {};
                allocator.free(random_suffix);
                allocator.free(dir_name_with_txt);
                return err;
            },
        };
        defer fd_file.close();

        // Write fd and size to file (format: fd\nsize)
        // This allows the child to know exactly how many bytes to mmap
        const fd_str = if (comptime is_windows)
            try std.fmt.allocPrint(allocator, "{}\n{}", .{ @intFromPtr(shm_handle.fd), shm_handle.size })
        else
            try std.fmt.allocPrint(allocator, "{}\n{}", .{ shm_handle.fd, shm_handle.size });
        defer allocator.free(fd_str);

        try fd_file.writeAll(fd_str);

        // Create hardlink to executable in temp directory
        const exe_basename = std.fs.path.basename(exe_path);
        const temp_exe_path = try std.fs.path.join(allocator, &.{ temp_dir_path, exe_basename });
        defer allocator.free(temp_exe_path);

        // Try to create a hardlink first (more efficient than copying)
        createHardlink(allocator, exe_path, temp_exe_path) catch {
            // If hardlinking fails for any reason, fall back to copying
            // Common reasons: cross-device link, permissions, file already exists
            try std.fs.cwd().copyFile(exe_path, std.fs.cwd(), temp_exe_path, .{});
        };

        // Allocate and return just the executable path
        const final_exe_path = try allocator.dupe(u8, temp_exe_path);

        // Free all temporary allocations
        allocator.free(dir_name_with_txt);
        allocator.free(random_suffix);

        return final_exe_path;
    }

    // Failed after 10 attempts
    return error.FailedToCreateUniqueTempDir;
}

/// The CLI entrypoint for the Roc compiler.
pub fn main() !void {
    var gpa_tracy: tracy.TracyAllocator(null) = undefined;
    var gpa = std.heap.c_allocator;

    if (tracy.enable_allocation) {
        gpa_tracy = tracy.tracyAllocator(gpa);
        gpa = gpa_tracy.allocator();
    }

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);

    const result = mainArgs(gpa, arena, args);
    if (tracy.enable) {
        try tracy.waitForShutdown();
    }
    return result;
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const parsed_args = try cli_args.parse(gpa, args[1..]);
    defer parsed_args.deinit(gpa);

    try switch (parsed_args) {
        .run => |run_args| rocRun(gpa, run_args),
        .check => |check_args| rocCheck(gpa, check_args),
        .build => |build_args| rocBuild(gpa, build_args),
        .format => |format_args| rocFormat(gpa, arena, format_args),
        .test_cmd => |test_args| rocTest(gpa, test_args),
        .repl => rocRepl(gpa),
        .version => stdout.print("Roc compiler version {s}\n", .{build_options.compiler_version}),
        .docs => |docs_args| rocDocs(gpa, docs_args),
        .help => |help_message| stdout.writeAll(help_message),
        .licenses => stdout.writeAll(legalDetailsFileContent),
        .problem => |problem| {
            try switch (problem) {
                .missing_flag_value => |details| stderr.print("Error: no value was supplied for {s}\n", .{details.flag}),
                .unexpected_argument => |details| stderr.print("Error: roc {s} received an unexpected argument: `{s}`\n", .{ details.cmd, details.arg }),
                .invalid_flag_value => |details| stderr.print("Error: `{s}` is not a valid value for {s}. The valid options are {s}\n", .{ details.value, details.flag, details.valid_options }),
            };
            std.process.exit(1);
        },
    };
}

fn rocRun(gpa: Allocator, args: cli_args.RunArgs) void {
    const trace = tracy.trace(@src());
    defer trace.end();

    // Initialize cache - used to store our shim, and linked interpreter executables in cache
    const cache_config = CacheConfig{
        .enabled = !args.no_cache,
        .verbose = false,
    };
    var cache_manager = CacheManager.init(gpa, cache_config, Filesystem.default());

    // Create cache directory for linked interpreter executables
    const cache_dir = cache_manager.config.getCacheEntriesDir(gpa) catch |err| {
        std.log.err("Failed to get cache directory: {}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(cache_dir);
    const exe_cache_dir = std.fs.path.join(gpa, &.{ cache_dir, "executables" }) catch |err| {
        std.log.err("Failed to create executable cache path: {}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(exe_cache_dir);

    std.fs.cwd().makePath(exe_cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.log.err("Failed to create cache directory: {}\n", .{err});
            std.process.exit(1);
        },
    };

    // Generate executable name based on the roc file path
    // TODO use something more interesting like a hash from the platform.main or platform/host.a etc
    const exe_name = std.fmt.allocPrint(gpa, "roc_run_{}", .{std.hash.crc.Crc32.hash(args.path)}) catch |err| {
        std.log.err("Failed to generate executable name: {}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(exe_name);

    const exe_path = std.fs.path.join(gpa, &.{ exe_cache_dir, exe_name }) catch |err| {
        std.log.err("Failed to create executable path: {}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(exe_path);

    // Check if the interpreter executable already exists (cached)
    const exe_exists = if (args.no_cache) false else blk: {
        std.fs.accessAbsolute(exe_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!exe_exists) {

        // Production platform loading: resolve platform from app header
        const host_path = resolvePlatformHost(gpa, args.path) catch |err| {
            std.log.err("Failed to resolve platform: {}\n", .{err});
            std.process.exit(1);
        };
        defer gpa.free(host_path);

        // Check for cached shim library, extract if not present
        const shim_path = std.fs.path.join(gpa, &.{ exe_cache_dir, "libread_roc_file_path_shim.a" }) catch |err| {
            std.log.err("Failed to create shim library path: {}\n", .{err});
            std.process.exit(1);
        };
        defer gpa.free(shim_path);

        // Only extract if the shim doesn't already exist in cache
        std.fs.cwd().access(shim_path, .{}) catch {
            // Shim not found in cache, extract it
            extractReadRocFilePathShimLibrary(gpa, shim_path) catch |err| {
                std.log.err("Failed to extract read roc file path shim library: {}\n", .{err});
                std.process.exit(1);
            };
        };

        // Link the host.a with our shim to create the interpreter executable using clang
        const link_result = std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{ "clang", "-o", exe_path, host_path, shim_path },
        }) catch |err| {
            std.log.err("Failed to link executable: {}\n", .{err});
            std.process.exit(1);
        };
        defer gpa.free(link_result.stdout);
        defer gpa.free(link_result.stderr);

        if (link_result.term.Exited != 0) {
            std.log.err("Linker failed with exit code: {}\n", .{link_result.term.Exited});
            if (link_result.stderr.len > 0) {
                std.log.err("Linker stderr: {s}\n", .{link_result.stderr});
            }
            std.process.exit(1);
        }
    }

    // Set up shared memory with ModuleEnv
    const shm_handle = setupSharedMemoryWithModuleEnv(gpa, args.path) catch |err| {
        std.log.err("Failed to set up shared memory with ModuleEnv: {}\n", .{err});
        std.process.exit(1);
    };

    // Ensure we clean up shared memory resources on all exit paths
    defer {
        if (comptime is_windows) {
            _ = windows.UnmapViewOfFile(shm_handle.ptr);
            _ = windows.CloseHandle(@ptrCast(shm_handle.fd));
        } else {
            _ = posix.munmap(shm_handle.ptr, shm_handle.size);
            _ = c.close(shm_handle.fd);
        }
        cleanupSharedMemory();
    }

    // Get cache directory for temporary files
    const temp_cache_dir = cache_manager.config.getTempDir(gpa) catch |err| {
        std.log.err("Failed to get temp cache directory: {}\n", .{err});
        cleanupSharedMemory();
        std.process.exit(1);
    };
    defer gpa.free(temp_cache_dir);

    // Ensure temp cache directory exists
    std.fs.cwd().makePath(temp_cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.log.err("Failed to create temp cache directory: {}\n", .{err});
            cleanupSharedMemory();
            std.process.exit(1);
        },
    };

    // Create temporary directory structure for fd communication
    const temp_exe_path = createTempDirStructure(gpa, exe_path, shm_handle, temp_cache_dir) catch |err| {
        std.log.err("Failed to create temp dir structure: {}\n", .{err});
        cleanupSharedMemory();
        std.process.exit(1);
    };
    defer gpa.free(temp_exe_path);

    // Configure handle/fd inheritance for all platforms
    if (comptime !is_windows) {
        var flags = posix.fcntl(shm_handle.fd, posix.F_GETFD, 0);
        if (flags < 0) {
            std.log.err("Failed to get fd flags: {}\n", .{c._errno().*});
            cleanupSharedMemory();
            std.process.exit(1);
        }

        flags &= ~@as(c_int, posix.FD_CLOEXEC);

        if (posix.fcntl(shm_handle.fd, posix.F_SETFD, flags) < 0) {
            std.log.err("Failed to set fd flags: {}\n", .{c._errno().*});
            cleanupSharedMemory();
            std.process.exit(1);
        }
    }

    // Run the interpreter as a child process from the temp directory
    var child = std.process.Child.init(&.{temp_exe_path}, gpa);
    child.cwd = std.fs.cwd().realpathAlloc(gpa, ".") catch |err| {
        std.log.err("Failed to get current directory: {}\n", .{err});
        cleanupSharedMemory();
        std.process.exit(1);
    };
    defer gpa.free(child.cwd.?);

    // Forward stdout and stderr
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| {
        std.log.err("Failed to spawn {s}: {}\n", .{ exe_path, err });
        cleanupSharedMemory();
        std.process.exit(1);
    };

    // Wait for child to complete
    _ = child.wait() catch |err| {
        std.log.err("Failed waiting for child process: {}\n", .{err});
        std.process.exit(1);
    };

}

/// Handle for cross-platform shared memory operations.
/// Contains the file descriptor/handle, memory pointer, and size.
pub const SharedMemoryHandle = struct {
    fd: if (is_windows) *anyopaque else c_int,
    ptr: *anyopaque,
    size: usize,
};

/// Write data to shared memory for inter-process communication.
/// Creates a shared memory region and writes the data with a length prefix.
/// Returns a handle that can be used to access the shared memory.
pub fn writeToSharedMemory(data: []const u8) !SharedMemoryHandle {
    // Calculate total size needed: length + data
    const total_size = @sizeOf(usize) + data.len;

    if (comptime is_windows) {
        return writeToWindowsSharedMemory(data, total_size);
    } else {
        return writeToPosixSharedMemory(data, total_size);
    }
}

fn writeToWindowsSharedMemory(data: []const u8, total_size: usize) !SharedMemoryHandle {
    const shm_name_wide = std.unicode.utf8ToUtf16LeStringLiteral("ROC_FILE_TO_INTERPRET");

    // Create shared memory object
    const shm_handle = windows.CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        null,
        windows.PAGE_READWRITE,
        0,
        @intCast(total_size),
        shm_name_wide,
    ) orelse {
        std.debug.print("Failed to create shared memory mapping\n", .{});
        return error.SharedMemoryCreateFailed;
    };

    // Map the shared memory
    const mapped_ptr = windows.MapViewOfFile(
        shm_handle,
        windows.FILE_MAP_ALL_ACCESS,
        0,
        0,
        0,
    ) orelse {
        _ = windows.CloseHandle(shm_handle);
        std.debug.print("Failed to map shared memory\n", .{});
        return error.SharedMemoryMapFailed;
    };

    // Write length and data
    const length_ptr: *usize = @ptrCast(@alignCast(mapped_ptr));
    length_ptr.* = data.len;

    const data_ptr = @as([*]u8, @ptrCast(mapped_ptr)) + @sizeOf(usize);
    @memcpy(data_ptr[0..data.len], data);

    return SharedMemoryHandle{
        .fd = shm_handle,
        .ptr = mapped_ptr,
        .size = total_size,
    };
}

/// Set up shared memory with a compiled ModuleEnv from a Roc file
/// This function parses, canonicalizes, and type-checks the Roc file, then stores the resulting ModuleEnv in shared memory
pub fn setupSharedMemoryWithModuleEnv(gpa: std.mem.Allocator, roc_file_path: []const u8) !SharedMemoryHandle {
    // Create shared memory with SharedMemoryAllocator
    const page_size = try SharedMemoryAllocator.getSystemPageSize();
    var shm = try SharedMemoryAllocator.create(gpa, "ROC_FILE_TO_INTERPRET", SHARED_MEMORY_SIZE, page_size);
    // Don't defer deinit here - we need to keep the shared memory alive

    const shm_allocator = shm.allocator();

    // Allocate space for the offset value at the beginning
    const offset_ptr = try shm_allocator.alloc(u64, 1);
    // Also store the canonicalized expression index for the child to evaluate
    const expr_idx_ptr = try shm_allocator.alloc(u32, 1);

    // Store the parent's address where the first allocation is
    // The first allocation starts at offset 504 (0x1f8) from base
    const first_alloc_addr = @intFromPtr(shm.base_ptr) + 504;
    offset_ptr[0] = first_alloc_addr;

    // Allocate and store a pointer to the ModuleEnv
    const env_ptr = try shm_allocator.create(ModuleEnv);

    // Read the actual Roc file
    const roc_file = std.fs.cwd().openFile(roc_file_path, .{}) catch |err| {
        std.log.err("Failed to open Roc file '{s}': {}\n", .{ roc_file_path, err });
        return error.FileNotFound;
    };
    defer roc_file.close();

    // Read the entire file into shared memory
    const file_size = try roc_file.getEndPos();
    const source = try shm_allocator.alloc(u8, file_size);
    _ = try roc_file.read(source);

    // Extract module name from the file path
    const basename = std.fs.path.basename(roc_file_path);
    const module_name = try shm_allocator.dupe(u8, basename);

    var env = try ModuleEnv.init(shm_allocator, source);
    env.source = source;
    env.module_name = module_name;
    try env.calcLineStarts();

    // Parse the source code as an expression for simplicity
    var parse_ast = try parse.parseExpr(&env);

    // Empty scratch space (required before canonicalization)
    parse_ast.store.emptyScratch();

    // Initialize CIR fields in ModuleEnv
    try env.initCIRFields(shm_allocator, "test");

    // Create canonicalizer
    var canonicalizer = try can.init(&env, &parse_ast, null);

    // For parseExpr, the root_node_idx points directly to the expression
    const main_expr_idx: parse.AST.Expr.Idx = @enumFromInt(parse_ast.root_node_idx);

    const canonicalized_expr_idx = try canonicalizer.canonicalizeExpr(main_expr_idx) orelse {
        return error.CanonicalizeFailure;
    };

    // Store the canonicalized expression index for the child
    expr_idx_ptr[0] = @intFromEnum(canonicalized_expr_idx.idx);

    // Type check the expression
    var checker = try check.init(shm_allocator, &env.types, &env, &.{}, &env.store.regions);
    _ = try checker.checkExpr(canonicalized_expr_idx.idx);

    // Copy the ModuleEnv to the allocated space
    env_ptr.* = env;

    // Clean up the canonicalizer (but keep parse_ast data since it's in shared memory)
    canonicalizer.deinit();

    // Don't deinit parse_ast since its data is in shared memory
    // Don't deinit checker since its data is in shared memory

    // Update the header with used size
    shm.updateHeader();

    // Return the shared memory handle
    // The caller is responsible for cleanup
    return SharedMemoryHandle{
        .fd = shm.handle,
        .ptr = shm.base_ptr,
        .size = shm.getUsedSize(),
    };
}

fn writeToPosixSharedMemory(data: []const u8, total_size: usize) !SharedMemoryHandle {
    const shm_name = "/ROC_FILE_TO_INTERPRET";

    // Unlink any existing shared memory object first
    _ = posix.shm_unlink(shm_name);

    // Create shared memory object
    const shm_fd = posix.shm_open(shm_name, 0x0002 | 0x0200, 0o666); // O_RDWR | O_CREAT
    if (shm_fd < 0) {
        const errno = c._errno().*;
        std.debug.print("Failed to create shared memory: {s}, fd = {}, errno = {}\n", .{ shm_name, shm_fd, errno });
        return error.SharedMemoryCreateFailed;
    }

    // Set the size of the shared memory object
    if (c.ftruncate(shm_fd, @intCast(total_size)) != 0) {
        _ = c.close(shm_fd);
        std.debug.print("Failed to set shared memory size\n", .{});
        return error.SharedMemoryTruncateFailed;
    }

    // Map the shared memory
    const mapped_ptr = posix.mmap(
        null,
        total_size,
        0x01 | 0x02, // PROT_READ | PROT_WRITE
        0x0001, // MAP_SHARED
        shm_fd,
        0,
    ) orelse {
        _ = c.close(shm_fd);
        std.debug.print("Failed to map shared memory\n", .{});
        return error.SharedMemoryMapFailed;
    };
    const mapped_memory = @as([*]u8, @ptrCast(mapped_ptr))[0..total_size];

    // Write length at the beginning
    const length_ptr: *align(1) usize = @ptrCast(mapped_memory.ptr);
    length_ptr.* = data.len;

    // Write data after the length
    const data_ptr = mapped_memory.ptr + @sizeOf(usize);
    @memcpy(data_ptr[0..data.len], data);

    return SharedMemoryHandle{
        .fd = shm_fd,
        .ptr = mapped_ptr,
        .size = total_size,
    };
}

/// Resolve platform specification from a Roc file to find the host library
pub fn resolvePlatformHost(gpa: std.mem.Allocator, roc_file_path: []const u8) (std.mem.Allocator.Error || error{ NoPlatformFound, PlatformNotSupported })![]u8 {
    // Read the Roc file to parse the app header
    const roc_file = std.fs.cwd().openFile(roc_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoPlatformFound,
        else => return error.NoPlatformFound, // Treat all file errors as no platform found
    };
    defer roc_file.close();

    const file_size = roc_file.getEndPos() catch return error.NoPlatformFound;
    const source = gpa.alloc(u8, file_size) catch return error.OutOfMemory;
    defer gpa.free(source);
    _ = roc_file.read(source) catch return error.NoPlatformFound;

    // Parse the source to find the app header
    // Look for "app" followed by platform specification
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check if this is an app header line
        if (std.mem.startsWith(u8, trimmed, "app")) {
            // Look for platform specification after "platform"
            if (std.mem.indexOf(u8, trimmed, "platform")) |platform_start| {
                const after_platform = trimmed[platform_start + "platform".len ..];

                // Find the platform name/URL in quotes
                if (std.mem.indexOf(u8, after_platform, "\"")) |quote_start| {
                    const after_quote = after_platform[quote_start + 1 ..];
                    if (std.mem.indexOf(u8, after_quote, "\"")) |quote_end| {
                        const platform_spec = after_quote[0..quote_end];

                        // Try to resolve platform to a local host library
                        return resolvePlatformSpecToHostLib(gpa, platform_spec);
                    }
                }
            }
        }
    }

    return error.NoPlatformFound;
}

/// Resolve a platform specification to a local host library path
fn resolvePlatformSpecToHostLib(gpa: std.mem.Allocator, platform_spec: []const u8) (std.mem.Allocator.Error || error{PlatformNotSupported})![]u8 {
    // Check for common platform names and map them to host libraries
    if (std.mem.eql(u8, platform_spec, "cli")) {
        // Try to find CLI platform host library
        const cli_paths = [_][]const u8{
            "zig-out/lib/libplatform_host_cli.a",
            "platform/cli/host.a",
            "platforms/cli/host.a",
        };

        for (cli_paths) |path| {
            std.fs.cwd().access(path, .{}) catch continue;
            return try gpa.dupe(u8, path);
        }
    } else if (std.mem.eql(u8, platform_spec, "basic-cli")) {
        // Try to find basic-cli platform host library
        const basic_cli_paths = [_][]const u8{
            "zig-out/lib/libplatform_host_basic_cli.a",
            "platform/basic-cli/host.a",
            "platforms/basic-cli/host.a",
        };

        for (basic_cli_paths) |path| {
            std.fs.cwd().access(path, .{}) catch continue;
            return try gpa.dupe(u8, path);
        }
    } else if (std.mem.startsWith(u8, platform_spec, "http")) {
        // This is a URL - for production, would download and resolve
        // For now, return not supported
        return error.PlatformNotSupported;
    }

    // Try to interpret as a direct file path
    std.fs.cwd().access(platform_spec, .{}) catch {
        return error.PlatformNotSupported;
    };

    return try gpa.dupe(u8, platform_spec);
}

/// Clean up shared memory resources.
/// On POSIX systems, unlinks the shared memory object. On Windows, cleanup is automatic.
pub fn cleanupSharedMemory() void {
    if (comptime is_windows) {
        // On Windows, shared memory is automatically cleaned up when all handles are closed
        return;
    } else {
        const shm_name = "/ROC_FILE_TO_INTERPRET";
        if (posix.shm_unlink(shm_name) != 0) {}
    }
}

/// Extract the embedded read_roc_file_path_shim library to the specified path
/// This library contains the shim code that runs in child processes to read ModuleEnv from shared memory
pub fn extractReadRocFilePathShimLibrary(gpa: Allocator, output_path: []const u8) !void {
    _ = gpa; // unused but kept for consistency

    if (builtin.is_test) {
        // In test mode, create an empty file to avoid embedding issues
        const shim_file = try std.fs.cwd().createFile(output_path, .{});
        defer shim_file.close();
        return;
    }

    // Write the embedded shim library to the output path
    const shim_file = try std.fs.cwd().createFile(output_path, .{});
    defer shim_file.close();

    try shim_file.writeAll(read_roc_file_path_shim_lib);
}

fn rocBuild(gpa: Allocator, args: cli_args.BuildArgs) !void {
    // Handle the --z-bench-tokenize flag
    if (args.z_bench_tokenize) |file_path| {
        try benchTokenizer(gpa, file_path);
        return;
    }

    // Handle the --z-bench-parse flag
    if (args.z_bench_parse) |directory_path| {
        try benchParse(gpa, directory_path);
        return;
    }

    fatal("build not implemented", .{});
}

fn rocTest(gpa: Allocator, args: cli_args.TestArgs) !void {
    _ = gpa;
    _ = args;
    fatal("test not implemented", .{});
}

fn rocRepl(gpa: Allocator) !void {
    _ = gpa;
    fatal("repl not implemented", .{});
}

/// Reads, parses, formats, and overwrites all Roc files at the given paths.
/// Recurses into directories to search for Roc files.
fn rocFormat(gpa: Allocator, arena: Allocator, args: cli_args.FormatArgs) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    const stdout = std.io.getStdOut();
    if (args.stdin) {
        fmt.formatStdin(gpa) catch std.process.exit(1);
        return;
    }

    var timer = try std.time.Timer.start();
    var elapsed: u64 = undefined;
    var failure_count: usize = 0;
    var exit_code: u8 = 0;

    if (args.check) {
        var unformatted_files = std.ArrayList([]const u8).init(gpa);
        defer unformatted_files.deinit();

        for (args.paths) |path| {
            var result = try fmt.formatPath(gpa, arena, std.fs.cwd(), path, true);
            defer result.deinit();
            if (result.unformatted_files) |files| {
                try unformatted_files.appendSlice(files.items);
            }
            failure_count += result.failure;
        }

        elapsed = timer.read();
        if (unformatted_files.items.len > 0) {
            try stdout.writer().print("The following file(s) failed `roc format --check`:\n", .{});
            for (unformatted_files.items) |file_name| {
                try stdout.writer().print("    {s}\n", .{file_name});
            }
            try stdout.writer().print("You can fix this with `roc format FILENAME.roc`.\n", .{});
            exit_code = 1;
        } else {
            try stdout.writer().print("All formatting valid\n", .{});
        }
        if (failure_count > 0) {
            try stdout.writer().print("Failed to check {} files.\n", .{failure_count});
            exit_code = 1;
        }
    } else {
        var success_count: usize = 0;
        for (args.paths) |path| {
            const result = try fmt.formatPath(gpa, arena, std.fs.cwd(), path, false);
            success_count += result.success;
            failure_count += result.failure;
        }
        elapsed = timer.read();
        try stdout.writer().print("Successfully formatted {} files\n", .{success_count});
        if (failure_count > 0) {
            try stdout.writer().print("Failed to format {} files.\n", .{failure_count});
            exit_code = 1;
        }
    }

    try stdout.writer().print("Took ", .{});
    try formatElapsedTime(stdout.writer(), elapsed);
    try stdout.writer().print(".\n", .{});

    std.process.exit(exit_code);
}

/// Helper function to format elapsed time, showing decimal milliseconds
fn formatElapsedTime(writer: anytype, elapsed_ns: u64) !void {
    const elapsed_ms_float = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    try writer.print("{d:.1} ms", .{elapsed_ms_float});
}

fn handleProcessFileError(err: anytype, stderr: anytype, path: []const u8) noreturn {
    stderr.print("Failed to check {s}: ", .{path}) catch {};
    switch (err) {
        error.FileNotFound => stderr.print("File not found\n", .{}) catch {},
        error.AccessDenied => stderr.print("Access denied\n", .{}) catch {},
        error.FileReadError => stderr.print("Could not read file\n", .{}) catch {},
        else => stderr.print("{}\n", .{err}) catch {},
    }
    std.process.exit(1);
}

fn rocCheck(gpa: Allocator, args: cli_args.CheckArgs) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const stderr_writer = stderr.any();

    var timer = try std.time.Timer.start();

    // Initialize cache if enabled
    const cache_config = CacheConfig{
        .enabled = !args.no_cache,
        .verbose = args.verbose,
    };

    var cache_manager = if (cache_config.enabled) blk: {
        const manager = CacheManager.init(gpa, cache_config, Filesystem.default());
        break :blk manager;
    } else null;

    // Process the file and get Reports
    var process_result = coordinate_simple.processFile(
        gpa,
        Filesystem.default(),
        args.path,
        if (cache_manager) |*cm| cm else null,
        args.time,
    ) catch |err| {
        handleProcessFileError(err, stderr, args.path);
    };

    defer process_result.deinit(gpa);

    const elapsed = timer.read();

    // Print cache statistics if verbose
    if (cache_manager) |*cm| {
        if (args.verbose) {
            cm.printStats(gpa);
        }
    }

    // Handle cached results vs fresh compilation results differently
    if (process_result.was_cached) {
        // For cached results, use the stored diagnostic counts
        const total_errors = process_result.error_count;
        const total_warnings = process_result.warning_count;

        if (total_errors > 0 or total_warnings > 0) {
            stderr.print("Found {} error(s) and {} warning(s) in ", .{
                total_errors,
                total_warnings,
            }) catch {};
            formatElapsedTime(stderr, elapsed) catch {};
            stderr.print(" for {s} (note module loaded from cache, use --no-cache to display Errors and Warnings.).\n", .{args.path}) catch {};
            std.process.exit(1);
        } else {
            stdout.print("No errors found in ", .{}) catch {};
            formatElapsedTime(stdout, elapsed) catch {};
            stdout.print(" for {s} (loaded from cache)\n", .{args.path}) catch {};
        }
    } else {
        // For fresh compilation, process and display reports normally
        if (process_result.reports.len > 0) {
            var fatal_errors: usize = 0;
            var runtime_errors: usize = 0;
            var warnings: usize = 0;

            // Render each report
            for (process_result.reports) |*report| {

                // Render the diagnostic report to stderr
                reporting.renderReportToTerminal(report, stderr_writer, ColorPalette.ANSI, reporting.ReportingConfig.initColorTerminal()) catch |render_err| {
                    stderr.print("Error rendering diagnostic report: {}\n", .{render_err}) catch {};
                    // Fallback to just printing the title
                    stderr.print("  {s}\n", .{report.title}) catch {};
                };

                switch (report.severity) {
                    .info => {}, // Informational messages don't affect error/warning counts
                    .runtime_error => {
                        runtime_errors += 1;
                    },
                    .fatal => {
                        fatal_errors += 1;
                    },
                    .warning => {
                        warnings += 1;
                    },
                }
            }
            stderr.writeAll("\n") catch {};

            stderr.print("Found {} error(s) and {} warning(s) in ", .{
                (fatal_errors + runtime_errors),
                warnings,
            }) catch {};
            formatElapsedTime(stderr, elapsed) catch {};
            stderr.print(" for {s}.\n", .{args.path}) catch {};

            std.process.exit(1);
        } else {
            stdout.print("No errors found in ", .{}) catch {};
            formatElapsedTime(stdout, elapsed) catch {};
            stdout.print(" for {s}\n", .{args.path}) catch {};
        }
    }

    printTimingBreakdown(stdout, process_result.timing);
}

fn printTimingBreakdown(writer: anytype, timing: ?coordinate_simple.TimingInfo) void {
    if (timing) |t| {
        writer.print("\nTiming breakdown:\n", .{}) catch {};
        writer.print("  tokenize + parse:             ", .{}) catch {};
        formatElapsedTime(writer, t.tokenize_parse_ns) catch {};
        writer.print("  ({} ns)\n", .{t.tokenize_parse_ns}) catch {};
        writer.print("  canonicalize:                 ", .{}) catch {};
        formatElapsedTime(writer, t.canonicalize_ns) catch {};
        writer.print("  ({} ns)\n", .{t.canonicalize_ns}) catch {};
        writer.print("  can diagnostics:              ", .{}) catch {};
        formatElapsedTime(writer, t.canonicalize_diagnostics_ns) catch {};
        writer.print("  ({} ns)\n", .{t.canonicalize_diagnostics_ns}) catch {};
        writer.print("  type checking:                ", .{}) catch {};
        formatElapsedTime(writer, t.type_checking_ns) catch {};
        writer.print("  ({} ns)\n", .{t.type_checking_ns}) catch {};
        writer.print("  type checking diagnostics:    ", .{}) catch {};
        formatElapsedTime(writer, t.check_diagnostics_ns) catch {};
        writer.print("  ({} ns)\n", .{t.check_diagnostics_ns}) catch {};
    }
}

fn rocDocs(gpa: Allocator, args: cli_args.DocsArgs) !void {
    _ = gpa;
    _ = args;
    fatal("docs not implemented", .{});
}

/// Log a fatal error and exit the process with a non-zero code.
pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print(format, args) catch unreachable;
    if (tracy.enable) {
        tracy.waitForShutdown() catch unreachable;
    }
    std.process.exit(1);
}
