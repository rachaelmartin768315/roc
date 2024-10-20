use crate::{
    foreign_symbol::ForeignSymbolId, mono_module::InternedStrId, mono_num::Number,
    mono_struct::MonoFieldId, mono_type::MonoTypeId, specialize_type::Problem,
};
use roc_can::expr::Recursive;
use roc_collections::soa::Slice;
use roc_module::low_level::LowLevel;
use roc_module::symbol::Symbol;
use soa::{Id, NonEmptySlice, Slice2, Slice3};

#[derive(Clone, Copy, Debug)]
pub struct MonoPatternId {
    inner: u32,
}

pub type IdentId = Symbol; // TODO make this an Index into an array local to this module

#[derive(Clone, Copy, Debug)]
pub struct Def {
    pub pattern: MonoPatternId,
    /// Named variables in the pattern, e.g. `a` in `Ok a ->`
    pub pattern_vars: Slice2<IdentId, MonoTypeId>,
    pub expr: MonoExprId,
    pub expr_type: MonoTypeId,
}

#[derive(Debug)]
pub struct MonoExprs {
    exprs: Vec<MonoExpr>,
}

impl MonoExprs {
    pub fn add(&mut self, expr: MonoExpr) -> MonoExprId {
        let index = self.exprs.len() as u32;
        self.exprs.push(expr);

        MonoExprId {
            inner: Id::new(index),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MonoExprId {
    inner: Id<MonoExpr>,
}

#[derive(Clone, Copy, Debug)]
pub enum MonoExpr {
    Str,
    Number(Number),
    List {
        elem_type: MonoTypeId,
        elems: Slice<MonoExprId>,
    },
    Lookup(IdentId, MonoTypeId),

    /// Like Lookup, but from a module with params
    ParameterizedLookup {
        name: IdentId,
        lookup_type: MonoTypeId,
        params_name: IdentId,
        params_type: MonoTypeId,
    },

    // Branching
    When {
        /// The actual condition of the when expression.
        cond: MonoExprId,
        cond_type: MonoTypeId,
        /// Type of each branch (and therefore the type of the entire `when` expression)
        branch_type: MonoTypeId,
        /// Note: if the branches weren't exhaustive, we will have already generated a default
        /// branch which crashes if it's reached. (The compiler will have reported an error already;
        /// this is for if you want to run anyway.)
        branches: NonEmptySlice<WhenBranch>,
    },
    If {
        /// Type of each branch (and therefore the type of the entire `if` expression)
        branch_type: MonoTypeId,
        branches: Slice<(MonoExprId, MonoExprId)>,
        final_else: Option<MonoTypeId>,
    },

    // Let
    LetRec {
        defs: Slice<Def>,
        ending_expr: MonoExprId,
    },
    LetNonRec {
        def: Def,
        ending_expr: MonoExprId,
    },

    /// This is *only* for calling functions, not for tag application.
    /// The Tag variant contains any applied values inside it.
    Call {
        fn_type: MonoTypeId,
        fn_expr: MonoExprId,
        args: Slice2<MonoTypeId, MonoExprId>,
        /// This is the type of the closure based only on canonical IR info,
        /// not considering what other closures might later influence it.
        /// Lambda set specialization may change this type later!
        closure_type: MonoTypeId,
    },
    RunLowLevel {
        op: LowLevel,
        args: Slice<(MonoTypeId, MonoExprId)>,
        ret_type: MonoTypeId,
    },
    ForeignCall {
        foreign_symbol: ForeignSymbolId,
        args: Slice<(MonoTypeId, MonoExprId)>,
        ret_type: MonoTypeId,
    },

    Lambda {
        fn_type: MonoTypeId,
        arguments: Slice<(MonoTypeId, MonoPatternId)>,
        body: MonoExprId,
        captured_symbols: Slice<(IdentId, MonoTypeId)>,
        recursive: Recursive,
    },

    /// Either a record literal or a tuple literal.
    /// Rather than storing field names, we instead store a u16 field index.
    Struct {
        struct_type: MonoTypeId,
        fields: Slice2<MonoFieldId, MonoTypeId>,
    },

    /// The "crash" keyword. Importantly, during code gen we must mark this as "nothing happens after this"
    Crash {
        msg: MonoExprId,
        /// The type of the `crash` expression (which will have unified to whatever's around it)
        expr_type: MonoTypeId,
    },

    /// Look up exactly one field on a record, tuple, or tag payload.
    /// At this point we've already unified those concepts and have
    /// converted (for example) record field names to indices, and have
    /// also dropped all fields that have no runtime representation (e.g. empty records).
    ///
    /// In a later compilation phase, these indices will be re-sorted
    /// by alignment and converted to byte offsets, but we in this
    /// phase we aren't concerned with alignment or sizes, just indices.
    StructAccess {
        record_expr: MonoExprId,
        record_type: MonoTypeId,
        field_type: MonoTypeId,
        field_id: MonoFieldId,
    },

    RecordUpdate {
        record_type: MonoTypeId,
        record_name: IdentId,
        updates: Slice2<MonoFieldId, MonoExprId>,
    },

    /// Same as BigTag but with u8 discriminant instead of u16
    SmallTag {
        discriminant: u8,
        tag_union_type: MonoTypeId,
        args: Slice2<MonoTypeId, MonoExprId>,
    },

    /// Same as SmallTag but with u16 discriminant instead of u8
    BigTag {
        discriminant: u16,
        tag_union_type: MonoTypeId,
        args: Slice2<MonoTypeId, MonoExprId>,
    },

    Expect {
        condition: MonoExprId,
        continuation: MonoExprId,
        /// If the expectation fails, we print the values of all the named variables
        /// in the final expr. These are those values.
        lookups_in_cond: Slice2<MonoTypeId, IdentId>,
    },
    Dbg {
        source_location: InternedStrId,
        source: InternedStrId,
        msg: MonoExprId,
        continuation: MonoExprId,
        expr_type: MonoTypeId,
        name: IdentId,
    },
    CompilerBug(Problem),
}

#[derive(Clone, Copy, Debug)]
pub struct WhenBranch {
    pub patterns: Slice<MonoPatternId>,
    pub body: MonoExprId,
    pub guard: Option<MonoExprId>,
}

#[derive(Clone, Copy, Debug)]
pub enum MonoPattern {
    Identifier(IdentId),
    As(MonoPatternId, IdentId),
    StrLiteral(InternedStrId),
    NumberLiteral(Number),
    AppliedTag {
        tag_union_type: MonoTypeId,
        tag_name: IdentId,
        args: Slice<MonoPatternId>,
    },
    StructDestructure {
        struct_type: MonoTypeId,
        destructs: Slice3<IdentId, MonoFieldId, DestructType>,
    },
    List {
        elem_type: MonoTypeId,
        patterns: Slice<MonoPatternId>,

        /// Where a rest pattern splits patterns before and after it, if it does at all.
        /// If present, patterns at index >= the rest index appear after the rest pattern.
        /// For example:
        ///   [ .., A, B ] -> patterns = [A, B], rest = 0
        ///   [ A, .., B ] -> patterns = [A, B], rest = 1
        ///   [ A, B, .. ] -> patterns = [A, B], rest = 2
        /// Optionally, the rest pattern can be named - e.g. `[ A, B, ..others ]`
        opt_rest: Option<(u16, Option<IdentId>)>,
    },
    Underscore,
}

#[derive(Clone, Copy, Debug)]
pub enum DestructType {
    Required,
    Optional(MonoTypeId, MonoExprId),
    Guard(MonoTypeId, MonoPatternId),
}
