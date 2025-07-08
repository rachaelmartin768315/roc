//! This module defines the `Statement` type, which represents all possible statement forms
//! in the Canonical Intermediate Representation (CIR) of the Roc compiler. Statements are
//! produced during the canonicalization phase, after parsing and semantic analysis, and
//! serve as the structured, type-aware building blocks for Roc program logic.
//!
//! Each variant of `Statement` corresponds to a distinct kind of Roc statement, including
//! immutable and mutable declarations, reassignments, expressions, control flow constructs
//! (such as `for`, `return`, and `crash`), imports, type declarations, and type annotations.
//!
//! The CIR `Statement` is used both at the module top level and within block expressions,
//! and is designed to support robust error recovery and diagnostics, in line with Roc's
//! "inform, don't block" compilation philosophy.

const std = @import("std");
const base = @import("../../base.zig");
const types = @import("../../types.zig");
const CIR = @import("CIR.zig");

const Region = base.Region;
const StringLiteral = base.StringLiteral;
const Ident = base.Ident;
const DataSpan = base.DataSpan;
const SExpr = base.SExpr;
const SExprTree = base.SExprTree;
const Pattern = CIR.Pattern;
const Expr = CIR.Expr;

/// A single statement - either at the top-level or within a block expression.
pub const Statement = union(enum) {
    /// A simple immutable declaration.
    ///
    /// ```roc
    /// foo = "bar"
    /// ```
    s_decl: struct {
        pattern: Pattern.Idx,
        expr: Expr.Idx,
        region: Region,
    },
    /// A rebindable declaration using the "var" keyword.
    ///
    /// Not valid at the top level of a module.
    ///
    /// ```roc
    /// var foo_ = "bar"
    /// ```
    s_var: struct {
        pattern_idx: Pattern.Idx,
        expr: Expr.Idx,
        region: Region,
    },
    /// Reassignment of a previously declared var
    ///
    /// Not valid at the top level of a module
    ///
    /// ```roc
    /// foo_ = "bar"
    /// ```
    s_reassign: struct {
        pattern_idx: Pattern.Idx,
        expr: Expr.Idx,
        region: Region,
    },
    /// The "crash" keyword instruct a runtime crash with message
    ///
    /// Not valid at the top level of a module
    ///
    /// ```roc
    /// crash "something unrecoverable happened here"
    /// ```
    s_crash: struct {
        msg: StringLiteral.Idx,
        region: Region,
    },
    /// Just an expression - usually the return value for a block
    ///
    /// Not valid at the top level of a module
    s_expr: struct {
        expr: Expr.Idx,
        region: Region,
    },
    /// An expression that will cause a panic (or some other error handling mechanism) if it evaluates to false
    /// ```roc
    /// expect [1,2,3].len() == 3
    /// ```
    s_expect: struct {
        body: Expr.Idx,
        region: Region,
    },
    /// A block of code that will be ran multiple times for each item in a list.
    ///
    /// Not valid at the top level of a module
    ///
    /// ```roc
    /// for item in [1,2,3] {
    ///     print!(item.toStr())
    /// }
    /// ```
    s_for: struct {
        patt: Pattern.Idx,
        expr: Expr.Idx,
        body: Expr.Idx,
        region: Region,
    },
    /// A early return of the enclosing function.
    ///
    /// Not valid at the top level of a module
    ///
    /// ```roc
    /// return Err(-1)
    /// ```
    s_return: struct {
        expr: Expr.Idx,
        region: Region,
    },
    /// Brings in another module for use in the current module, optionally exposing only certain members of that module.
    ///
    /// ```roc
    /// import json.Utf8 as Json
    /// ```
    s_import: struct {
        module_name_tok: Ident.Idx,
        qualifier_tok: ?Ident.Idx,
        alias_tok: ?Ident.Idx,
        exposes: CIR.ExposedItem.Span,
        region: Region,
    },
    /// An alias type declaration, e.g., `Foo : Str`
    ///
    /// Only valid at the top level of a module
    s_alias_decl: struct {
        header: CIR.TypeHeader.Idx,
        anno: CIR.TypeAnno.Idx,
        anno_var: types.Var,
        where: ?CIR.WhereClause.Span,
        region: Region,
    },
    /// A nominal type declaration, e.g., `Foo := (U64, Str)`
    ///
    /// Only valid at the top level of a module
    s_nominal_decl: struct {
        header: CIR.TypeHeader.Idx,
        anno: CIR.TypeAnno.Idx,
        anno_var: types.Var,
        where: ?CIR.WhereClause.Span,
        region: Region,
    },
    /// A type annotation, declaring that the value referred to by an ident in the same scope should be a given type.
    ///
    /// ```roc
    /// print! : Str => Result({}, [IOErr])
    /// ```
    s_type_anno: struct {
        name: Ident.Idx,
        anno: CIR.TypeAnno.Idx,
        where: ?CIR.WhereClause.Span,
        region: Region,
    },

    pub const Idx = enum(u32) { _ };
    pub const Span = struct { span: DataSpan };

    pub fn toSExpr(self: *const @This(), ir: *const CIR) SExpr {
        const gpa = ir.env.gpa;
        switch (self.*) {
            .s_decl => |d| {
                var node = SExpr.init(gpa, "s-let");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, d.region);

                var pattern_node = ir.store.getPattern(d.pattern).toSExpr(ir, d.pattern);
                node.appendNode(gpa, &pattern_node);

                var expr_node = ir.store.getExpr(d.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                return node;
            },
            .s_var => |v| {
                var node = SExpr.init(gpa, "s-var");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, v.region);

                var pattern_node = ir.store.getPattern(v.pattern_idx).toSExpr(ir, v.pattern_idx);
                node.appendNode(gpa, &pattern_node);

                var expr_node = ir.store.getExpr(v.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                return node;
            },
            .s_reassign => |r| {
                var node = SExpr.init(gpa, "s-reassign");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, r.region);

                var pattern_node = ir.store.getPattern(r.pattern_idx).toSExpr(ir, r.pattern_idx);
                node.appendNode(gpa, &pattern_node);

                var expr_node = ir.store.getExpr(r.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                return node;
            },
            .s_crash => |c| {
                var node = SExpr.init(gpa, "s-crash");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, c.region);
                node.appendStringAttr(gpa, "msg", ir.env.strings.get(c.msg));
                return node;
            },
            .s_expr => |s| {
                var node = SExpr.init(gpa, "s-expr");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                var expr_node = ir.store.getExpr(s.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                return node;
            },
            .s_expect => |s| {
                var node = SExpr.init(gpa, "s-expect");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                var body_node = ir.store.getExpr(s.body).toSExpr(ir);
                node.appendNode(gpa, &body_node);

                return node;
            },
            .s_for => |s| {
                var node = SExpr.init(gpa, "s-for");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                var pattern_node = ir.store.getPattern(s.patt).toSExpr(ir, s.patt);
                node.appendNode(gpa, &pattern_node);

                var expr_node = ir.store.getExpr(s.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                var body_node = ir.store.getExpr(s.body).toSExpr(ir);
                node.appendNode(gpa, &body_node);

                return node;
            },
            .s_return => |s| {
                var node = SExpr.init(gpa, "s-return");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                var expr_node = ir.store.getExpr(s.expr).toSExpr(ir);
                node.appendNode(gpa, &expr_node);

                return node;
            },
            .s_import => |s| {
                var node = SExpr.init(gpa, "s-import");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                node.appendStringAttr(gpa, "module", ir.env.idents.getText(s.module_name_tok));

                if (s.qualifier_tok) |qualifier| {
                    node.appendStringAttr(gpa, "qualifier", ir.getIdentText(qualifier));
                }

                if (s.alias_tok) |alias| {
                    node.appendStringAttr(gpa, "alias", ir.getIdentText(alias));
                }

                var exposes_node = SExpr.init(gpa, "exposes");
                const exposes_slice = ir.store.sliceExposedItems(s.exposes);
                for (exposes_slice) |exposed_idx| {
                    const exposed_sexpr = ir.store.getExposedItem(exposed_idx).toSExpr(ir);
                    exposes_node.appendNode(gpa, &exposed_sexpr);
                }
                node.appendNode(gpa, &exposes_node);

                return node;
            },
            .s_alias_decl => |s| {
                var node = SExpr.init(gpa, "s-alias-decl");
                node.appendRegion(gpa, ir.calcRegionInfo(s.region));

                // Add the type header
                var header_node = ir.store.getTypeHeader(s.header).toSExpr(ir);
                node.appendNode(gpa, &header_node);

                // Add the type annotation
                var anno_node = ir.store.getTypeAnno(s.anno).toSExpr(ir);
                node.appendNode(gpa, &anno_node);

                // Add where clause if present
                if (s.where) |where_span| {
                    var where_node = SExpr.init(gpa, "where");
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        var clause_child = clause.toSExpr(ir);
                        where_node.appendNode(gpa, &clause_child);
                    }
                    node.appendNode(gpa, &where_node);
                }

                return node;
            },
            .s_nominal_decl => |s| {
                var node = SExpr.init(gpa, "s-nominal-decl");
                node.appendRegion(gpa, ir.calcRegionInfo(s.region));

                // Add the type header
                var header_node = ir.store.getTypeHeader(s.header).toSExpr(ir);
                node.appendNode(gpa, &header_node);

                // Add the type annotation
                var anno_node = ir.store.getTypeAnno(s.anno).toSExpr(ir);
                node.appendNode(gpa, &anno_node);

                // Add where clause if present
                if (s.where) |where_span| {
                    var where_node = SExpr.init(gpa, "where");
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        var clause_child = clause.toSExpr(ir);
                        where_node.appendNode(gpa, &clause_child);
                    }
                    node.appendNode(gpa, &where_node);
                }

                return node;
            },
            .s_type_anno => |s| {
                var node = SExpr.init(gpa, "s-type-anno");
                ir.appendRegionInfoToSexprNodeFromRegion(&node, s.region);

                node.appendStringAttr(gpa, "name", ir.getIdentText(s.name));

                var anno_node = ir.store.getTypeAnno(s.anno).toSExpr(ir);
                node.appendNode(gpa, &anno_node);

                if (s.where) |where_span| {
                    var where_node = SExpr.init(gpa, "where");
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        var clause_child = clause.toSExpr(ir);
                        where_node.appendNode(gpa, &clause_child);
                    }
                    node.appendNode(gpa, &where_node);
                }

                return node;
            },
        }
    }

    pub fn pushToSExprTree(self: *const @This(), ir: *const CIR, tree: *SExprTree) void {
        switch (self.*) {
            .s_decl => |d| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-let");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, d.region);
                const attrs = tree.beginNode();

                ir.store.getPattern(d.pattern).pushToSExprTree(ir, tree, d.pattern, null);
                ir.store.getExpr(d.expr).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_var => |v| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-var");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, v.region);
                const attrs = tree.beginNode();

                ir.store.getPattern(v.pattern_idx).pushToSExprTree(ir, tree, v.pattern_idx, null);
                ir.store.getExpr(v.expr).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_reassign => |r| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-reassign");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, r.region);
                const attrs = tree.beginNode();

                ir.store.getPattern(r.pattern_idx).pushToSExprTree(ir, tree, r.pattern_idx, null);
                ir.store.getExpr(r.expr).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_crash => |c| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-crash");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, c.region);
                tree.pushStringPair("msg", ir.env.strings.get(c.msg));
                const attrs = tree.beginNode();
                tree.endNode(begin, attrs);
            },
            .s_expr => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-expr");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getExpr(s.expr).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_expect => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-expect");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getExpr(s.body).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_for => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-for");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getPattern(s.patt).pushToSExprTree(ir, tree, s.patt, null);
                ir.store.getExpr(s.expr).pushToSExprTree(ir, tree);
                ir.store.getExpr(s.body).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_return => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-return");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getExpr(s.expr).pushToSExprTree(ir, tree);

                tree.endNode(begin, attrs);
            },
            .s_import => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-import");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                tree.pushStringPair("module", ir.env.idents.getText(s.module_name_tok));

                if (s.qualifier_tok) |qualifier| {
                    tree.pushStringPair("qualifier", ir.getIdentText(qualifier));
                }

                if (s.alias_tok) |alias| {
                    tree.pushStringPair("alias", ir.getIdentText(alias));
                }

                const attrs = tree.beginNode();

                const exposes_begin = tree.beginNode();
                tree.pushStaticAtom("exposes");
                const exposes_attrs = tree.beginNode();
                const exposes_slice = ir.store.sliceExposedItems(s.exposes);
                for (exposes_slice) |exposed_idx| {
                    ir.store.getExposedItem(exposed_idx).pushToSExprTree(ir.env, ir, tree);
                }
                tree.endNode(exposes_begin, exposes_attrs);

                tree.endNode(begin, attrs);
            },
            .s_alias_decl => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-alias-decl");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getTypeHeader(s.header).pushToSExprTree(ir, tree);
                ir.store.getTypeAnno(s.anno).pushToSExprTree(ir, tree);

                if (s.where) |where_span| {
                    const where_begin = tree.beginNode();
                    tree.pushStaticAtom("where");
                    const where_attrs = tree.beginNode();
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        clause.pushToSExprTree(ir, tree);
                    }
                    tree.endNode(where_begin, where_attrs);
                }

                tree.endNode(begin, attrs);
            },
            .s_nominal_decl => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-nominal-decl");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                const attrs = tree.beginNode();

                ir.store.getTypeHeader(s.header).pushToSExprTree(ir, tree);
                ir.store.getTypeAnno(s.anno).pushToSExprTree(ir, tree);

                if (s.where) |where_span| {
                    const where_begin = tree.beginNode();
                    tree.pushStaticAtom("where");
                    const where_attrs = tree.beginNode();
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        clause.pushToSExprTree(ir, tree);
                    }
                    tree.endNode(where_begin, where_attrs);
                }

                tree.endNode(begin, attrs);
            },
            .s_type_anno => |s| {
                const begin = tree.beginNode();
                tree.pushStaticAtom("s-type-anno");
                ir.appendRegionInfoToSExprTreeFromRegion(tree, s.region);
                tree.pushStringPair("name", ir.getIdentText(s.name));
                const attrs = tree.beginNode();

                ir.store.getTypeAnno(s.anno).pushToSExprTree(ir, tree);

                if (s.where) |where_span| {
                    const where_begin = tree.beginNode();
                    tree.pushStaticAtom("where");
                    const where_attrs = tree.beginNode();
                    const where_clauses = ir.store.sliceWhereClauses(where_span);
                    for (where_clauses) |clause_idx| {
                        const clause = ir.store.getWhereClause(clause_idx);
                        clause.pushToSExprTree(ir, tree);
                    }
                    tree.endNode(where_begin, where_attrs);
                }

                tree.endNode(begin, attrs);
            },
        }
    }

    /// Extract the region from any Statement variant
    pub fn toRegion(self: *const @This()) Region {
        switch (self.*) {
            .s_decl => |s| return s.region,
            .s_var => |s| return s.region,
            .s_reassign => |s| return s.region,
            .s_crash => |s| return s.region,
            .s_expr => |s| return s.region,
            .s_expect => |s| return s.region,
            .s_for => |s| return s.region,
            .s_return => |s| return s.region,
            .s_import => |s| return s.region,
            .s_alias_decl => |s| return s.region,
            .s_nominal_decl => |s| return s.region,
            .s_type_anno => |s| return s.region,
        }
    }
};
