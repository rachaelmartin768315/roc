//! CompactWriter provides efficient serialization using scatter-gather I/O operations.
//! It collects multiple memory regions into iovecs and writes them in a single system call
//! using pwritev, minimizing system call overhead for serialization tasks.
//! The writer handles alignment requirements and padding automatically to ensure
//! proper deserialization of the written data.

const std = @import("std");

/// A writer that efficiently serializes data using scatter-gather I/O operations.
pub const CompactWriter = struct {
    pub const ALIGNMENT = 16; // Buffer alignment requirement for deserialization

    const ZEROS: [16]u8 = [_]u8{0} ** 16;

    iovecs: std.ArrayListUnmanaged(Iovec),
    total_bytes: usize,

    /// Does a pwritev() on UNIX systems.
    /// There is no usable equivalent of this on Windows
    /// (WriteFileGather has ludicrous alignment requirements that make it useless),
    /// so Windows must call
    pub fn writeGather(
        self: *@This(),
        allocator: std.mem.Allocator,
        file: std.fs.File,
    ) !void {
        // Handle partial writes (where pwritev returns that it only wrote some of the bytes)
        var bytes_written: usize = 0;
        var current_iovec: usize = 0;
        var iovec_offset: usize = 0;
        const total_size = self.total_bytes;

        while (bytes_written < total_size) {
            // Create adjusted iovec array for partial writes
            const remaining_iovecs = self.iovecs.items.len - current_iovec;
            var adjusted_iovecs = try allocator.alloc(std.posix.iovec_const, remaining_iovecs);
            defer allocator.free(adjusted_iovecs);

            // Copy remaining iovecs, adjusting first one for partial write
            for (self.iovecs.items[current_iovec..], 0..) |iovec, j| {
                if (j == 0 and iovec_offset > 0) {
                    // Adjust first iovec for partial write
                    adjusted_iovecs[j] = .{
                        .base = @ptrFromInt(@intFromPtr(iovec.iov_base) + iovec_offset),
                        .len = iovec.iov_len - iovec_offset,
                    };
                } else {
                    adjusted_iovecs[j] = .{
                        .base = iovec.iov_base,
                        .len = iovec.iov_len,
                    };
                }
            }

            const n = try std.posix.pwritev(file.handle, adjusted_iovecs, bytes_written);
            if (n == 0) return error.UnexpectedEof;

            // Update position tracking
            bytes_written += n;
            var remaining = n;

            // Figure out where we are now
            while (remaining > 0 and current_iovec < self.iovecs.items.len) {
                const iovec_remaining = self.iovecs.items[current_iovec].iov_len - iovec_offset;
                if (remaining >= iovec_remaining) {
                    remaining -= iovec_remaining;
                    current_iovec += 1;
                    iovec_offset = 0;
                } else {
                    iovec_offset += remaining;
                    remaining = 0;
                }
            }
        }
    }

    /// Appends a pointer the writer, after adding padding for alignment as necessary.
    pub fn append(
        self: *@This(),
        allocator: std.mem.Allocator,
        ptr: anytype,
    ) std.mem.Allocator.Error!void {
        const T = std.meta.Child(@TypeOf(ptr));
        const size = @sizeOf(T);
        const alignment = @alignOf(T);

        // When we deserialize, we align the bytes we're deserializing into to ALIGNMENT,
        // which means that we can't serialize anything with alignment higher than that.
        std.debug.assert(alignment <= ALIGNMENT);

        // Pad up front to the alignment of T
        try self.padToAlignment(allocator, alignment);

        // Add the pointer to the iovecs.
        try self.iovecs.append(allocator, .{
            .iov_base = @ptrCast(@as([*]u8, @ptrCast(ptr))),
            .iov_len = size,
        });
        self.total_bytes += size;
    }

    pub fn appendSlice(
        self: *@This(),
        allocator: std.mem.Allocator,
        slice: anytype,
    ) std.mem.Allocator.Error!@TypeOf(slice) {
        const SliceType = @TypeOf(slice);
        const T = std.meta.Child(SliceType);
        const size = @sizeOf(T);
        const alignment = @alignOf(T);
        const len = slice.len;

        // Pad up front to the alignment of T
        try self.padToAlignment(allocator, alignment);

        const offset = self.total_bytes;

        try self.iovecs.append(allocator, .{
            .iov_base = @ptrCast(@as([*]const u8, @ptrCast(slice.ptr))),
            .iov_len = size * len,
        });
        self.total_bytes += size * len;

        // Return the same slice type as the input
        const info = @typeInfo(SliceType);
        return if (info.pointer.is_const)
            @as([*]const T, @ptrFromInt(offset))[0..len]
        else
            @as([*]T, @ptrFromInt(offset))[0..len];
    }

    fn padToAlignment(self: *@This(), allocator: std.mem.Allocator, alignment: usize) std.mem.Allocator.Error!void {
        const padding_bytes_needed = std.mem.alignForward(usize, self.total_bytes, alignment) - self.total_bytes;

        if (padding_bytes_needed > 0) {
            try self.iovecs.append(allocator, .{
                .iov_base = @ptrCast(@as([*]const u8, &ZEROS)),
                .iov_len = padding_bytes_needed,
            });
            self.total_bytes += padding_bytes_needed;
        }
    }

    /// Write all iovecs to a single contiguous buffer for testing purposes.
    /// Returns the slice of buffer that was written to.
    pub fn writeToBuffer(
        self: *@This(),
        buffer: []u8,
    ) ![]u8 {
        if (buffer.len < self.total_bytes) {
            return error.BufferTooSmall;
        }

        var offset: usize = 0;
        for (self.iovecs.items) |iovec| {
            @memcpy(buffer[offset..][0..iovec.iov_len], iovec.iov_base[0..iovec.iov_len]);
            offset += iovec.iov_len;
        }

        return buffer[0..self.total_bytes];
    }

    /// Deinitialize the CompactWriter, freeing all allocated memory
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.iovecs.deinit(allocator);
    }
};

const Iovec = extern struct {
    iov_base: [*]const u8,
    iov_len: usize,
};
