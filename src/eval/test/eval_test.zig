//! Tests for the expression evaluator
const helpers = @import("helpers.zig");
const eval = @import("../interpreter.zig");

const EvalError = eval.EvalError;
const runExpectInt = helpers.runExpectInt;
const runExpectError = helpers.runExpectError;

test "eval simple number" {
    try runExpectInt("1", 1, .no_trace);
    try runExpectInt("42", 42, .no_trace);
    try runExpectInt("-1234", -1234, .no_trace);
}

test "if-else" {
    try runExpectInt("if (1 == 1) 42 else 99", 42, .no_trace);
    try runExpectInt("if (1 == 2) 42 else 99", 99, .no_trace);
    try runExpectInt("if (5 > 3) 100 else 200", 100, .no_trace);
    try runExpectInt("if (3 > 5) 100 else 200", 200, .no_trace);
}

test "nested if-else" {
    try runExpectInt("if True (if True 10 else 20) else 30", 10, .no_trace);
    try runExpectInt("if True (if False 10 else 20) else 30", 20, .no_trace);
    try runExpectInt("if False (if True 10 else 20) else 30", 30, .no_trace);
    try runExpectInt("if False 99 else (if True 40 else 50)", 40, .no_trace);
    try runExpectInt("if False 99 else (if False 40 else 50)", 50, .no_trace);
}

test "chained if-else" {
    try runExpectInt("if True 10 else if True 20 else 30", 10, .no_trace);
    try runExpectInt("if False 10 else if True 20 else 30", 20, .no_trace);
    try runExpectInt("if False 10 else if False 20 else 30", 30, .no_trace);
}

test "if-else arithmetic" {
    try runExpectInt("if True (1 + 2) else (3 + 4)", 3, .no_trace);
    try runExpectInt("if False (1 + 2) else (3 + 4)", 7, .no_trace);
    try runExpectInt("if True (10 * 5) else (20 / 4)", 50, .no_trace);
    try runExpectInt("if (2 > 1) (100 - 50) else (200 - 100)", 50, .no_trace);
}

test "eval if expression with non-boolean condition" {
    // TypeContainedMismatch error because condition must be a boolean tag union
    try runExpectError("if 42 1 else 0", EvalError.TypeContainedMismatch, .no_trace);
}

test "list literal" {
    // List literals are not yet implemented
    try runExpectError("[1, 2, 3]", EvalError.LayoutError, .no_trace);
}
test "record literal" {
    // Empty record literal is a zero-sized type
    try runExpectError("{}", EvalError.ZeroSizedType, .no_trace);

    // Record with integer fields
    const expected_fields = &[_]helpers.ExpectedField{
        .{ .name = "x", .value = 10 },
        .{ .name = "y", .value = 20 },
    };
    try helpers.runExpectRecord("{ x: 10, y: 20 }", expected_fields, .no_trace);
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

// TODO -- implement captures properly
test "lambdas closures" {
    // try runExpectInt("(|a| |b| a * b)(5)(10)", 50, .trace);
    // try runExpectInt("(((|a| |b| |c| a + b + c)(100))(20))(3)", 123, .no_trace);
    // try runExpectInt("(|a, b, c| |d| a + b + c + d)(10, 20, 5)(7)", 42, .no_trace);
    return error.SkipZigTest;
}
