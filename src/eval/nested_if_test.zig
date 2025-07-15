const std = @import("std");
const testing = std.testing;
const eval = @import("eval.zig");
const CIR = @import("../check/canonicalize/CIR.zig");
const stack = @import("stack.zig");
const layout_store = @import("../layout/store.zig");
const types = @import("../types.zig");
const base = @import("../base.zig");
const parse = @import("../check/parse.zig");
const canonicalize = @import("../check/canonicalize.zig");
const check_types = @import("../check/check_types.zig");

test "eval nested if expression - iterative" {
    const allocator = testing.allocator;
    const source = "if 5 > 3 (if 1 > 2 3 else 4) else 5";

    std.debug.print("\n=== Testing nested if expression ===\n", .{});
    std.debug.print("Source: {s}\n", .{source});

    // Initialize ModuleEnv
    const owned_source = try allocator.dupe(u8, source);
    var module_env = try base.ModuleEnv.init(allocator, owned_source);
    defer module_env.deinit();

    // Parse
    var parse_ast = try parse.parseExpr(&module_env, source);
    defer parse_ast.deinit(allocator);

    // Canonicalize
    var cir = try CIR.init(&module_env, "test");
    defer cir.deinit();

    var can = try canonicalize.init(&cir, &parse_ast, null);
    defer can.deinit();

    const expr_idx: parse.AST.Expr.Idx = @enumFromInt(parse_ast.root_node_idx);
    const canonical_expr_idx = try can.canonicalizeExpr(expr_idx) orelse return error.CanonicalizeError;

    // Type check the expression
    var checker = try check_types.init(allocator, &module_env.types, &cir, &.{}, &cir.store.regions);
    defer checker.deinit();
    _ = try checker.checkExpr(canonical_expr_idx);

    // Check if canonicalization succeeded
    const expr = cir.store.getExpr(canonical_expr_idx);
    if (expr == .e_runtime_error) {
        return error.CanonicalizeError;
    }

    // Create stack for evaluation
    var eval_stack = try stack.Stack.initCapacity(allocator, 1024);
    defer eval_stack.deinit();

    // Create layout cache
    var layout_cache = try layout_store.Store.init(&module_env, &module_env.types);
    defer layout_cache.deinit();

    // Evaluate the expression
    std.debug.print("About to evaluate expression idx: {}\n", .{@intFromEnum(canonical_expr_idx)});
    const result = try eval.eval(allocator, &cir, canonical_expr_idx, &eval_stack, &layout_cache, &module_env.types);
    std.debug.print("Evaluation completed successfully\n", .{});

    // The result should be 4
    // Outer if: 5 > 3 is true, so evaluate then branch
    // Inner if: 1 > 2 is false, so evaluate else branch which is 4
    try testing.expectEqual(result.layout.tag, .scalar);
    try testing.expectEqual(result.layout.data.scalar.tag, .int);

    // Read the integer value
    const int_val = switch (result.layout.data.scalar.data.int) {
        .i64 => @as(*i64, @ptrCast(@alignCast(result.ptr))).*,
        .i32 => @as(*i32, @ptrCast(@alignCast(result.ptr))).*,
        .i16 => @as(*i16, @ptrCast(@alignCast(result.ptr))).*,
        .i8 => @as(*i8, @ptrCast(@alignCast(result.ptr))).*,
        .u64 => @as(i64, @intCast(@as(*u64, @ptrCast(@alignCast(result.ptr))).*)),
        .u32 => @as(i64, @intCast(@as(*u32, @ptrCast(@alignCast(result.ptr))).*)),
        .u16 => @as(i64, @intCast(@as(*u16, @ptrCast(@alignCast(result.ptr))).*)),
        .u8 => @as(i64, @intCast(@as(*u8, @ptrCast(@alignCast(result.ptr))).*)),
        .u128 => @as(i64, @intCast(@as(*u128, @ptrCast(@alignCast(result.ptr))).*)),
        .i128 => @as(i64, @intCast(@as(*i128, @ptrCast(@alignCast(result.ptr))).*)),
    };

    try testing.expectEqual(@as(i64, 4), int_val);
}

test "eval comparison operations" {
    const allocator = testing.allocator;
    std.debug.print("\n=== Testing comparison operations ===\n", .{});

    const test_cases = [_]struct {
        source: []const u8,
        expected: bool,
    }{
        .{ .source = "5 > 3", .expected = true },
        .{ .source = "1 > 2", .expected = false },
        .{ .source = "3 == 3", .expected = true },
        .{ .source = "3 != 3", .expected = false },
        .{ .source = "10 >= 10", .expected = true },
        .{ .source = "5 <= 10", .expected = true },
    };

    for (test_cases) |test_case| {
        std.debug.print("\nTesting: {s}\n", .{test_case.source});

        // Initialize ModuleEnv
        const owned_source = try allocator.dupe(u8, test_case.source);
        var module_env = try base.ModuleEnv.init(allocator, owned_source);
        defer module_env.deinit();

        // Parse
        var parse_ast = try parse.parseExpr(&module_env, test_case.source);
        defer parse_ast.deinit(allocator);

        // Canonicalize
        var cir = try CIR.init(&module_env, "test");
        defer cir.deinit();

        var can = try canonicalize.init(&cir, &parse_ast, null);
        defer can.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(parse_ast.root_node_idx);
        const canonical_expr_idx = try can.canonicalizeExpr(expr_idx) orelse continue;

        // Type check the expression
        var checker = try check_types.init(allocator, &module_env.types, &cir, &.{}, &cir.store.regions);
        defer checker.deinit();
        _ = try checker.checkExpr(canonical_expr_idx);

        // Check if canonicalization succeeded
        const expr = cir.store.getExpr(canonical_expr_idx);
        if (expr == .e_runtime_error) {
            continue; // Skip if canonicalization failed
        }

        // Create stack for evaluation
        var eval_stack = try stack.Stack.initCapacity(allocator, 1024);
        defer eval_stack.deinit();

        // Create layout cache
        var layout_cache = try layout_store.Store.init(&module_env, &module_env.types);
        defer layout_cache.deinit();

        // Evaluate the expression
        const result = try eval.eval(allocator, &cir, canonical_expr_idx, &eval_stack, &layout_cache, &module_env.types);

        // Result should be a boolean
        try testing.expectEqual(result.layout.tag, .scalar);
        try testing.expectEqual(result.layout.data.scalar.tag, .bool);

        // Read the boolean value
        const bool_val = @as(*bool, @ptrCast(@alignCast(result.ptr))).*;
        try testing.expectEqual(test_case.expected, bool_val);
    }
}

test "eval simple arithmetic operations" {
    const allocator = testing.allocator;

    const test_cases = [_]struct {
        source: []const u8,
        expected: i64,
    }{
        .{ .source = "5 + 3", .expected = 8 },
        .{ .source = "10 - 4", .expected = 6 },
        .{ .source = "3 * 4", .expected = 12 },
        .{ .source = "15 / 3", .expected = 5 },
    };

    for (test_cases) |test_case| {
        // Initialize ModuleEnv
        const owned_source = try allocator.dupe(u8, test_case.source);
        var module_env = try base.ModuleEnv.init(allocator, owned_source);
        defer module_env.deinit();

        // Parse
        var parse_ast = try parse.parseExpr(&module_env, test_case.source);
        defer parse_ast.deinit(allocator);

        // Canonicalize
        var cir = try CIR.init(&module_env, "test");
        defer cir.deinit();

        var can = try canonicalize.init(&cir, &parse_ast, null);
        defer can.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(parse_ast.root_node_idx);
        const canonical_expr_idx = try can.canonicalizeExpr(expr_idx) orelse continue;

        // Type check the expression
        var checker = try check_types.init(allocator, &module_env.types, &cir, &.{}, &cir.store.regions);
        defer checker.deinit();
        _ = try checker.checkExpr(canonical_expr_idx);

        // Check if canonicalization succeeded
        const expr = cir.store.getExpr(canonical_expr_idx);
        if (expr == .e_runtime_error) {
            continue; // Skip if canonicalization failed
        }

        // Create stack for evaluation
        var eval_stack = try stack.Stack.initCapacity(allocator, 1024);
        defer eval_stack.deinit();

        // Create layout cache
        var layout_cache = try layout_store.Store.init(&module_env, &module_env.types);
        defer layout_cache.deinit();

        // Evaluate the expression
        const result = try eval.eval(allocator, &cir, canonical_expr_idx, &eval_stack, &layout_cache, &module_env.types);

        // Result should be an integer
        try testing.expectEqual(result.layout.tag, .scalar);
        try testing.expectEqual(result.layout.data.scalar.tag, .int);

        // Read the integer value
        const int_val = switch (result.layout.data.scalar.data.int) {
            .i64 => @as(*i64, @ptrCast(@alignCast(result.ptr))).*,
            .i32 => @as(*i32, @ptrCast(@alignCast(result.ptr))).*,
            .i16 => @as(*i16, @ptrCast(@alignCast(result.ptr))).*,
            .i8 => @as(*i8, @ptrCast(@alignCast(result.ptr))).*,
            .u64 => @as(i64, @intCast(@as(*u64, @ptrCast(@alignCast(result.ptr))).*)),
            .u32 => @as(i64, @intCast(@as(*u32, @ptrCast(@alignCast(result.ptr))).*)),
            .u16 => @as(i64, @intCast(@as(*u16, @ptrCast(@alignCast(result.ptr))).*)),
            .u8 => @as(i64, @intCast(@as(*u8, @ptrCast(@alignCast(result.ptr))).*)),
            .u128 => @as(i64, @intCast(@as(*u128, @ptrCast(@alignCast(result.ptr))).*)),
            .i128 => @as(i64, @intCast(@as(*i128, @ptrCast(@alignCast(result.ptr))).*)),
        };

        try testing.expectEqual(test_case.expected, int_val);
    }
}
