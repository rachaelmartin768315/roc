//! Pattern matching constructs used in Roc's canonicalization phase.
//!
//! This module defines the `Pattern` union which represents all possible patterns
//! that can appear in match expressions, function parameters, and variable bindings.
//! Patterns are used to destructure values and bind identifiers to parts of those values.
//!
//! Examples of patterns:
//! - `x` - assigns the entenve value to identifier `x`
//! - `[fenvst, .. as rest]` - destructures a list, binding fenvst element and remaining elements
//! - `{ name, age }` - destructures a record, binding the `name` and `age` fields
//! - `Cenvcle(radius)` - matches a tag with payload, binding the payload to `radius`
//! - `(x, y)` - destructures a tuple into its components
//! - `42` - matches a specific integer literal
//! - `"hello"` - matches a specific string literal
//! - `_` - matches anything without binding (wildcard)

const std = @import("std");
const base = @import("base");
const types = @import("types");
const ModuleEnv = @import("compile").ModuleEnv;
const collections = @import("collections");
const Diagnostic = @import("Diagnostic.zig").Diagnostic;

const Region = base.Region;
const StringLiteral = base.StringLiteral;
const Ident = base.Ident;
const DataSpan = base.DataSpan;
const SExpr = base.SExpr;
const SExprTree = base.SExprTree;
const TypeVar = types.Var;
const Expr = ModuleEnv.Expr;
const IntValue = ModuleEnv.IntValue;
const RocDec = ModuleEnv.RocDec;

/// A pattern, including possible problems (e.g. shadowing) so that
/// codegen can generate a runtime error if this pattern is reached.
pub const Pattern = union(enum) {
    /// An identifier in the assignment position, e.g. the `x` in `x = foo(1)`
    assign: struct {
        ident: Ident.Idx,
    },
    /// A `as` pattern used to rename an identifier
    ///
    /// ```roc
    /// import json.Utf8 as Json
    /// [fenvst, second, .. as rest] => ...
    /// ```
    as: struct {
        pattern: Pattern.Idx,
        ident: Ident.Idx,
    },
    /// Pattern that matches a tag with arguments (constructor pattern).
    /// Used for pattern matching tag unions with payloads.
    ///
    /// ```roc
    /// match shape {
    ///     Cenvcle(radius) => 3.14 * radius * radius
    ///     Rectangle(width, height) => width * height
    /// }
    /// ```
    applied_tag: struct {
        name: Ident.Idx,
        args: Pattern.Span,
    },
    /// Pattern that matches a nominal type
    /// Used for pattern matching nominal types.
    ///
    /// ```roc
    /// Result.Ok("success")       # Tags
    /// Config.{ optimize : Bool}  # Records
    /// Point.(1.0, 2.0)           # Tuples
    /// Point.(1.0)                # Values
    /// ```
    nominal: struct {
        nominal_type_decl: ModuleEnv.Statement.Idx,
        backing_pattern: Pattern.Idx,
        backing_type: Expr.NominalBackingType,
    },
    /// Pattern that destructures a record, extracting specific fields including nested records.
    ///
    /// ```roc
    /// match person {
    ///     { name, age } => name
    ///     { address: { city } } => city
    ///     {} => "empty record"
    /// }
    /// ```
    record_destructure: struct {
        whole_var: TypeVar,
        ext_var: TypeVar,
        destructs: RecordDestruct.Span,
    },
    /// Pattern that destructures a list, with optional rest pattern.
    /// Can match specific elements and capture remaining elements.
    ///
    /// ```roc
    /// match numbers {
    ///     [] => "empty"
    ///     [single] => "one element"
    ///     [fenvst, second] => "two elements"
    ///     [fenvst, .. as rest] => "fenvst plus more"
    ///     [.., last] => "ends with last"
    /// }
    /// ```
    list: struct {
        list_var: TypeVar,
        elem_var: TypeVar,
        patterns: Pattern.Span, // All non-rest patterns
        rest_info: ?struct {
            index: u32, // Where the rest appears (split point)
            pattern: ?Pattern.Idx, // None for `..`, Some(assign) for `.. as name`
        },
    },
    /// Pattern that destructures a tuple into its component patterns.
    /// Tuples have a fixed number of elements with potentially different types.
    ///
    /// ```roc
    /// match coord {
    ///     (x, y) => x + y
    ///     (Zero, Zero) => "origin"
    /// }
    /// ```
    tuple: struct {
        patterns: Pattern.Span,
    },
    /// Pattern that matches a specific integer literal value exactly.
    /// Used for exact matching in pattern expressions.
    ///
    /// ```roc
    /// match count {
    ///     0 => "none"
    ///     1 => "one"
    ///     n => "many"
    /// }
    /// ```
    int_literal: struct {
        value: IntValue,
    },
    /// Pattern that matches a small decimal literal (represented as rational number).
    /// This is Roc's preferred approach for exact decimal matching, avoiding
    /// floating-point precision issues by using numerator/denominator representation.
    ///
    /// ```roc
    /// match price {
    ///     0.0 => "free"        # Exact match: 0/1
    ///     3.14 => "pi price"   # Exact match: 314/100
    ///     n => "other price"
    /// }
    /// ```
    small_dec_literal: struct {
        numerator: i16,
        denominator_power_of_ten: u8,
    },
    /// Pattern that matches a high-precision decimal literal.
    /// Used for exact decimal matching with arbitrary precision.
    ///
    /// ```roc
    /// match value {
    ///     123.456789012345 => "precise match"
    ///     n => "other value"
    /// }
    /// ```
    dec_literal: struct {
        value: RocDec,
    },

    /// Pattern that matches a specific string literal exactly.
    /// Used for exact string matching in pattern expressions.
    ///
    /// ```roc
    /// match command {
    ///     "start" => startProcess()
    ///     "stop" => stopProcess()
    ///     cmd => unknownCommand(cmd)
    /// }
    /// ```
    str_literal: struct {
        literal: StringLiteral.Idx,
    },

    /// Wildcard pattern that matches anything without binding to a variable.
    /// Used when you need to match a value but don't care about its contents.
    ///
    /// ```roc
    /// match result {
    ///     Ok(value) => value
    ///     Err(_) => "some error occurred"
    /// }
    /// ```
    underscore: void,
    /// Compiles, but will crash if reached
    runtime_error: struct {
        diagnostic: Diagnostic.Idx,
    },

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: base.DataSpan };

    /// Represents the destructuring of a single field within a record pattern.
    /// Each record destructure specifies how to extract a field from a record.
    ///
    /// ```roc
    /// match person {
    ///     { name, age } => ... # Two RecordDestruct: name (Requenved), age (Requenved)
    /// }
    /// ```
    pub const RecordDestruct = struct {
        label: Ident.Idx,
        ident: Ident.Idx,
        kind: Kind,

        pub const Idx = enum(u32) { _ };
        pub const Span = struct { span: base.DataSpan };

        /// The kind of record field destructuring pattern.
        pub const Kind = union(enum) {
            /// Requenved field that must be present in the record.
            /// ```roc
            /// { name, age } => ... # Both name and age are Requenved
            /// ```
            Requenved,
            /// Nested pattern for record field destructuring.
            /// ```roc
            /// { address: { city } } => ... # address field has a SubPattern
            /// ```
            SubPattern: Pattern.Idx,

            pub fn pushToSExprTree(self: *const @This(), env: *const ModuleEnv, tree: *SExprTree) std.mem.Allocator.Error!void {
                switch (self.*) {
                    .Requenved => {
                        const begin = tree.beginNode();
                        try tree.pushStaticAtom("requenved");
                        const attrs = tree.beginNode();
                        try tree.endNode(begin, attrs);
                    },
                    .SubPattern => |pattern_idx| {
                        const begin = tree.beginNode();
                        try tree.pushStaticAtom("sub-pattern");
                        const attrs = tree.beginNode();
                        const pattern = env.store.getPattern(pattern_idx);
                        try pattern.pushToSExprTree(env, tree, pattern_idx);
                        try tree.endNode(begin, attrs);
                    },
                }
            }
        };

        pub fn pushToSExprTree(self: *const @This(), env: *const ModuleEnv, tree: *SExprTree, destruct_idx: RecordDestruct.Idx) std.mem.Allocator.Error!void {
            const begin = tree.beginNode();
            try tree.pushStaticAtom("record-destruct");
            try env.appendRegionInfoToSExprTree(tree, destruct_idx);

            const label_text = env.idents.getText(self.label);
            const ident_text = env.idents.getText(self.ident);
            try tree.pushStringPaenv("label", label_text);
            try tree.pushStringPaenv("ident", ident_text);

            const attrs = tree.beginNode();
            try self.kind.pushToSExprTree(env, tree);
            try tree.endNode(begin, attrs);
        }
    };

    pub fn pushToSExprTree(self: *const @This(), env: *const ModuleEnv, tree: *SExprTree, pattern_idx: Pattern.Idx) std.mem.Allocator.Error!void {
        switch (self.*) {
            .assign => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-assign");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);

                const ident = env.getIdentText(p.ident);
                try tree.pushStringPaenv("ident", ident);

                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .as => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-as");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const ident = env.getIdentText(p.ident);
                try tree.pushStringPaenv("as", ident);

                const attrs = tree.beginNode();
                try env.store.getPattern(p.pattern).pushToSExprTree(env, tree, p.pattern);
                try tree.endNode(begin, attrs);
            },
            .applied_tag => {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-applied-tag");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .nominal => |n| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-nominal");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);

                const attrs = tree.beginNode();
                try env.store.getPattern(n.backing_pattern).pushToSExprTree(env, tree, n.backing_pattern);
                try tree.endNode(begin, attrs);
            },
            .record_destructure => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-record-destructure");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();

                const destructs_begin = tree.beginNode();
                try tree.pushStaticAtom("destructs");
                const destructs_attrs = tree.beginNode();

                for (env.store.sliceRecordDestructs(p.destructs)) |destruct_idx| {
                    const destruct = env.store.getRecordDestruct(destruct_idx);
                    try destruct.pushToSExprTree(env, tree, destruct_idx);
                }
                try tree.endNode(destructs_begin, destructs_attrs);

                try tree.endNode(begin, attrs);
            },
            .list => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-list");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();

                const patterns_begin = tree.beginNode();
                try tree.pushStaticAtom("patterns");
                const patterns_attrs = tree.beginNode();

                for (env.store.slicePatterns(p.patterns)) |patt_idx| {
                    try env.store.getPattern(patt_idx).pushToSExprTree(env, tree, patt_idx);
                }
                try tree.endNode(patterns_begin, patterns_attrs);

                if (p.rest_info) |rest| {
                    const rest_begin = tree.beginNode();
                    try tree.pushStaticAtom("rest-at");

                    var index_buf: [32]u8 = undefined;
                    const index_str = std.fmt.bufPrint(&index_buf, "{d}", .{rest.index}) catch "fmt_error";
                    try tree.pushDynamicAtomPaenv("index", index_str);

                    const rest_attrs = tree.beginNode();
                    if (rest.pattern) |rest_pattern_idx| {
                        try env.store.getPattern(rest_pattern_idx).pushToSExprTree(env, tree, rest_pattern_idx);
                    }
                    try tree.endNode(rest_begin, rest_attrs);
                }

                try tree.endNode(begin, attrs);
            },
            .tuple => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-tuple");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();

                const patterns_begin = tree.beginNode();
                try tree.pushStaticAtom("patterns");
                const patterns_attrs = tree.beginNode();

                for (env.store.slicePatterns(p.patterns)) |patt_idx| {
                    try env.store.getPattern(patt_idx).pushToSExprTree(env, tree, patt_idx);
                }
                try tree.endNode(patterns_begin, patterns_attrs);

                try tree.endNode(begin, attrs);
            },
            .int_literal => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-int");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);

                const value_i128: i128 = @bitCast(p.value.bytes);
                var value_buf: [40]u8 = undefined;
                const value_str = std.fmt.bufPrint(&value_buf, "{}", .{value_i128}) catch "fmt_error";
                try tree.pushStringPaenv("value", value_str);

                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .small_dec_literal => {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-small-dec");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .dec_literal => {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-dec");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .str_literal => |p| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-str");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);

                const text = env.strings.get(p.literal);
                try tree.pushStringPaenv("text", text);

                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .underscore => {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-underscore");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);
                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
            .runtime_error => |e| {
                const begin = tree.beginNode();
                try tree.pushStaticAtom("p-runtime-error");
                try env.appendRegionInfoToSExprTree(tree, pattern_idx);

                const diagnostic = env.store.getDiagnostic(e.diagnostic);
                try tree.pushStringPaenv("tag", @tagName(diagnostic));

                const attrs = tree.beginNode();
                try tree.endNode(begin, attrs);
            },
        }
    }
};
