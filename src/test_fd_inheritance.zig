const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const main_mod = @import("main.zig");

test "fd inheritance works correctly" {
    const allocator = testing.allocator;

    const test_roc_content = "# Test roc file\n";
    const test_roc_path = "test_fd_inheritance.roc";

    {
        const file = try std.fs.cwd().createFile(test_roc_path, .{});
        defer file.close();
        try file.writeAll(test_roc_content);
    }
    defer std.fs.cwd().deleteFile(test_roc_path) catch {};

    {
        var child = std.process.Child.init(&.{
            "zig", "build", "-Dllvm", "-Dfuzz", "-Dsystem-afl=false",
        }, allocator);
        const term = try child.spawnAndWait();
        try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    }

    var child = std.process.Child.init(&.{
        "./zig-out/bin/roc", "run", "--no-cache", test_roc_path,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    const expected_output = "/path/to/main.roc (from shared memory)\n";
    try testing.expectEqualStrings(expected_output, stdout);

    var stderr_lines = std.mem.tokenizeScalar(u8, stderr, '\n');
    while (stderr_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "error:") != null or
            std.mem.indexOf(u8, line, "Error:") != null or
            std.mem.indexOf(u8, line, "Failed") != null)
        {
            std.debug.print("Unexpected error in stderr:\n{s}\n", .{line});
            try testing.expect(false);
        }
    }
}

test "fd inheritance works on multiple runs" {
    const allocator = testing.allocator;

    const test_roc_content = "# Test roc file\n";
    const test_roc_path = "test_fd_multiple.roc";

    {
        const file = try std.fs.cwd().createFile(test_roc_path, .{});
        defer file.close();
        try file.writeAll(test_roc_content);
    }
    defer std.fs.cwd().deleteFile(test_roc_path) catch {};

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var child = std.process.Child.init(&.{
            "./zig-out/bin/roc", "run", "--no-cache", test_roc_path,
        }, allocator);

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(stdout);
        const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(stderr);

        const term = try child.wait();

        try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

        const expected_output = "/path/to/main.roc (from shared memory)\n";
        try testing.expectEqualStrings(expected_output, stdout);

        var stderr_lines = std.mem.tokenizeScalar(u8, stderr, '\n');
        while (stderr_lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "error:") != null or
                std.mem.indexOf(u8, line, "Error:") != null or
                std.mem.indexOf(u8, line, "Failed") != null)
            {
                std.debug.print("Unexpected error in stderr:\n{s}\n", .{line});
                try testing.expect(false);
            }
        }
    }
}
