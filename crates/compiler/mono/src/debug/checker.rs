//! Type-checking of the generated [ir][crate::ir::Proc].

use bumpalo::Bump;
use roc_collections::{MutMap, VecMap, VecSet};
use roc_module::symbol::Symbol;

use crate::{
    ir::{
        Call, CallSpecId, CallType, Expr, HigherOrderLowLevel, JoinPointId, ListLiteralElement,
        ModifyRc, Param, Proc, ProcLayout, Stmt,
    },
    layout::{
        Builtin, InLayout, LambdaSet, Layout, LayoutInterner, STLayoutInterner, TagIdIntType,
        UnionLayout,
    },
};

pub enum UseKind {
    Ret,
    TagExpr,
    TagReuse,
    TagPayloadArg,
    ListElemExpr,
    CallArg,
    JumpArg,
    CrashArg,
    SwitchCond,
    ExpectCond,
    ExpectLookup,
}

pub enum ProblemKind<'a> {
    RedefinedSymbol {
        symbol: Symbol,
        old_line: usize,
    },
    NoSymbolInScope {
        symbol: Symbol,
    },
    SymbolUseMismatch {
        symbol: Symbol,
        def_layout: InLayout<'a>,
        def_line: usize,
        use_layout: InLayout<'a>,
        use_kind: UseKind,
    },
    SymbolDefMismatch {
        symbol: Symbol,
        def_layout: InLayout<'a>,
        expr_layout: InLayout<'a>,
    },
    BadSwitchConditionLayout {
        found_layout: InLayout<'a>,
    },
    DuplicateSwitchBranch {},
    RedefinedJoinPoint {
        id: JoinPointId,
        old_line: usize,
    },
    NoJoinPoint {
        id: JoinPointId,
    },
    JumpArityMismatch {
        def_line: usize,
        num_needed: usize,
        num_given: usize,
    },
    CallingUndefinedProc {
        symbol: Symbol,
        proc_layout: ProcLayout<'a>,
        similar: Vec<ProcLayout<'a>>,
    },
    DuplicateCallSpecId {
        old_call_line: usize,
    },
    StructIndexOOB {
        structure: Symbol,
        def_line: usize,
        index: u64,
        size: usize,
    },
    NotAStruct {
        structure: Symbol,
        def_line: usize,
    },
    IndexingTagIdNotInUnion {
        structure: Symbol,
        def_line: usize,
        tag_id: u16,
        union_layout: UnionLayout<'a>,
    },
    TagUnionStructIndexOOB {
        structure: Symbol,
        def_line: usize,
        tag_id: u16,
        index: u64,
        size: usize,
    },
    IndexIntoNullableTag {
        structure: Symbol,
        def_line: usize,
        tag_id: u16,
        union_layout: UnionLayout<'a>,
    },
    UnboxNotABox {
        symbol: Symbol,
        def_line: usize,
    },
    CreatingTagIdNotInUnion {
        tag_id: u16,
        union_layout: UnionLayout<'a>,
    },
    CreateTagPayloadMismatch {
        num_needed: usize,
        num_given: usize,
    },
}

pub struct Problem<'a> {
    pub proc: &'a Proc<'a>,
    pub proc_layout: ProcLayout<'a>,
    pub line: usize,
    pub kind: ProblemKind<'a>,
}

type Procs<'a> = MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>;
pub struct Problems<'a>(pub(crate) Vec<Problem<'a>>);

impl<'a> Problems<'a> {
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

pub fn check_procs<'a>(
    arena: &'a Bump,
    interner: &mut STLayoutInterner<'a>,
    procs: &Procs<'a>,
) -> Problems<'a> {
    let mut problems = Default::default();

    for ((_, proc_layout), proc) in procs.iter() {
        let mut ctx = Ctx {
            arena,
            interner,
            proc,
            proc_layout: *proc_layout,
            ret_layout: proc.ret_layout,
            problems: &mut problems,
            call_spec_ids: Default::default(),
            procs,
            venv: Default::default(),
            joinpoints: Default::default(),
            line: 0,
        };
        ctx.check_proc(proc);
    }

    Problems(problems)
}

type VEnv<'a> = VecMap<Symbol, (usize, InLayout<'a>)>;
type JoinPoints<'a> = VecMap<JoinPointId, (usize, &'a [Param<'a>])>;
type CallSpecIds = VecMap<CallSpecId, usize>;
struct Ctx<'a, 'r> {
    arena: &'a Bump,
    interner: &'r mut STLayoutInterner<'a>,
    problems: &'r mut Vec<Problem<'a>>,
    proc: &'r Proc<'a>,
    proc_layout: ProcLayout<'a>,
    procs: &'r Procs<'a>,
    call_spec_ids: CallSpecIds,
    ret_layout: InLayout<'a>,
    venv: VEnv<'a>,
    joinpoints: JoinPoints<'a>,
    line: usize,
}

impl<'a, 'r> Ctx<'a, 'r> {
    fn problem(&mut self, problem_kind: ProblemKind<'a>) {
        self.problems.push(Problem {
            proc: self.arena.alloc(self.proc.clone()),
            proc_layout: self.proc_layout,
            line: self.line,
            kind: problem_kind,
        })
    }

    fn in_scope<T>(&mut self, f: impl FnOnce(&mut Self) -> T) -> T {
        let old_venv = self.venv.clone();
        let r = f(self);
        self.venv = old_venv;
        r
    }

    fn resolve(&mut self, mut layout: InLayout<'a>) -> InLayout<'a> {
        // Note that we are more aggressive than the usual `runtime_representation`
        // here because we need strict equality, and so cannot unwrap lambda sets
        // lazily.
        loop {
            match self.interner.get(layout) {
                Layout::LambdaSet(ls) => layout = ls.representation,
                _ => return layout,
            }
        }
    }

    fn insert(&mut self, symbol: Symbol, layout: InLayout<'a>) {
        if let Some((old_line, _)) = self.venv.insert(symbol, (self.line, layout)) {
            self.problem(ProblemKind::RedefinedSymbol { symbol, old_line })
        }
    }

    fn check_sym_exists(&mut self, symbol: Symbol) {
        if !self.venv.contains_key(&symbol) {
            self.problem(ProblemKind::NoSymbolInScope { symbol })
        }
    }

    fn with_sym_layout<T>(
        &mut self,
        symbol: Symbol,
        f: impl FnOnce(&mut Self, usize, InLayout<'a>) -> Option<T>,
    ) -> Option<T> {
        if let Some(&(def_line, layout)) = self.venv.get(&symbol) {
            f(self, def_line, layout)
        } else {
            self.problem(ProblemKind::NoSymbolInScope { symbol });
            None
        }
    }

    fn check_sym_layout(
        &mut self,
        symbol: Symbol,
        expected_layout: InLayout<'a>,
        use_kind: UseKind,
    ) {
        if let Some(&(def_line, layout)) = self.venv.get(&symbol) {
            if self.resolve(layout) != self.resolve(expected_layout) {
                self.problem(ProblemKind::SymbolUseMismatch {
                    symbol,
                    def_layout: layout,
                    def_line,
                    use_layout: expected_layout,
                    use_kind,
                });
            }
        } else {
            self.problem(ProblemKind::NoSymbolInScope { symbol })
        }
    }

    fn check_proc(&mut self, proc: &Proc<'a>) {
        for (lay, arg) in proc.args.iter() {
            self.insert(*arg, *lay);
        }

        self.check_stmt(&proc.body)
    }

    fn check_stmt(&mut self, body: &Stmt<'a>) {
        self.line += 1;

        match body {
            Stmt::Let(x, e, x_layout, rest) => {
                if let Some(e_layout) = self.check_expr(e) {
                    if self.resolve(e_layout) != self.resolve(*x_layout) {
                        self.problem(ProblemKind::SymbolDefMismatch {
                            symbol: *x,
                            def_layout: *x_layout,
                            expr_layout: e_layout,
                        })
                    }
                }
                self.insert(*x, *x_layout);
                self.check_stmt(rest);
            }
            Stmt::Switch {
                cond_symbol,
                cond_layout,
                branches,
                default_branch,
                ret_layout: _,
            } => {
                self.check_sym_layout(*cond_symbol, *cond_layout, UseKind::SwitchCond);
                let layout = self.resolve(*cond_layout);
                match self.interner.get(layout) {
                    Layout::Builtin(Builtin::Int(_)) => {}
                    Layout::Builtin(Builtin::Bool) => {}
                    _ => self.problem(ProblemKind::BadSwitchConditionLayout {
                        found_layout: *cond_layout,
                    }),
                }

                // TODO: need to adjust line numbers as we step through, and depending on whether
                // the switch is printed as true/false or a proper switch.
                let mut seen_branches = VecSet::with_capacity(branches.len());
                for (match_no, _branch_info, branch) in branches.iter() {
                    if seen_branches.insert(match_no) {
                        self.problem(ProblemKind::DuplicateSwitchBranch {});
                    }
                    self.in_scope(|ctx| ctx.check_stmt(branch));
                }
                let (_branch_info, default_branch) = default_branch;
                self.in_scope(|ctx| ctx.check_stmt(default_branch));
            }
            &Stmt::Ret(sym) => self.check_sym_layout(sym, self.ret_layout, UseKind::Ret),
            &Stmt::Refcounting(rc, rest) => {
                self.check_modify_rc(rc);
                self.check_stmt(rest);
            }
            &Stmt::Dbg { remainder, .. } => {
                self.check_stmt(remainder);
            }
            &Stmt::Expect {
                condition,
                region: _,
                lookups,
                variables: _,
                remainder,
            }
            | &Stmt::ExpectFx {
                condition,
                region: _,
                lookups,
                variables: _,
                remainder,
            } => {
                self.check_sym_layout(condition, Layout::BOOL, UseKind::ExpectCond);
                for sym in lookups.iter() {
                    self.check_sym_exists(*sym);
                }
                self.check_stmt(remainder);
            }
            &Stmt::Join {
                id,
                parameters,
                body,
                remainder,
            } => {
                if let Some((old_line, _)) = self.joinpoints.insert(id, (self.line, parameters)) {
                    self.problem(ProblemKind::RedefinedJoinPoint { id, old_line })
                }
                self.in_scope(|ctx| {
                    for Param {
                        symbol,
                        layout,
                        ownership: _,
                    } in parameters
                    {
                        ctx.insert(*symbol, *layout);
                    }
                    ctx.check_stmt(body)
                });
                self.line += 1; // `in` line
                self.check_stmt(remainder);
            }
            &Stmt::Jump(id, symbols) => {
                if let Some(&(def_line, parameters)) = self.joinpoints.get(&id) {
                    if symbols.len() != parameters.len() {
                        self.problem(ProblemKind::JumpArityMismatch {
                            def_line,
                            num_needed: parameters.len(),
                            num_given: symbols.len(),
                        });
                    }
                    for (arg, param) in symbols.iter().zip(parameters.iter()) {
                        let Param {
                            symbol: _,
                            ownership: _,
                            layout,
                        } = param;
                        self.check_sym_layout(*arg, *layout, UseKind::JumpArg);
                    }
                } else {
                    self.problem(ProblemKind::NoJoinPoint { id });
                }
            }
            &Stmt::Crash(sym, _) => self.check_sym_layout(sym, Layout::STR, UseKind::CrashArg),
        }
    }

    fn check_expr(&mut self, e: &Expr<'a>) -> Option<InLayout<'a>> {
        match e {
            Expr::Literal(_) => None,
            Expr::Call(call) => self.check_call(call),
            &Expr::Tag {
                tag_layout,
                tag_id,
                arguments,
            } => {
                self.check_tag_expr(tag_layout, tag_id, arguments);
                Some(self.interner.insert(Layout::Union(tag_layout)))
            }
            Expr::Struct(syms) => {
                for sym in syms.iter() {
                    self.check_sym_exists(*sym);
                }
                // TODO: pass the field order hash down, so we can check this
                None
            }
            &Expr::StructAtIndex {
                index,
                // TODO: pass the field order hash down, so we can check this
                field_layouts: _,
                structure,
            } => self.check_struct_at_index(structure, index),
            Expr::GetTagId {
                structure: _,
                union_layout,
            } => Some(union_layout.tag_id_layout()),
            &Expr::UnionAtIndex {
                structure,
                tag_id,
                union_layout,
                index,
            } => self.check_union_at_index(structure, union_layout, tag_id, index),
            Expr::Array { elem_layout, elems } => {
                for elem in elems.iter() {
                    match elem {
                        ListLiteralElement::Literal(_) => {}
                        ListLiteralElement::Symbol(sym) => {
                            self.check_sym_layout(*sym, *elem_layout, UseKind::ListElemExpr)
                        }
                    }
                }
                Some(
                    self.interner
                        .insert(Layout::Builtin(Builtin::List(*elem_layout))),
                )
            }
            Expr::EmptyArray => {
                // TODO don't know what the element layout is
                None
            }
            &Expr::ExprBox { symbol } => self.with_sym_layout(symbol, |ctx, _def_line, layout| {
                let inner = layout;
                Some(ctx.interner.insert(Layout::Boxed(inner)))
            }),
            &Expr::ExprUnbox { symbol } => self.with_sym_layout(symbol, |ctx, def_line, layout| {
                let layout = ctx.resolve(layout);
                match ctx.interner.get(layout) {
                    Layout::Boxed(inner) => Some(inner),
                    _ => {
                        ctx.problem(ProblemKind::UnboxNotABox { symbol, def_line });
                        None
                    }
                }
            }),
            &Expr::Reuse {
                symbol,
                update_tag_id: _,
                update_mode: _,
                tag_layout,
                tag_id: _,
                arguments: _,
            } => {
                let union = self.interner.insert(Layout::Union(tag_layout));
                self.check_sym_layout(symbol, union, UseKind::TagReuse);
                // TODO also check update arguments
                Some(union)
            }
            &Expr::Reset {
                symbol,
                update_mode: _,
            }
            | &Expr::ResetRef {
                symbol,
                update_mode: _,
            } => {
                self.check_sym_exists(symbol);
                None
            }
            Expr::RuntimeErrorFunction(_) => None,
        }
    }

    fn check_struct_at_index(&mut self, structure: Symbol, index: u64) -> Option<InLayout<'a>> {
        self.with_sym_layout(structure, |ctx, def_line, layout| {
            let layout = ctx.resolve(layout);
            match ctx.interner.get(layout) {
                Layout::Struct { field_layouts, .. } => {
                    if index as usize >= field_layouts.len() {
                        ctx.problem(ProblemKind::StructIndexOOB {
                            structure,
                            def_line,
                            index,
                            size: field_layouts.len(),
                        });
                        None
                    } else {
                        Some(field_layouts[index as usize])
                    }
                }
                _ => {
                    ctx.problem(ProblemKind::NotAStruct {
                        structure,
                        def_line,
                    });
                    None
                }
            }
        })
    }

    fn check_union_at_index(
        &mut self,
        structure: Symbol,
        union_layout: UnionLayout<'a>,
        tag_id: u16,
        index: u64,
    ) -> Option<InLayout<'a>> {
        let union = self.interner.insert(Layout::Union(union_layout));
        self.with_sym_layout(structure, |ctx, def_line, _layout| {
            ctx.check_sym_layout(structure, union, UseKind::TagExpr);

            match get_tag_id_payloads(union_layout, tag_id) {
                TagPayloads::IdNotInUnion => {
                    ctx.problem(ProblemKind::IndexingTagIdNotInUnion {
                        structure,
                        def_line,
                        tag_id,
                        union_layout,
                    });
                    None
                }
                TagPayloads::Payloads(payloads) => {
                    if index as usize >= payloads.len() {
                        ctx.problem(ProblemKind::TagUnionStructIndexOOB {
                            structure,
                            def_line,
                            tag_id,
                            index,
                            size: payloads.len(),
                        });
                        return None;
                    }
                    let layout = resolve_recursive_layout(
                        ctx.arena,
                        ctx.interner,
                        payloads[index as usize],
                        union_layout,
                    );
                    Some(layout)
                }
            }
        })
    }

    fn check_call(&mut self, call: &Call<'a>) -> Option<InLayout<'a>> {
        let Call {
            call_type,
            arguments,
        } = call;

        match call_type {
            CallType::ByName {
                name,
                ret_layout,
                arg_layouts,
                specialization_id,
            } => {
                let proc_layout = ProcLayout {
                    arguments: arg_layouts,
                    result: *ret_layout,
                    niche: name.niche(),
                };
                if !self.procs.contains_key(&(name.name(), proc_layout)) {
                    let similar = self
                        .procs
                        .keys()
                        .filter(|(sym, _)| *sym == name.name())
                        .map(|(_, lay)| *lay)
                        .collect();
                    self.problem(ProblemKind::CallingUndefinedProc {
                        symbol: name.name(),
                        proc_layout,
                        similar,
                    });
                }
                for (arg, wanted_layout) in arguments.iter().zip(arg_layouts.iter()) {
                    self.check_sym_layout(*arg, *wanted_layout, UseKind::CallArg);
                }
                if let Some(old_call_line) =
                    self.call_spec_ids.insert(*specialization_id, self.line)
                {
                    self.problem(ProblemKind::DuplicateCallSpecId { old_call_line });
                }
                Some(*ret_layout)
            }
            CallType::HigherOrder(HigherOrderLowLevel {
                op: _,
                closure_env_layout: _,
                update_mode: _,
                passed_function: _,
            }) => {
                // TODO
                None
            }
            CallType::Foreign {
                foreign_symbol: _,
                ret_layout,
            } => Some(*ret_layout),
            CallType::LowLevel {
                op: _,
                update_mode: _,
            } => None,
        }
    }

    fn check_tag_expr(&mut self, union_layout: UnionLayout<'a>, tag_id: u16, arguments: &[Symbol]) {
        match get_tag_id_payloads(union_layout, tag_id) {
            TagPayloads::IdNotInUnion => {
                self.problem(ProblemKind::CreatingTagIdNotInUnion {
                    tag_id,
                    union_layout,
                });
            }
            TagPayloads::Payloads(payloads) => {
                if arguments.len() != payloads.len() {
                    self.problem(ProblemKind::CreateTagPayloadMismatch {
                        num_needed: payloads.len(),
                        num_given: arguments.len(),
                    });
                }
                for (arg, wanted_layout) in arguments.iter().zip(payloads.iter()) {
                    let wanted_layout = resolve_recursive_layout(
                        self.arena,
                        self.interner,
                        *wanted_layout,
                        union_layout,
                    );
                    self.check_sym_layout(*arg, wanted_layout, UseKind::TagPayloadArg);
                }
            }
        }
    }

    fn check_modify_rc(&mut self, rc: ModifyRc) {
        match rc {
            ModifyRc::Inc(sym, _) | ModifyRc::Dec(sym) | ModifyRc::DecRef(sym) => {
                // TODO: also check that sym layout needs refcounting
                self.check_sym_exists(sym);
            }
        }
    }
}

fn resolve_recursive_layout<'a>(
    arena: &'a Bump,
    interner: &mut STLayoutInterner<'a>,
    layout: InLayout<'a>,
    when_recursive: UnionLayout<'a>,
) -> InLayout<'a> {
    macro_rules! go {
        ($lay:expr) => {
            resolve_recursive_layout(arena, interner, $lay, when_recursive)
        };
    }

    // TODO check if recursive pointer not in recursive union
    let layout = match interner.get(layout) {
        Layout::RecursivePointer(_) => Layout::Union(when_recursive),
        Layout::Union(union_layout) => match union_layout {
            UnionLayout::NonRecursive(payloads) => {
                let payloads = payloads.iter().map(|args| {
                    let args = args.iter().map(|lay| go!(*lay));
                    &*arena.alloc_slice_fill_iter(args)
                });
                let payloads = arena.alloc_slice_fill_iter(payloads);
                Layout::Union(UnionLayout::NonRecursive(payloads))
            }
            UnionLayout::Recursive(_)
            | UnionLayout::NonNullableUnwrapped(_)
            | UnionLayout::NullableWrapped { .. }
            | UnionLayout::NullableUnwrapped { .. } => {
                // This is the recursive layout.
                // TODO will need fixing to be modified once we support multiple
                // recursive pointers in one structure.
                return layout;
            }
        },
        Layout::Boxed(inner) => {
            let inner = go!(inner);
            Layout::Boxed(inner)
        }
        Layout::Struct {
            field_order_hash,
            field_layouts,
        } => {
            let field_layouts = field_layouts
                .iter()
                .map(|lay| resolve_recursive_layout(arena, interner, *lay, when_recursive));
            let field_layouts = arena.alloc_slice_fill_iter(field_layouts);
            Layout::Struct {
                field_order_hash,
                field_layouts,
            }
        }
        Layout::Builtin(builtin) => match builtin {
            Builtin::List(inner) => {
                let inner = resolve_recursive_layout(arena, interner, inner, when_recursive);
                Layout::Builtin(Builtin::List(inner))
            }
            Builtin::Int(_)
            | Builtin::Float(_)
            | Builtin::Bool
            | Builtin::Decimal
            | Builtin::Str => return layout,
        },
        Layout::LambdaSet(LambdaSet {
            args,
            ret,
            set,
            representation,
            full_layout,
        }) => {
            let set = set.iter().map(|(symbol, captures)| {
                let captures = captures.iter().map(|lay_in| go!(*lay_in));
                let captures = &*arena.alloc_slice_fill_iter(captures);
                (*symbol, captures)
            });
            let set = arena.alloc_slice_fill_iter(set);
            Layout::LambdaSet(LambdaSet {
                args,
                ret,
                set: arena.alloc(&*set),
                representation,
                full_layout,
            })
        }
    };

    interner.insert(layout)
}

enum TagPayloads<'a> {
    IdNotInUnion,
    Payloads(&'a [InLayout<'a>]),
}

fn get_tag_id_payloads(union_layout: UnionLayout, tag_id: TagIdIntType) -> TagPayloads {
    macro_rules! check_tag_id_oob {
        ($len:expr) => {
            if tag_id as usize >= $len {
                return TagPayloads::IdNotInUnion;
            }
        };
    }

    match union_layout {
        UnionLayout::NonRecursive(union) => {
            check_tag_id_oob!(union.len());
            let payloads = union[tag_id as usize];
            TagPayloads::Payloads(payloads)
        }
        UnionLayout::Recursive(union) => {
            check_tag_id_oob!(union.len());
            let payloads = union[tag_id as usize];
            TagPayloads::Payloads(payloads)
        }
        UnionLayout::NonNullableUnwrapped(payloads) => {
            if tag_id != 0 {
                TagPayloads::Payloads(&[])
            } else {
                TagPayloads::Payloads(payloads)
            }
        }
        UnionLayout::NullableWrapped {
            nullable_id,
            other_tags,
        } => {
            if tag_id == nullable_id {
                TagPayloads::Payloads(&[])
            } else {
                let num_tags = other_tags.len() + 1;
                check_tag_id_oob!(num_tags);

                let tag_id_idx = if tag_id > nullable_id {
                    tag_id - 1
                } else {
                    tag_id
                };
                let payloads = other_tags[tag_id_idx as usize];
                TagPayloads::Payloads(payloads)
            }
        }
        UnionLayout::NullableUnwrapped {
            nullable_id,
            other_fields,
        } => {
            if tag_id == nullable_id as _ {
                TagPayloads::Payloads(&[])
            } else {
                check_tag_id_oob!(2);
                TagPayloads::Payloads(other_fields)
            }
        }
    }
}
