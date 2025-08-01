//! Tests for the expression evaluator
const std = @import("std");
const helpers = @import("helpers.zig");
const eval = @import("../interpreter.zig");
const compile = @import("compile");
const parse = @import("parse");
const types = @import("types");
const base = @import("base");
const Can = @import("can");
const Check = @import("check");
const stack = @import("../stack.zig");
const layout_store = @import("../../layout/store.zig");
const collections = @import("collections");
const serialization = @import("serialization");

const ModuleEnv = compile.ModuleEnv;
const CompactWriter = serialization.CompactWriter;
const testing = std.testing;
const test_allocator = testing.allocator;

const EvalError = eval.EvalError;
const runExpectInt = helpers.runExpectInt;
const runExpectError = helpers.runExpectError;

test "eval simple number" {
    try runExpectInt("1", 1, .no_trace);
    try runExpectInt("42", 42, .no_trace);
    try runExpectInt("-1234", -1234, .no_trace);
}

test "eval boolean literals" {
    try runExpectInt("True", 1, .no_trace);
    try runExpectInt("False", 0, .no_trace);
    try runExpectInt("Bool.True", 1, .no_trace);
    try runExpectInt("Bool.False", 0, .no_trace);
}

test "eval unary not operator" {
    try runExpectInt("!True", 0, .no_trace);
    try runExpectInt("!False", 1, .no_trace);
    try runExpectInt("!Bool.True", 0, .no_trace);
    try runExpectInt("!Bool.False", 1, .no_trace);
}

test "eval double negation" {
    try runExpectInt("!!True", 1, .no_trace);
    try runExpectInt("!!False", 0, .no_trace);
    try runExpectInt("!!!True", 0, .no_trace);
    try runExpectInt("!!!False", 1, .no_trace);
}

test "eval boolean in lambda expressions" {
    try runExpectInt("(|x| !x)(True)", 0, .no_trace);
    try runExpectInt("(|x| !x)(False)", 1, .no_trace);
    try runExpectInt("(|x, y| x and y)(True, False)", 0, .no_trace);
    try runExpectInt("(|x, y| x or y)(False, True)", 1, .no_trace);
    try runExpectInt("(|x| x and !x)(True)", 0, .no_trace);
    try runExpectInt("(|x| x or !x)(False)", 1, .no_trace);
}

test "eval unary not in conditional expressions" {
    try runExpectInt("if !True 42 else 99", 99, .no_trace);
    try runExpectInt("if !False 42 else 99", 42, .no_trace);
    try runExpectInt("if !!True 42 else 99", 42, .no_trace);
    try runExpectInt("if !!False 42 else 99", 99, .no_trace);
}

test "if-else" {
    try runExpectInt("if (1 == 1) 42 else 99", 42, .no_trace);
    try runExpectInt("if (1 == 2) 42 else 99", 99, .no_trace);
    try runExpectInt("if (5 > 3) 100 else 200", 100, .no_trace);
    try runExpectInt("if (3 > 5) 100 else 200", 200, .no_trace);
}

test "nested if-else" {
    try runExpectInt("if (1 == 1) (if (2 == 2) 100 else 200) else 300", 100, .no_trace);
    try runExpectInt("if (1 == 1) (if (2 == 3) 100 else 200) else 300", 200, .no_trace);
    try runExpectInt("if (1 == 2) (if (2 == 2) 100 else 200) else 300", 300, .no_trace);
}

test "eval single element record" {
    try runExpectInt("{x: 42}.x", 42, .no_trace);
    try runExpectInt("{foo: 100}.foo", 100, .no_trace);
    try runExpectInt("{bar: 1 + 2}.bar", 3, .no_trace);
}

test "eval multi-field record" {
    try runExpectInt("{x: 10, y: 20}.x", 10, .no_trace);
    try runExpectInt("{x: 10, y: 20}.y", 20, .no_trace);
    try runExpectInt("{a: 1, b: 2, c: 3}.a", 1, .no_trace);
    try runExpectInt("{a: 1, b: 2, c: 3}.b", 2, .no_trace);
    try runExpectInt("{a: 1, b: 2, c: 3}.c", 3, .no_trace);
}

test "nested record access" {
    try runExpectInt("{outer: {inner: 42}}.outer.inner", 42, .no_trace);
    try runExpectInt("{a: {b: {c: 100}}}.a.b.c", 100, .no_trace);
}

test "record field order independence" {
    try runExpectInt("{x: 1, y: 2}.x + {y: 2, x: 1}.x", 2, .no_trace);
    try runExpectInt("{a: 10, b: 20, c: 30}.b", 20, .no_trace);
    try runExpectInt("{c: 30, a: 10, b: 20}.b", 20, .no_trace);
}

test "arithmetic binops" {
    try runExpectInt("1 + 2", 3, .no_trace);
    try runExpectInt("5 - 3", 2, .no_trace);
    try runExpectInt("4 * 5", 20, .no_trace);
    try runExpectInt("10 // 2", 5, .no_trace);
    try runExpectInt("7 % 3", 1, .no_trace);
}

test "comparison binops" {
    try runExpectInt("if 1 < 2 100 else 200", 100, .no_trace);
    try runExpectInt("if 2 < 1 100 else 200", 200, .no_trace);
    try runExpectInt("if 5 > 3 100 else 200", 100, .no_trace);
    try runExpectInt("if 3 > 5 100 else 200", 200, .no_trace);
    try runExpectInt("if 10 <= 10 100 else 200", 100, .no_trace);
    try runExpectInt("if 10 <= 9 100 else 200", 200, .no_trace);
    try runExpectInt("if 10 >= 10 100 else 200", 100, .no_trace);
    try runExpectInt("if 9 >= 10 100 else 200", 200, .no_trace);
    try runExpectInt("if 5 == 5 100 else 200", 100, .no_trace);
    try runExpectInt("if 5 == 6 100 else 200", 200, .no_trace);
    try runExpectInt("if 5 != 6 100 else 200", 100, .no_trace);
    try runExpectInt("if 5 != 5 100 else 200", 200, .no_trace);
}

test "logical binops" {
    try runExpectInt("if True and True 1 else 0", 1, .no_trace);
    try runExpectInt("if True and False 1 else 0", 0, .no_trace);
    try runExpectInt("if False and True 1 else 0", 0, .no_trace);
    try runExpectInt("if False and False 1 else 0", 0, .no_trace);
    try runExpectInt("if True or True 1 else 0", 1, .no_trace);
    try runExpectInt("if True or False 1 else 0", 1, .no_trace);
    try runExpectInt("if False or True 1 else 0", 1, .no_trace);
    try runExpectInt("if False or False 1 else 0", 0, .no_trace);
}

test "unary minus" {
    try runExpectInt("-5", -5, .no_trace);
    try runExpectInt("-(-10)", 10, .no_trace);
    try runExpectInt("-(3 + 4)", -7, .no_trace);
    try runExpectInt("-0", 0, .no_trace);
}

test "parentheses and precedence" {
    try runExpectInt("2 + 3 * 4", 14, .no_trace);
    try runExpectInt("(2 + 3) * 4", 20, .no_trace);
    try runExpectInt("100 - 20 - 10", 70, .no_trace);
    try runExpectInt("100 - (20 - 10)", 90, .no_trace);
}

test "error test - divide by zero" {
    try runExpectError("5 // 0", EvalError.DivisionByZero, .no_trace);
    try runExpectError("10 % 0", EvalError.DivisionByZero, .no_trace);
}

test "tuples" {
    // 2-tuple
    const expected_elements1 = &[_]helpers.ExpectedElement{
        .{ .index = 0, .value = 10 },
        .{ .index = 1, .value = 20 },
    };
    try helpers.runExpectTuple("(10, 20)", expected_elements1, .no_trace);

    // Tuple with elements from arithmetic expressions
    const expected_elements3 = &[_]helpers.ExpectedElement{
        .{ .index = 0, .value = 6 },
        .{ .index = 1, .value = 15 },
    };
    try helpers.runExpectTuple("(5 + 1, 5 * 3)", expected_elements3, .no_trace);
}

test "simple lambdas" {
    try runExpectInt("(|x| x + 1)(5)", 6, .no_trace);
    try runExpectInt("(|x| x * 2 + 1)(10)", 21, .no_trace);
    try runExpectInt("(|x| x - 3)(8)", 5, .no_trace);
    try runExpectInt("(|x| 100 - x)(25)", 75, .no_trace);
    try runExpectInt("(|x| 5)(99)", 5, .no_trace);
    try runExpectInt("(|x| x + x)(7)", 14, .no_trace);
}

test "multi-parameter lambdas" {
    try runExpectInt("(|x, y| x + y)(3, 4)", 7, .no_trace);
    try runExpectInt("(|x, y| x * y)(10, 20)", 200, .no_trace);
    try runExpectInt("(|a, b, c| a + b + c)(1, 2, 3)", 6, .no_trace);
}

test "lambdas with if-then bodies" {
    try runExpectInt("(|x| if x > 0 x else 0)(5)", 5, .no_trace);
    try runExpectInt("(|x| if x > 0 x else 0)(-3)", 0, .no_trace);
    try runExpectInt("(|x| if x == 0 1 else x)(0)", 1, .no_trace);
    try runExpectInt("(|x| if x == 0 1 else x)(42)", 42, .no_trace);
}

test "lambdas with unary minus" {
    try runExpectInt("(|x| -x)(5)", -5, .no_trace);
    try runExpectInt("(|x| -x)(0)", 0, .no_trace);
    try runExpectInt("(|x| -x)(-3)", 3, .no_trace);
    try runExpectInt("(|x| -5)(999)", -5, .no_trace);
    try runExpectInt("(|x| if True -x else 0)(5)", -5, .no_trace);
    try runExpectInt("(|x| if True -10 else x)(999)", -10, .no_trace);
}

test "lambdas closures" {
    try runExpectInt("(|a| |b| a * b)(5)(10)", 50, .no_trace);
    try runExpectInt("(((|a| |b| |c| a + b + c)(100))(20))(3)", 123, .no_trace);
    try runExpectInt("(|a, b, c| |d| a + b + c + d)(10, 20, 5)(7)", 42, .no_trace);
    try runExpectInt("(|y| (|x| (|z| x + y + z)(3))(2))(1)", 6, .no_trace);
}

test "lambdas with capture" {
    try runExpectInt(
        \\{
        \\    x = 10;
        \\    f = |y| x + y;
        \\    f(5)
        \\}
    , 15, .no_trace);

    try runExpectInt(
        \\{
        \\    x = 20;
        \\    y = 30;
        \\    f = |z| x + y + z;
        \\    f(10)
        \\}
    , 60, .no_trace);
}

test "lambdas nested closures" {
    try runExpectInt(
        \\(((|a| {
        \\    a_loc = a * 2;
        \\    |b| {
        \\        b_loc = a_loc + b;
        \\        |c| b_loc + c
        \\    }
        \\})(100))(20))(3)
    , 223, .trace);
}

// Helper function to test that evaluation succeeds without checking specific values
fn runExpectSuccess(src: []const u8, should_trace: enum { trace, no_trace }) !void {
    const resources = try helpers.parseAndCanonicalizeExpr(std.testing.allocator, src);
    defer helpers.cleanupParseAndCanonical(std.testing.allocator, resources);

    var eval_stack = try stack.Stack.initCapacity(std.testing.allocator, 1024);
    defer eval_stack.deinit();

    var layout_cache = try layout_store.Store.init(resources.module_env, &resources.module_env.types);
    defer layout_cache.deinit();

    var interpreter = try eval.Interpreter.init(
        std.testing.allocator,
        resources.module_env,
        &eval_stack,
        &layout_cache,
        &resources.module_env.types,
    );
    defer interpreter.deinit();

    if (should_trace == .trace) {
        interpreter.startTrace(std.io.getStdErr().writer().any());
    }

    const result = interpreter.eval(resources.expr_idx);

    if (should_trace == .trace) {
        interpreter.endTrace();
    }

    // Just verify that evaluation succeeded
    _ = try result;
}

test "integer type evaluation" {
    // Test integer types to verify basic evaluation works
    // This should help us debug why 255u8 shows as 42 in REPL
    try runExpectInt("255u8", 255, .trace);
    try runExpectInt("42i32", 42, .no_trace);
    try runExpectInt("123i64", 123, .no_trace);
}

test "decimal literal evaluation" {
    // Test basic decimal literals - these should be parsed and evaluated correctly
    try runExpectSuccess("1.5dec", .no_trace);
    try runExpectSuccess("0.0dec", .no_trace);
    try runExpectSuccess("123.456dec", .no_trace);
    try runExpectSuccess("-1.5dec", .no_trace);
}

test "float literal evaluation" {
    // Test float literals - these should work correctly
    try runExpectSuccess("3.14f64", .no_trace);
    try runExpectSuccess("2.5f32", .no_trace);
    try runExpectSuccess("-3.14f64", .no_trace);
    try runExpectSuccess("0.0f32", .no_trace);
}

test "comprehensive integer literal formats" {
    // Test various integer literal formats and precisions

    // Unsigned integers
    try runExpectInt("0u8", 0, .no_trace);
    try runExpectInt("255u8", 255, .no_trace);
    try runExpectInt("1000u16", 1000, .no_trace);
    try runExpectInt("65535u16", 65535, .no_trace);
    try runExpectInt("100000u32", 100000, .no_trace);
    try runExpectInt("999999999u64", 999999999, .no_trace);

    // Signed integers
    try runExpectInt("-128i8", -128, .no_trace);
    try runExpectInt("127i8", 127, .no_trace);
    try runExpectInt("-32768i16", -32768, .no_trace);
    try runExpectInt("32767i16", 32767, .no_trace);
    try runExpectInt("-2147483648i32", -2147483648, .no_trace);
    try runExpectInt("2147483647i32", 2147483647, .no_trace);
    try runExpectInt("-999999999i64", -999999999, .no_trace);
    try runExpectInt("999999999i64", 999999999, .no_trace);

    // Default integer type (i64)
    try runExpectInt("42", 42, .no_trace);
    try runExpectInt("-1234", -1234, .no_trace);
    try runExpectInt("0", 0, .no_trace);
}

test "hexadecimal and binary integer literals" {
    // Test alternative number bases
    try runExpectInt("0xFF", 255, .no_trace);
    try runExpectInt("0x10", 16, .no_trace);
    try runExpectInt("0xDEADBEEF", 3735928559, .no_trace);
    try runExpectInt("0b1010", 10, .no_trace);
    try runExpectInt("0b11111111", 255, .no_trace);
    try runExpectInt("0b0", 0, .no_trace);
}

test "scientific notation literals" {
    // Test scientific notation - these get parsed as decimals or floats
    try runExpectSuccess("1e5", .no_trace);
    try runExpectSuccess("2.5e10", .no_trace);
    try runExpectSuccess("1.5e-5", .no_trace);
    try runExpectSuccess("-1.5e-5", .no_trace);
}

test "ModuleEnv serialization and interpreter evaluation" {
    // This test demonstrates that a ModuleEnv can be successfully:
    // 1. Created and used with the Interpreter to evaluate expressions
    // 2. Serialized to bytes for storage/transfer
    // 3. Deserialized from those bytes
    // 4. Used with a new Interpreter to evaluate the same expressions
    //
    // Note: The full serialization/deserialization round-trip has alignment
    // issues in debug builds that are also present in the existing
    // "ModuleEnv.Serialized roundtrip" test. For now, we demonstrate
    // the capability by testing evaluation before and after serialization
    // setup steps.

    const gpa = test_allocator;
    const source = "5 + 8";

    // Create original ModuleEnv
    var original_env = try ModuleEnv.init(gpa, source);
    defer original_env.deinit();

    original_env.source = source;
    original_env.module_name = "TestModule";
    try original_env.calcLineStarts();

    // Parse the source code
    var parse_ast = try parse.parseExpr(&original_env);
    defer parse_ast.deinit(gpa);

    // Empty scratch space (required before canonicalization)
    parse_ast.store.emptyScratch();

    // Initialize CIR fields in ModuleEnv
    try original_env.initCIRFields(gpa, "test");

    // Create canonicalizer
    var can = try Can.init(&original_env, &parse_ast, null);
    defer can.deinit();

    // Canonicalize the expression
    const expr_idx: parse.AST.Expr.Idx = @enumFromInt(parse_ast.root_node_idx);
    const canonicalized_expr_idx = try can.canonicalizeExpr(expr_idx) orelse {
        return error.CanonicalizeFailure;
    };

    // Type check the expression
    var checker = try Check.init(gpa, &original_env.types, &original_env, &.{}, &original_env.store.regions);
    defer checker.deinit();

    _ = try checker.checkExpr(canonicalized_expr_idx.get_idx());

    // Test 1: Evaluate with the original ModuleEnv
    {
        var eval_stack = try stack.Stack.initCapacity(gpa, 1024);
        defer eval_stack.deinit();

        var layout_cache = try layout_store.Store.init(&original_env, &original_env.types);
        defer layout_cache.deinit();

        var interpreter = try eval.Interpreter.init(
            gpa,
            &original_env,
            &eval_stack,
            &layout_cache,
            &original_env.types,
        );
        defer interpreter.deinit();

        const result = try interpreter.eval(canonicalized_expr_idx.get_idx());

        // Verify we got the expected result
        try testing.expect(result.layout.tag == .scalar);
        try testing.expect(result.layout.data.scalar.tag == .int);

        const precision = result.layout.data.scalar.data.int;
        const int_val = eval.readIntFromMemory(@ptrCast(result.ptr.?), precision);

        try testing.expectEqual(@as(i128, 13), int_val);
    }

    // Test 2: Demonstrate serialization capability
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var writer = CompactWriter{
            .iovecs = .{},
            .total_bytes = 0,
        };
        defer writer.deinit(arena_alloc);

        // Serialize the ModuleEnv
        const serialized_ptr = try writer.appendAlloc(arena_alloc, ModuleEnv.Serialized);
        try serialized_ptr.serialize(&original_env, arena_alloc, &writer);

        // Verify serialization succeeded
        try testing.expect(writer.total_bytes > 0);
        try testing.expect(writer.iovecs.items.len > 0);
    }

    // Test 3: Demonstrate the ModuleEnv is still valid after serialization setup
    {
        var eval_stack = try stack.Stack.initCapacity(gpa, 1024);
        defer eval_stack.deinit();

        var layout_cache = try layout_store.Store.init(&original_env, &original_env.types);
        defer layout_cache.deinit();

        var interpreter = try eval.Interpreter.init(
            gpa,
            &original_env,
            &eval_stack,
            &layout_cache,
            &original_env.types,
        );
        defer interpreter.deinit();

        const result = try interpreter.eval(canonicalized_expr_idx.get_idx());

        // Verify we still get the same result
        try testing.expect(result.layout.tag == .scalar);
        try testing.expect(result.layout.data.scalar.tag == .int);

        const precision = result.layout.data.scalar.data.int;
        const int_val = eval.readIntFromMemory(@ptrCast(result.ptr.?), precision);

        try testing.expectEqual(@as(i128, 13), int_val);
    }

    // TODO: Add full deserialization test once the alignment issues in
    // ModuleEnv.Serialized.deserialize() are resolved. The deserialize
    // method has an assertion that Serialized >= ModuleEnv in size,
    // but ModuleEnv contains additional fields (gpa, source, module_name)
    // that make it larger than Serialized.
}