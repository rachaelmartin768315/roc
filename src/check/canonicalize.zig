const std = @import("std");
const base = @import("../base.zig");
const parse = @import("parse.zig");
const problem = @import("../problem.zig");
const collections = @import("../collections.zig");
const types = @import("../types/types.zig");

const Scope = @import("./canonicalize/Scope.zig");
const Alias = @import("./canonicalize/Alias.zig");

can_ir: *CIR,
parse_ir: *parse.IR,
scope: *Scope,

const Ident = base.Ident;
const Region = base.Region;
const TagName = base.TagName;
const ModuleEnv = base.ModuleEnv;
const Problem = problem.Problem;
const exitOnOom = collections.utils.exitOnOom;

const BUILTIN_NUM_ADD: CIR.Pattern.Idx = @enumFromInt(0);
const BUILTIN_NUM_SUB: CIR.Pattern.Idx = @enumFromInt(1);

pub fn init(self: *CIR, parse_ir: *parse.IR, scope: *Scope) Self {
    const gpa = self.env.gpa;
    const ident_store = &self.env.idents;

    // Simulate the builtins by adding to both the NodeStore and Scope
    // Not sure if this is how we want to do it long term, but want something to
    // make a start on canonicalization.

    // BUILTIN_NUM_ADD
    const ident_add = self.env.idents.insert(gpa, base.Ident.for_text("add"), base.Region.zero());
    const pattern_idx_add = self.store.addPattern(CIR.Pattern{ .assign = ident_add });
    _ = scope.levels.introduce(gpa, ident_store, .ident, ident_add, pattern_idx_add) catch {};
    std.debug.assert(BUILTIN_NUM_ADD == pattern_idx_add);

    // BUILTIN_NUM_SUB
    const ident_sub = self.env.idents.insert(gpa, base.Ident.for_text("sub"), base.Region.zero());
    const pattern_idx_sub = self.store.addPattern(CIR.Pattern{ .assign = ident_sub });
    _ = scope.levels.introduce(gpa, ident_store, .ident, ident_sub, pattern_idx_sub) catch {};
    std.debug.assert(BUILTIN_NUM_SUB == pattern_idx_sub);

    return .{
        .can_ir = self,
        .parse_ir = parse_ir,
        .scope = scope,
    };
}

const Self = @This();

/// The intermediate representation of a canonicalized Roc program.
pub const CIR = @import("canonicalize/CIR.zig");

/// After parsing a Roc program, the [ParseIR](src/check/parse/ir.zig) is transformed into a [canonical
/// form](src/check/canonicalize/ir.zig) called CanIR.
///
/// Canonicalization performs analysis to catch user errors, and sets up the state necessary to solve the types in a
/// program. Among other things, canonicalization;
/// - Uniquely identifies names (think variable and function names). Along the way,
///     canonicalization builds a graph of all variables' references, and catches
///     unused definitions, undefined definitions, and shadowed definitions.
/// - Resolves type signatures, including aliases, into a form suitable for type
///     solving.
/// - Determines the order definitions are used in, if they are defined
///     out-of-order.
/// - Eliminates syntax sugar (for example, renaming `+` to the function call `add`).
///
/// The canonicalization occurs on a single module (file) in isolation. This allows for this work to be easily parallelized and also cached. So where the source code for a module has not changed, the CanIR can simply be loaded from disk and used immediately.
pub fn canonicalize_file(
    self: *Self,
) void {
    const gpa = self.can_ir.env.gpa;

    const file = self.parse_ir.store.getFile();

    // canonicalize_header_packages();

    // Track the start of scratch defs
    const scratch_defs_start = self.can_ir.store.scratchDefTop();

    for (self.parse_ir.store.statementSlice(file.statements)) |stmt_id| {
        const stmt = self.parse_ir.store.getStatement(stmt_id);
        switch (stmt) {
            .import => |import| {
                self.bringImportIntoScope(&import);
            },
            .decl => |decl| {
                if (self.canonicalize_decl(decl)) |def_idx| {
                    self.can_ir.store.addScratchDef(def_idx);
                } else {
                    self.can_ir.env.pushProblem(Problem.Compiler.can(.failed_to_canonicalize_decl));
                }
            },
            .@"var" => |v| {
                // Not valid at top-level
                self.can_ir.pushDiagnostic(.invalid_top_level_statement, v.region.toBase());
            },
            .expr => |expr| {
                // Not valid at top-level
                self.can_ir.pushDiagnostic(.invalid_top_level_statement, expr.region.toBase());
            },
            .crash => |crash| {
                // Not valid at top-level
                self.can_ir.pushDiagnostic(.invalid_top_level_statement, crash.region.toBase());
            },
            .expect => |_| {
                self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            },
            .@"for" => |f| {
                // Not valid at top-level
                self.can_ir.pushDiagnostic(.invalid_top_level_statement, f.region.toBase());
            },
            .@"return" => |return_stmt| {
                // Not valid at top-level
                self.can_ir.pushDiagnostic(.invalid_top_level_statement, return_stmt.region.toBase());
            },
            .type_decl => |_| {
                self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            },
            .type_anno => |_| {
                self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            },
            .malformed => |malformed| {
                // We won't touch this since it's already a parse error.
                _ = malformed;
            },
        }
    }

    // TODO: implement

    // Get the header and canonicalize exposes based on header type
    const header = self.parse_ir.store.getHeader(file.header);
    switch (header) {
        .module => |h| self.canonicalize_header_exposes(h.exposes),
        .package => |h| self.canonicalize_header_exposes(h.exposes),
        .platform => |h| self.canonicalize_header_exposes(h.exposes),
        .hosted => |h| self.canonicalize_header_exposes(h.exposes),
        .app => {
            // App headers have 'provides' instead of 'exposes'
            // TODO: Handle app provides differently
        },
        .malformed => {
            // Skip malformed headers
        },
    }

    // Create the span of all top-level defs
    self.can_ir.top_level_defs = self.can_ir.store.defSpanFrom(scratch_defs_start);

    // Copy errors across to ModuleEnv problems
    for (self.can_ir.diagnostics.items) |msg| {
        _ = self.can_ir.env.problems.append(gpa, .{ .canonicalize = msg });
    }
}

fn canonicalize_header_exposes(
    self: *Self,
    exposes: parse.IR.NodeStore.CollectionIdx,
) void {
    const collection = self.parse_ir.store.getCollection(exposes);
    const exposed_items = self.parse_ir.store.exposedItemSlice(.{ .span = collection.span });

    for (exposed_items) |exposed_idx| {
        const exposed = self.parse_ir.store.getExposedItem(exposed_idx);
        switch (exposed) {
            .lower_ident => |ident| {
                // For now, just mark that we've seen this exposed identifier
                // In a full implementation, we'd check if it's actually defined
                _ = ident;
            },
            .upper_ident => |type_name| {
                // For now, just mark that we've seen this exposed type
                // In a full implementation, we'd check if it's actually defined
                _ = type_name;
            },
            .upper_ident_star => |type_with_constructors| {
                // For now, just mark that we've seen this exposed type with constructors
                // In a full implementation, we'd check if it's actually defined and has constructors
                _ = type_with_constructors;
            },
        }
    }
}

fn bringImportIntoScope(
    self: *Self,
    import: *const parse.IR.NodeStore.Statement.Import,
) void {
    // const gpa = self.can_ir.env.gpa;

    // const import_name: []u8 = &.{}; // import.module_name_tok;
    // const shorthand: []u8 = &.{}; // import.qualifier_tok;
    // const region = Region{
    //     .start = Region.Position.zero(),
    //     .end = Region.Position.zero(),
    // };

    // const res = self.can_ir.imports.getOrInsert(gpa, import_name, shorthand);

    // if (res.was_present) {
    //     _ = self.can_ir.env.problems.append(gpa, Problem.Canonicalize.make(.{ .DuplicateImport = .{
    //         .duplicate_import_region = region,
    //     } }));
    // }

    const exposesSlice = self.parse_ir.store.exposedItemSlice(import.exposes);
    for (exposesSlice) |exposed_idx| {
        const exposed = self.parse_ir.store.getExposedItem(exposed_idx);
        switch (exposed) {
            .lower_ident => |ident| {

                // TODO handle `as` here using an Alias

                if (self.parse_ir.tokens.resolveIdentifier(ident.ident)) |ident_idx| {
                    _ = ident_idx;

                    // TODO Introduce our import

                    // _ = self.scope.levels.introduce(gpa, &self.can_ir.env.idents, .ident, .{ .scope_name = ident_idx, .ident = ident_idx });
                }
            },
            .upper_ident => |imported_type| {
                _ = imported_type;
                // const alias = Alias{
                //     .name = imported_type.name,
                //     .region = ir.env.tag_names.getRegion(imported_type.name),
                //     .is_builtin = false,
                //     .kind = .ImportedUnknown,
                // };
                // const alias_idx = ir.aliases.append(alias);
                //
                // _ = scope.levels.introduce(.alias, .{
                //     .scope_name = imported_type.name,
                //     .alias = alias_idx,
                // });
            },
            .upper_ident_star => |ident| {
                _ = ident;
            },
            // .CustomTagUnion => |custom| {
            //     const alias = Alias{
            //         .name = custom.name,
            //         .region = ir.env.tag_names.getRegion(custom.name),
            //         .is_builtin = false,
            //         .kind = .ImportedCustomUnion,
            //     };
            //     const alias_idx = ir.aliases.append(alias);
            //
            //     _ = scope.levels.introduce(.alias, .{
            //         .scope_name = custom.name,
            //         .alias = alias_idx,
            //     });
            //     _ = scope.custom_tags.fetchPutAssumeCapacity(custom.name, alias_idx);
            //     // TODO: add to scope.custom_tags
            // },
        }
    }
}

fn bringIngestedFileIntoScope(
    self: *Self,
    import: *const parse.IR.Stmt.Import,
) void {
    const res = self.can_ir.env.modules.getOrInsert(
        import.name,
        import.package_shorthand,
    );

    if (res.was_present) {
        _ = self.can_ir.env.problems.append(Problem.Canonicalize.make(.DuplicateImport{
            .duplicate_import_region = import.name_region,
        }));
    }

    // scope.introduce(self: *Scope, comptime item_kind: Level.ItemKind, ident: Ident.Idx)

    for (import.exposing.items.items) |exposed| {
        const exposed_ident = switch (exposed) {
            .Value => |ident| ident,
            .Type => |ident| ident,
            .CustomTagUnion => |custom| custom.name,
        };
        self.can_ir.env.addExposedIdentForModule(exposed_ident, res.module_idx);
        self.scope.introduce(exposed);
    }
}

fn canonicalize_decl(
    self: *Self,
    decl: parse.IR.NodeStore.Statement.Decl,
) ?CIR.Def.Idx {
    const pattern_idx = self.canonicalize_pattern(decl.pattern) orelse return null;
    const expr_idx = self.canonicalize_expr(decl.body) orelse return null;

    // Create a new type variable for this definition
    const expr_var = self.can_ir.env.types_store.fresh();

    // Create the def entry
    return self.can_ir.store.addDef(.{
        .pattern = pattern_idx,
        .pattern_region = self.parse_ir.store.getPattern(decl.pattern).to_region().toBase(),
        .expr = expr_idx,
        .expr_region = self.parse_ir.store.getExpr(decl.body).to_region().toBase(),
        .expr_var = expr_var,
        .annotation = null,
        .kind = .let,
    });
}

/// Canonicalize an expression.
pub fn canonicalize_expr(
    self: *Self,
    expr_idx: parse.IR.NodeStore.ExprIdx,
) ?CIR.Expr.Idx {
    const expr = self.parse_ir.store.getExpr(expr_idx);
    switch (expr) {
        .apply => |e| {
            // Mark the start of scratch expressions
            const scratch_top = self.can_ir.store.scratchExprTop();

            // Canonicalize the function being called and add as first element
            const fn_expr = self.canonicalize_expr(e.@"fn") orelse {
                self.can_ir.store.clearScratchExprsFrom(scratch_top);
                return null;
            };
            self.can_ir.store.addScratchExpr(fn_expr);

            // Canonicalize and add all arguments
            const args_slice = self.parse_ir.store.exprSlice(e.args);
            for (args_slice) |arg| {
                if (self.canonicalize_expr(arg)) |canonicalized_arg| {
                    self.can_ir.store.addScratchExpr(canonicalized_arg);
                }
            }

            // Create span from scratch expressions
            const args_span = self.can_ir.store.exprSpanFrom(scratch_top);

            // Create the call expression
            const call_expr = CIR.Expr{
                .call = .{
                    .args = args_span,
                },
            };

            return self.can_ir.store.addExpr(.{
                .expr = call_expr,
                .region = e.region.toBase(),
            });
        },
        .ident => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.token)) |ident| {
                if (self.scope.levels.lookup(&self.can_ir.env.idents, .ident, ident)) |pattern_idx| {
                    // We found the ident in scope, lookup to reference the pattern
                    return self.can_ir.store.addExpr(
                        CIR.ExprAtRegion{
                            .expr = .{ .lookup = .{ .pattern_idx = pattern_idx } },
                            .region = e.region.toBase(),
                        },
                    );
                } else {
                    // We did not find the ident in scope
                    return self.can_ir.pushMalformed(CIR.Expr.Idx, .ident_not_in_scope, e.region.toBase());
                }
            } else {
                self.can_ir.env.pushProblem(Problem.Compiler.can(.unable_to_resolve_identifier));
                return null;
            }
        },
        .int => |e| {
            // resolve to a string slice from the source
            const token_text = self.parse_ir.resolve(e.token);

            // intern the string slice
            const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, token_text);

            // parse the integer value
            const value = std.fmt.parseInt(i128, token_text, 10) catch {

                // Invalid number literal
                return self.can_ir.pushMalformed(CIR.Expr.Idx, .invalid_num_literal, e.region.toBase());
            };

            const fresh_num_var = self.can_ir.env.types_store.fresh();
            const fresh_prec_var = self.can_ir.env.types_store.fresh();

            const int_expr = CIR.Expr{
                .int = .{
                    .num_var = fresh_num_var,
                    .precision_var = fresh_prec_var,
                    .literal = literal,
                    .value = CIR.IntValue{
                        .bytes = @bitCast(value),
                        .kind = .i128,
                    },
                    // TODO shouldn't this be a flex_var?
                    .bound = types.Num.Compact.Int.Precision.i128,
                },
            };

            return self.can_ir.store.addExpr(.{
                .expr = int_expr,
                .region = e.region.toBase(),
            });
        },
        .float => |e| {
            // resolve to a string slice from the source
            const token_text = self.parse_ir.resolve(e.token);

            // intern the string slice
            const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, token_text);

            // parse the float value
            const value = std.fmt.parseFloat(f64, token_text) catch {
                return self.can_ir.pushMalformed(CIR.Expr.Idx, .invalid_num_literal, e.region.toBase());
            };

            const fresh_num_var = self.can_ir.env.types_store.fresh();
            const fresh_prec_var = self.can_ir.env.types_store.fresh();

            const float_expr = CIR.Expr{
                .float = .{
                    .num_var = fresh_num_var,
                    .precision_var = fresh_prec_var,
                    .literal = literal,
                    .value = value,
                    // TODO shouldn't this be a flex_var?
                    .bound = types.Num.Compact.Frac.Precision.dec,
                },
            };

            return self.can_ir.store.addExpr(.{
                .expr = float_expr,
                .region = e.region.toBase(),
            });
        },
        .string => |e| {
            // Get all the string parts
            const parts = self.parse_ir.store.exprSlice(e.parts);

            // Extract segments from the string, inserting them into the string interner
            // For non-string interpolation segments, canonicalize them
            //
            // Returns a Expr.Span containing the canonicalized string segments
            // a string may consist of multiple string literal or expression segments
            const str_segments_span = self.extractStringSegments(parts);

            return self.can_ir.store.addExpr(.{
                .expr = CIR.Expr{ .str = str_segments_span },
                .region = e.region.toBase(),
            });
        },
        .list => |e| {
            var items = collections.SafeList(CIR.Expr.Idx).initCapacity(self.can_ir.env.gpa, 0);
            const items_slice = self.parse_ir.store.exprSlice(e.items);

            for (items_slice) |item| {
                if (self.canonicalize_expr(item)) |canonicalized| {
                    _ = items.append(self.can_ir.env.gpa, canonicalized);
                }
            }

            const fresh_type_var = self.can_ir.env.types_store.fresh();

            // Mark the start of scratch expressions for the list
            const scratch_top = self.can_ir.store.scratchExprTop();

            // Add all canonicalized items to scratch
            var iter = items.iterIndices();
            while (iter.next()) |idx| {
                self.can_ir.store.addScratchExpr(items.get(idx).*);
            }

            // Create span from scratch expressions
            const elems_span = self.can_ir.store.exprSpanFrom(scratch_top);

            const list_expr = CIR.Expr{
                .list = .{
                    .elems = elems_span,
                    .elem_var = fresh_type_var,
                },
            };

            return self.can_ir.store.addExpr(.{
                .expr = list_expr,
                .region = e.region.toBase(),
            });
        },
        .tag => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.token)) |tag_name| {
                const fresh_type_var_tag_union = self.can_ir.env.types_store.fresh();
                const fresh_type_var_ext = self.can_ir.env.types_store.fresh();

                const tag_expr = CIR.Expr{
                    .tag = .{
                        .tag_union_var = fresh_type_var_tag_union,
                        .ext_var = fresh_type_var_ext,
                        .name = tag_name,
                        .args = .{ .span = .{ .start = 0, .len = 0 } }, // empty arguments
                    },
                };

                return self.can_ir.store.addExpr(.{
                    .expr = tag_expr,
                    .region = e.region.toBase(),
                });
            } else {
                return null;
            }
        },
        .string_part => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .tuple => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .record => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .lambda => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .record_updater => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .field_access => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .local_dispatch => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .bin_op => |e| {

            // Canonicalize left and right operands
            const lhs = if (self.canonicalize_expr(e.left)) |left_expr_idx|
                left_expr_idx
            else
                self.can_ir.pushMalformed(CIR.Expr.Idx, .expr_not_canonicalized, e.region.toBase());

            const rhs = if (self.canonicalize_expr(e.right)) |right_expr_idx|
                right_expr_idx
            else
                self.can_ir.pushMalformed(CIR.Expr.Idx, .expr_not_canonicalized, e.region.toBase());

            // Get the operator token
            const op_token = self.parse_ir.tokens.tokens.get(e.operator);

            const op: CIR.Expr.Binop.Op = switch (op_token.tag) {
                .OpPlus => .add,
                .OpBinaryMinus => .sub,
                .OpStar => .mul,
                else => {
                    // Unknown operator
                    self.can_ir.env.pushProblem(Problem.Compiler.can(.unexpected_token_binop));
                    return null;
                },
            };

            return self.can_ir.store.addExpr(.{
                .expr = .{ .binop = CIR.Expr.Binop.init(op, lhs, rhs) },
                .region = e.region.toBase(),
            });
        },
        .suffix_single_question => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .unary_op => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .if_then_else => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .match => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .dbg => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .record_builder => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .ellipsis => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .block => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .malformed => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
    }
}

/// Extract string segments from parsed string parts
fn extractStringSegments(self: *Self, parts: []const parse.IR.NodeStore.ExprIdx) CIR.Expr.Span {
    const gpa = self.can_ir.env.gpa;
    const start = self.can_ir.store.scratchExprTop();

    for (parts) |part| {
        const part_node = self.parse_ir.store.getExpr(part);
        switch (part_node) {
            .string_part => |sp| {
                // get the raw text of the string part
                const part_text = self.parse_ir.resolve(sp.token);

                // intern the string in the ModuleEnv
                const string_idx = self.can_ir.env.strings.insert(gpa, part_text);

                // create a node for the string literal
                const str_expr_idx = self.can_ir.store.addExpr(CIR.ExprAtRegion{
                    .expr = .{ .str_segment = string_idx },
                    .region = part_node.to_region().toBase(),
                });

                // add the node idx to our scratch expr stack
                self.can_ir.store.addScratchExpr(str_expr_idx);
            },
            else => {

                // Any non-string-part is an interpolation
                if (self.canonicalize_expr(part)) |expr_idx| {
                    // append our interpolated expression
                    self.can_ir.store.addScratchExpr(expr_idx);
                } else {
                    // unable to canonicalize the interpolation, push a malformed node
                    const malformed_idx = self.can_ir.pushMalformed(CIR.Expr.Idx, .invalid_string_interpolation, part_node.to_region().toBase());
                    self.can_ir.store.addScratchExpr(malformed_idx);
                }
            },
        }
    }

    return self.can_ir.store.exprSpanFrom(start);
}

fn canonicalize_pattern(
    self: *Self,
    pattern_idx: parse.IR.NodeStore.PatternIdx,
) ?CIR.Pattern.Idx {
    const gpa = self.can_ir.env.gpa;
    switch (self.parse_ir.store.getPattern(pattern_idx)) {
        .ident => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.ident_tok)) |ident_idx| {

                // Push a Pattern node for our identifier
                const assign_idx = self.can_ir.store.addPattern(CIR.Pattern{ .assign = ident_idx });

                // Introduce the identifier into scope mapping to this pattern node
                self.scope.levels.introduce(
                    gpa,
                    &self.can_ir.env.idents,
                    .ident,
                    ident_idx,
                    assign_idx,
                ) catch {
                    return self.can_ir.pushMalformed(CIR.Pattern.Idx, .ident_already_in_scope, e.region.toBase());
                };

                return assign_idx;
            } else {
                self.can_ir.env.pushProblem(Problem.Compiler.can(.unable_to_resolve_identifier));
                return null;
            }
        },
        .underscore => {
            const underscore_pattern = CIR.Pattern{
                .Underscore = {},
            };

            return self.can_ir.store.addPattern(underscore_pattern);
        },
        .number => |e| {
            // resolve to a string slice from the source
            const token_text = self.parse_ir.resolve(e.number_tok);

            // intern the string slice
            const literal = self.can_ir.env.strings.insert(gpa, token_text);

            // parse the integer value
            const value = std.fmt.parseInt(i128, token_text, 10) catch {
                // Invalid num literal
                return self.can_ir.pushMalformed(CIR.Pattern.Idx, .invalid_num_literal, e.region.toBase());
            };

            const fresh_num_var = self.can_ir.env.types_store.fresh();
            const fresh_precision_var = self.can_ir.env.types_store.fresh();

            const int_pattern = CIR.Pattern{
                .int_literal = .{
                    .num_var = fresh_num_var,
                    .precision_var = fresh_precision_var,
                    .literal = literal,
                    .value = CIR.IntValue{
                        .bytes = @bitCast(value),
                        .kind = .i128,
                    },
                    // TODO shouldn't this be a flex_var?
                    .bound = types.Num.Compact.Int.Precision.i128,
                },
            };

            return self.can_ir.store.addPattern(int_pattern);
        },
        .string => |e| {
            // resolve to a string slice from the source
            const token_text = self.parse_ir.resolve(e.string_tok);

            // TODO: Handle escape sequences
            // For now, just intern the raw string
            const literal = self.can_ir.env.strings.insert(gpa, token_text);

            const str_pattern = CIR.Pattern{
                .str_literal = literal,
            };

            return self.can_ir.store.addPattern(str_pattern);
        },
        .tag => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.tag_tok)) |tag_name| {

                // TODO: handle tag arguments from e.args
                const arguments: CIR.TypedPatternAtRegion.Span = .{ .span = base.DataSpan{
                    .start = 867,
                    .len = 867,
                } };

                const fresh_num_var = self.can_ir.env.types_store.fresh();
                const fresh_ext_var = self.can_ir.env.types_store.fresh();

                const tag_pattern = CIR.Pattern{
                    .applied_tag = .{
                        .whole_var = fresh_num_var,
                        .ext_var = fresh_ext_var,
                        .tag_name = tag_name,
                        .arguments = arguments,
                    },
                };

                return self.can_ir.store.addPattern(tag_pattern);
            }
            return null;
        },
        .record => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .tuple => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .list => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .list_rest => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .alternatives => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
        .malformed => |_| {
            self.can_ir.env.pushProblem(Problem.Compiler.can(.not_implemented));
            return null;
        },
    }
    return null;
}
