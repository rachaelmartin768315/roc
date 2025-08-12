//! Bundle and unbundle a roc package and everything it requires, including host object files if the
//! package is a platform, and any files imported via `import` with `Str` or `List(U8)`.
//!
//! Future work:
//! - Canonicalize to discover all the files we actually need to pull in, including non-.roc files.
//! - Create a zstd dictionary for roc code (using ~1-10MB of representative roc source code, with the zstd cli;
//!   adds about 110KB to our final binary) and use that. It's a backwards-compatible change, as we can keep decoding
//!   dictionary-free .zst files even after we introduce the dictionary.
//! - Changing dictionaries after you've started using one is a breaking change (there's an auto-generated
//!   dictionary ID in the binary, so you know when you're trying to decode with a different dictionary than
//!   the one that the binary was compressed with, and zstd will error), and each time we add new dictionaries
//!   in a nonbreaking way, we have to add +110KB to the `roc` binary, so we should avoid this and instead
//!   only introduce a dictionary when we're confident we'll be happy with that being THE dictionary for a long time.
//! - Compress/Decompress large binary blobs (e.g. for host data, or static List(U8) imports) separately
//!   using different compression params and dictionaries (e.g. make a .tar.zst inside the main .tar.zst)

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
});

// Base58 alphabet (no '0', 'O', 'I', or 'l' to deter visual similarity attacks.)
const base58_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Constants for magic numbers
const SIZE_STORAGE_BYTES: usize = 16; // Extra bytes for storing allocation size; use 16 to preserve alignment.
const TAR_PATH_MAX_LENGTH: usize = 255; // Maximum path length for tar compatibility

// Calculate how many base58 characters are needed to represent a 256-bit hash
// Each base58 character can represent 58 values
// So we need ceil(log58(MAX_HASH + 1)) characters
// Which is ceil(log(MAX_HASH + 1) / log(58))
// Since MAX_HASH is 2^256 - 1, we need ceil(256 * log(2) / log(58))
// log(2) / log(58) ≈ 0.17329
// 256 * 0.17329 ≈ 44.36
// So we need 45 characters
const MAX_BASE58_HASH_BYTES = 45;

/// Encode the given nonempty slice of bytes as a base58 string and write it to the destination.
/// This is guaranteed to write at least 1 byte to the destination, even if the given bytes are all zeros.
pub fn base58Encode(src: []const u8, dest: *[MAX_BASE58_HASH_BYTES]u8) void {
    // The src slice should have been nonempty.
    std.debug.assert(src.len > 0);

    // Preserve leading zeros so we always have the same output string length
    var leading_zeros: usize = 0;
    for (src) |byte| {
        if (byte == 0) {
            dest[leading_zeros] = '1'; // Base58 excludes "0" because it can be mixed up with "O", so '1' represents 0.
            leading_zeros += 1;
        } else {
            break;
        }
    }

    // Fill in the dest buffer, working from the end to the start to avoid needing a second pass.
    var dest_idx: usize = MAX_BASE58_HASH_BYTES;

    for (src[leading_zeros + 1 ..]) |byte| {
        var carry: u32 = byte;

        // Multiply existing base58 digits by 256 and add carry
        var j: usize = MAX_BASE58_HASH_BYTES;
        while (j > dest_idx or carry != 0) {
            j -= 1;
            if (j >= dest_idx) {
                carry += @as(u32, dest[j] - '1') * 256;
            }
            dest[j] = base58_alphabet[carry % 58];
            carry /= 58;
        }
        dest_idx = j;
    }
}

/// Decode base58 string back to binary data.
/// The caller owns the returned memory.
/// Returns InvalidBase58 error if the string contains invalid characters.
pub fn base58Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0) return allocator.dupe(u8, "");

    // Count leading '1's (representing zeros)
    var leading_ones: usize = 0;
    for (encoded) |char| {
        if (char == '1') leading_ones += 1 else break;
    }

    // Allocate result (overestimate)
    var result = try allocator.alloc(u8, encoded.len);
    defer allocator.free(result);
    @memset(result, 0);

    // Decode
    for (encoded) |char| {
        // Find char in alphabet
        var carry: usize = 0;
        for (base58_alphabet, 0..) |alpha_char, i| {
            if (char == alpha_char) {
                carry = i;
                break;
            }
        } else {
            return error.InvalidBase58;
        }

        // Multiply by 58 and add carry
        var j = result.len;
        while (j > 0) {
            j -= 1;
            carry += @as(usize, result[j]) * 58;
            result[j] = @intCast(carry & 0xFF);
            carry >>= 8;
        }
    }

    // Find first non-zero byte
    var first_non_zero: usize = 0;
    for (result) |byte| {
        if (byte != 0) break;
        first_non_zero += 1;
    }

    // Create final result with leading zeros
    const final_size = leading_ones + (result.len - first_non_zero);
    var final_result = try allocator.alloc(u8, final_size);
    @memset(final_result[0..leading_ones], 0);
    @memcpy(final_result[leading_ones..], result[first_non_zero..]);

    return final_result;
}

// zstd's C library does custom allocations using a slightly different format from Zig's allocator API.
fn allocForZstd(opaque_ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
    const allocator = @as(*std.mem.Allocator, @ptrCast(@alignCast(opaque_ptr.?)));
    // Allocate extra bytes to store the size
    const total_size = size + SIZE_STORAGE_BYTES;
    const mem = allocator.alloc(u8, total_size) catch return null;

    // Store the size in the first 8 bytes (usize)
    const size_ptr = @as(*usize, @ptrCast(@alignCast(mem.ptr)));
    size_ptr.* = total_size;

    // Return pointer offset by overhead bytes
    return @ptrFromInt(@intFromPtr(mem.ptr) + SIZE_STORAGE_BYTES);
}

fn freeForZstd(opaque_ptr: ?*anyopaque, address: ?*anyopaque) callconv(.C) void {
    if (address == null) return;
    const allocator = @as(*std.mem.Allocator, @ptrCast(@alignCast(opaque_ptr.?)));

    // Get the original allocation by subtracting overhead bytes
    const original_ptr = @as([*]u8, @ptrFromInt(@intFromPtr(address) - SIZE_STORAGE_BYTES));

    // Read the size from the first 8 bytes
    const size_ptr = @as(*const usize, @ptrCast(@alignCast(original_ptr)));
    const total_size = size_ptr.*;

    // Free the full allocation
    allocator.free(original_ptr[0..total_size]);
}

/// Errors that can occur during the bundle operation.
pub const BundleError = error{
    FilePathTooLong,
    FileOpenFailed,
    FileStatFailed,
    FileReadFailed,
    FileTooLarge,
    TarWriteFailed,
    CompressionFailed,
    WriteFailed,
    FlushFailed,
} || std.mem.Allocator.Error;

/// Errors that can occur during the unbundle operation.
pub const UnbundleError = error{
    DecompressionFailed,
    InvalidTarHeader,
    UnexpectedEndOfStream,
    FileCreateFailed,
    DirectoryCreateFailed,
    FileWriteFailed,
    HashMismatch,
    InvalidFilename,
    FileTooLarge,
} || std.mem.Allocator.Error;

/// Bundle files into a compressed tar archive.
///
/// The file_path_iter must yield file paths that are valid for use with `Dir.openFile`.
/// This means paths must be relative (not absolute), must not contain ".." components,
/// and on Windows must use forward slashes. File paths are limited to 255 bytes for
/// tar compatibility. Paths must be encoded as WTF-8 on Windows, UTF-8 elsewhere.
///
/// If path_prefix is provided, it will be stripped from the beginning of each file path
/// before adding to the tar archive.
///
/// Returns the filename (base58-encoded blake3 hash + .tar.zst). Caller must free the returned string.
pub fn bundle(
    file_path_iter: anytype,
    compression_level: c_int,
    allocator: std.mem.Allocator,
    output_writer: anytype,
    base_dir: std.fs.Dir,
    path_prefix: ?[]const u8,
) BundleError![]u8 {
    // First create the tar in memory
    var tar_buffer = std.ArrayList(u8).init(allocator);
    defer tar_buffer.deinit();

    // Create tar writer
    var tar_writer = std.tar.writer(tar_buffer.writer());

    // Create reusable buffer for file contents
    var file_buffer = std.ArrayList(u8).init(allocator);
    defer file_buffer.deinit();

    // Write files to tar
    while (try file_path_iter.next()) |file_path| {
        const file = base_dir.openFile(file_path, .{}) catch {
            return error.FileOpenFailed;
        };
        defer file.close();

        const stat = file.stat() catch {
            return error.FileStatFailed;
        };

        // Reset buffer and ensure capacity
        file_buffer.clearRetainingCapacity();
        const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        try file_buffer.ensureTotalCapacity(file_size);
        file_buffer.items.len = file_size;

        const bytes_read = file.readAll(file_buffer.items) catch {
            return error.FileReadFailed;
        };
        if (bytes_read != file_size) {
            return error.FileReadFailed;
        }

        // Strip path prefix if provided
        const tar_path = if (path_prefix) |prefix| blk: {
            if (std.mem.startsWith(u8, file_path, prefix)) {
                break :blk file_path[prefix.len..];
            } else {
                break :blk file_path;
            }
        } else file_path;

        if (tar_path.len > TAR_PATH_MAX_LENGTH) {
            return error.FilePathTooLong;
        }

        // Use mtime of 0 for reproducible builds
        const Options = @TypeOf(tar_writer).Options;
        const options = Options{
            .mode = 0o644,
            .mtime = 0,
        };
        tar_writer.writeFileBytes(tar_path, file_buffer.items[0..bytes_read], options) catch {
            return error.TarWriteFailed;
        };
    }

    // Finish the tar archive
    tar_writer.finish() catch {
        return error.TarWriteFailed;
    };

    // Now compress the tar data and compute blake3 hash incrementally
    var buffered_writer = std.io.bufferedWriter(output_writer);
    const buffered = buffered_writer.writer();

    // Initialize blake3 hasher
    var hasher = std.crypto.hash.Blake3.init(.{});

    // Create custom memory allocator for zstd
    const custom_mem = c.ZSTD_customMem{
        .customAlloc = allocForZstd,
        .customFree = freeForZstd,
        .@"opaque" = @ptrCast(@constCast(&allocator)),
    };

    const ctx = c.ZSTD_createCCtx_advanced(custom_mem) orelse return std.mem.Allocator.Error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(ctx);

    _ = c.ZSTD_CCtx_setParameter(ctx, c.ZSTD_c_compressionLevel, compression_level);

    const out_buffer_size = c.ZSTD_CStreamOutSize();
    var out_buffer = try allocator.alloc(u8, out_buffer_size);
    defer allocator.free(out_buffer);

    // Compress the tar data
    var in_buf = c.ZSTD_inBuffer{ .src = tar_buffer.items.ptr, .size = tar_buffer.items.len, .pos = 0 };
    var out_buf = c.ZSTD_outBuffer{ .dst = out_buffer.ptr, .size = out_buffer.len, .pos = 0 };

    // Compress all data
    while (in_buf.pos < in_buf.size) {
        const result = c.ZSTD_compressStream2(ctx, &out_buf, &in_buf, c.ZSTD_e_continue);
        if (c.ZSTD_isError(result) != 0) {
            return error.CompressionFailed;
        }

        if (out_buf.pos > 0) {
            const chunk = out_buffer[0..out_buf.pos];
            buffered.writeAll(chunk) catch {
                return error.WriteFailed;
            };
            // Update hash with compressed data
            hasher.update(chunk);
            out_buf.pos = 0;
        }
    }

    // Finalize compression
    in_buf = c.ZSTD_inBuffer{ .src = "", .size = 0, .pos = 0 };
    while (true) {
        const remaining = c.ZSTD_compressStream2(ctx, &out_buf, &in_buf, c.ZSTD_e_end);
        if (c.ZSTD_isError(remaining) != 0) {
            return error.CompressionFailed;
        }

        if (out_buf.pos > 0) {
            const chunk = out_buffer[0..out_buf.pos];
            buffered.writeAll(chunk) catch {
                return error.WriteFailed;
            };
            // Update hash with compressed data
            hasher.update(chunk);
            out_buf.pos = 0;
        }

        if (remaining == 0) break;
    }

    buffered_writer.flush() catch {
        return error.FlushFailed;
    };

    // Get the blake3 hash and encode as base58
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    const base58_hash = try base58Encode(allocator, &hash);
    defer allocator.free(base58_hash);

    // Create filename with .tar.zst extension
    const filename = try std.fmt.allocPrint(allocator, "{s}.tar.zst", .{base58_hash});
    return filename;
}

/// Validate a base58-encoded hash string and return the decoded hash.
/// Returns null if the hash is invalid.
pub fn validateBase58Hash(allocator: std.mem.Allocator, base58_hash: []const u8) !?[32]u8 {
    const decoded = base58Decode(allocator, base58_hash) catch return null;
    defer allocator.free(decoded);

    if (decoded.len != 32) {
        return null;
    }

    var hash: [32]u8 = undefined;
    @memcpy(&hash, decoded);
    return hash;
}

/// Writer interface for extracting files during unbundle
pub const ExtractWriter = struct {
    ptr: *anyopaque,
    makeDirFn: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,
    writeFileFn: *const fn (ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void,

    pub fn makeDir(self: ExtractWriter, path: []const u8) !void {
        return self.makeDirFn(self.ptr, path);
    }

    pub fn writeFile(self: ExtractWriter, path: []const u8, data: []const u8) !void {
        return self.writeFileFn(self.ptr, path, data);
    }
};

/// Directory-based extract writer
pub const DirExtractWriter = struct {
    dir: std.fs.Dir,

    pub fn init(dir: std.fs.Dir) DirExtractWriter {
        return .{ .dir = dir };
    }

    pub fn extractWriter(self: *DirExtractWriter) ExtractWriter {
        return .{
            .ptr = self,
            .makeDirFn = makeDir,
            .writeFileFn = writeFile,
        };
    }

    fn makeDir(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self = @as(*DirExtractWriter, @ptrCast(@alignCast(ptr)));
        try self.dir.makePath(path);
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self = @as(*DirExtractWriter, @ptrCast(@alignCast(ptr)));

        // Create parent directories if needed
        if (std.fs.path.dirname(path)) |dir_name| {
            try self.dir.makePath(dir_name);
        }

        const file = try self.dir.createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }
};

/// Unbundle files from a compressed tar archive stream.
///
/// This is the core streaming unbundle logic that can be used by both file-based
/// unbundling and network-based downloading.
pub fn unbundleStream(
    input_reader: anytype,
    extract_writer: ExtractWriter,
    allocator: std.mem.Allocator,
    expected_hash: *const [32]u8,
) UnbundleError!void {
    // Buffered reader for input
    var buffered_reader = std.io.bufferedReader(input_reader);
    const buffered = buffered_reader.reader();

    // Initialize blake3 hasher to verify integrity
    var hasher = std.crypto.hash.Blake3.init(.{});

    // Create custom memory allocator for zstd
    const custom_mem = c.ZSTD_customMem{
        .customAlloc = allocForZstd,
        .customFree = freeForZstd,
        .@"opaque" = @ptrCast(@constCast(&allocator)),
    };

    const dctx = c.ZSTD_createDCtx_advanced(custom_mem) orelse return std.mem.Allocator.Error.OutOfMemory;
    defer _ = c.ZSTD_freeDCtx(dctx);

    // Read and decompress data in chunks
    var decompressed_data = std.ArrayList(u8).init(allocator);
    defer decompressed_data.deinit();

    const in_buffer_size = c.ZSTD_DStreamInSize();
    const out_buffer_size = c.ZSTD_DStreamOutSize();
    const in_buffer = try allocator.alloc(u8, in_buffer_size);
    defer allocator.free(in_buffer);
    var out_buffer = try allocator.alloc(u8, out_buffer_size);
    defer allocator.free(out_buffer);

    // Decompress the entire stream
    while (true) {
        const bytes_read = buffered.read(in_buffer) catch {
            return error.UnexpectedEndOfStream;
        };
        if (bytes_read == 0) break;

        // Update hash with compressed data as we read it
        hasher.update(in_buffer[0..bytes_read]);

        var in_buf = c.ZSTD_inBuffer{ .src = in_buffer.ptr, .size = bytes_read, .pos = 0 };

        while (in_buf.pos < in_buf.size) {
            var out_buf = c.ZSTD_outBuffer{ .dst = out_buffer.ptr, .size = out_buffer.len, .pos = 0 };

            const result = c.ZSTD_decompressStream(dctx, &out_buf, &in_buf);
            if (c.ZSTD_isError(result) != 0) {
                return error.DecompressionFailed;
            }

            if (out_buf.pos > 0) {
                try decompressed_data.appendSlice(out_buffer[0..out_buf.pos]);
            }
        }
    }

    // Verify the hash
    var actual_hash: [32]u8 = undefined;
    hasher.final(&actual_hash);
    if (!std.mem.eql(u8, &actual_hash, expected_hash)) {
        return error.HashMismatch;
    }

    // Create a reader from the decompressed data
    var decompressed_stream = std.io.fixedBufferStream(decompressed_data.items);
    const tar_reader = decompressed_stream.reader();

    // Use std.tar to parse the archive; allocate MAX_LENGTH + 1 for null terminator
    var file_name_buffer: [TAR_PATH_MAX_LENGTH + 1]u8 = undefined;
    var link_name_buffer: [TAR_PATH_MAX_LENGTH + 1]u8 = undefined;
    var tar_iter = std.tar.iterator(tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    // Process each file in the archive
    while (true) {
        const file = tar_iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            // Some tar implementations add extra padding at the end
            // If we've successfully extracted at least one file, treat other errors as end of archive
            return error.InvalidTarHeader;
        };

        if (file == null) break;
        const tar_file = file.?;

        switch (tar_file.kind) {
            .file => {
                // Read file content into buffer
                const tar_file_size = std.math.cast(usize, tar_file.size) orelse return error.FileTooLarge;
                const file_content = try allocator.alloc(u8, tar_file_size);
                defer allocator.free(file_content);

                const reader = tar_file.reader();
                const bytes_read = try reader.readAll(file_content);
                if (bytes_read != tar_file_size) {
                    return error.UnexpectedEndOfStream;
                }

                // Write complete file
                extract_writer.writeFile(tar_file.name, file_content) catch {
                    return error.FileWriteFailed;
                };
            },
            .directory => {
                extract_writer.makeDir(tar_file.name) catch {
                    return error.DirectoryCreateFailed;
                };
            },
            else => {
                // Skip other file types (symlinks, etc.)
                // std.tar automatically handles skipping the content for us
            },
        }
    }
}

/// Unbundle files from a compressed tar archive.
///
/// Extracts files to the provided directory, creating subdirectories as needed.
/// The filename parameter should be the base58-encoded blake3 hash + .tar.zst extension.
pub fn unbundle(
    input_reader: anytype,
    extract_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    filename: []const u8,
) UnbundleError!void {
    // Extract expected hash from filename
    if (!std.mem.endsWith(u8, filename, ".tar.zst")) {
        return error.InvalidFilename;
    }
    const base58_hash = filename[0 .. filename.len - 8]; // Remove .tar.zst
    const expected_hash = (try validateBase58Hash(allocator, base58_hash)) orelse {
        return error.InvalidFilename;
    };

    var dir_writer = DirExtractWriter.init(extract_dir);
    return unbundleStream(input_reader, dir_writer.extractWriter(), allocator, &expected_hash);
}
