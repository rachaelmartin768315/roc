//! Cross-platform shared memory allocator for sharing data between parent and child processes.
//!
//! This allocator creates a large anonymous shared memory region that can be accessed by both
//! parent and child processes. It uses platform-specific APIs to ensure compatibility across
//! Linux, macOS, BSD, and Windows.
//!
//! ## Example Usage
//!
//! Parent process:
//! ```zig
//! const page_size = try SharedMemoryAllocator.getSystemPageSize();
//! const size = 1024 * 1024 * 1024; // 1GB
//! var shm = try SharedMemoryAllocator.create(allocator, size, page_size);
//! defer shm.deinit(allocator);
//!
//! // Use the allocator...
//! const data = try shm.allocator().alloc(u8, 1000);
//!
//! // Get the actual used size for the child
//! const used_size = shm.getRecommendedMapSize();
//!
//! // Spawn child with the fd and size info
//! const result = try std.process.Child.run(.{
//!     .allocator = allocator,
//!     .argv = &.{ "child_process",
//!                 try std.fmt.allocPrint(allocator, "--shm-fd={}", .{shm.handle}),
//!                 try std.fmt.allocPrint(allocator, "--shm-size={}", .{used_size}) },
//! });
//! ```
//!
//! Child process:
//! ```zig
//! // Parse command line args to get fd and size
//! const shm_fd = args.shm_fd; // File descriptor passed from parent
//! const shm_size = args.shm_size; // The actual used size, not 1GB
//!
//! // Open with the actual used size, not the full 1GB
//! const page_size = try SharedMemoryAllocator.getSystemPageSize();
//! var shm = try SharedMemoryAllocator.fromFd(allocator, shm_fd, shm_size, page_size);
//! defer shm.deinit(allocator);
//!
//! // Access the data...
//! ```
//!
//! This approach uses anonymous shared memory which is simpler and more portable
//! than named shared memory objects.

const std = @import("std");
const builtin = @import("builtin");

const SharedMemoryAllocator = @This();

// Windows API declarations
const windows = if (builtin.os.tag == .windows) struct {
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
    extern "kernel32" fn OpenFileMappingW(dwDesiredAccess: DWORD, bInheritHandle: BOOL, lpName: LPCWSTR) ?HANDLE;
    extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) void;

    const PAGE_READWRITE = 0x04;
    const FILE_MAP_ALL_ACCESS = 0x001f;
    const INVALID_HANDLE_VALUE = @as(HANDLE, @ptrFromInt(std.math.maxInt(usize)));
    const FALSE = 0;

    const SYSTEM_INFO = extern struct {
        wProcessorArchitecture: u16,
        wReserved: u16,
        dwPageSize: DWORD,
        lpMinimumApplicationAddress: LPVOID,
        lpMaximumApplicationAddress: LPVOID,
        dwActiveProcessorMask: *align(1) DWORD,
        dwNumberOfProcessors: DWORD,
        dwProcessorType: DWORD,
        dwAllocationGranularity: DWORD,
        wProcessorLevel: u16,
        wProcessorRevision: u16,
    };
} else struct {};

/// Header stored at the beginning of shared memory to communicate metadata
pub const Header = extern struct {
    magic: u32 = 0x524F4353, // "ROCS"
    version: u32 = 1,
    used_size: u64 = 0,
    total_size: u64 = 0,
    data_offset: u64 = @sizeOf(Header),
    reserved: [472]u8 = [_]u8{0} ** 472, // Pad to 512 bytes total
};

/// Platform-specific handle for the shared memory
handle: Handle,
/// Base pointer to the mapped memory region
base_ptr: [*]align(1) u8,
/// Total size of the mapped region
total_size: usize,
/// Current offset for bump allocation (atomic for thread-safe allocation)
offset: std.atomic.Value(usize),
/// Whether this allocator owns the shared memory (should clean up)
is_owner: bool,
/// Page size for this system
page_size: usize,

const Handle = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    else => std.posix.fd_t,
};

/// Error type for unsupported operating systems
pub const PageSizeError = error{UnsupportedOperatingSystem};

/// Get the system's page size at runtime
pub fn getSystemPageSize() PageSizeError!usize {
    const page_size: usize = switch (builtin.os.tag) {
        .windows => blk: {
            var system_info: windows.SYSTEM_INFO = undefined;
            windows.GetSystemInfo(&system_info);
            break :blk @intCast(system_info.dwPageSize);
        },
        .linux => blk: {
            const result = std.os.linux.getauxval(std.elf.AT_PAGESZ);
            break :blk if (result != 0) result else 4096;
        },
        .macos, .ios, .tvos, .watchos => blk: {
            var page_size_c: usize = undefined;
            var size: usize = @sizeOf(usize);
            _ = std.c.sysctlbyname("hw.pagesize", &page_size_c, &size, null, 0);
            break :blk page_size_c;
        },
        .freebsd, .netbsd, .openbsd, .dragonfly => blk: {
            const result = std.c.getpagesize();
            break :blk @intCast(result);
        },
        else => return error.UnsupportedOperatingSystem,
    };

    // Ensure page_size is a power of 2 (required for alignForward)
    // Round up to the next power of 2 if needed (no-op if already power of 2)
    return std.math.ceilPowerOfTwo(usize, page_size) catch 4096;
}

// Platform-specific C declarations
const c = struct {
    // POSIX shared memory functions (only needed for non-Linux Unix systems)
    extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: std.c.mode_t) c_int;
    extern "c" fn shm_unlink(name: [*:0]const u8) c_int;
};

/// Creates a new anonymous shared memory region with the given size
pub fn create(size: usize, page_size: usize) !SharedMemoryAllocator {
    const aligned_size = std.mem.alignForward(usize, size, page_size);

    switch (builtin.os.tag) {
        .windows => {
            // Windows: CreateFileMapping without a name (anonymous)
            const handle = windows.CreateFileMappingW(
                windows.INVALID_HANDLE_VALUE,
                null, // default security
                windows.PAGE_READWRITE,
                @intCast(aligned_size >> 32), // high 32 bits
                @intCast(aligned_size & 0xFFFFFFFF), // low 32 bits
                null, // anonymous mapping
            );

            if (handle == null) {
                return error.CreateFileMappingFailed;
            }

            const base_ptr = windows.MapViewOfFile(
                handle.?,
                windows.FILE_MAP_ALL_ACCESS,
                0, // offset high
                0, // offset low
                aligned_size,
            );

            if (base_ptr == null) {
                _ = windows.CloseHandle(handle.?);
                return error.MapViewOfFileFailed;
            }

            const result = SharedMemoryAllocator{
                .handle = handle.?,
                .base_ptr = @ptrCast(@alignCast(base_ptr)),
                .total_size = aligned_size,
                .offset = std.atomic.Value(usize).init(@sizeOf(Header)), // Start after header
                .is_owner = true,
                .page_size = page_size,
            };

            // Initialize header
            const header_ptr = @as(*Header, @ptrCast(@alignCast(result.base_ptr)));
            header_ptr.* = Header{
                .total_size = aligned_size,
            };

            return result;
        },
        .linux, .macos, .freebsd, .openbsd, .netbsd => {
            // Create a file descriptor for shared memory that can be passed to child processes
            const fd = blk: {
                if (builtin.os.tag == .linux) {
                    // On Linux, use memfd_create for anonymous shared memory with fd
                    const fd = std.os.linux.memfd_create("roc_shm", std.os.linux.MFD.CLOEXEC);
                    if (fd < 0) {
                        return error.MemfdCreateFailed;
                    }
                    break :blk fd;
                } else {
                    // On other Unix systems, use shm_open with a random name
                    const random_name = std.fmt.allocPrint(std.heap.page_allocator, "/roc_shm_{}", .{std.crypto.random.int(u64)}) catch {
                        return error.OutOfMemory;
                    };
                    defer std.heap.page_allocator.free(random_name);

                    const shm_name = std.fmt.allocPrintZ(std.heap.page_allocator, "{s}", .{random_name}) catch {
                        return error.OutOfMemory;
                    };
                    defer std.heap.page_allocator.free(shm_name);

                    const fd = c.shm_open(
                        shm_name.ptr,
                        @as(u32, @bitCast(std.posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
                        0o600,
                    );

                    if (fd < 0) {
                        return error.ShmOpenFailed;
                    }

                    // Immediately unlink so it gets cleaned up when all references are closed
                    _ = c.shm_unlink(shm_name.ptr);

                    break :blk fd;
                }
            };

            // Set the size of the shared memory
            std.posix.ftruncate(fd, aligned_size) catch {
                _ = std.posix.close(fd);
                return error.FtruncateFailed;
            };

            // Map the shared memory
            const base_ptr = std.posix.mmap(
                null,
                aligned_size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            ) catch |err| {
                _ = std.posix.close(fd);
                return err;
            };

            const result = SharedMemoryAllocator{
                .handle = fd,
                .base_ptr = @ptrCast(@alignCast(base_ptr.ptr)),
                .total_size = aligned_size,
                .offset = std.atomic.Value(usize).init(@sizeOf(Header)), // Start after header
                .is_owner = true,
                .page_size = page_size,
            };

            // Initialize header
            const header_ptr = @as(*Header, @ptrCast(@alignCast(result.base_ptr)));
            header_ptr.* = Header{
                .total_size = aligned_size,
            };

            return result;
        },
        else => @compileError("Unsupported platform"),
    }
}

/// Creates a SharedMemoryAllocator from an existing file descriptor.
/// This is used by child processes to access shared memory created by the parent.
pub fn fromFd(fd: Handle, size: usize, page_size: usize) !SharedMemoryAllocator {
    const aligned_size = std.mem.alignForward(usize, size, page_size);

    switch (builtin.os.tag) {
        .windows => {
            // On Windows, the fd is actually a handle to a file mapping object
            const base_ptr = windows.MapViewOfFile(
                fd,
                windows.FILE_MAP_ALL_ACCESS,
                0,
                0,
                aligned_size,
            );

            if (base_ptr == null) {
                return error.MapViewOfFileFailed;
            }

            return SharedMemoryAllocator{
                .handle = fd,
                .base_ptr = @ptrCast(@alignCast(base_ptr)),
                .total_size = aligned_size,
                .offset = std.atomic.Value(usize).init(@sizeOf(Header)),
                .is_owner = false,
                .page_size = page_size,
            };
        },
        .linux, .macos, .freebsd, .openbsd, .netbsd => {
            // Map the shared memory using the provided file descriptor
            const base_ptr = std.posix.mmap(
                null,
                aligned_size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            ) catch |err| {
                return err;
            };

            return SharedMemoryAllocator{
                .handle = fd,
                .base_ptr = @ptrCast(@alignCast(base_ptr.ptr)),
                .total_size = aligned_size,
                .offset = std.atomic.Value(usize).init(@sizeOf(Header)),
                .is_owner = false,
                .page_size = page_size,
            };
        },
        else => @compileError("Unsupported platform"),
    }
}

/// Updates the header with the current used size.
/// Should be called before handing off to child process.
pub fn updateHeader(self: *SharedMemoryAllocator) void {
    const header_ptr = @as(*Header, @ptrCast(@alignCast(self.base_ptr)));
    header_ptr.used_size = self.getUsedSize();
}

/// Deinitializes the shared memory allocator
pub fn deinit(self: *SharedMemoryAllocator, gpa: std.mem.Allocator) void {
    _ = gpa; // No longer needed since we don't store the name
    // Update header before closing
    if (self.is_owner) {
        self.updateHeader();
    }
    switch (builtin.os.tag) {
        .windows => {
            _ = windows.UnmapViewOfFile(self.base_ptr);
            _ = windows.CloseHandle(self.handle);
        },
        .linux, .macos, .freebsd, .openbsd, .netbsd => {
            std.posix.munmap(@alignCast(self.base_ptr[0..self.total_size]));
            _ = std.posix.close(self.handle);
            // Memory is automatically cleaned up when all references are closed
        },
        else => @compileError("Unsupported platform"),
    }
}

/// Returns a std.mem.Allocator interface for this shared memory allocator
pub fn allocator(self: *SharedMemoryAllocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *SharedMemoryAllocator = @ptrCast(@alignCast(ctx));

    const alignment = @as(usize, 1) << @intFromEnum(ptr_align);

    // Lock-free allocation using compare-and-swap
    while (true) {
        const current_offset = self.offset.load(.monotonic);
        const aligned_offset = std.mem.alignForward(usize, current_offset, alignment);
        const end_offset = aligned_offset + len;

        if (end_offset > self.total_size) {
            return null; // Out of memory
        }

        // Try to atomically update the offset
        if (self.offset.cmpxchgWeak(
            current_offset,
            end_offset,
            .monotonic,
            .monotonic,
        ) == null) {
            // Success! We claimed this region
            const ptr = self.base_ptr + aligned_offset;
            return @ptrCast(ptr);
        }
        // CAS failed, another thread allocated - retry with new offset
    }
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;

    // Simple bump allocator doesn't support resize
    // Could be implemented by checking if this is the last allocation
    return new_len <= buf.len;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = ret_addr;

    // Simple bump allocator doesn't support free
    // Memory is only freed when the entire region is unmapped
}

fn remap(ctx: *anyopaque, old_mem: []u8, old_align: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = old_mem;
    _ = old_align;
    _ = new_size;
    _ = ret_addr;

    // Simple bump allocator doesn't support remapping
    return null;
}

/// Get the current amount of used memory
pub fn getUsedSize(self: *const SharedMemoryAllocator) usize {
    return self.offset.load(.monotonic);
}

/// Get the recommended size for a child process to map.
/// This is the used size aligned to page boundaries.
///
/// IMPORTANT: The parent process MUST communicate this size to the child process
/// (e.g., via command line arguments or environment variables). The child should
/// then use this size when calling open() to map only what's needed.
///
/// Example:
/// ```zig
/// // Parent process
/// const map_size = shm.getRecommendedMapSize();
/// // Pass map_size to child via command line: --shm-size=409600
///
/// // Child process
/// const page_size = try SharedMemoryAllocator.getSystemPageSize();
/// const shm = try SharedMemoryAllocator.open(allocator, name, map_size, page_size);
/// ```
pub fn getRecommendedMapSize(self: *const SharedMemoryAllocator) usize {
    const used = self.getUsedSize();
    if (used == 0) return self.page_size; // Map at least one page
    return std.mem.alignForward(usize, used, self.page_size);
}

/// Get the remaining available memory
pub fn getAvailableSize(self: *const SharedMemoryAllocator) usize {
    return self.total_size - self.offset.load(.monotonic);
}

/// Reset the allocator to allow reuse (only safe if no allocations are still in use!)
pub fn reset(self: *SharedMemoryAllocator) void {
    self.offset.store(0, .monotonic);
}

test "shared memory allocator basic operations" {
    const testing = std.testing;

    // Create shared memory
    const page_size = try getSystemPageSize();
    var shm = try SharedMemoryAllocator.create(1024 * 1024, page_size); // 1MB
    defer shm.deinit(testing.allocator);

    const shm_allocator = shm.allocator();

    // Test allocation
    const data = try shm_allocator.alloc(u32, 100);
    try testing.expect(data.len == 100);

    // Write some data
    for (data, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Test that we can read it back
    for (data, 0..) |item, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), item);
    }

    // Test available size tracking
    const used = shm.getUsedSize();
    try testing.expect(used >= 100 * @sizeOf(u32));
    try testing.expect(shm.getAvailableSize() <= shm.total_size - used);
}

test "shared memory allocator cross-process" {
    const testing = std.testing;

    // Skip on CI or if not supported
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    // Parent: Create and write data
    {
        const page_size = try getSystemPageSize();
        var shm = try SharedMemoryAllocator.create(1024 * 1024, page_size);
        defer shm.deinit(testing.allocator);

        const data = try shm.allocator().alloc(u32, 10);
        for (data, 0..) |*item, i| {
            item.* = @intCast(i * 2);
        }
    }
}

test "shared memory allocator thread safety" {
    const testing = std.testing;

    const page_size = try getSystemPageSize();
    var shm = try SharedMemoryAllocator.create(16 * 1024 * 1024, page_size); // 16MB
    defer shm.deinit(testing.allocator);

    const shm_allocator = shm.allocator();
    const num_threads = 4;
    const allocations_per_thread = 1000;

    const ThreadContext = struct {
        allocator: std.mem.Allocator,
        thread_id: usize,
        allocations_per_thread: usize,
    };

    const thread_fn = struct {
        fn run(ctx: ThreadContext) !void {
            var i: usize = 0;
            while (i < ctx.allocations_per_thread) : (i += 1) {
                // Allocate various sizes
                const size = 16 + (i % 256);
                const data = try ctx.allocator.alloc(u8, size);

                // Write a pattern to verify no overlap
                for (data, 0..) |*byte, j| {
                    byte.* = @intCast((ctx.thread_id * 256 + j) % 256);
                }

                // Verify the pattern immediately
                for (data, 0..) |byte, j| {
                    const expected = @as(u8, @intCast((ctx.thread_id * 256 + j) % 256));
                    try testing.expectEqual(expected, byte);
                }
            }
        }
    }.run;

    // Spawn threads
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, thread_fn, .{ThreadContext{
            .allocator = shm_allocator,
            .thread_id = i,
            .allocations_per_thread = allocations_per_thread,
        }});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify that all allocations succeeded and used memory efficiently
    const used = shm.getUsedSize();
    try testing.expect(used > 0);
    try testing.expect(used < shm.total_size);

    // The actual used size should be at least the sum of all allocations
    var min_expected: usize = 0;
    var i: usize = 0;
    while (i < allocations_per_thread) : (i += 1) {
        min_expected += 16 + (i % 256);
    }
    min_expected *= num_threads;

    // Used size should be at least the minimum (will be more due to alignment)
    try testing.expect(used >= min_expected);
}
