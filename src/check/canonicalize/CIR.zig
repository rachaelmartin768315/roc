//! The canonical intermediate representation (CIR) is a representation of the
//! canonicalized abstract syntax tree (AST) that is used for interpreting code generation and type checking, and later compilation stages.

const std = @import("std");
const testing = std.testing;
const base = @import("../../base.zig");
const types = @import("../../types.zig");
const problem = @import("../../problem.zig");
const collections = @import("../../collections.zig");
const Alias = @import("./Alias.zig");
const sexpr = @import("../../base/sexpr.zig");
const exitOnOom = collections.utils.exitOnOom;
const Scratch = base.Scratch;
const DataSpan = base.DataSpan;
const Ident = base.Ident;
const Region = base.Region;
const ModuleImport = base.ModuleImport;
const ModuleEnv = base.ModuleEnv;
const StringLiteral = base.StringLiteral;
const TypeVar = types.Var;
const Problem = problem.Problem;
const Node = @import("Node.zig");
const NodeStore = @import("NodeStore.zig");

const CIR = @This();

env: base.ModuleEnv,
store: NodeStore,
ingested_files: IngestedFile.List,
imports: ModuleImport.Store,
top_level_defs: Def.Span,
diagnostics: std.ArrayListUnmanaged(CIR.Diagnostic),

/// Initialize the IR for a module's canonicalization info.
///
/// When caching the can IR for a siloed module, we can avoid
/// manual deserialization of the cached data into IR by putting
/// the entirety of the IR into an arena that holds nothing besides
/// the IR. We can then load the cached binary data back into memory
/// with only 2 syscalls.
///
/// Since the can IR holds indices into the `ModuleEnv`, we need
/// the `ModuleEnv` to also be owned by the can IR to cache it.
///
/// Takes ownership of the module_env
pub fn init(env: ModuleEnv) CIR {
    // TODO: Figure out what capacity should be
    return CIR.initCapacity(env, 1000);
}

/// Initialize the IR for a module's canonicalization info with a specified capacity.
/// For more information refer to documentation on [init] as well
pub fn initCapacity(env: ModuleEnv, capacity: usize) CIR {
    var ident_store = env.idents;

    return CIR{
        .env = env,
        .store = NodeStore.initCapacity(env.gpa, capacity),
        .ingested_files = .{},
        .imports = ModuleImport.Store.init(&.{}, &ident_store, env.gpa),
        .top_level_defs = .{ .span = .{ .start = 0, .len = 0 } },
        .diagnostics = .{},
    };
}

/// Deinit the IR's memory.
pub fn deinit(self: *CIR) void {
    self.store.deinit();
    self.ingested_files.deinit(self.env.gpa);
    self.imports.deinit(self.env.gpa);
    self.diagnostics.deinit(self.env.gpa);
}

/// Diagnostics related to canonicalization
pub const Diagnostic = struct {
    tag: Tag,
    region: Region,

    /// different types of diagnostic errors
    pub const Tag = enum {
        not_implemented,
        invalid_num_literal,
        ident_already_in_scope,
        ident_not_in_scope,
        invalid_top_level_statement,
        expr_not_canonicalized,
        invalid_string_interpolation,
    };
};

/// Push a diagnostic error during canonicalization
///
/// Do not use for compiler errors, but invalid input where you cannot insert a malformed node
pub fn pushDiagnostic(self: *CIR, tag: CIR.Diagnostic.Tag, region: base.Region) void {
    self.diagnostics.append(self.env.gpa, .{
        .tag = tag,
        .region = region,
    }) catch |err| exitOnOom(err);
}

/// Returns a malformed token of the requested type, and pushes a diagnostic error
pub fn pushMalformed(self: *CIR, comptime t: type, tag: CIR.Diagnostic.Tag, region: base.Region) t {
    self.diagnostics.append(self.env.gpa, .{
        .tag = tag,
        .region = region,
    }) catch |err| exitOnOom(err);
    return self.store.addMalformed(t, tag, region);
}

// Helper to add type index info
fn appendTypeVarChild(node: *sexpr.Expr, gpa: std.mem.Allocator, name: []const u8, type_idx: TypeVar) void {
    var type_node = sexpr.Expr.init(gpa, name);
    type_node.appendUnsignedIntChild(gpa, @intCast(@intFromEnum(type_idx)));
    node.appendNodeChild(gpa, &type_node);
}

// Helper to add identifier info
fn appendIdentChild(node: *sexpr.Expr, gpa: std.mem.Allocator, ir: *const CIR, name: []const u8, ident_idx: Ident.Idx) void {
    const ident_text = ir.env.idents.getText(ident_idx);

    // Create a node with no pre-allocated children to avoid aliasing issues
    const ident_node = sexpr.Expr{
        .node = .{
            .value = gpa.dupe(u8, name) catch @panic("Failed to duplicate name"),
            .children = .{}, // Empty ArrayListUnmanaged - no allocation
        },
    };

    // Append the node to the parent first
    switch (node.*) {
        .node => |*n| {
            n.children.append(gpa, ident_node) catch @panic("Failed to append node");

            // Now add the string child directly to the node in its final location
            const last_idx = n.children.items.len - 1;
            n.children.items[last_idx].appendStringChild(gpa, ident_text);
        },
        else => @panic("appendIdentChild called on non-node"),
    }
}

test "Node is 24 bytes" {
    try testing.expectEqual(24, @sizeOf(Node));
}

/// A single statement - either at the top-level or within a block.
pub const Statement = union(enum) {
    decl: Decl,
    @"var": Var,
    crash: Crash,
    expr: ExprStmt,
    expect: Expect,
    @"for": For,
    @"return": Return,
    import: Import,
    type_decl: TypeDecl,
    type_anno: Statement.TypeAnno,

    /// A simple immutable declaration
    pub const Decl = struct {
        pattern: Pattern.Idx,
        expr: Expr.Idx,
    };
    /// A rebindable declaration using the "var" keyword
    /// Not valid at the top level of a module
    pub const Var = struct {
        ident: Ident.Idx,
        expr: Expr.Idx,
    };
    /// The "crash" keyword
    /// Not valid at the top level of a module
    pub const Crash = struct {
        msg: Expr.Idx,
    };
    /// Just an expression - usually the return value for a block
    /// Not valid at the top level of a module
    pub const ExprStmt = struct {
        expr: Expr.Idx,
        region: Region,
    };
    /// An expression that will cause a panic (or some other error handling mechanism) if it evaluates to false
    pub const Expect = struct {
        body: Expr.Idx,
        region: Region,
    };
    /// A block of code that will be ran multiple times for each item in a list.
    /// Not valid at the top level of a module
    pub const For = struct {
        patt: Pattern.Idx,
        expr: Expr.Idx,
        body: Expr.Idx,
        region: Region,
    };
    /// A early return of the enclosing function.
    /// Not valid at the top level of a module
    pub const Return = struct {
        expr: Expr.Idx,
        region: Region,
    };
    /// Brings in another module for use in the current module, optionally exposing only certain members of that module.
    /// Only valid at the top level of a module
    pub const Import = struct {
        module_name_tok: Ident.Idx,
        qualifier_tok: ?Ident.Idx,
        alias_tok: ?Ident.Idx,
        exposes: ExposedItem.Span,
        region: Region,
    };
    /// A declaration of a new type - whether an alias or a new nominal custom type
    /// Only valid at the top level of a module
    pub const TypeDecl = struct {
        header: TypeHeader.Idx,
        anno: CIR.TypeAnno.Idx,
        where: ?WhereClause.Span,
        region: Region,
    };
    /// A type annotation, declaring that the value referred to by an ident in the same scope should be a given type.
    pub const TypeAnno = struct {
        name: Ident.Idx,
        anno: CIR.TypeAnno.Idx,
        where: ?WhereClause.Span,
        region: Region,
    };

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// A working representation of a record field
pub const RecordField = struct {
    name: Ident.Idx,
    value: Expr.Idx,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement WhereClause
pub const WhereClause = union(enum) {
    alias: WhereClause.Alias,
    method: Method,
    mod_method: ModuleMethod,

    pub const Alias = struct {
        var_tok: Ident.Idx,
        alias_tok: Ident.Idx,
        region: Region,
    };
    pub const Method = struct {
        var_tok: Ident.Idx,
        name_tok: Ident.Idx,
        args: TypeAnno.Span,
        ret_anno: TypeAnno.Idx,
        region: Region,
    };
    pub const ModuleMethod = struct {
        var_tok: Ident.Idx,
        name_tok: Ident.Idx,
        args: TypeAnno.Span,
        ret_anno: TypeAnno.Span,
        region: Region,
    };

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement PatternRecordField
pub const PatternRecordField = struct {
    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement TypeAnno
pub const TypeAnno = union(enum) {
    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement TypeHeader
pub const TypeHeader = struct {
    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement AnnoRecordField
pub const AnnoRecordField = struct {
    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// TODO: implement ExposedItem
pub const ExposedItem = struct {
    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// Type variables that have been explicitly named, e.g. `a` in `items : List a`.
pub const RigidVariables = struct {
    named: std.AutoHashMap(TypeVar, Ident.Idx),
    // with_methods: std.AutoHashMap(TypeVar, WithMethods),

    // pub const WithMethods = struct {
    //     name: Ident.Idx,
    //     methods: MethodSet,
    // };
};

/// An expression that has been canonicalized.
pub const Expr = union(enum) {
    num: struct {
        num_var: TypeVar,
        literal: StringLiteral.Idx,
        value: IntValue,
        bound: types.Num.Compact,
    },
    int: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        literal: StringLiteral.Idx,
        value: IntValue,
        bound: types.Num.Compact.Int.Precision,
    },
    float: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        literal: StringLiteral.Idx,
        value: f64,
        bound: types.Num.Compact.Frac.Precision,
    },
    // A single segment of a string literal
    // a single string may be made up of a span sequential segments
    // for example if it was split across multiple lines
    str_segment: StringLiteral.Idx,
    // A string is combined of one or more segments, some of which may be interpolated
    // An interpolated string contains one or more non-string_segment's in the span
    str: Expr.Span,
    single_quote: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        value: u32,
        bound: types.Num.Compact.Int.Precision,
    },
    lookup: Lookup,
    list: struct {
        elem_var: TypeVar,
        elems: Expr.Span,
    },
    when: When.Idx,
    @"if": struct {
        cond_var: TypeVar,
        branch_var: TypeVar,
        branches: IfBranch.Span,
        final_else: Expr.Idx,
    },
    /// This is *only* for calling functions, not for tag application.
    /// The Tag variant contains any applied values inside it.
    call: struct {
        args: Expr.Span,
        // called_via: base.CalledVia,
    },
    record: struct {
        record_var: TypeVar,
        // TODO:
        // fields: SendMap<Lowercase, Field>,
    },
    /// Empty record constant
    empty_record,
    /// Look up exactly one field on a record, e.g. (expr).foo.
    record_access: struct {
        record_var: TypeVar,
        ext_var: TypeVar,
        field_var: TypeVar,
        loc_expr: Expr.Idx,
        field: Ident.Idx,
    },
    tag: struct {
        tag_union_var: TypeVar,
        ext_var: TypeVar,
        name: Ident.Idx,
        args: Expr.Span,
    },
    zero_argument_tag: struct {
        closure_name: Ident.Idx,
        variant_var: TypeVar,
        ext_var: TypeVar,
        name: Ident.Idx,
    },
    binop: Binop,
    /// Compiles, but will crash if reached
    runtime_error: struct {
        tag: Diagnostic.Tag,
        region: base.Region,
    },

    pub const Lookup = struct {
        pattern_idx: Pattern.Idx,
    };

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };

    pub const Binop = struct {
        op: Op,
        lhs: Expr.Idx,
        rhs: Expr.Idx,

        pub const Op = enum {
            add,
            sub,
            mul,
            div,
            rem,
            lt,
            gt,
            le,
            ge,
            eq,
            ne,
        };

        pub fn init(op: Op, lhs: Expr.Idx, rhs: Expr.Idx) Binop {
            return .{ .lhs = lhs, .op = op, .rhs = rhs };
        }
    };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;
        switch (self.*) {
            .num => |num_expr| {
                var num_node = sexpr.Expr.init(gpa, "num");

                // Add num_var
                var num_var_node = sexpr.Expr.init(gpa, "num_var");
                const num_var_str = num_expr.num_var.allocPrint(gpa);
                defer gpa.free(num_var_str);
                num_var_node.appendStringChild(gpa, num_var_str);
                num_node.appendNodeChild(gpa, &num_var_node);

                // Add literal
                var literal_node = sexpr.Expr.init(gpa, "literal");
                const literal_str = ir.env.strings.get(num_expr.literal);
                literal_node.appendStringChild(gpa, literal_str);
                num_node.appendNodeChild(gpa, &literal_node);

                // Add value info
                var value_node = sexpr.Expr.init(gpa, "value");
                // TODO: Format the actual integer value properly
                value_node.appendStringChild(gpa, "TODO");
                num_node.appendNodeChild(gpa, &value_node);

                // Add bound info
                var bound_node = sexpr.Expr.init(gpa, "bound");
                bound_node.appendStringChild(gpa, @tagName(num_expr.bound));
                num_node.appendNodeChild(gpa, &bound_node);

                return num_node;
            },
            .int => |int_expr| {
                var int_node = sexpr.Expr.init(gpa, "int");

                // Add num_var
                var num_var_node = sexpr.Expr.init(gpa, "num_var");
                const num_var_str = int_expr.num_var.allocPrint(gpa);
                defer gpa.free(num_var_str);
                num_var_node.appendStringChild(gpa, num_var_str);
                int_node.appendNodeChild(gpa, &num_var_node);

                // Add precision_var
                var prec_var_node = sexpr.Expr.init(gpa, "precision_var");
                const prec_var_str = int_expr.precision_var.allocPrint(gpa);
                defer gpa.free(prec_var_str);
                prec_var_node.appendStringChild(gpa, prec_var_str);
                int_node.appendNodeChild(gpa, &prec_var_node);

                // Add literal
                var literal_node = sexpr.Expr.init(gpa, "literal");
                const literal_str = ir.env.strings.get(int_expr.literal);
                literal_node.appendStringChild(gpa, literal_str);
                int_node.appendNodeChild(gpa, &literal_node);

                // Add value info
                var value_node = sexpr.Expr.init(gpa, "value");
                value_node.appendStringChild(gpa, "TODO");
                int_node.appendNodeChild(gpa, &value_node);

                // Add bound info
                var bound_node = sexpr.Expr.init(gpa, "bound");
                bound_node.appendStringChild(gpa, @tagName(int_expr.bound));
                int_node.appendNodeChild(gpa, &bound_node);

                return int_node;
            },
            .float => |float_expr| {
                var float_node = sexpr.Expr.init(gpa, "float");

                // Add num_var
                var num_var_node = sexpr.Expr.init(gpa, "num_var");
                const num_var_str = float_expr.num_var.allocPrint(gpa);
                defer gpa.free(num_var_str);
                num_var_node.appendStringChild(gpa, num_var_str);
                float_node.appendNodeChild(gpa, &num_var_node);

                // Add precision_var
                var prec_var_node = sexpr.Expr.init(gpa, "precision_var");
                const prec_var_str = float_expr.precision_var.allocPrint(gpa);
                defer gpa.free(prec_var_str);
                prec_var_node.appendStringChild(gpa, prec_var_str);
                float_node.appendNodeChild(gpa, &prec_var_node);

                // Add literal
                var literal_node = sexpr.Expr.init(gpa, "literal");
                const literal = ir.env.strings.get(float_expr.literal);
                literal_node.appendStringChild(gpa, literal);
                float_node.appendNodeChild(gpa, &literal_node);

                // Add value
                var value_node = sexpr.Expr.init(gpa, "value");
                const value_str = std.fmt.allocPrint(gpa, "{d}", .{float_expr.value}) catch |err| exitOnOom(err);
                defer gpa.free(value_str);
                value_node.appendStringChild(gpa, value_str);
                float_node.appendNodeChild(gpa, &value_node);

                // Add bound info
                var bound_node = sexpr.Expr.init(gpa, "bound");
                bound_node.appendStringChild(gpa, @tagName(float_expr.bound));
                float_node.appendNodeChild(gpa, &bound_node);

                return float_node;
            },
            .str_segment => |str_idx| {
                const value = ir.env.strings.get(str_idx);
                var str_node = sexpr.Expr.init(gpa, "literal");
                str_node.appendStringChild(gpa, value);
                return str_node;
            },
            .str => |segment_span| {
                var str_node = sexpr.Expr.init(gpa, "string");

                for (ir.store.sliceExpr(segment_span)) |segment| {
                    var segment_node = ir.store.getExpr(segment).toSExpr(ir, line_starts, source);
                    str_node.appendNodeChild(gpa, &segment_node);
                }

                return str_node;
            },
            .single_quote => |e| {
                var single_quote_node = sexpr.Expr.init(gpa, "single_quote");

                // Add num_var
                var num_var_node = sexpr.Expr.init(gpa, "num_var");
                const num_var_str = e.num_var.allocPrint(gpa);
                defer gpa.free(num_var_str);
                num_var_node.appendStringChild(gpa, num_var_str);
                single_quote_node.appendNodeChild(gpa, &num_var_node);

                // Add precision_var
                var prec_var_node = sexpr.Expr.init(gpa, "precision_var");
                const prec_var_str = e.precision_var.allocPrint(gpa);
                defer gpa.free(prec_var_str);
                prec_var_node.appendStringChild(gpa, prec_var_str);
                single_quote_node.appendNodeChild(gpa, &prec_var_node);

                // Add value
                var value_node = sexpr.Expr.init(gpa, "value");
                const value_str = std.fmt.allocPrint(gpa, "'\\u{{{x}}}'", .{e.value}) catch |err| exitOnOom(err);
                defer gpa.free(value_str);
                value_node.appendStringChild(gpa, value_str);
                single_quote_node.appendNodeChild(gpa, &value_node);

                // Add bound info
                var bound_node = sexpr.Expr.init(gpa, "bound");
                bound_node.appendStringChild(gpa, @tagName(e.bound));
                single_quote_node.appendNodeChild(gpa, &bound_node);

                return single_quote_node;
            },
            .list => |l| {
                var list_node = sexpr.Expr.init(gpa, "list");

                // Add elem_var
                var elem_var_node = sexpr.Expr.init(gpa, "elem_var");
                const elem_var_str = l.elem_var.allocPrint(gpa);
                defer gpa.free(elem_var_str);
                elem_var_node.appendStringChild(gpa, elem_var_str);
                list_node.appendNodeChild(gpa, &elem_var_node);

                // TODO print list elems
                // implement proper span access when collection is available
                var elems_node = sexpr.Expr.init(gpa, "elems");
                elems_node.appendStringChild(gpa, "TODO each element");
                list_node.appendNodeChild(gpa, &elems_node);

                return list_node;
            },
            .lookup => |l| {
                var lookup_node = sexpr.Expr.init(gpa, "lookup");

                var ident_node = sexpr.Expr.init(gpa, "pattern_idx");

                const pattern_idx_str = std.fmt.allocPrint(gpa, "{}", .{@intFromEnum(l.pattern_idx)}) catch |err| exitOnOom(err);
                defer gpa.free(pattern_idx_str);

                ident_node.appendStringChild(gpa, pattern_idx_str);
                lookup_node.appendNodeChild(gpa, &ident_node);

                return lookup_node;
            },
            .when => |_| {
                var when_branch_node = sexpr.Expr.init(gpa, "when");
                when_branch_node.appendStringChild(gpa, "TODO when branch");

                return when_branch_node;
            },
            .@"if" => |if_expr| {
                var if_node = sexpr.Expr.init(gpa, "if");

                // Add cond_var
                var cond_var_node = sexpr.Expr.init(gpa, "cond_var");
                const cond_var_str = if_expr.cond_var.allocPrint(gpa);
                defer gpa.free(cond_var_str);
                cond_var_node.appendStringChild(gpa, cond_var_str);
                if_node.appendNodeChild(gpa, &cond_var_node);

                // Add branch_var
                var branch_var_node = sexpr.Expr.init(gpa, "branch_var");
                const branch_var_str = if_expr.branch_var.allocPrint(gpa);
                defer gpa.free(branch_var_str);
                branch_var_node.appendStringChild(gpa, branch_var_str);
                if_node.appendNodeChild(gpa, &branch_var_node);

                // Add branches
                // const if_branch_slice = ir.store.sliceIfBranch(if_expr.branches);
                var branches_node = sexpr.Expr.init(gpa, "branches");
                // for (if_branch_slice) |if_branch_idx| {
                //     const if_branch = ir.store.getIfBranch(if_branch_idx);
                //     _ = if_branch;
                // var cond_node = cond.toSExpr(env, ir);
                // var body_node = body.toSExpr(env, ir);
                // var branch_node = sexpr.Expr.init(gpa, "branch");
                // branch_node.appendNodeChild(gpa, &cond_node);
                // branch_node.appendNodeChild(gpa, &body_node);
                // branches_node.appendNodeChild(gpa, &branch_node);
                // }
                // node.appendNodeChild(gpa, &branches_node);

                // var else_node = sexpr.Expr.init(gpa, "else");
                // const final_else_expr = ir.exprs_at_regions.get(i.final_else);
                // var else_sexpr = final_else_expr.toSExpr(env, ir);
                // else_node.appendNodeChild(gpa, &else_sexpr);
                // node.appendNodeChild(gpa, &else_node);
                branches_node.appendStringChild(gpa, "TODO: access if branches");
                if_node.appendNodeChild(gpa, &branches_node);

                // Add final_else
                var else_node = sexpr.Expr.init(gpa, "else");
                // TODO: Implement proper final_else access
                else_node.appendStringChild(gpa, "TODO: access final else");
                if_node.appendNodeChild(gpa, &else_node);

                return if_node;
            },
            .call => |c| {
                var call_node = sexpr.Expr.init(gpa, "call");

                // Get all expressions from the args span
                const all_exprs = ir.store.exprSlice(c.args);

                // First element is the function being called
                if (all_exprs.len > 0) {
                    const fn_expr = ir.store.getExpr(all_exprs[0]);
                    var fn_node = fn_expr.toSExpr(ir, line_starts, source);
                    call_node.appendNodeChild(gpa, &fn_node);
                }

                // Remaining elements are the arguments
                if (all_exprs.len > 1) {
                    for (all_exprs[1..]) |arg_idx| {
                        const arg_expr = ir.store.getExpr(arg_idx);
                        var arg_node = arg_expr.toSExpr(ir, line_starts, source);
                        call_node.appendNodeChild(gpa, &arg_node);
                    }
                }

                return call_node;
            },
            .record => |record_expr| {
                var record_node = sexpr.Expr.init(gpa, "record");

                // Add record_var
                var record_var_node = sexpr.Expr.init(gpa, "record_var");
                const record_var_str = record_expr.record_var.allocPrint(gpa);
                defer gpa.free(record_var_str);
                record_var_node.appendStringChild(gpa, record_var_str);
                record_node.appendNodeChild(gpa, &record_var_node);

                // TODO: Add fields when implemented
                var fields_node = sexpr.Expr.init(gpa, "fields");
                fields_node.appendStringChild(gpa, "TODO");
                record_node.appendNodeChild(gpa, &fields_node);

                return record_node;
            },
            .empty_record => {
                return sexpr.Expr.init(gpa, "empty_record");
            },
            .record_access => |access_expr| {
                var access_node = sexpr.Expr.init(gpa, "record_access");

                // Add record_var
                var record_var_node = sexpr.Expr.init(gpa, "record_var");
                const record_var_str = access_expr.record_var.allocPrint(gpa);
                defer gpa.free(record_var_str);
                record_var_node.appendStringChild(gpa, record_var_str);
                access_node.appendNodeChild(gpa, &record_var_node);

                // Add ext_var
                var ext_var_node = sexpr.Expr.init(gpa, "ext_var");
                const ext_var_str = access_expr.ext_var.allocPrint(gpa);
                defer gpa.free(ext_var_str);
                ext_var_node.appendStringChild(gpa, ext_var_str);
                access_node.appendNodeChild(gpa, &ext_var_node);

                // Add field_var
                var field_var_node = sexpr.Expr.init(gpa, "field_var");
                const field_var_str = access_expr.field_var.allocPrint(gpa);
                defer gpa.free(field_var_str);
                field_var_node.appendStringChild(gpa, field_var_str);
                access_node.appendNodeChild(gpa, &field_var_node);

                // Add loc_expr
                var loc_expr = ir.store.getExpr(access_expr.loc_expr);
                var loc_expr_node = loc_expr.toSExpr(ir, line_starts, source);
                access_node.appendNodeChild(gpa, &loc_expr_node);

                // Add field
                var field_node = sexpr.Expr.init(gpa, "field");
                const field_str = ir.env.idents.getText(access_expr.field);
                field_node.appendStringChild(gpa, field_str);
                access_node.appendNodeChild(gpa, &field_node);

                return access_node;
            },
            .tag => |tag_expr| {
                var tag_node = sexpr.Expr.init(gpa, "tag");

                // Add tag_union_var
                var tag_union_var_node = sexpr.Expr.init(gpa, "tag_union_var");
                const tag_union_var_str = tag_expr.tag_union_var.allocPrint(gpa);
                defer gpa.free(tag_union_var_str);
                tag_union_var_node.appendStringChild(gpa, tag_union_var_str);
                tag_node.appendNodeChild(gpa, &tag_union_var_node);

                // Add ext_var
                var ext_var_node = sexpr.Expr.init(gpa, "ext_var");
                const ext_var_str = tag_expr.ext_var.allocPrint(gpa);
                defer gpa.free(ext_var_str);
                ext_var_node.appendStringChild(gpa, ext_var_str);
                tag_node.appendNodeChild(gpa, &ext_var_node);

                // Add name
                var name_node = sexpr.Expr.init(gpa, "name");
                const name_str = ir.env.idents.getText(tag_expr.name);
                name_node.appendStringChild(gpa, name_str);
                tag_node.appendNodeChild(gpa, &name_node);

                // Add args
                var args_node = sexpr.Expr.init(gpa, "args");
                // const args_slice = ir.typed_exprs_at_regions.rangeToSlice(tag_expr.args);
                args_node.appendStringChild(gpa, "TODO");
                tag_node.appendNodeChild(gpa, &args_node);

                return tag_node;
            },
            .zero_argument_tag => |tag_expr| {
                var tag_node = sexpr.Expr.init(gpa, "zero_argument_tag");

                // Add closure_name
                var closure_name_node = sexpr.Expr.init(gpa, "closure_name");
                const closure_name_str = ir.env.idents.getText(tag_expr.closure_name);
                closure_name_node.appendStringChild(gpa, closure_name_str);
                tag_node.appendNodeChild(gpa, &closure_name_node);

                // Add variant_var
                var variant_var_node = sexpr.Expr.init(gpa, "variant_var");
                const variant_var_str = tag_expr.variant_var.allocPrint(gpa);
                defer gpa.free(variant_var_str);
                variant_var_node.appendStringChild(gpa, variant_var_str);
                tag_node.appendNodeChild(gpa, &variant_var_node);

                // Add ext_var
                var ext_var_node = sexpr.Expr.init(gpa, "ext_var");
                const ext_var_str = tag_expr.ext_var.allocPrint(gpa);
                defer gpa.free(ext_var_str);
                ext_var_node.appendStringChild(gpa, ext_var_str);
                tag_node.appendNodeChild(gpa, &ext_var_node);

                // Add name
                var name_node = sexpr.Expr.init(gpa, "name");
                const name_str = ir.env.idents.getText(tag_expr.name);
                name_node.appendStringChild(gpa, name_str);
                tag_node.appendNodeChild(gpa, &name_node);

                return tag_node;
            },
            .binop => |e| {
                var binop_node = sexpr.Expr.init(gpa, "binop");
                binop_node.appendStringChild(gpa, @tagName(e.op));
                var lhs_node = ir.store.getExpr(e.lhs).toSExpr(ir, line_starts, source);
                var rhs_node = ir.store.getExpr(e.rhs).toSExpr(ir, line_starts, source);
                binop_node.appendNodeChild(gpa, &lhs_node);
                binop_node.appendNodeChild(gpa, &rhs_node);
                return binop_node;
            },
            .runtime_error => |e| {
                var runtime_err_node = sexpr.Expr.init(gpa, "runtime_error");

                runtime_err_node.appendRegionChild(gpa, regionInfo(source, e.region, line_starts));

                var buf = std.ArrayList(u8).init(gpa);
                defer buf.deinit();

                buf.writer().writeAll("RUNTIME ERROR ") catch |err| exitOnOom(err);
                buf.writer().writeAll(@tagName(e.tag)) catch |err| exitOnOom(err);

                runtime_err_node.appendStringChild(gpa, buf.items);

                return runtime_err_node;
            },
        }
    }
};

/// A file of any type that has been ingested into a Roc module
/// as raw data, e.g. `import "lookups.txt" as lookups : Str`.
///
/// These ingestions aren't resolved until the import resolution
/// compiler stage.
pub const IngestedFile = struct {
    relative_path: StringLiteral.Idx,
    ident: Ident.Idx,
    type: Annotation,

    pub const List = collections.SafeList(@This());
    pub const Idx = List.Idx;
    pub const Range = List.Range;
    pub const NonEmptyRange = List.NonEmptyRange;

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        _ = line_starts;
        const gpa = ir.env.gpa;
        var node = sexpr.Expr.init(gpa, "ingested_file");
        node.appendStringChild(gpa, "path"); // TODO: use self.relative_path
        appendIdentChild(&node, gpa, ir.env, "ident", self.ident);
        var type_node = self.type.toSExpr(ir);
        node.appendNodeChild(gpa, &type_node);
        return node;
    }
};

/// A definition of a value (or destructured values) that
/// takes its value from an expression.
pub const Def = struct {
    pattern: Pattern.Idx,
    pattern_region: Region,
    expr: Expr.Idx,
    expr_region: Region,
    expr_var: TypeVar,
    // TODO:
    // pattern_vars: SendMap<Symbol, Variable>,
    annotation: ?Annotation.Idx,
    kind: Kind,

    pub const Kind = union(enum) {
        /// A def that introduces identifiers
        let,
        /// A standalone statement with an fx variable
        stmt: TypeVar,
        /// Ignored result, must be effectful
        ignored: TypeVar,

        pub fn toSExpr(self: *const @This(), gpa: std.mem.Allocator) sexpr.Expr {
            switch (self.*) {
                .let => return sexpr.Expr.init(gpa, "let"),
                .stmt => return sexpr.Expr.init(gpa, "stmt"),
                .ignored => return sexpr.Expr.init(gpa, "ignored"),
            }
        }

        /// encode the kind of def into two u32 values
        pub fn encode(self: *const Kind) [2]u32 {
            switch (self.*) {
                .let => return .{ 0, 0 },
                .stmt => |ty_var| return .{ 1, @intFromEnum(ty_var) },
                .ignored => |ty_var| return .{ 2, @intFromEnum(ty_var) },
            }
        }

        /// decode the kind of def from two u32 values
        pub fn decode(data: [2]u32) Kind {
            if (data[0] == 0) {
                return .let;
            } else if (data[0] == 1) {
                return .{ .stmt = @as(TypeVar, @enumFromInt(data[1])) };
            } else if (data[0] == 2) {
                return .{ .ignored = @as(TypeVar, @enumFromInt(data[1])) };
            } else {
                @panic("invalid def kind");
            }
        }

        test "encode and decode def kind" {
            const kind: Kind = Kind.let;
            const encoded = kind.encode();
            const decoded = Kind.decode(encoded);
            try std.testing.expect(decoded == Kind.let);
        }

        test "encode and decode def kind with type var" {
            const kind: Kind = .{ .stmt = @as(TypeVar, @enumFromInt(42)) };
            const encoded = kind.encode();
            const decoded = Kind.decode(encoded);
            switch (decoded) {
                .stmt => |stmt| {
                    try std.testing.expect(stmt == @as(TypeVar, @enumFromInt(42)));
                },
                else => @panic("invalid def kind"),
            }
        }
    };

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
    pub const Range = struct { start: u32, len: u32 };

    pub fn toSExpr(self: *const @This(), ir: *CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;
        var node = sexpr.Expr.init(gpa, "def");

        var kind_node = self.kind.toSExpr(gpa);
        node.appendNodeChild(gpa, &kind_node);

        var pattern_node = sexpr.Expr.init(gpa, "pattern");
        pattern_node.appendRegionChild(gpa, regionInfo(source, self.pattern_region, line_starts));

        const pattern = ir.store.getPattern(self.pattern);
        var pattern_sexpr = pattern.toSExpr(ir, line_starts, source);
        pattern_node.appendNodeChild(gpa, &pattern_sexpr);
        node.appendNodeChild(gpa, &pattern_node);

        var expr_node = sexpr.Expr.init(gpa, "expr");
        expr_node.appendRegionChild(gpa, regionInfo(source, self.expr_region, line_starts));

        const expr = ir.store.getExpr(self.expr);
        var expr_sexpr = expr.toSExpr(ir, line_starts, source);
        expr_node.appendNodeChild(gpa, &expr_sexpr);
        node.appendNodeChild(gpa, &expr_node);

        const expr_var = self.expr_var.allocPrint(gpa);
        defer gpa.free(expr_var);
        node.appendStringChild(gpa, expr_var);

        if (self.annotation) |anno_idx| {
            _ = anno_idx; // TODO: implement annotation lookup
            // var anno_node = anno.toSExpr(env, ir);
            // node.appendNodeChild(env.gpa, &anno_node);
        }

        return node;
    }
};

/// todo
pub const Annotation = struct {
    signature: TypeVar,
    // introduced_variables: IntroducedVariables,
    // aliases: VecMap<Symbol, Alias>,
    region: Region,

    pub const Idx = enum(u32) { _ };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        _ = self;
        _ = line_starts;
        const gpa = ir.env.gpa;
        const node = sexpr.Expr.init(gpa, "annotation");
        // TODO add signature info
        return node;
    }
};

/// todo
pub const IntValue = struct {
    bytes: [16]u8,
    kind: Kind,

    /// todo
    pub const Kind = enum { i128, u128 };
};

/// todo
pub const ExprAtRegion = struct {
    expr: Expr,
    region: Region,

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        const gpa = ir.env.gpa;
        var node = sexpr.Expr.init(gpa, "expr_at_region");

        node.appendRegionChild(gpa, self.region);

        const expr = ir.store.getExpr(self.expr);
        var expr_sexpr = expr.toSExpr(ir, line_starts);

        node.appendNodeChild(gpa, &expr_sexpr);

        return expr.toSExpr(ir, line_starts);
    }
};

/// todo
pub const TypedExprAtRegion = struct {
    expr: Expr.Idx,
    type_var: TypeVar,
    region: Region,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;

        var typed_expr_node = sexpr.Expr.init(gpa, "typed_expr_at_region");
        typed_expr_node.appendRegionChild(gpa, regionInfo(source, self.region, line_starts));

        const expr = ir.store.getExpr(self.expr);
        typed_expr_node.appendNodeChild(gpa, &expr.toSExpr(ir));

        return typed_expr_node;
    }
};

/// todo
pub const Function = struct {
    return_var: TypeVar,
    fx_var: TypeVar,
    function_var: TypeVar,
    expr: Expr.Idx,
    region: Region,

    // TODO: Add toSExpr if needed, might be part of Expr.Closure?
};

/// todo - evaluate if we need this?
pub const IfBranch = struct {
    cond: ExprAtRegion,
    body: ExprAtRegion,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    // Note: toSExpr is handled within Expr.if because the slice reference is there
};

/// todo - evaluate if we need this?
pub const When = struct {
    /// The actual condition of the when expression.
    loc_cond: Expr.Idx,
    cond_var: TypeVar,
    /// Type of each branch (and therefore the type of the entire `when` expression)
    expr_var: TypeVar,
    region: Region,
    /// The branches of the when, and the type of the condition that they expect to be matched
    /// against.
    branches: WhenBranch.Span,
    branches_cond_var: TypeVar,
    /// Whether the branches are exhaustive.
    exhaustive: ExhaustiveMark,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        const gpa = ir.env.gpa;
        var node = sexpr.Expr.init(gpa, "when");

        node.appendRegionChild(gpa, self.region);

        var cond_node = sexpr.Expr.init(gpa, "cond");
        const cond_expr = ir.store.getExpr(self.loc_cond);
        var cond_sexpr = cond_expr.toSExpr(ir, line_starts);
        cond_node.appendNodeChild(gpa, &cond_sexpr);

        node.appendNodeChild(gpa, &cond_node);

        appendTypeVarChild(&node, gpa, "cond_var", self.cond_var);
        appendTypeVarChild(&node, gpa, "expr_var", self.expr_var);
        appendTypeVarChild(&node, gpa, "branches_cond_var", self.branches_cond_var);
        appendTypeVarChild(&node, gpa, "exhaustive_mark", self.exhaustive);

        var branches_node = sexpr.Expr.init(gpa, "branches");
        for (ir.store.whenBranchSlice(self.branches)) |branch_idx| {
            const branch = ir.store.getWhenBranch(branch_idx);

            var branch_sexpr = branch.toSExpr(ir);
            branches_node.appendNodeChild(gpa, &branch_sexpr);
        }
        node.appendNodeChild(gpa, &branches_node);

        return node;
    }
};

/// todo - evaluate if we need this?
pub const WhenBranchPattern = struct {
    pattern: PatternAtRegion,
    /// Degenerate branch patterns are those that don't fully bind symbols that the branch body
    /// needs. For example, in `A x | B y -> x`, the `B y` pattern is degenerate.
    /// Degenerate patterns emit a runtime error if reached in a program.
    degenerate: bool,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        _ = line_starts;
        const gpa = ir.gpa;
        var node = sexpr.Expr.init(gpa, "when_branch_pattern");
        var pattern_sexpr = self.pattern.toSExpr(ir);
        node.appendNodeChild(gpa, &pattern_sexpr);
        if (self.degenerate) {
            node.appendStringChild(gpa, "degenerate=true");
        }
        return node;
    }
};

/// todo - evaluate if we need this?
pub const WhenBranch = struct {
    patterns: WhenBranchPattern.Span,
    value: Expr.Idx,
    guard: ?Expr.Idx,
    /// Whether this branch is redundant in the `when` it appears in
    redundant: RedundantMark,

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        const gpa = ir.env.gpa;
        var node = sexpr.Expr.init(gpa, "when_branch");

        var patterns_node = sexpr.Expr.init(gpa, "patterns");
        // Need WhenBranchPattern.List storage in IR to resolve slice
        // Assuming `ir.when_branch_patterns` exists:
        // for (ir.when_branch_patterns.getSlice(self.patterns)) |patt| {
        //     var patt_sexpr = patt.toSExpr(env, ir);
        //     patterns_node.appendNodeChild(gpa, &patt_sexpr);
        // }
        patterns_node.appendStringChild(gpa, "TODO: Store and represent WhenBranchPattern slice");
        node.appendNodeChild(gpa, &patterns_node);

        var value_node = sexpr.Expr.init(gpa, "value");
        const value_expr = ir.exprs_at_regions.get(self.value);
        var value_sexpr = value_expr.toSExpr(ir, line_starts);
        value_node.appendNodeChild(gpa, &value_sexpr);
        node.appendNodeChild(gpa, &value_node);

        if (self.guard) |guard_idx| {
            var guard_node = sexpr.Expr.init(gpa, "guard");
            const guard_expr = ir.exprs_at_regions.get(guard_idx);
            var guard_sexpr = guard_expr.toSExpr(ir, line_starts);
            guard_node.appendNodeChild(gpa, &guard_sexpr);
            node.appendNodeChild(gpa, &guard_node);
        }

        return node;
    }

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };
};

/// A pattern, including possible problems (e.g. shadowing) so that
/// codegen can generate a runtime error if this pattern is reached.
pub const Pattern = union(enum) {
    /// An identifier in the assignment position, e.g. the `x` in `x = foo(1)`
    assign: Ident.Idx,
    as: struct {
        pattern: Pattern.Idx,
        region: Region,
        ident: Ident.Idx,
    },
    applied_tag: struct {
        whole_var: TypeVar,
        ext_var: TypeVar,
        tag_name: Ident.Idx,
        arguments: TypedPatternAtRegion.Span,
    },
    record_destructure: struct {
        whole_var: TypeVar,
        ext_var: TypeVar,
        destructs: RecordDestruct.Span,
    },
    list: struct {
        list_var: TypeVar,
        elem_var: TypeVar,
        patterns: Pattern.Span,
    },
    num_literal: struct {
        num_var: TypeVar,
        literal: StringLiteral.Idx,
        value: IntValue,
        bound: types.Num.Compact,
    },
    int_literal: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        literal: StringLiteral.Idx,
        value: IntValue,
        bound: types.Num.Compact.Int.Precision,
    },
    float_literal: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        literal: StringLiteral.Idx,
        value: f64,
        bound: types.Num.Compact.Frac.Precision,
    },
    str_literal: StringLiteral.Idx,
    char_literal: struct {
        num_var: TypeVar,
        precision_var: TypeVar,
        value: u32,
        bound: types.Num.Compact.Int.Precision,
    },
    Underscore,

    // TODO: do we want these runtime exceptions here?
    // // Runtime Exceptions
    // Shadowed(Region, Loc<Ident>, Symbol),
    // OpaqueNotInScope(Loc<Ident>),
    // // Example: (5 = 1 + 2) is an unsupported pattern in an assignment; Int patterns aren't allowed in assignments!
    // UnsupportedPattern(Region),
    // parse error patterns
    // MalformedPattern: .{ MalformedPatternProblem, Region },

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;
        switch (self.*) {
            .assign => |ident_idx| {
                var node = sexpr.Expr.init(gpa, "assign");
                appendIdentChild(&node, gpa, ir, "ident", ident_idx);
                return node;
            },
            .as => |a| {
                var node = sexpr.Expr.init(gpa, "as");
                node.appendRegionChild(gpa, regionInfo(source, a.region, line_starts));
                appendIdentChild(&node, gpa, ir, "ident", a.ident);
                var inner_patt_node = sexpr.Expr.init(gpa, "pattern");
                const inner_patt = ir.store.getPattern(a.pattern);
                var inner_patt_sexpr = inner_patt.toSExpr(ir, line_starts, source);
                inner_patt_node.appendNodeChild(gpa, &inner_patt_sexpr);
                node.appendNodeChild(gpa, &inner_patt_node);
                return node;
            },
            .applied_tag => |_| {
                @panic("TODO pattern applied_tag");
                // var node = sexpr.Expr.init(gpa, "pattern_applied_tag");
                // appendIdentChild(&node, gpa, ir, "tag_name", t.tag_name);
                // var args_node = sexpr.Expr.init(gpa, "arguments");
                // ir.store.pa
                // for (ir.patterns_at_regions.rangeToSlice(t.arguments).items(.pattern), ir.typed_patterns_at_regions.rangeToSlice(t.arguments).items(.type_var)) |arg, type_var| {
                //     var arg_sexpr = ir.patterns.get(arg).toSExpr(ir);
                //     var pat_ty_var = sexpr.Expr.init(gpa, "argty");
                //     pat_ty_var.appendNodeChild(gpa, &arg_sexpr);
                //     pat_ty_var.appendUnsignedIntChild(gpa, @intFromEnum(type_var)); // TODO: use a type var name or something
                //     args_node.appendNodeChild(gpa, &pat_ty_var);
                // }
                // node.appendNodeChild(gpa, &args_node);
                // return node;
            },
            .record_destructure => {
                var node = sexpr.Expr.init(gpa, "record_destructure");
                var destructs_node = sexpr.Expr.init(gpa, "destructs");
                // Need RecordDestruct storage in IR
                // Assuming ir.record_destructs exists:
                // for (ir.record_destructs.getSlice(r.destructs)) |destruct| {
                //     var d_sexpr = destruct.toSExpr(env, ir);
                //     destructs_node.appendNodeChild(gpa, &d_sexpr);
                // }
                destructs_node.appendStringChild(gpa, "TODO: Store and represent RecordDestruct slice");
                node.appendNodeChild(gpa, &destructs_node);
                return node;
            },
            .list => |l| {
                var pattern_list_node = sexpr.Expr.init(gpa, "list");
                var patterns_node = sexpr.Expr.init(gpa, "patterns");

                for (ir.store.slicePatterns(l.patterns)) |patt_idx| {
                    const patt = ir.store.getPattern(patt_idx);
                    var patt_sexpr = patt.toSExpr(ir, line_starts, source);
                    patterns_node.appendNodeChild(gpa, &patt_sexpr);
                }

                pattern_list_node.appendNodeChild(gpa, &patterns_node);

                return pattern_list_node;
            },
            .num_literal => |l| {
                var node = sexpr.Expr.init(gpa, "num");
                node.appendStringChild(gpa, "literal"); // TODO: use l.literal
                node.appendStringChild(gpa, "value=<int_value>");
                node.appendStringChild(gpa, @tagName(l.bound));
                return node;
            },
            .int_literal => |l| {
                var node = sexpr.Expr.init(gpa, "int");
                node.appendStringChild(gpa, "literal"); // TODO: use l.literal
                node.appendStringChild(gpa, "value=<int_value>");
                node.appendStringChild(gpa, @tagName(l.bound));
                return node;
            },
            .float_literal => |l| {
                var node = sexpr.Expr.init(gpa, "float");
                node.appendStringChild(gpa, "literal"); // TODO: use l.literal
                const val_str = std.fmt.allocPrint(gpa, "{d}", .{l.value}) catch "<oom>";
                defer gpa.free(val_str);
                node.appendStringChild(gpa, val_str);
                node.appendStringChild(gpa, @tagName(l.bound));
                return node;
            },
            .str_literal => |str_idx| {
                _ = str_idx; // str_idx not used currently, but keep for signature consistency
                var node = sexpr.Expr.init(gpa, "str");
                node.appendStringChild(gpa, "value"); // TODO: use str_idx
                return node;
            },
            .char_literal => |l| {
                var node = sexpr.Expr.init(gpa, "char");
                const char_str = std.fmt.allocPrint(gpa, "'\\u({d})'", .{l.value}) catch "<oom>";
                defer gpa.free(char_str);
                node.appendStringChild(gpa, char_str);
                node.appendStringChild(gpa, @tagName(l.bound));
                return node;
            },
            .Underscore => return sexpr.Expr.init(gpa, "underscore"),
        }
    }
};

/// todo - evaluate if we need this?
pub const PatternAtRegion = struct {
    pattern: Pattern.Idx,
    region: Region,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
        const gpa = ir.env.gpa;

        var pattern_node = sexpr.Expr.init(gpa, "pattern_at_region");
        pattern_node.appendRegionChild(gpa, self.region);

        const pattern = ir.patterns.get(self.pattern);
        var pattern_sexpr = pattern.toSExpr(ir, line_starts);
        pattern_node.appendNodeChild(gpa, &pattern_sexpr);

        return pattern_node;
    }
};

/// todo - evaluate if we need this?
pub const TypedPatternAtRegion = struct {
    pattern: Pattern.Idx,
    region: Region,
    type_var: TypeVar,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;

        var type_pattern_node = sexpr.Expr.init(gpa, "typed_pattern_at_region");
        type_pattern_node.appendRegionChild(gpa, self.region);

        const pattern = ir.patterns.get(self.pattern);
        var pattern_sexpr = pattern.toSExpr(ir, line_starts, source);
        type_pattern_node.appendNodeChild(gpa, &pattern_sexpr);

        return type_pattern_node;
    }
};

/// todo
pub const RecordDestruct = struct {
    type_var: TypeVar,
    region: Region,
    label: Ident.Idx,
    ident: Ident.Idx,
    kind: Kind,

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    /// todo
    pub const Kind = union(enum) {
        Required,
        Guard: TypedPatternAtRegion.Idx,

        pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32)) sexpr.Expr {
            const gpa = ir.env.gpa;

            switch (self.*) {
                .Required => return sexpr.Expr.init(gpa, "required"),
                .Guard => |guard_idx| {
                    var guard_kind_node = sexpr.Expr.init(gpa, "guard");

                    const guard_patt = ir.typed_patterns_at_regions.get(guard_idx);
                    var guard_sexpr = guard_patt.toSExpr(ir.env, ir, line_starts);
                    guard_kind_node.appendNodeChild(gpa, &guard_sexpr);

                    return guard_kind_node;
                },
            }
        }
    };

    pub fn toSExpr(self: *const @This(), ir: *const CIR, line_starts: std.ArrayList(u32), source: []const u8) sexpr.Expr {
        const gpa = ir.env.gpa;

        var record_destruct_node = sexpr.Expr.init(gpa, "record_destruct");

        record_destruct_node.appendTypeVarChild(&record_destruct_node, gpa, "type_var", self.type_var);
        record_destruct_node.appendRegionChild(gpa, regionInfo(source, self.region, line_starts));

        appendIdentChild(&record_destruct_node, gpa, ir, "label", self.label);
        appendIdentChild(&record_destruct_node, gpa, ir, "ident", self.ident);

        var kind_node = self.kind.toSExpr(ir);
        record_destruct_node.appendNodeChild(gpa, &kind_node);

        return record_destruct_node;
    }
};

/// Marks whether a when branch is redundant using a variable.
pub const RedundantMark = TypeVar;

/// Marks whether a when expression is exhaustive using a variable.
pub const ExhaustiveMark = TypeVar;

/// Helper function to convert the entire Canonical IR to a string in S-expression format
/// and write it to the given writer.
///
/// If a single expression is provided we only print that expression
pub fn toSExprStr(ir: *CIR, writer: std.io.AnyWriter, maybe_expr_idx: ?Expr.Idx, line_starts: std.ArrayList(u32), source: []const u8) !void {
    const gpa = ir.env.gpa;

    if (maybe_expr_idx) |expr_idx| {
        // Get the expression from the store
        const expr = ir.store.getExpr(expr_idx);

        var expr_node = expr.toSExpr(ir, line_starts, source);
        defer expr_node.deinit(gpa);

        expr_node.toStringPretty(writer);
    } else {
        var root_node = sexpr.Expr.init(gpa, "can_ir");
        defer root_node.deinit(gpa);

        var defs_node = sexpr.Expr.init(gpa, "top_level_defs");

        // Iterate over each top-level definition and convert it to an S-expression
        const defs_slice = ir.store.sliceDefs(ir.top_level_defs);

        if (defs_slice.len == 0) {
            defs_node.appendStringChild(gpa, "empty");
        }

        for (defs_slice) |def_idx| {
            const d = ir.store.getDef(def_idx);
            var def_node = d.toSExpr(ir, line_starts, source);
            defs_node.appendNodeChild(gpa, &def_node);
        }

        root_node.appendNodeChild(gpa, &defs_node);

        root_node.toStringPretty(writer);
    }
}

/// todo - evaluate if we need this?
/// I think Types are now implemented in `src/types.zig` etc...
pub const Content = union(enum) {
    /// A type variable which the user did not name in an annotation,
    ///
    /// When we auto-generate a type var name, e.g. the "a" in (a -> a), we
    /// change the Option in here from None to Some.
    FlexVar: ?Ident.Idx,
    /// name given in a user-written annotation
    RigidVar: Ident.Idx,
    /// name given to a recursion variable
    RecursionVar: struct {
        structure: TypeVar,
        opt_name: ?Ident.Idx,
    },
    Structure: FlatType,
    Alias: struct {
        ident: Ident.Idx,
        // vars: AliasVariables,
        type_var: TypeVar,
        kind: Alias.Kind,
    },
    RangedNumber: types.num.NumericRange,
    Error,
    /// The fx type variable for a given function
    Pure,
    Effectful,
};

/// todo - evaluate if we need this?
/// I think Types are now implemented in `src/types.zig` etc...
pub const FlatType = union(enum) {
    Apply: struct {
        ident: Ident.Idx,
        vars: collections.SafeList(TypeVar).Range,
    },
    Func: struct {
        arg_vars: collections.SafeList(TypeVar).Range,
        ret_var: TypeVar,
        fx: TypeVar,
    },
    /// A function that we know nothing about yet except that it's effectful
    EffectfulFunc,
    Record: struct {
        whole_var: TypeVar,
        fields: FlatType.RecordField.Range,
    },
    // TagUnion: struct {
    //     union_tags: UnionTags,
    //     ext: TagExt,
    // },

    // /// `A` might either be a function
    // ///   x -> A x : a -> [A a, B a, C a]
    // /// or a tag `[A, B, C]`
    // FunctionOrTagUnion: struct {
    //     name: Ident.Idx,
    //     ident: Ident.Idx,
    //     ext: TagExt,
    // },

    // RecursiveTagUnion: struct {
    //     type_var: TypeVar,
    //     union_tags: UnionTags,
    //     ext: TagExt,
    // },

    EmptyRecord,
    EmptyTagUnion,

    /// todo
    pub const RecordField = struct {
        name: Ident.Idx,
        type_var: TypeVar,

        // pub const List = collections.SafeMultiList(@This());
        // pub const Range = List.Range;
        pub const Idx = enum(u32) { _ };
    };
};

/// todo
pub const TagExt = union(enum) {
    /// This tag extension variable measures polymorphism in the openness of the tag,
    /// or the lack thereof. It can only be unified with
    ///   - an empty tag union, or
    ///   - a rigid extension variable
    ///
    /// Openness extensions are used when tag annotations are introduced, since tag union
    /// annotations may contain hidden extension variables which we want to reflect openness,
    /// but not growth in the monomorphic size of the tag. For example, openness extensions enable
    /// catching
    ///
    /// ```ignore
    /// f : [A]
    /// f = if Bool.true then A else B
    /// ```
    ///
    /// as an error rather than resolving as [A][B].
    Openness: TypeVar,
    /// This tag extension can grow unboundedly.
    Any: TypeVar,
};

test "NodeStore - init and deinit" {
    var store = CIR.NodeStore.init(testing.allocator);
    defer store.deinit();

    try testing.expect(store.nodes.len() == 0);
    try testing.expect(store.extra_data.items.len == 0);
}

/// Returns diagnostic position information for the given region.
/// This is a standalone utility function that takes the source text as a parameter
/// to avoid storing it in the cacheable IR structure.
pub fn regionInfo(source: []const u8, region: Region, line_starts: std.ArrayList(u32)) base.DiagnosticPosition {
    // In the Can IR, regions store byte offsets directly, not token indices.
    // We can use these offsets directly to calculate the diagnostic position.
    const info = base.DiagnosticPosition.position(source, line_starts, region.start.offset, region.end.offset) catch {
        // Return a zero position if we can't calculate it
        return .{
            .start_line_idx = 0,
            .start_col_idx = 0,
            .end_line_idx = 0,
            .end_col_idx = 0,
            .line_text = "",
        };
    };

    return info;
}
