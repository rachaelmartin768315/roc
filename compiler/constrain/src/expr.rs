use crate::builtins::{
    empty_list_type, float_literal, int_literal, list_type, num_literal, num_u32, str_type,
};
use crate::pattern::{constrain_pattern, PatternState};
use roc_can::annotation::IntroducedVariables;
use roc_can::constraint::{Constraint, Constraints};
use roc_can::def::{Declaration, Def};
use roc_can::expected::Expected::{self, *};
use roc_can::expected::PExpected;
use roc_can::expr::Expr::{self, *};
use roc_can::expr::{ClosureData, Field, WhenBranch};
use roc_can::pattern::Pattern;
use roc_collections::all::{HumanIndex, ImMap, MutMap, SendMap};
use roc_module::ident::{Lowercase, TagName};
use roc_module::symbol::{ModuleId, Symbol};
use roc_region::all::{Loc, Region};
use roc_types::subs::Variable;
use roc_types::types::Type::{self, *};
use roc_types::types::{AliasKind, AnnotationSource, Category, PReason, Reason, RecordField};

/// This is for constraining Defs
#[derive(Default, Debug)]
pub struct Info {
    pub vars: Vec<Variable>,
    pub constraints: Vec<Constraint>,
    pub def_types: SendMap<Symbol, Loc<Type>>,
}

impl Info {
    pub fn with_capacity(capacity: usize) -> Self {
        Info {
            vars: Vec::with_capacity(capacity),
            constraints: Vec::with_capacity(capacity),
            def_types: SendMap::default(),
        }
    }
}

pub struct Env {
    /// Whenever we encounter a user-defined type variable (a "rigid" var for short),
    /// for example `a` in the annotation `identity : a -> a`, we add it to this
    /// map so that expressions within that annotation can share these vars.
    pub rigids: MutMap<Lowercase, Variable>,
    pub home: ModuleId,
}

fn constrain_untyped_args(
    constraints: &mut Constraints,
    env: &Env,
    arguments: &[(Variable, Loc<Pattern>)],
    closure_type: Type,
    return_type: Type,
) -> (Vec<Variable>, PatternState, Type) {
    let mut vars = Vec::with_capacity(arguments.len());
    let mut pattern_types = Vec::with_capacity(arguments.len());

    let mut pattern_state = PatternState::default();

    for (pattern_var, loc_pattern) in arguments {
        let pattern_type = Type::Variable(*pattern_var);
        let pattern_expected = PExpected::NoExpectation(pattern_type.clone());

        pattern_types.push(pattern_type);

        constrain_pattern(
            constraints,
            env,
            &loc_pattern.value,
            loc_pattern.region,
            pattern_expected,
            &mut pattern_state,
        );

        vars.push(*pattern_var);
    }

    let function_type =
        Type::Function(pattern_types, Box::new(closure_type), Box::new(return_type));

    (vars, pattern_state, function_type)
}

pub fn constrain_expr(
    constraints: &mut Constraints,
    env: &Env,
    region: Region,
    expr: &Expr,
    expected: Expected<Type>,
) -> Constraint {
    match expr {
        &Int(var, precision, _, _, bound) => {
            int_literal(constraints, var, precision, expected, region, bound)
        }
        &Num(var, _, _, bound) => num_literal(constraints, var, expected, region, bound),
        &Float(var, precision, _, _, bound) => {
            float_literal(constraints, var, precision, expected, region, bound)
        }
        EmptyRecord => constrain_empty_record(constraints, region, expected),
        Expr::Record { record_var, fields } => {
            if fields.is_empty() {
                constrain_empty_record(constraints, region, expected)
            } else {
                let mut field_exprs = SendMap::default();
                let mut field_types = SendMap::default();
                let mut field_vars = Vec::with_capacity(fields.len());

                // Constraints need capacity for each field
                // + 1 for the record itself + 1 for record var
                let mut rec_constraints = Vec::with_capacity(2 + fields.len());

                for (label, field) in fields {
                    let field_var = field.var;
                    let loc_field_expr = &field.loc_expr;
                    let (field_type, field_con) =
                        constrain_field(constraints, env, field_var, &*loc_field_expr);

                    field_vars.push(field_var);
                    field_exprs.insert(label.clone(), loc_field_expr);
                    field_types.insert(label.clone(), RecordField::Required(field_type));

                    rec_constraints.push(field_con);
                }

                let record_type = Type::Record(
                    field_types,
                    // TODO can we avoid doing Box::new on every single one of these?
                    // We can put `static EMPTY_REC: Type = Type::EmptyRec`, but that requires a
                    // lifetime parameter on `Type`
                    Box::new(Type::EmptyRec),
                );
                let record_con = constraints.equal_types(
                    record_type,
                    expected.clone(),
                    Category::Record,
                    region,
                );

                rec_constraints.push(record_con);

                // variable to store in the AST
                let stored_con = constraints.equal_types(
                    Type::Variable(*record_var),
                    expected,
                    Category::Storage(std::file!(), std::line!()),
                    region,
                );

                field_vars.push(*record_var);
                rec_constraints.push(stored_con);

                let and_constraint = constraints.and_constraint(rec_constraints);
                constraints.exists(field_vars, and_constraint)
            }
        }
        Update {
            record_var,
            ext_var,
            symbol,
            updates,
        } => {
            let mut fields: SendMap<Lowercase, RecordField<Type>> = SendMap::default();
            let mut vars = Vec::with_capacity(updates.len() + 2);
            let mut cons = Vec::with_capacity(updates.len() + 1);
            for (field_name, Field { var, loc_expr, .. }) in updates.clone() {
                let (var, tipe, con) = constrain_field_update(
                    constraints,
                    env,
                    var,
                    loc_expr.region,
                    field_name.clone(),
                    &loc_expr,
                );
                fields.insert(field_name, RecordField::Required(tipe));
                vars.push(var);
                cons.push(con);
            }

            let fields_type = Type::Record(fields, Box::new(Type::Variable(*ext_var)));
            let record_type = Type::Variable(*record_var);

            // NOTE from elm compiler: fields_type is separate so that Error propagates better
            let fields_con = constraints.equal_types(
                record_type.clone(),
                NoExpectation(fields_type),
                Category::Record,
                region,
            );
            let record_con =
                constraints.equal_types(record_type.clone(), expected, Category::Record, region);

            vars.push(*record_var);
            vars.push(*ext_var);

            let con = constraints.lookup(
                *symbol,
                ForReason(
                    Reason::RecordUpdateKeys(
                        *symbol,
                        updates
                            .iter()
                            .map(|(key, field)| (key.clone(), field.region))
                            .collect(),
                    ),
                    record_type,
                    region,
                ),
                region,
            );

            // ensure constraints are solved in this order, gives better errors
            cons.insert(0, fields_con);
            cons.insert(1, con);
            cons.insert(2, record_con);

            let and_constraint = constraints.and_constraint(cons);
            constraints.exists(vars, and_constraint)
        }
        Str(_) => constraints.equal_types(str_type(), expected, Category::Str, region),
        SingleQuote(_) => constraints.equal_types(num_u32(), expected, Category::Character, region),
        List {
            elem_var,
            loc_elems,
        } => {
            if loc_elems.is_empty() {
                let eq = constraints.equal_types(
                    empty_list_type(*elem_var),
                    expected,
                    Category::List,
                    region,
                );
                constraints.exists(vec![*elem_var], eq)
            } else {
                let list_elem_type = Type::Variable(*elem_var);
                let mut list_constraints = Vec::with_capacity(1 + loc_elems.len());

                for (index, loc_elem) in loc_elems.iter().enumerate() {
                    let elem_expected = ForReason(
                        Reason::ElemInList {
                            index: HumanIndex::zero_based(index),
                        },
                        list_elem_type.clone(),
                        loc_elem.region,
                    );
                    let constraint = constrain_expr(
                        constraints,
                        env,
                        loc_elem.region,
                        &loc_elem.value,
                        elem_expected,
                    );

                    list_constraints.push(constraint);
                }

                list_constraints.push(constraints.equal_types(
                    list_type(list_elem_type),
                    expected,
                    Category::List,
                    region,
                ));

                let and_constraint = constraints.and_constraint(list_constraints);
                constraints.exists([*elem_var], and_constraint)
            }
        }
        Call(boxed, loc_args, called_via) => {
            let (fn_var, loc_fn, closure_var, ret_var) = &**boxed;
            // The expression that evaluates to the function being called, e.g. `foo` in
            // (foo) bar baz
            let opt_symbol = if let Var(symbol) = loc_fn.value {
                Some(symbol)
            } else {
                None
            };

            let fn_type = Variable(*fn_var);
            let fn_region = loc_fn.region;
            let fn_expected = NoExpectation(fn_type.clone());

            let fn_reason = Reason::FnCall {
                name: opt_symbol,
                arity: loc_args.len() as u8,
            };

            let fn_con =
                constrain_expr(constraints, env, loc_fn.region, &loc_fn.value, fn_expected);

            // The function's return type
            let ret_type = Variable(*ret_var);

            // type of values captured in the closure
            let closure_type = Variable(*closure_var);

            // This will be used in the occurs check
            let mut vars = Vec::with_capacity(2 + loc_args.len());

            vars.push(*fn_var);
            vars.push(*ret_var);
            vars.push(*closure_var);

            let mut arg_types = Vec::with_capacity(loc_args.len());
            let mut arg_cons = Vec::with_capacity(loc_args.len());

            for (index, (arg_var, loc_arg)) in loc_args.iter().enumerate() {
                let region = loc_arg.region;
                let arg_type = Variable(*arg_var);

                let reason = Reason::FnArg {
                    name: opt_symbol,
                    arg_index: HumanIndex::zero_based(index),
                };
                let expected_arg = ForReason(reason, arg_type.clone(), region);
                let arg_con = constrain_expr(
                    constraints,
                    env,
                    loc_arg.region,
                    &loc_arg.value,
                    expected_arg,
                );

                vars.push(*arg_var);
                arg_types.push(arg_type);
                arg_cons.push(arg_con);
            }

            let expected_fn_type = ForReason(
                fn_reason,
                Function(
                    arg_types,
                    Box::new(closure_type),
                    Box::new(ret_type.clone()),
                ),
                region,
            );

            let category = Category::CallResult(opt_symbol, *called_via);

            let and_cons = [
                fn_con,
                constraints.equal_types(fn_type, expected_fn_type, category.clone(), fn_region),
                constraints.and_constraint(arg_cons),
                constraints.equal_types(ret_type, expected, category, region),
            ];

            let and_constraint = constraints.and_constraint(and_cons);
            constraints.exists(vars, and_constraint)
        }
        Var(symbol) => {
            // make lookup constraint to lookup this symbol's type in the environment
            constraints.lookup(*symbol, expected, region)
        }
        Closure(ClosureData {
            function_type: fn_var,
            closure_type: closure_var,
            closure_ext_var,
            return_type: ret_var,
            arguments,
            loc_body: boxed,
            captured_symbols,
            name,
            ..
        }) => {
            // NOTE defs are treated somewhere else!
            let loc_body_expr = &**boxed;

            let ret_var = *ret_var;
            let closure_var = *closure_var;
            let closure_ext_var = *closure_ext_var;

            let closure_type = Type::Variable(closure_var);
            let return_type = Type::Variable(ret_var);
            let (mut vars, pattern_state, function_type) = constrain_untyped_args(
                constraints,
                env,
                arguments,
                closure_type,
                return_type.clone(),
            );

            vars.push(ret_var);
            vars.push(closure_var);
            vars.push(closure_ext_var);
            vars.push(*fn_var);

            let body_type = NoExpectation(return_type);
            let ret_constraint = constrain_expr(
                constraints,
                env,
                loc_body_expr.region,
                &loc_body_expr.value,
                body_type,
            );

            // make sure the captured symbols are sorted!
            debug_assert_eq!(captured_symbols.clone(), {
                let mut copy = captured_symbols.clone();
                copy.sort();
                copy
            });

            let closure_constraint = constrain_closure_size(
                constraints,
                *name,
                region,
                captured_symbols,
                closure_var,
                closure_ext_var,
                &mut vars,
            );

            let pattern_state_constraints = constraints.and_constraint(pattern_state.constraints);
            let cons = [
                constraints.let_constraint(
                    [],
                    pattern_state.vars,
                    pattern_state.headers,
                    pattern_state_constraints,
                    ret_constraint,
                ),
                // "the closure's type is equal to expected type"
                constraints.equal_types(function_type.clone(), expected, Category::Lambda, region),
                // "fn_var is equal to the closure's type" - fn_var is used in code gen
                constraints.equal_types(
                    Type::Variable(*fn_var),
                    NoExpectation(function_type),
                    Category::Storage(std::file!(), std::line!()),
                    region,
                ),
                closure_constraint,
            ];

            constraints.exists_many(vars, cons)
        }

        Expect(loc_cond, continuation) => {
            let expect_bool = |region| {
                let bool_type = Type::Variable(Variable::BOOL);
                Expected::ForReason(Reason::ExpectCondition, bool_type, region)
            };

            let cond_con = constrain_expr(
                constraints,
                env,
                loc_cond.region,
                &loc_cond.value,
                expect_bool(loc_cond.region),
            );

            let continuation_con = constrain_expr(
                constraints,
                env,
                continuation.region,
                &continuation.value,
                expected,
            );

            constraints.exists_many([], [cond_con, continuation_con])
        }

        If {
            cond_var,
            branch_var,
            branches,
            final_else,
        } => {
            let expect_bool = |region| {
                let bool_type = Type::Variable(Variable::BOOL);
                Expected::ForReason(Reason::IfCondition, bool_type, region)
            };
            let mut branch_cons = Vec::with_capacity(2 * branches.len() + 3);

            // TODO why does this cond var exist? is it for error messages?
            let first_cond_region = branches[0].0.region;
            let cond_var_is_bool_con = constraints.equal_types(
                Type::Variable(*cond_var),
                expect_bool(first_cond_region),
                Category::If,
                first_cond_region,
            );

            branch_cons.push(cond_var_is_bool_con);

            match expected {
                FromAnnotation(name, arity, ann_source, tipe) => {
                    let num_branches = branches.len() + 1;
                    for (index, (loc_cond, loc_body)) in branches.iter().enumerate() {
                        let cond_con = constrain_expr(
                            constraints,
                            env,
                            loc_cond.region,
                            &loc_cond.value,
                            expect_bool(loc_cond.region),
                        );

                        let then_con = constrain_expr(
                            constraints,
                            env,
                            loc_body.region,
                            &loc_body.value,
                            FromAnnotation(
                                name.clone(),
                                arity,
                                AnnotationSource::TypedIfBranch {
                                    index: HumanIndex::zero_based(index),
                                    num_branches,
                                    region: ann_source.region(),
                                },
                                tipe.clone(),
                            ),
                        );

                        branch_cons.push(cond_con);
                        branch_cons.push(then_con);
                    }

                    let else_con = constrain_expr(
                        constraints,
                        env,
                        final_else.region,
                        &final_else.value,
                        FromAnnotation(
                            name,
                            arity,
                            AnnotationSource::TypedIfBranch {
                                index: HumanIndex::zero_based(branches.len()),
                                num_branches,
                                region: ann_source.region(),
                            },
                            tipe.clone(),
                        ),
                    );

                    let ast_con = constraints.equal_types(
                        Type::Variable(*branch_var),
                        NoExpectation(tipe),
                        Category::Storage(std::file!(), std::line!()),
                        region,
                    );

                    branch_cons.push(ast_con);
                    branch_cons.push(else_con);

                    constraints.exists_many([*cond_var, *branch_var], branch_cons)
                }
                _ => {
                    for (index, (loc_cond, loc_body)) in branches.iter().enumerate() {
                        let cond_con = constrain_expr(
                            constraints,
                            env,
                            loc_cond.region,
                            &loc_cond.value,
                            expect_bool(loc_cond.region),
                        );

                        let then_con = constrain_expr(
                            constraints,
                            env,
                            loc_body.region,
                            &loc_body.value,
                            ForReason(
                                Reason::IfBranch {
                                    index: HumanIndex::zero_based(index),
                                    total_branches: branches.len(),
                                },
                                Type::Variable(*branch_var),
                                loc_body.region,
                            ),
                        );

                        branch_cons.push(cond_con);
                        branch_cons.push(then_con);
                    }
                    let else_con = constrain_expr(
                        constraints,
                        env,
                        final_else.region,
                        &final_else.value,
                        ForReason(
                            Reason::IfBranch {
                                index: HumanIndex::zero_based(branches.len()),
                                total_branches: branches.len() + 1,
                            },
                            Type::Variable(*branch_var),
                            final_else.region,
                        ),
                    );

                    branch_cons.push(constraints.equal_types(
                        Type::Variable(*branch_var),
                        expected,
                        Category::Storage(std::file!(), std::line!()),
                        region,
                    ));
                    branch_cons.push(else_con);

                    constraints.exists_many([*cond_var, *branch_var], branch_cons)
                }
            }
        }
        When {
            cond_var,
            expr_var,
            loc_cond,
            branches,
            ..
        } => {
            // Infer the condition expression's type.
            let cond_var = *cond_var;
            let cond_type = Variable(cond_var);
            let expr_con = constrain_expr(
                constraints,
                env,
                region,
                &loc_cond.value,
                NoExpectation(cond_type.clone()),
            );

            let mut branch_constraints = Vec::with_capacity(branches.len() + 1);
            branch_constraints.push(expr_con);

            match &expected {
                FromAnnotation(name, arity, ann_source, _typ) => {
                    // NOTE deviation from elm.
                    //
                    // in elm, `_typ` is used, but because we have this `expr_var` too
                    // and need to constrain it, this is what works and gives better error messages
                    let typ = Type::Variable(*expr_var);

                    for (index, when_branch) in branches.iter().enumerate() {
                        let pattern_region =
                            Region::across_all(when_branch.patterns.iter().map(|v| &v.region));

                        let branch_con = constrain_when_branch(
                            constraints,
                            env,
                            when_branch.value.region,
                            when_branch,
                            PExpected::ForReason(
                                PReason::WhenMatch {
                                    index: HumanIndex::zero_based(index),
                                },
                                cond_type.clone(),
                                pattern_region,
                            ),
                            FromAnnotation(
                                name.clone(),
                                *arity,
                                AnnotationSource::TypedWhenBranch {
                                    index: HumanIndex::zero_based(index),
                                    region: ann_source.region(),
                                },
                                typ.clone(),
                            ),
                        );

                        branch_constraints.push(branch_con);
                    }

                    branch_constraints.push(constraints.equal_types(
                        typ,
                        expected,
                        Category::When,
                        region,
                    ));

                    return constraints.exists_many([cond_var, *expr_var], branch_constraints);
                }

                _ => {
                    let branch_type = Variable(*expr_var);
                    let mut branch_cons = Vec::with_capacity(branches.len());

                    for (index, when_branch) in branches.iter().enumerate() {
                        let pattern_region =
                            Region::across_all(when_branch.patterns.iter().map(|v| &v.region));
                        let branch_con = constrain_when_branch(
                            constraints,
                            env,
                            region,
                            when_branch,
                            PExpected::ForReason(
                                PReason::WhenMatch {
                                    index: HumanIndex::zero_based(index),
                                },
                                cond_type.clone(),
                                pattern_region,
                            ),
                            ForReason(
                                Reason::WhenBranch {
                                    index: HumanIndex::zero_based(index),
                                },
                                branch_type.clone(),
                                when_branch.value.region,
                            ),
                        );

                        branch_cons.push(branch_con);
                    }

                    // Deviation: elm adds another layer of And nesting
                    //
                    // Record the original conditional expression's constraint.
                    // Each branch's pattern must have the same type
                    // as the condition expression did.
                    //
                    // The return type of each branch must equal the return type of
                    // the entire when-expression.
                    branch_cons.push(constraints.equal_types(
                        branch_type,
                        expected,
                        Category::When,
                        region,
                    ));
                    branch_constraints.push(constraints.and_constraint(branch_cons));
                }
            }

            // exhautiveness checking happens when converting to mono::Expr
            constraints.exists_many([cond_var, *expr_var], branch_constraints)
        }
        Access {
            record_var,
            ext_var,
            field_var,
            loc_expr,
            field,
        } => {
            let ext_var = *ext_var;
            let ext_type = Type::Variable(ext_var);
            let field_var = *field_var;
            let field_type = Type::Variable(field_var);

            let mut rec_field_types = SendMap::default();

            let label = field.clone();
            rec_field_types.insert(label, RecordField::Demanded(field_type.clone()));

            let record_type = Type::Record(rec_field_types, Box::new(ext_type));
            let record_expected = Expected::NoExpectation(record_type);

            let category = Category::Access(field.clone());

            let record_con = constraints.equal_types(
                Type::Variable(*record_var),
                record_expected.clone(),
                category.clone(),
                region,
            );

            let constraint = constrain_expr(
                constraints,
                &Env {
                    home: env.home,
                    rigids: MutMap::default(),
                },
                region,
                &loc_expr.value,
                record_expected,
            );

            let eq = constraints.equal_types(field_type, expected, category, region);
            constraints.exists_many(
                [*record_var, field_var, ext_var],
                [constraint, eq, record_con],
            )
        }
        Accessor {
            name: closure_name,
            function_var,
            field,
            record_var,
            closure_ext_var: closure_var,
            ext_var,
            field_var,
        } => {
            let ext_var = *ext_var;
            let ext_type = Variable(ext_var);
            let field_var = *field_var;
            let field_type = Variable(field_var);

            let mut field_types = SendMap::default();
            let label = field.clone();
            field_types.insert(label, RecordField::Demanded(field_type.clone()));
            let record_type = Type::Record(field_types, Box::new(ext_type));

            let category = Category::Accessor(field.clone());

            let record_expected = Expected::NoExpectation(record_type.clone());
            let record_con = constraints.equal_types(
                Type::Variable(*record_var),
                record_expected,
                category.clone(),
                region,
            );

            let lambda_set = Type::ClosureTag {
                name: *closure_name,
                ext: *closure_var,
            };

            let function_type = Type::Function(
                vec![record_type],
                Box::new(lambda_set),
                Box::new(field_type),
            );

            let cons = [
                constraints.equal_types(function_type.clone(), expected, category.clone(), region),
                constraints.equal_types(
                    function_type,
                    NoExpectation(Variable(*function_var)),
                    category,
                    region,
                ),
                record_con,
            ];

            constraints.exists_many(
                [*record_var, *function_var, *closure_var, field_var, ext_var],
                cons,
            )
        }
        LetRec(defs, loc_ret, var) => {
            let body_con = constrain_expr(
                constraints,
                env,
                loc_ret.region,
                &loc_ret.value,
                expected.clone(),
            );

            let cons = [
                constrain_recursive_defs(constraints, env, defs, body_con),
                // Record the type of tne entire def-expression in the variable.
                // Code gen will need that later!
                constraints.equal_types(
                    Type::Variable(*var),
                    expected,
                    Category::Storage(std::file!(), std::line!()),
                    loc_ret.region,
                ),
            ];

            constraints.exists_many([*var], cons)
        }
        LetNonRec(def, loc_ret, var) => {
            let mut stack = Vec::with_capacity(1);

            let mut loc_ret = loc_ret;

            stack.push((def, var, loc_ret.region));

            while let LetNonRec(def, new_loc_ret, var) = &loc_ret.value {
                stack.push((def, var, new_loc_ret.region));
                loc_ret = new_loc_ret;
            }

            let mut body_con = constrain_expr(
                constraints,
                env,
                loc_ret.region,
                &loc_ret.value,
                expected.clone(),
            );

            while let Some((def, var, ret_region)) = stack.pop() {
                let cons = [
                    constrain_def(constraints, env, def, body_con),
                    // Record the type of the entire def-expression in the variable.
                    // Code gen will need that later!
                    constraints.equal_types(
                        Type::Variable(*var),
                        expected.clone(),
                        Category::Storage(std::file!(), std::line!()),
                        ret_region,
                    ),
                ];

                body_con = constraints.exists_many([*var], cons)
            }

            body_con
        }
        Tag {
            variant_var,
            ext_var,
            name,
            arguments,
        } => {
            let mut vars = Vec::with_capacity(arguments.len());
            let mut types = Vec::with_capacity(arguments.len());
            let mut arg_cons = Vec::with_capacity(arguments.len());

            for (var, loc_expr) in arguments {
                let arg_con = constrain_expr(
                    constraints,
                    env,
                    loc_expr.region,
                    &loc_expr.value,
                    Expected::NoExpectation(Type::Variable(*var)),
                );

                arg_cons.push(arg_con);
                vars.push(*var);
                types.push(Type::Variable(*var));
            }

            let union_con = constraints.equal_types(
                Type::TagUnion(
                    vec![(name.clone(), types)],
                    Box::new(Type::Variable(*ext_var)),
                ),
                expected.clone(),
                Category::TagApply {
                    tag_name: name.clone(),
                    args_count: arguments.len(),
                },
                region,
            );
            let ast_con = constraints.equal_types(
                Type::Variable(*variant_var),
                expected,
                Category::Storage(std::file!(), std::line!()),
                region,
            );

            vars.push(*variant_var);
            vars.push(*ext_var);
            arg_cons.push(union_con);
            arg_cons.push(ast_con);

            constraints.exists_many(vars, arg_cons)
        }
        ZeroArgumentTag {
            variant_var,
            ext_var,
            name,
            arguments,
            closure_name,
        } => {
            let mut vars = Vec::with_capacity(arguments.len());
            let mut types = Vec::with_capacity(arguments.len());
            let mut arg_cons = Vec::with_capacity(arguments.len());

            for (var, loc_expr) in arguments {
                let arg_con = constrain_expr(
                    constraints,
                    env,
                    loc_expr.region,
                    &loc_expr.value,
                    Expected::NoExpectation(Type::Variable(*var)),
                );

                arg_cons.push(arg_con);
                vars.push(*var);
                types.push(Type::Variable(*var));
            }

            let union_con = constraints.equal_types(
                Type::FunctionOrTagUnion(
                    name.clone(),
                    *closure_name,
                    Box::new(Type::Variable(*ext_var)),
                ),
                expected.clone(),
                Category::TagApply {
                    tag_name: name.clone(),
                    args_count: arguments.len(),
                },
                region,
            );
            let ast_con = constraints.equal_types(
                Type::Variable(*variant_var),
                expected,
                Category::Storage(std::file!(), std::line!()),
                region,
            );

            vars.push(*variant_var);
            vars.push(*ext_var);
            arg_cons.push(union_con);
            arg_cons.push(ast_con);

            constraints.exists_many(vars, arg_cons)
        }

        OpaqueRef {
            opaque_var,
            name,
            argument,
            specialized_def_type,
            type_arguments,
            lambda_set_variables,
        } => {
            let (arg_var, arg_loc_expr) = &**argument;
            let arg_type = Type::Variable(*arg_var);

            let opaque_type = Type::Alias {
                symbol: *name,
                type_arguments: type_arguments.clone(),
                lambda_set_variables: lambda_set_variables.clone(),
                actual: Box::new(arg_type.clone()),
                kind: AliasKind::Opaque,
            };

            // Constrain the argument
            let arg_con = constrain_expr(
                constraints,
                env,
                arg_loc_expr.region,
                &arg_loc_expr.value,
                Expected::NoExpectation(arg_type.clone()),
            );

            // Link the entire wrapped opaque type (with the now-constrained argument) to the
            // expected type
            let opaque_con = constraints.equal_types(
                opaque_type,
                expected.clone(),
                Category::OpaqueWrap(*name),
                region,
            );

            // Link the entire wrapped opaque type (with the now-constrained argument) to the type
            // variables of the opaque type
            // TODO: better expectation here
            let link_type_variables_con = constraints.equal_types(
                arg_type,
                Expected::NoExpectation((**specialized_def_type).clone()),
                Category::OpaqueArg,
                arg_loc_expr.region,
            );

            // Store the entire wrapped opaque type in `opaque_var`
            let storage_con = constraints.equal_types(
                Type::Variable(*opaque_var),
                expected,
                Category::Storage(std::file!(), std::line!()),
                region,
            );

            let mut vars = vec![*arg_var, *opaque_var];
            // Also add the fresh variables we created for the type argument and lambda sets
            vars.extend(type_arguments.iter().map(|(_, t)| {
                t.expect_variable("all type arguments should be fresh variables here")
            }));
            vars.extend(lambda_set_variables.iter().map(|v| {
                v.0.expect_variable("all lambda sets should be fresh variables here")
            }));

            constraints.exists_many(
                vars,
                [arg_con, opaque_con, link_type_variables_con, storage_con],
            )
        }

        RunLowLevel { args, ret_var, op } => {
            // This is a modified version of what we do for function calls.

            // The operation's return type
            let ret_type = Variable(*ret_var);

            // This will be used in the occurs check
            let mut vars = Vec::with_capacity(1 + args.len());

            vars.push(*ret_var);

            let mut arg_types = Vec::with_capacity(args.len());
            let mut arg_cons = Vec::with_capacity(args.len());

            let mut add_arg = |index, arg_type: Type, arg| {
                let reason = Reason::LowLevelOpArg {
                    op: *op,
                    arg_index: HumanIndex::zero_based(index),
                };
                let expected_arg = ForReason(reason, arg_type.clone(), Region::zero());
                let arg_con = constrain_expr(constraints, env, Region::zero(), arg, expected_arg);

                arg_types.push(arg_type);
                arg_cons.push(arg_con);
            };

            for (index, (arg_var, arg)) in args.iter().enumerate() {
                vars.push(*arg_var);

                add_arg(index, Variable(*arg_var), arg);
            }

            let category = Category::LowLevelOpResult(*op);

            // Deviation: elm uses an additional And here
            let eq = constraints.equal_types(ret_type, expected, category, region);
            arg_cons.push(eq);
            constraints.exists_many(vars, arg_cons)
        }
        ForeignCall {
            args,
            ret_var,
            foreign_symbol,
        } => {
            // This is a modified version of what we do for function calls.

            // The operation's return type
            let ret_type = Variable(*ret_var);

            // This will be used in the occurs check
            let mut vars = Vec::with_capacity(1 + args.len());

            vars.push(*ret_var);

            let mut arg_types = Vec::with_capacity(args.len());
            let mut arg_cons = Vec::with_capacity(args.len());

            let mut add_arg = |index, arg_type: Type, arg| {
                let reason = Reason::ForeignCallArg {
                    foreign_symbol: foreign_symbol.clone(),
                    arg_index: HumanIndex::zero_based(index),
                };
                let expected_arg = ForReason(reason, arg_type.clone(), Region::zero());
                let arg_con = constrain_expr(constraints, env, Region::zero(), arg, expected_arg);

                arg_types.push(arg_type);
                arg_cons.push(arg_con);
            };

            for (index, (arg_var, arg)) in args.iter().enumerate() {
                vars.push(*arg_var);

                add_arg(index, Variable(*arg_var), arg);
            }

            let category = Category::ForeignCall;

            // Deviation: elm uses an additional And here
            let eq = constraints.equal_types(ret_type, expected, category, region);
            arg_cons.push(eq);
            constraints.exists_many(vars, arg_cons)
        }
        RuntimeError(_) => {
            // Runtime Errors have no constraints because they're going to crash.
            Constraint::True
        }
    }
}

#[inline(always)]
fn constrain_when_branch(
    constraints: &mut Constraints,
    env: &Env,
    region: Region,
    when_branch: &WhenBranch,
    pattern_expected: PExpected<Type>,
    expr_expected: Expected<Type>,
) -> Constraint {
    let ret_constraint = constrain_expr(
        constraints,
        env,
        region,
        &when_branch.value.value,
        expr_expected,
    );

    let mut state = PatternState {
        headers: SendMap::default(),
        vars: Vec::with_capacity(1),
        constraints: Vec::with_capacity(1),
    };

    // TODO investigate for error messages, is it better to unify all branches with a variable,
    // then unify that variable with the expectation?
    for loc_pattern in &when_branch.patterns {
        constrain_pattern(
            constraints,
            env,
            &loc_pattern.value,
            loc_pattern.region,
            pattern_expected.clone(),
            &mut state,
        );
    }

    if let Some(loc_guard) = &when_branch.guard {
        let guard_constraint = constrain_expr(
            constraints,
            env,
            region,
            &loc_guard.value,
            Expected::ForReason(
                Reason::WhenGuard,
                Type::Variable(Variable::BOOL),
                loc_guard.region,
            ),
        );

        // must introduce the headers from the pattern before constraining the guard
        let state_constraints = constraints.and_constraint(state.constraints);
        let inner = constraints.let_constraint(
            [],
            [],
            SendMap::default(),
            guard_constraint,
            ret_constraint,
        );

        constraints.let_constraint([], state.vars, state.headers, state_constraints, inner)
    } else {
        let state_constraints = constraints.and_constraint(state.constraints);
        constraints.let_constraint(
            [],
            state.vars,
            state.headers,
            state_constraints,
            ret_constraint,
        )
    }
}

fn constrain_field(
    constraints: &mut Constraints,
    env: &Env,
    field_var: Variable,
    loc_expr: &Loc<Expr>,
) -> (Type, Constraint) {
    let field_type = Variable(field_var);
    let field_expected = NoExpectation(field_type.clone());
    let constraint = constrain_expr(
        constraints,
        env,
        loc_expr.region,
        &loc_expr.value,
        field_expected,
    );

    (field_type, constraint)
}

#[inline(always)]
fn constrain_empty_record(
    constraints: &mut Constraints,
    region: Region,
    expected: Expected<Type>,
) -> Constraint {
    let expected_index = constraints.push_expected_type(expected);

    Constraint::Eq(
        Constraints::EMPTY_RECORD,
        expected_index,
        Constraints::CATEGORY_RECORD,
        region,
    )
}

/// Constrain top-level module declarations
#[inline(always)]
pub fn constrain_decls(
    constraints: &mut Constraints,
    home: ModuleId,
    decls: &[Declaration],
) -> Constraint {
    let mut constraint = Constraint::SaveTheEnvironment;

    let mut env = Env {
        home,
        rigids: MutMap::default(),
    };

    for decl in decls.iter().rev() {
        // Clear the rigids from the previous iteration.
        // rigids are not shared between top-level definitions
        env.rigids.clear();

        match decl {
            Declaration::Declare(def) | Declaration::Builtin(def) => {
                constraint = constrain_def(constraints, &env, def, constraint);
            }
            Declaration::DeclareRec(defs) => {
                constraint = constrain_recursive_defs(constraints, &env, defs, constraint);
            }
            Declaration::InvalidCycle(_) => {
                // invalid cycles give a canonicalization error. we skip them here.
                continue;
            }
        }
    }

    // this assert make the "root" of the constraint wasn't dropped
    debug_assert!(constraints.contains_save_the_environment(&constraint));

    constraint
}

fn constrain_def_pattern(
    constraints: &mut Constraints,
    env: &Env,
    loc_pattern: &Loc<Pattern>,
    expr_type: Type,
) -> PatternState {
    let pattern_expected = PExpected::NoExpectation(expr_type);

    let mut state = PatternState {
        headers: SendMap::default(),
        vars: Vec::with_capacity(1),
        constraints: Vec::with_capacity(1),
    };

    constrain_pattern(
        constraints,
        env,
        &loc_pattern.value,
        loc_pattern.region,
        pattern_expected,
        &mut state,
    );

    state
}

fn constrain_def(
    constraints: &mut Constraints,
    env: &Env,
    def: &Def,
    body_con: Constraint,
) -> Constraint {
    let expr_var = def.expr_var;
    let expr_type = Type::Variable(expr_var);

    let mut def_pattern_state =
        constrain_def_pattern(constraints, env, &def.loc_pattern, expr_type.clone());

    def_pattern_state.vars.push(expr_var);

    match &def.annotation {
        Some(annotation) => {
            let arity = annotation.signature.arity();
            let rigids = &env.rigids;
            let mut ftv = rigids.clone();

            let InstantiateRigids {
                signature,
                new_rigid_variables,
                new_infer_variables,
            } = instantiate_rigids(
                &annotation.signature,
                &annotation.introduced_variables,
                &def.loc_pattern,
                &mut ftv,
                &mut def_pattern_state.headers,
            );

            let env = &Env {
                home: env.home,
                rigids: ftv,
            };

            let annotation_expected = FromAnnotation(
                def.loc_pattern.clone(),
                arity,
                AnnotationSource::TypedBody {
                    region: annotation.region,
                },
                signature.clone(),
            );

            def_pattern_state.constraints.push(constraints.equal_types(
                expr_type,
                annotation_expected.clone(),
                Category::Storage(std::file!(), std::line!()),
                Region::span_across(&annotation.region, &def.loc_expr.region),
            ));

            // when a def is annotated, and it's body is a closure, treat this
            // as a named function (in elm terms) for error messages.
            //
            // This means we get errors like "the first argument of `f` is weird"
            // instead of the more generic "something is wrong with the body of `f`"
            match (&def.loc_expr.value, &signature) {
                (
                    Closure(ClosureData {
                        function_type: fn_var,
                        closure_type: closure_var,
                        closure_ext_var,
                        return_type: ret_var,
                        captured_symbols,
                        arguments,
                        loc_body,
                        name,
                        ..
                    }),
                    Type::Function(arg_types, signature_closure_type, ret_type),
                ) => {
                    // NOTE if we ever have problems with the closure, the ignored `_closure_type`
                    // is probably a good place to start the investigation!

                    let region = def.loc_expr.region;

                    let loc_body_expr = &**loc_body;
                    let mut state = PatternState {
                        headers: SendMap::default(),
                        vars: Vec::with_capacity(arguments.len()),
                        constraints: Vec::with_capacity(1),
                    };
                    let mut vars = Vec::with_capacity(state.vars.capacity() + 1);
                    let mut pattern_types = Vec::with_capacity(state.vars.capacity());
                    let ret_var = *ret_var;
                    let closure_var = *closure_var;
                    let closure_ext_var = *closure_ext_var;
                    let ret_type = *ret_type.clone();

                    vars.push(ret_var);
                    vars.push(closure_var);
                    vars.push(closure_ext_var);

                    let it = arguments.iter().zip(arg_types.iter()).enumerate();
                    for (index, ((pattern_var, loc_pattern), loc_ann)) in it {
                        {
                            // ensure type matches the one in the annotation
                            let opt_label =
                                if let Pattern::Identifier(label) = def.loc_pattern.value {
                                    Some(label)
                                } else {
                                    None
                                };
                            let pattern_type: &Type = loc_ann;

                            let pattern_expected = PExpected::ForReason(
                                PReason::TypedArg {
                                    index: HumanIndex::zero_based(index),
                                    opt_name: opt_label,
                                },
                                pattern_type.clone(),
                                loc_pattern.region,
                            );

                            constrain_pattern(
                                constraints,
                                env,
                                &loc_pattern.value,
                                loc_pattern.region,
                                pattern_expected,
                                &mut state,
                            );
                        }

                        {
                            // NOTE: because we perform an equality with part of the signature
                            // this constraint must be to the def_pattern_state's constraints
                            def_pattern_state.vars.push(*pattern_var);
                            pattern_types.push(Type::Variable(*pattern_var));

                            let pattern_con = constraints.equal_types(
                                Type::Variable(*pattern_var),
                                Expected::NoExpectation(loc_ann.clone()),
                                Category::Storage(std::file!(), std::line!()),
                                loc_pattern.region,
                            );

                            def_pattern_state.constraints.push(pattern_con);
                        }
                    }

                    let closure_constraint = constrain_closure_size(
                        constraints,
                        *name,
                        region,
                        captured_symbols,
                        closure_var,
                        closure_ext_var,
                        &mut vars,
                    );

                    let body_type = FromAnnotation(
                        def.loc_pattern.clone(),
                        arguments.len(),
                        AnnotationSource::TypedBody {
                            region: annotation.region,
                        },
                        ret_type.clone(),
                    );

                    let ret_constraint = constrain_expr(
                        constraints,
                        env,
                        loc_body_expr.region,
                        &loc_body_expr.value,
                        body_type,
                    );

                    vars.push(*fn_var);
                    let defs_constraint = constraints.and_constraint(state.constraints);

                    let cons = [
                        constraints.let_constraint(
                            [],
                            state.vars,
                            state.headers,
                            defs_constraint,
                            ret_constraint,
                        ),
                        constraints.equal_types(
                            Type::Variable(closure_var),
                            Expected::FromAnnotation(
                                def.loc_pattern.clone(),
                                arity,
                                AnnotationSource::TypedBody {
                                    region: annotation.region,
                                },
                                *signature_closure_type.clone(),
                            ),
                            Category::ClosureSize,
                            region,
                        ),
                        constraints.store(signature.clone(), *fn_var, std::file!(), std::line!()),
                        constraints.store(signature, expr_var, std::file!(), std::line!()),
                        constraints.store(ret_type, ret_var, std::file!(), std::line!()),
                        closure_constraint,
                    ];

                    let expr_con = constraints.exists_many(vars, cons);

                    constrain_def_make_constraint(
                        constraints,
                        new_rigid_variables,
                        new_infer_variables,
                        expr_con,
                        body_con,
                        def_pattern_state,
                    )
                }

                _ => {
                    let expected = annotation_expected;

                    let ret_constraint = constrain_expr(
                        constraints,
                        env,
                        def.loc_expr.region,
                        &def.loc_expr.value,
                        expected,
                    );

                    let cons = [
                        constraints.let_constraint(
                            [],
                            [],
                            SendMap::default(),
                            Constraint::True,
                            ret_constraint,
                        ),
                        // Store type into AST vars. We use Store so errors aren't reported twice
                        constraints.store(signature, expr_var, std::file!(), std::line!()),
                    ];
                    let expr_con = constraints.and_constraint(cons);

                    constrain_def_make_constraint(
                        constraints,
                        new_rigid_variables,
                        new_infer_variables,
                        expr_con,
                        body_con,
                        def_pattern_state,
                    )
                }
            }
        }
        None => {
            // no annotation, so no extra work with rigids

            let expr_con = constrain_expr(
                constraints,
                env,
                def.loc_expr.region,
                &def.loc_expr.value,
                NoExpectation(expr_type),
            );

            constrain_def_make_constraint(
                constraints,
                vec![],
                vec![],
                expr_con,
                body_con,
                def_pattern_state,
            )
        }
    }
}

fn constrain_def_make_constraint(
    constraints: &mut Constraints,
    new_rigid_variables: Vec<Variable>,
    new_infer_variables: Vec<Variable>,
    expr_con: Constraint,
    body_con: Constraint,
    def_pattern_state: PatternState,
) -> Constraint {
    let and_constraint = constraints.and_constraint(def_pattern_state.constraints);

    let def_con = constraints.let_constraint(
        [],
        new_infer_variables,
        SendMap::default(), // empty, because our functions have no arguments!
        and_constraint,
        expr_con,
    );

    constraints.let_constraint(
        new_rigid_variables,
        def_pattern_state.vars,
        def_pattern_state.headers,
        def_con,
        body_con,
    )
}

fn constrain_closure_size(
    constraints: &mut Constraints,
    name: Symbol,
    region: Region,
    captured_symbols: &[(Symbol, Variable)],
    closure_var: Variable,
    closure_ext_var: Variable,
    variables: &mut Vec<Variable>,
) -> Constraint {
    debug_assert!(variables.iter().any(|s| *s == closure_var));
    debug_assert!(variables.iter().any(|s| *s == closure_ext_var));

    let mut tag_arguments = Vec::with_capacity(captured_symbols.len());
    let mut captured_symbols_constraints = Vec::with_capacity(captured_symbols.len());

    for (symbol, var) in captured_symbols {
        // make sure the variable is registered
        variables.push(*var);

        // this symbol is captured, so it must be part of the closure type
        tag_arguments.push(Type::Variable(*var));

        // make the variable equal to the looked-up type of symbol
        captured_symbols_constraints.push(constraints.lookup(
            *symbol,
            Expected::NoExpectation(Type::Variable(*var)),
            Region::zero(),
        ));
    }

    // pick a more efficient representation if we don't actually capture anything
    let closure_type = if tag_arguments.is_empty() {
        Type::ClosureTag {
            name,
            ext: closure_ext_var,
        }
    } else {
        let tag_name = TagName::Closure(name);
        Type::TagUnion(
            vec![(tag_name, tag_arguments)],
            Box::new(Type::Variable(closure_ext_var)),
        )
    };

    let finalizer = constraints.equal_types(
        Type::Variable(closure_var),
        NoExpectation(closure_type),
        Category::ClosureSize,
        region,
    );

    captured_symbols_constraints.push(finalizer);

    constraints.and_constraint(captured_symbols_constraints)
}

pub struct InstantiateRigids {
    pub signature: Type,
    pub new_rigid_variables: Vec<Variable>,
    pub new_infer_variables: Vec<Variable>,
}

fn instantiate_rigids(
    annotation: &Type,
    introduced_vars: &IntroducedVariables,
    loc_pattern: &Loc<Pattern>,
    ftv: &mut MutMap<Lowercase, Variable>, // rigids defined before the current annotation
    headers: &mut SendMap<Symbol, Loc<Type>>,
) -> InstantiateRigids {
    let mut annotation = annotation.clone();
    let mut new_rigid_variables = Vec::new();

    let mut rigid_substitution: ImMap<Variable, Type> = ImMap::default();
    for (name, var) in introduced_vars.var_by_name.iter() {
        use std::collections::hash_map::Entry::*;

        match ftv.entry(name.clone()) {
            Occupied(occupied) => {
                let existing_rigid = occupied.get();
                rigid_substitution.insert(*var, Type::Variable(*existing_rigid));
            }
            Vacant(vacant) => {
                // It's possible to use this rigid in nested defs
                vacant.insert(*var);
                new_rigid_variables.push(*var);
            }
        }
    }

    // wildcards are always freshly introduced in this annotation
    new_rigid_variables.extend(introduced_vars.wildcards.iter().copied());

    // lambda set vars are always freshly introduced in this annotation
    new_rigid_variables.extend(introduced_vars.lambda_sets.iter().copied());

    let new_infer_variables = introduced_vars.inferred.clone();

    // Instantiate rigid variables
    if !rigid_substitution.is_empty() {
        annotation.substitute(&rigid_substitution);
    }

    let loc_annotation_ref = Loc::at(loc_pattern.region, &annotation);
    if let Pattern::Identifier(symbol) = loc_pattern.value {
        headers.insert(symbol, Loc::at(loc_pattern.region, annotation.clone()));
    } else if let Some(new_headers) =
        crate::pattern::headers_from_annotation(&loc_pattern.value, &loc_annotation_ref)
    {
        headers.extend(new_headers)
    }

    InstantiateRigids {
        signature: annotation,
        new_rigid_variables,
        new_infer_variables,
    }
}

fn constrain_recursive_defs(
    constraints: &mut Constraints,
    env: &Env,
    defs: &[Def],
    body_con: Constraint,
) -> Constraint {
    rec_defs_help(
        constraints,
        env,
        defs,
        body_con,
        Info::with_capacity(defs.len()),
        Info::with_capacity(defs.len()),
    )
}

pub fn rec_defs_help(
    constraints: &mut Constraints,
    env: &Env,
    defs: &[Def],
    body_con: Constraint,
    mut rigid_info: Info,
    mut flex_info: Info,
) -> Constraint {
    for def in defs {
        let expr_var = def.expr_var;
        let expr_type = Type::Variable(expr_var);

        let mut def_pattern_state =
            constrain_def_pattern(constraints, env, &def.loc_pattern, expr_type.clone());

        def_pattern_state.vars.push(expr_var);

        match &def.annotation {
            None => {
                let expr_con = constrain_expr(
                    constraints,
                    env,
                    def.loc_expr.region,
                    &def.loc_expr.value,
                    NoExpectation(expr_type),
                );

                // TODO investigate if this let can be safely removed
                let def_con = constraints.let_constraint(
                    [],
                    [],                 // empty because Roc function defs have no args
                    SendMap::default(), // empty because Roc function defs have no args
                    Constraint::True, // I think this is correct, once again because there are no args
                    expr_con,
                );

                flex_info.vars = def_pattern_state.vars;
                flex_info.constraints.push(def_con);
                flex_info.def_types.extend(def_pattern_state.headers);
            }

            Some(annotation) => {
                let arity = annotation.signature.arity();
                let mut ftv = env.rigids.clone();

                let InstantiateRigids {
                    signature,
                    new_rigid_variables,
                    new_infer_variables,
                } = instantiate_rigids(
                    &annotation.signature,
                    &annotation.introduced_variables,
                    &def.loc_pattern,
                    &mut ftv,
                    &mut def_pattern_state.headers,
                );

                flex_info.vars.extend(new_infer_variables);

                let annotation_expected = FromAnnotation(
                    def.loc_pattern.clone(),
                    arity,
                    AnnotationSource::TypedBody {
                        region: annotation.region,
                    },
                    signature.clone(),
                );

                // when a def is annotated, and it's body is a closure, treat this
                // as a named function (in elm terms) for error messages.
                //
                // This means we get errors like "the first argument of `f` is weird"
                // instead of the more generic "something is wrong with the body of `f`"
                match (&def.loc_expr.value, &signature) {
                    (
                        Closure(ClosureData {
                            function_type: fn_var,
                            closure_type: closure_var,
                            closure_ext_var,
                            return_type: ret_var,
                            captured_symbols,
                            arguments,
                            loc_body,
                            name,
                            ..
                        }),
                        Type::Function(arg_types, _closure_type, ret_type),
                    ) => {
                        // NOTE if we ever have trouble with closure type unification, the ignored
                        // `_closure_type` here is a good place to start investigating

                        let expected = annotation_expected;
                        let region = def.loc_expr.region;

                        let loc_body_expr = &**loc_body;
                        let mut state = PatternState {
                            headers: SendMap::default(),
                            vars: Vec::with_capacity(arguments.len()),
                            constraints: Vec::with_capacity(1),
                        };
                        let mut vars = Vec::with_capacity(state.vars.capacity() + 1);
                        let mut pattern_types = Vec::with_capacity(state.vars.capacity());
                        let ret_var = *ret_var;
                        let closure_var = *closure_var;
                        let closure_ext_var = *closure_ext_var;
                        let ret_type = *ret_type.clone();

                        vars.push(ret_var);
                        vars.push(closure_var);
                        vars.push(closure_ext_var);

                        let it = arguments.iter().zip(arg_types.iter()).enumerate();
                        for (index, ((pattern_var, loc_pattern), loc_ann)) in it {
                            {
                                // ensure type matches the one in the annotation
                                let opt_label =
                                    if let Pattern::Identifier(label) = def.loc_pattern.value {
                                        Some(label)
                                    } else {
                                        None
                                    };
                                let pattern_type: &Type = loc_ann;

                                let pattern_expected = PExpected::ForReason(
                                    PReason::TypedArg {
                                        index: HumanIndex::zero_based(index),
                                        opt_name: opt_label,
                                    },
                                    pattern_type.clone(),
                                    loc_pattern.region,
                                );

                                constrain_pattern(
                                    constraints,
                                    env,
                                    &loc_pattern.value,
                                    loc_pattern.region,
                                    pattern_expected,
                                    &mut state,
                                );
                            }

                            {
                                // NOTE: because we perform an equality with part of the signature
                                // this constraint must be to the def_pattern_state's constraints
                                def_pattern_state.vars.push(*pattern_var);
                                pattern_types.push(Type::Variable(*pattern_var));

                                let pattern_con = constraints.equal_types(
                                    Type::Variable(*pattern_var),
                                    Expected::NoExpectation(loc_ann.clone()),
                                    Category::Storage(std::file!(), std::line!()),
                                    loc_pattern.region,
                                );

                                def_pattern_state.constraints.push(pattern_con);
                            }
                        }

                        let closure_constraint = constrain_closure_size(
                            constraints,
                            *name,
                            region,
                            captured_symbols,
                            closure_var,
                            closure_ext_var,
                            &mut vars,
                        );

                        let fn_type = Type::Function(
                            pattern_types,
                            Box::new(Type::Variable(closure_var)),
                            Box::new(ret_type.clone()),
                        );
                        let body_type = NoExpectation(ret_type.clone());
                        let expr_con = constrain_expr(
                            constraints,
                            env,
                            loc_body_expr.region,
                            &loc_body_expr.value,
                            body_type,
                        );

                        vars.push(*fn_var);

                        let state_constraints = constraints.and_constraint(state.constraints);
                        let cons = [
                            constraints.let_constraint(
                                [],
                                state.vars,
                                state.headers,
                                state_constraints,
                                expr_con,
                            ),
                            constraints.equal_types(
                                fn_type.clone(),
                                expected.clone(),
                                Category::Lambda,
                                region,
                            ),
                            // "fn_var is equal to the closure's type" - fn_var is used in code gen
                            // Store type into AST vars. We use Store so errors aren't reported twice
                            constraints.store(
                                signature.clone(),
                                *fn_var,
                                std::file!(),
                                std::line!(),
                            ),
                            constraints.store(signature, expr_var, std::file!(), std::line!()),
                            constraints.store(ret_type, ret_var, std::file!(), std::line!()),
                            closure_constraint,
                        ];

                        let and_constraint = constraints.and_constraint(cons);
                        let def_con = constraints.exists(vars, and_constraint);

                        rigid_info.vars.extend(&new_rigid_variables);

                        rigid_info.constraints.push(constraints.let_constraint(
                            new_rigid_variables,
                            def_pattern_state.vars,
                            SendMap::default(), // no headers introduced (at this level)
                            def_con,
                            Constraint::True,
                        ));
                        rigid_info.def_types.extend(def_pattern_state.headers);
                    }
                    _ => {
                        let expected = annotation_expected;

                        let ret_constraint = constrain_expr(
                            constraints,
                            env,
                            def.loc_expr.region,
                            &def.loc_expr.value,
                            expected,
                        );

                        let cons = [
                            constraints.let_constraint(
                                [],
                                [],
                                SendMap::default(),
                                Constraint::True,
                                ret_constraint,
                            ),
                            // Store type into AST vars. We use Store so errors aren't reported twice
                            constraints.store(signature, expr_var, std::file!(), std::line!()),
                        ];
                        let def_con = constraints.and_constraint(cons);

                        rigid_info.vars.extend(&new_rigid_variables);

                        rigid_info.constraints.push(constraints.let_constraint(
                            new_rigid_variables,
                            def_pattern_state.vars,
                            SendMap::default(), // no headers introduced (at this level)
                            def_con,
                            Constraint::True,
                        ));
                        rigid_info.def_types.extend(def_pattern_state.headers);
                    }
                }
            }
        }
    }

    let flex_constraints = constraints.and_constraint(flex_info.constraints);
    let inner_inner = constraints.let_constraint(
        [],
        [],
        flex_info.def_types.clone(),
        Constraint::True,
        flex_constraints,
    );

    let rigid_constraints = {
        let mut temp = rigid_info.constraints;
        temp.push(body_con);

        constraints.and_constraint(temp)
    };

    let inner = constraints.let_constraint(
        [],
        flex_info.vars,
        flex_info.def_types,
        inner_inner,
        rigid_constraints,
    );

    constraints.let_constraint(
        rigid_info.vars,
        [],
        rigid_info.def_types,
        Constraint::True,
        inner,
    )
}

#[inline(always)]
fn constrain_field_update(
    constraints: &mut Constraints,
    env: &Env,
    var: Variable,
    region: Region,
    field: Lowercase,
    loc_expr: &Loc<Expr>,
) -> (Variable, Type, Constraint) {
    let field_type = Type::Variable(var);
    let reason = Reason::RecordUpdateValue(field);
    let expected = ForReason(reason, field_type.clone(), region);
    let con = constrain_expr(constraints, env, loc_expr.region, &loc_expr.value, expected);

    (var, field_type, con)
}
