const std = @import("std");
const base = @import("../base.zig");
const parse = @import("parse.zig");
const problem = @import("../problem.zig");
const collections = @import("../collections.zig");
const types = @import("../types/types.zig");

const Scope = @import("./canonicalize/Scope.zig");
const Alias = @import("./canonicalize/Alias.zig");

// Placeholder TypeVars used during canonicalization
// These will be replaced with real type variables during type checking
const PLACEHOLDER_NUM_VAR: types.Var = @enumFromInt(0);
const PLACEHOLDER_PRECISION_VAR: types.Var = @enumFromInt(0);

/// Represents a segment of a string literal that may contain interpolations
const StringSegment = union(enum) {
    plaintext: []const u8,
    interpolation: parse.IR.NodeStore.ExprIdx,
};

can_ir: *IR,
parse_ir: *parse.IR,
scope: *Scope,

const Ident = base.Ident;
const Region = base.Region;
const TagName = base.TagName;
const ModuleEnv = base.ModuleEnv;
const Problem = problem.Problem;
const exitOnOom = collections.utils.exitOnOom;

pub fn init(can_ir: *IR, parse_ir: *parse.IR, scope: *Scope) Self {
    return .{
        .can_ir = can_ir,
        .parse_ir = parse_ir,
        .scope = scope,
    };
}

const Self = @This();

/// The intermediate representation of a canonicalized Roc program.
pub const IR = @import("canonicalize/IR.zig");

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

    for (self.parse_ir.store.statementSlice(file.statements)) |stmt_id| {
        const stmt = self.parse_ir.store.getStatement(stmt_id);
        switch (stmt) {
            .import => |import| {
                self.bringImportIntoScope(&import);
            },
            .decl => |decl| {
                self.canonicalize_decl(decl);
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

    // canonicalize_header_exposes();
}

fn bringImportIntoScope(
    self: *Self,
    import: *const parse.IR.NodeStore.Statement.Import,
) void {
    // Add error for partially implemented imports
    _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedImport = .{
        .region = import.region.toBase(),
    } }));

    // const import_name: []u8 = &.{}; // import.module_name_tok;
    // const shorthand: []u8 = &.{}; // import.qualifier_tok;
    // const region = Region{
    //     .start = Region.Position.zero(),
    //     .end = Region.Position.zero(),
    // };

    // const res = self.can_ir.imports.getOrInsert(self.can_ir.env.gpa, import_name, shorthand);

    // if (res.was_present) {
    //     _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .DuplicateImport = .{
    //         .duplicate_import_region = region,
    //     } }));
    // }

    const exposesSlice = self.parse_ir.store.exposedItemSlice(import.exposes);
    for (exposesSlice) |exposed_idx| {
        const exposed = self.parse_ir.store.getExposedItem(exposed_idx);
        switch (exposed) {
            .lower_ident => |ident| {
                if (self.parse_ir.tokens.resolveIdentifier(ident.ident)) |ident_idx| {
                    if (ident.as) |as_| {
                        if (self.parse_ir.tokens.resolveIdentifier(as_)) |alias_idx| {
                            _ = self.scope.levels.introduce(.alias, .{ .scope_name = ident_idx, .alias = alias_idx });
                        }
                    } else {
                        _ = self.scope.levels.introduce(.ident, .{ .scope_name = ident_idx, .ident = ident_idx });
                    }
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

const PendingValueDef = union(enum) {
    /// A standalone annotation with no body
    AnnotationOnly: struct {
        pattern: IR.PatternAtRegion.Idx,
        type: IR.Annotation.Idx,
    },
    /// A body with no type annotation
    Body: struct {
        pattern: IR.PatternAtRegion.Idx,
        expr: IR.ExprAtRegion.Idx,
    },
    /// A body with a type annotation
    TypedBody: struct {
        // &'a Loc<ast::Pattern<'a>>,
        // Loc<Pattern>,
        // &'a Loc<ast::TypeAnnotation<'a>>,
        // &'a Loc<ast::Expr<'a>>,
    },
    /// A standalone statement
    Stmt: IR.ExprAtRegion.Idx,

    pub const List = collections.SafeList(@This());
};

fn canonicalize_decl(
    self: *Self,
    decl: parse.IR.NodeStore.Statement.Decl,
) void {
    _ = self.canonicalize_expr(decl.body);
    _ = self.canonicalize_pattern(decl.pattern);
}

/// Canonicalize an expression.
pub fn canonicalize_expr(
    self: *Self,
    expr_idx: parse.IR.NodeStore.ExprIdx,
) ?IR.Expr.Idx {
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
            const call_expr = IR.Expr{
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
                switch (self.scope.levels.lookup(.ident, ident)) {
                    .InScope, .NotInScope => {
                        // Create lookup expression even if not in scope
                        // The lookup function already recorded the problem
                        return self.can_ir.store.addExpr(.{
                            .expr = .{ .lookup = .{
                                .ident = ident,
                            } },
                            .region = e.region.toBase(),
                        });
                    },
                    .NotPresent => {
                        // Identifier doesn't exist at all - this shouldn't happen
                        // but we'll still create a lookup for robustness
                        return self.can_ir.store.addExpr(.{
                            .expr = .{ .lookup = .{
                                .ident = ident,
                            } },
                            .region = e.region.toBase(),
                        });
                    },
                }
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
                    .expr = IR.Expr{ .RuntimeError = problem_id },
                    .region = e.region.toBase(),
                });
            };

            const fresh_num_var = self.can_ir.type_store.fresh();
            const fresh_prec_var = self.can_ir.type_store.fresh();

            const int_expr = IR.Expr{
                .int = .{
                    .num_var = fresh_num_var,
                    .precision_var = fresh_prec_var,
                    .literal = literal,
                    .value = IR.IntValue{
                        .bytes = @bitCast(value),
                        .kind = .i128,
                    },
                    .bound = .flex_var,
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
                    .expr = IR.Expr{ .RuntimeError = problem_id },
                    .region = e.region.toBase(),
                });
            };

            const fresh_num_var = self.can_ir.type_store.fresh();
            const fresh_prec_var = self.can_ir.type_store.fresh();

            const float_expr = IR.Expr{
                .float = .{
                    .num_var = fresh_num_var,
                    .precision_var = fresh_prec_var,
                    .literal = literal,
                    .value = value,
                    .bound = .flex_var,
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
            var items = collections.SafeList(IR.Expr.Idx).initCapacity(self.can_ir.env.gpa, 0);
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

            const list_expr = IR.Expr{
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

                const tag_expr = IR.Expr{
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
            }
        },
        .string_part => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "string_part",
                .region = e.region.toBase(),
            } }));
        },
        .tuple => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "tuple",
                .region = e.region.toBase(),
            } }));
        },
        .record => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record",
                .region = e.region.toBase(),
            } }));
        },
        .lambda => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "lambda",
                .region = e.region.toBase(),
            } }));
        },
        .record_updater => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record_updater",
                .region = e.region.toBase(),
            } }));
        },
        .field_access => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "field_access",
                .region = e.region.toBase(),
            } }));
        },
        .local_dispatch => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "local_dispatch",
                .region = e.region.toBase(),
            } }));
        },
        .bin_op => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "bin_op",
                .region = e.region.toBase(),
            } }));
        },
        .suffix_single_question => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "suffix_single_question",
                .region = e.region.toBase(),
            } }));
        },
        .unary_op => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "unary_op",
                .region = e.region.toBase(),
            } }));
        },
        .if_then_else => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "if_then_else",
                .region = e.region.toBase(),
            } }));
        },
        .match => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "match",
                .region = e.region.toBase(),
            } }));
        },
        .dbg => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "dbg",
                .region = e.region.toBase(),
            } }));
        },
        .record_builder => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "record_builder",
                .region = e.region.toBase(),
            } }));
        },
        .ellipsis => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "ellipsis",
                .region = e.region.toBase(),
            } }));
        },
        .block => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "block",
                .region = e.region.toBase(),
            } }));
        },
        .malformed => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedExpr = .{
                .expr_type = "malformed",
                .region = e.region.toBase(),
            } }));
        },
    }
    return null;
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
fn createStringLiteral(self: *Self, text: []const u8, region: Region) IR.Expr.Idx {
    const literal = self.can_ir.env.strings.insert(self.can_ir.env.gpa, text);
    const str_expr = IR.Expr{ .str = literal };

    return self.can_ir.store.addExpr(.{
        .expr = str_expr,
        .region = region,
    });
}

/// Desugar string interpolation into Str.concat calls
fn desugarStringInterpolation(self: *Self, segments: []const StringSegment, region: Region) IR.Expr.Idx {
    if (segments.len == 0) {
        return self.createStringLiteral("", region);
    }

    // Mark the start of scratch expressions
    const scratch_top = self.can_ir.store.scratchExprTop();
    defer self.can_ir.store.clearScratchExprsFrom(scratch_top);

    // Convert segments to expressions and add to scratch
    var has_segments = false;
    for (segments) |segment| {
        const segment_expr = switch (segment) {
            .plaintext => |text| self.createStringLiteral(text, region),
            .interpolation => |expr_idx| self.canonicalize_expr(expr_idx) orelse continue,
        };
        self.can_ir.store.addScratchExpr(segment_expr);
        has_segments = true;
    }

    if (!has_segments) {
        return self.createStringLiteral("", region);
    }

    // For now, return the first segment as we don't have Str.concat yet
    // When symbol resolution is implemented, this will create nested Str.concat calls
    //
    // The desugaring would work like:
    // segments = ["Hello ", name, "!"]
    // becomes: Str.concat (Str.concat "Hello " name) "!"

    const span = self.can_ir.store.exprSpanFrom(scratch_top);
    const exprs = self.can_ir.store.exprSlice(span);
    if (exprs.len > 0) {
        return exprs[0];
    }

    return self.createStringLiteral("", region);
}

fn canonicalize_pattern(
    self: *Self,
    pattern_idx: parse.IR.NodeStore.PatternIdx,
) ?IR.Pattern.Idx {
    const pattern = self.parse_ir.store.getPattern(pattern_idx);
    const region = Region.zero(); // TODO: Implement proper pattern region retrieval

    switch (pattern) {
        .ident => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.ident_tok)) |ident| {
                // Introduce the identifier into scope
                _ = self.scope.levels.introduce(.ident, .{ .scope_name = ident, .ident = ident });

                const ident_pattern = IR.Pattern{
                    .identifier = ident,
                };

                return self.can_ir.store.addPattern(ident_pattern);
            }
        },
        .underscore => {
            const underscore_pattern = IR.Pattern{
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

            const int_pattern = IR.Pattern{
                .int_literal = .{
                    .num_var = PLACEHOLDER_NUM_VAR,
                    .precision_var = PLACEHOLDER_PRECISION_VAR,
                    .literal = literal,
                    .value = IR.IntValue{
                        .bytes = @bitCast(value),
                        .kind = .i128,
                    },
                    .bound = .flex_var,
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

            const str_pattern = IR.Pattern{
                .str_literal = literal,
            };

            return self.can_ir.store.addPattern(str_pattern);
        },
        .tag => |e| {
            if (self.parse_ir.tokens.resolveIdentifier(e.tag_tok)) |tag_name| {
                // Tag patterns are handled as applied_tag
                const tag_pattern = IR.Pattern{
                    .applied_tag = .{
                        .whole_var = PLACEHOLDER_NUM_VAR,
                        .ext_var = PLACEHOLDER_NUM_VAR,
                        .tag_name = tag_name,
                        .arguments = .{ .start = @enumFromInt(0), .end = @enumFromInt(0) }, // TODO: handle tag arguments from e.args
                    },
                };

                return self.can_ir.store.addPattern(tag_pattern);
            }
        },
        .record => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "record",
                .region = e.region.toBase(),
            } }));
        },
        .tuple => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "tuple",
                .region = e.region.toBase(),
            } }));
        },
        .list => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "list",
                .region = e.region.toBase(),
            } }));
        },
        .list_rest => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "list_rest",
                .region = e.region.toBase(),
            } }));
        },
        .alternatives => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "alternatives",
                .region = e.region.toBase(),
            } }));
        },
        .malformed => |e| {
            _ = self.can_ir.env.problems.append(self.can_ir.env.gpa, Problem.Canonicalize.make(.{ .NotYetImplementedPattern = .{
                .pattern_type = "malformed",
                .region = e.region.toBase(),
            } }));
        },
    }
    return null;
}
