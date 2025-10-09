//! Tests for compiled builtin modules (Set and Dict).
//!
//! These tests verify that the build-time compiled Set and Dict modules
//! can be loaded from their serialized .bin files and used in type checking.

const std = @import("std");
const base = @import("base");
const types_mod = @import("types");
const can = @import("can");
const collections = @import("collections");
const Check = @import("../Check.zig");
const TestEnv = @import("./TestEnv.zig");

const ModuleEnv = can.ModuleEnv;
const testing = std.testing;
const compiled_builtins = @import("compiled_builtins");

/// Wrapper for a loaded compiled module that tracks the buffer
const LoadedModule = struct {
    env: *ModuleEnv,
    buffer: []align(collections.CompactWriter.SERIALIZATION_ALIGNMENT) u8,
    gpa: std.mem.Allocator,

    fn deinit(self: *LoadedModule) void {
        // Only free the hashmap that was allocated during deserialization
        // Most other data (like the SafeList contents) points into the buffer
        self.env.imports.map.deinit(self.gpa);

        // Free the buffer (the env points into this buffer for most data)
        self.gpa.free(self.buffer);
        // Free the env struct itself
        self.gpa.destroy(self.env);
    }
};

/// Load a compiled ModuleEnv from embedded binary data
fn loadCompiledModule(gpa: std.mem.Allocator, bin_data: []const u8, module_name: []const u8, source: []const u8) !LoadedModule {
    // Copy the embedded data to properly aligned memory
    // CompactWriter requires specific alignment for serialization
    const CompactWriter = collections.CompactWriter;
    const buffer = try gpa.alignedAlloc(u8, CompactWriter.SERIALIZATION_ALIGNMENT, bin_data.len);
    @memcpy(buffer, bin_data);

    // Cast to the serialized structure
    const serialized_ptr = @as(
        *ModuleEnv.Serialized,
        @ptrCast(@alignCast(buffer.ptr)),
    );

    const env = try gpa.create(ModuleEnv);
    errdefer gpa.destroy(env);

    // Deserialize
    const base_ptr = @intFromPtr(buffer.ptr);
    env.* = ModuleEnv{
        .gpa = gpa,
        .common = serialized_ptr.common.deserialize(@as(i64, @intCast(base_ptr)), source).*,
        .types = serialized_ptr.types.deserialize(@as(i64, @intCast(base_ptr))).*,
        .module_kind = serialized_ptr.module_kind,
        .all_defs = serialized_ptr.all_defs,
        .all_statements = serialized_ptr.all_statements,
        .exports = serialized_ptr.exports,
        .builtin_statements = serialized_ptr.builtin_statements,
        .external_decls = serialized_ptr.external_decls.deserialize(@as(i64, @intCast(base_ptr))).*,
        .imports = serialized_ptr.imports.deserialize(@as(i64, @intCast(base_ptr)), gpa).*,
        .module_name = module_name,
        .diagnostics = serialized_ptr.diagnostics,
        .store = serialized_ptr.store.deserialize(@as(i64, @intCast(base_ptr)), gpa).*,
    };

    return LoadedModule{
        .env = env,
        .buffer = buffer,
        .gpa = gpa,
    };
}

test "compiled builtins - load Dict" {
    const gpa = testing.allocator;

    const dict_source = "Dict := [EmptyDict].{}\n";
    var dict_loaded = try loadCompiledModule(gpa, compiled_builtins.dict_bin, "Dict", dict_source);
    defer dict_loaded.deinit();

    // Verify the module loaded
    try testing.expectEqualStrings("Dict", dict_loaded.env.module_name);
}

test "compiled builtins - load Set" {
    const gpa = testing.allocator;

    const set_source = "import Dict\n\nSet := [EmptySet(Dict)].{}\n";
    var set_loaded = try loadCompiledModule(gpa, compiled_builtins.set_bin, "Set", set_source);
    defer set_loaded.deinit();

    // Verify the module loaded
    try testing.expectEqualStrings("Set", set_loaded.env.module_name);
}

test "compiled builtins - use Set and Dict together" {
    const gpa = testing.allocator;

    // Load Dict first
    const dict_source = "Dict := [EmptyDict].{}\n";
    var dict_loaded = try loadCompiledModule(gpa, compiled_builtins.dict_bin, "Dict", dict_source);
    defer dict_loaded.deinit();

    // Load Set (which imports Dict)
    const set_source = "import Dict\n\nSet := [EmptySet(Dict)].{}\n";
    var set_loaded = try loadCompiledModule(gpa, compiled_builtins.set_bin, "Set", set_source);
    defer set_loaded.deinit();

    // Now create a test that uses both Set and Dict
    const test_source =
        \\module []
        \\
        \\import Set
        \\import Dict
        \\
        \\x : Set
        \\x = Set.EmptySet(Dict.EmptyDict)
        \\
        \\main = match x {
        \\  Set.EmptySet(Dict.EmptyDict) => "empty"
        \\}
    ;

    // Create module environment with Set and Dict imported
    var module_env: *ModuleEnv = try gpa.create(ModuleEnv);
    errdefer gpa.destroy(module_env);

    module_env.* = try ModuleEnv.init(gpa, test_source);
    errdefer module_env.deinit();

    module_env.common.source = test_source;
    module_env.module_name = "Test";
    try module_env.common.calcLineStarts(gpa);

    const module_common_idents: Check.CommonIdents = .{
        .module_name = try module_env.insertIdent(base.Ident.for_text("Test")),
        .list = try module_env.insertIdent(base.Ident.for_text("List")),
        .box = try module_env.insertIdent(base.Ident.for_text("Box")),
    };

    // Parse
    const parse = @import("parse");
    var parse_ast = try gpa.create(parse.AST);
    defer {
        parse_ast.deinit(gpa);
        gpa.destroy(parse_ast);
    }

    parse_ast.* = try parse.parse(&module_env.common, gpa);
    parse_ast.store.emptyScratch();

    if (parse_ast.hasErrors()) {
        std.debug.print("Parse errors:\n", .{});
        for (parse_ast.tokenize_diagnostics.items) |diag| {
            std.debug.print("  Tokenize: {any}\n", .{diag});
        }
        for (parse_ast.parse_diagnostics.items) |diag| {
            std.debug.print("  Parse: {any}\n", .{diag});
        }
        return error.ParseError;
    }

    // Set up module imports
    var module_envs = std.StringHashMap(*const ModuleEnv).init(gpa);
    defer module_envs.deinit();
    try module_envs.put("Set", set_loaded.env);
    try module_envs.put("Dict", dict_loaded.env);

    // Canonicalize
    try module_env.initCIRFields(gpa, "test");
    var can_result = try gpa.create(can.Can);
    defer {
        can_result.deinit();
        gpa.destroy(can_result);
    }

    can_result.* = try can.Can.init(module_env, parse_ast, &module_envs);
    try can_result.canonicalizeFile();
    try can_result.validateForChecking();

    // Type check
    var other_envs = std.ArrayList(*const ModuleEnv).init(gpa);
    defer other_envs.deinit();
    try other_envs.append(set_loaded.env);
    try other_envs.append(dict_loaded.env);

    var checker = try Check.init(
        gpa,
        &module_env.types,
        module_env,
        other_envs.items,
        &module_env.store.regions,
        module_common_idents,
    );
    defer checker.deinit();

    try checker.checkFile();

    // Verify no type errors
    try testing.expectEqual(0, checker.problems.problems.items.len);

    // Clean up module_env
    module_env.deinit();
    gpa.destroy(module_env);
}
