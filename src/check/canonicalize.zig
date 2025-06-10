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

pub fn init(can_ir: *CIR, parse_ir: *parse.IR, scope: *Scope) Self {
    return .{
        .can_ir = can_ir,
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
                }
            },
            .@"var" => |v| {
                // Not valid at top-level
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidTopLevelStatement = .{
                    .region = v.region.toBase(),
                    .ty = .@"var",
                } }));
            },
            .expr => |expr| {
                // Not valid at top-level
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidTopLevelStatement = .{
                    .region = expr.region.toBase(),
                    .ty = .expr,
                } }));
            },
            .crash => |crash| {
                // Not valid at top-level
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidTopLevelStatement = .{
                    .region = crash.region.toBase(),
                    .ty = .crash,
                } }));
            },
            .expect => |expect| {
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpect = .{
                    .region = expect.region.toBase(),
                } }));
            },
            .@"for" => |f| {
                // Not valid at top-level
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidTopLevelStatement = .{
                    .region = f.region.toBase(),
                    .ty = .@"for",
                } }));
            },
            .@"return" => |return_stmt| {
                // Not valid at top-level
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidTopLevelStatement = .{
                    .region = return_stmt.region.toBase(),
                    .ty = .@"return",
                } }));
            },
            .type_decl => |type_decl| {
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedTypeDecl = .{
                    .region = type_decl.region.toBase(),
                } }));
            },
            .type_anno => |type_anno| {
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedTypeAnno = .{
                    .region = type_anno.region.toBase(),
                } }));
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
    const gpa = self.can_ir.env.gpa;

    // Add error for partially implemented imports
    _ = self.can_ir.env.problems.append(gpa, Problem.Canonicalize.make(.{ .NotYetImplementedImport = .{
        .region = import.region.toBase(),
    } }));

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
    const expr_var = self.can_ir.type_store.fresh();

    // Create the def entry
    return self.can_ir.store.addDef(.{
        .pattern = pattern_idx,
        .pattern_region = self.parse_ir.store.getPattern(decl.pattern).to_region().toBase(),
        .expr = expr_idx,
        .expr_region = self.parse_ir.store.getExpr(decl.body).to_region().toBase(),
        .expr_var = expr_var,
        .annotation = null,
        .kind = .Let,
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
                _ = ident;

                @panic("TODO");

                // TODO: Implement identifier resolution logic
                // switch (self.scope.levels.lookup(&self.can_ir.env.idents, .ident, ident)) {
                //     .InScope, .NotInScope => {
                //         // Create lookup expression even if not in scope
                //         // The lookup function already recorded the problem
                //         return self.can_ir.store.addExpr(.{
                //             .expr = .{ .lookup = .{
                //                 .ident = ident,
                //             } },
                //             .region = e.region.toBase(),
                //         });
                //     },
                //     .NotPresent => {
                //         // Identifier doesn't exist at all - this shouldn't happen
                //         // but we'll still create a lookup for robustness
                //         return self.can_ir.store.addExpr(.{
                //             .expr = .{ .lookup = .{
                //                 .ident = ident,
                //             } },
                //             .region = e.region.toBase(),
                //         });
                //     },
                // }
            } else {
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
                // Add problem for invalid number literal
                const problem_id = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidNumLiteral = .{
                    .region = e.region.toBase(),
                    .literal = token_text,
                } }));

                return self.can_ir.store.addExpr(.{
                    .expr = CIR.Expr{ .runtime_error = problem_id },
                    .region = e.region.toBase(),
                });
            };

            const fresh_num_var = self.can_ir.type_store.fresh();
            const fresh_prec_var = self.can_ir.type_store.fresh();

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
                // Add problem for invalid number literal
                const problem_id = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidNumLiteral = .{
                    .region = e.region.toBase(),
                    .literal = token_text,
                } }));

                return self.can_ir.store.addExpr(.{
                    .expr = CIR.Expr{ .runtime_error = problem_id },
                    .region = e.region.toBase(),
                });
            };

            const fresh_num_var = self.can_ir.type_store.fresh();
            const fresh_prec_var = self.can_ir.type_store.fresh();

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
            const parts_span = e.parts;
            const parts = self.parse_ir.store.exprSlice(parts_span);

            // Extract segments from the string
            const segments = self.extractStringSegments(parts) catch |err| exitOnOom(err);
            defer self.can_ir.env.gpa.free(segments);

            // Check if this is a simple string (no interpolation)
            if (isSimpleString(segments)) {
                // Simple string case - concatenate all plaintext segments
                const final_string = self.concatenatePlaintextSegments(segments) catch |err| exitOnOom(err);
                defer self.can_ir.env.gpa.free(final_string);

                return self.createStringLiteral(final_string, e.region.toBase());
            }

            // Handle string interpolation by desugaring to Str.concat calls
            // TODO: This requires implementing function calls in the IR first
            //
            // The desugaring transforms interpolated strings into nested Str.concat calls:
            // "Hello ${name}, welcome!" becomes:
            //   Str.concat (Str.concat "Hello " name) ", welcome!"
            //
            // For now, we'll collect all the segments and prepare for future desugaring
            return self.desugarStringInterpolation(segments, e.region.toBase());
        },
        .list => |e| {
            var items = collections.SafeList(CIR.Expr.Idx).initCapacity(self.can_ir.env.gpa, 0);
            const items_slice = self.parse_ir.store.exprSlice(e.items);

            for (items_slice) |item| {
                if (self.canonicalize_expr(item)) |canonicalized| {
                    _ = items.append(self.can_ir.env.gpa, canonicalized);
                }
            }

            const fresh_type_var = self.can_ir.type_store.fresh();

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
                const fresh_type_var_tag_union = self.can_ir.type_store.fresh();
                const fresh_type_var_ext = self.can_ir.type_store.fresh();

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
        .string_part => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "string_part",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .tuple => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "tuple",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .record => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .lambda => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "lambda",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .record_updater => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record_updater",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .field_access => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "field_access",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .local_dispatch => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "local_dispatch",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .bin_op => |e| {
            // Binary operators are desugared to function calls
            // e.g., `x + y` becomes `Num.add x y`

            // Canonicalize left and right operands
            const left_expr = self.canonicalize_expr(e.left) orelse return null;
            const right_expr = self.canonicalize_expr(e.right) orelse return null;

            // Get the operator token
            const op_token = self.parse_ir.tokens.tokens.get(e.operator);

            // Map operator to function name
            // TODO find the correct names to use here...
            const op_name = switch (op_token.tag) {
                .OpPlus => "add",
                .OpStar => "mul",
                .OpAssign => "assign",
                .OpBinaryMinus => "sub",
                .OpUnaryMinus => "neg",
                .OpNotEquals => "isNotEq",
                .OpBang => "not",
                .OpAnd => "and",
                .OpAmpersand => "bitAnd",
                .OpOr => "or",
                .OpBar => "bitOr",
                .OpDoubleSlash => "doubleSlash",
                .OpSlash => "div",
                .OpPercent => "rem",
                .OpCaret => "pow",
                .OpGreaterThanOrEq => "isGte",
                .OpGreaterThan => "isGt",
                .OpLessThanOrEq => "isLte",
                .OpLessThan => "isLt",
                .OpEquals => "isEq",
                else => return null, // Unknown operator
            };

            // Determine module prefix based on operator type
            // TODO: Use module prefix when we properly resolve operator functions
            // const module_prefix = switch (e.op) {
            //     .plus, .minus, .star, .slash, .double_slash, .percent, .caret => "Num",
            //     .greater_than, .less_than, .greater_than_or_eq, .less_than_or_eq, .double_eq, .not_eq => "Bool",
            //     .double_ampersand, .double_pipe => "Bool",
            //     .pizza, .pipe => "", // No module prefix for these
            //     else => "",
            // };

            // For now, create a simple call expression
            const scratch_top = self.can_ir.store.scratchExprTop();

            // Create the operator function lookup
            // For now, we'll create a simple identifier lookup
            const ident = Ident.for_text(op_name);
            const op_ident = self.can_ir.env.idents.insert(self.can_ir.env.gpa, ident, e.region.toBase());
            const op_lookup = self.can_ir.store.addExpr(.{
                .expr = .{ .lookup = .{ .ident = op_ident } },
                .region = e.region.toBase(),
            });

            // Add function and arguments to scratch
            self.can_ir.store.addScratchExpr(op_lookup);
            self.can_ir.store.addScratchExpr(left_expr);
            self.can_ir.store.addScratchExpr(right_expr);

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
        .suffix_single_question => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "suffix_single_question",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .unary_op => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "unary_op",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .if_then_else => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "if_then_else",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .match => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "match",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .dbg => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "dbg",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .record_builder => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record_builder",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .ellipsis => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "ellipsis",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .block => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "block",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .malformed => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "malformed",
                .region = e.region.toBase(),
            } }));
            return null;
        },
    }
}

/// Extract string segments from parsed string parts
fn extractStringSegments(self: *Self, parts: []const parse.IR.NodeStore.ExprIdx) ![]StringSegment {
    var segments = std.ArrayList(StringSegment).init(self.can_ir.env.gpa);
    defer segments.deinit();

    for (parts) |part| {
        const part_node = self.parse_ir.store.getExpr(part);
        switch (part_node) {
            .string_part => |sp| {
                const part_text = self.parse_ir.resolve(sp.token);
                try segments.append(.{ .plaintext = part_text });
            },
            else => {
                // Any non-string-part is an interpolation
                try segments.append(.{ .interpolation = part });
            },
        }
    }

    return segments.toOwnedSlice();
}

/// Check if all segments are plaintext (no interpolation)
fn isSimpleString(segments: []const StringSegment) bool {
    for (segments) |segment| {
        if (segment == .interpolation) {
            return false;
        }
    }
    return true;
}

/// Concatenate all plaintext segments into a single string
///
/// Must only be called for simple strings, caller is responsible
fn concatenatePlaintextSegments(self: *Self, segments: []const StringSegment) ![]const u8 {
    var string_builder = std.ArrayList(u8).init(self.can_ir.env.gpa);
    defer string_builder.deinit();

    for (segments) |segment| {
        switch (segment) {
            .plaintext => |text| try string_builder.appendSlice(text),
            .interpolation => unreachable,
        }
    }

    return string_builder.toOwnedSlice();
}

/// Create a string literal expression
fn createStringLiteral(self: *Self, text: []const u8, region: Region) CIR.Expr.Idx {
    const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, text);
    const str_expr = CIR.Expr{ .str = literal };

    return self.can_ir.store.addExpr(.{
        .expr = str_expr,
        .region = region,
    });
}

/// Desugar string interpolation into Str.concat calls
fn desugarStringInterpolation(self: *Self, segments: []const StringSegment, region: Region) CIR.Expr.Idx {
    if (segments.len == 0) {
        return self.createStringLiteral("", region);
    }

    // Convert segments to expressions
    var segment_exprs = std.ArrayList(CIR.Expr.Idx).init(self.can_ir.env.gpa);
    defer segment_exprs.deinit();

    for (segments) |segment| {
        const segment_expr = switch (segment) {
            .plaintext => |text| self.createStringLiteral(text, region),
            .interpolation => |expr_idx| self.canonicalize_expr(expr_idx) orelse continue,
        };
        segment_exprs.append(segment_expr) catch |err| exitOnOom(err);
    }

    if (segment_exprs.items.len == 0) {
        return self.createStringLiteral("", region);
    }

    // If there's only one segment, return it directly
    if (segment_exprs.items.len == 1) {
        return segment_exprs.items[0];
    }

    // Create the Str.concat identifier
    // TODO use a proper builtin when we have this...
    const str_concat_ident = Ident.for_text("Str.concat");
    const str_concat_idx = self.can_ir.env.idents.insert(self.can_ir.env.gpa, str_concat_ident, region);

    // Build nested Str.concat calls from left to right
    // For segments ["Hello ", name, "!"], create: Str.concat (Str.concat "Hello " name) "!"
    var result = segment_exprs.items[0];

    for (segment_exprs.items[1..]) |segment_expr| {
        // Mark the start of scratch expressions for this call
        const call_scratch_top = self.can_ir.store.scratchExprTop();

        // Create the Str.concat lookup
        const concat_fn = self.can_ir.store.addExpr(.{
            .expr = .{ .lookup = .{
                .ident = str_concat_idx,
            } },
            .region = region,
        });
        self.can_ir.store.addScratchExpr(concat_fn);

        // Add the accumulated result as first argument
        self.can_ir.store.addScratchExpr(result);

        // Add the current segment as second argument
        self.can_ir.store.addScratchExpr(segment_expr);

        // Create span from scratch expressions
        const args_span = self.can_ir.store.exprSpanFrom(call_scratch_top);

        // Create the call expression
        const call_expr = CIR.Expr{
            .call = .{
                .args = args_span,
            },
        };

        result = self.can_ir.store.addExpr(.{
            .expr = call_expr,
            .region = region,
        });
    }

    return result;
}

fn canonicalize_pattern(
    self: *Self,
    pattern_idx: parse.IR.NodeStore.PatternIdx,
) ?CIR.Pattern.Idx {
    const pattern = self.parse_ir.store.getPattern(pattern_idx);
    const region = Region.zero(); // TODO: Implement proper pattern region retrieval

    switch (pattern) {
        .ident => |e| {
            _ = e;
            // TODO
            // if (self.parse_ir.tokens.resolveIdentifier(e.ident_tok)) |ident| {
            //     // Introduce the identifier into scope
            //     _ = self.scope.levels.introduce(self.can_ir.env.gpa, &self.can_ir.env.idents, .ident, .{ .scope_name = ident, .ident = ident });

            //     const ident_pattern = CIR.Pattern{
            //         .assign = ident,
            //     };

            //     return self.can_ir.store.addPattern(ident_pattern);
            // }
            return null;
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
            const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, token_text);

            // parse the integer value
            const value = std.fmt.parseInt(i128, token_text, 10) catch {
                // Add problem for invalid number literal
                _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .InvalidNumLiteral = .{
                    .region = region,
                    .literal = token_text,
                } }));
                return null;
            };

            const fresh_num_var = self.can_ir.type_store.fresh();
            const fresh_precision_var = self.can_ir.type_store.fresh();

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
            const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, token_text);

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

                const fresh_num_var = self.can_ir.type_store.fresh();
                const fresh_ext_var = self.can_ir.type_store.fresh();

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
        .record => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "record",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .tuple => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "tuple",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .list => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "list",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .list_rest => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "list_rest",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .alternatives => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "alternatives",
                .region = e.region.toBase(),
            } }));
            return null;
        },
        .malformed => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "malformed",
                .region = e.region.toBase(),
            } }));
            return null;
        },
    }
    return null;
}

/// Represents a segment of a string literal that may contain interpolations
const StringSegment = union(enum) {
    plaintext: []const u8,
    interpolation: parse.IR.NodeStore.ExprIdx,
};
