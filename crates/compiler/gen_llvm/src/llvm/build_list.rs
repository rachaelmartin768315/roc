#![allow(clippy::too_many_arguments)]
use crate::llvm::bitcode::{build_dec_wrapper, call_list_bitcode_fn};
use crate::llvm::build::{
    allocate_with_refcount_help, cast_basic_basic, Env, RocFunctionCall, Scope,
};
use crate::llvm::convert::basic_type_from_layout;
use crate::llvm::refcounting::increment_refcount_layout;
use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::types::{BasicType, BasicTypeEnum, PointerType};
use inkwell::values::{BasicValueEnum, FunctionValue, IntValue, PointerValue, StructValue};
use inkwell::{AddressSpace, IntPredicate};
use morphic_lib::UpdateMode;
use roc_builtins::bitcode;
use roc_module::symbol::Symbol;
use roc_mono::layout::{Builtin, Layout, LayoutIds};

use super::build::{create_entry_block_alloca, load_roc_value, load_symbol, store_roc_value};

pub fn list_symbol_to_c_abi<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    scope: &Scope<'a, 'ctx>,
    symbol: Symbol,
) -> PointerValue<'ctx> {
    let parent = env
        .builder
        .get_insert_block()
        .and_then(|b| b.get_parent())
        .unwrap();

    let list_type = super::convert::zig_list_type(env);
    let list_alloca = create_entry_block_alloca(env, parent, list_type.into(), "list_alloca");

    let list = load_symbol(scope, &symbol);
    env.builder.build_store(list_alloca, list);

    list_alloca
}

pub fn list_to_c_abi<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    list: BasicValueEnum<'ctx>,
) -> PointerValue<'ctx> {
    let parent = env
        .builder
        .get_insert_block()
        .and_then(|b| b.get_parent())
        .unwrap();

    let list_type = super::convert::zig_list_type(env);
    let list_alloca = create_entry_block_alloca(env, parent, list_type.into(), "list_alloca");

    env.builder.build_store(list_alloca, list);

    list_alloca
}

pub fn pass_update_mode<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    update_mode: UpdateMode,
) -> BasicValueEnum<'ctx> {
    match update_mode {
        UpdateMode::Immutable => env.context.i8_type().const_zero().into(),
        UpdateMode::InPlace => env.context.i8_type().const_int(1, false).into(),
    }
}

fn pass_element_as_opaque<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    element: BasicValueEnum<'ctx>,
    layout: Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let element_type = basic_type_from_layout(env, &layout);
    let element_ptr = env
        .builder
        .build_alloca(element_type, "element_to_pass_as_opaque");
    store_roc_value(env, layout, element_ptr, element);

    env.builder.build_bitcast(
        element_ptr,
        env.context.i8_type().ptr_type(AddressSpace::Generic),
        "pass_element_as_opaque",
    )
}

pub fn layout_width<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    env.ptr_int()
        .const_int(layout.stack_size(env.target_info) as u64, false)
        .into()
}

pub fn pass_as_opaque<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    ptr: PointerValue<'ctx>,
) -> BasicValueEnum<'ctx> {
    env.builder.build_bitcast(
        ptr,
        env.context.i8_type().ptr_type(AddressSpace::Generic),
        "pass_as_opaque",
    )
}

pub fn list_with_capacity<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    capacity: IntValue<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            capacity.into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
        ],
        bitcode::LIST_WITH_CAPACITY,
    )
}

pub fn list_get_unsafe<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    parent: FunctionValue<'ctx>,
    element_layout: &Layout<'a>,
    elem_index: IntValue<'ctx>,
    wrapper_struct: StructValue<'ctx>,
) -> BasicValueEnum<'ctx> {
    let builder = env.builder;

    let elem_type = basic_type_from_layout(env, element_layout);
    let ptr_type = elem_type.ptr_type(AddressSpace::Generic);
    // Load the pointer to the array data
    let array_data_ptr = load_list_ptr(builder, wrapper_struct, ptr_type);

    // Assume the bounds have already been checked earlier
    // (e.g. by List.get or List.first, which wrap List.#getUnsafe)
    let elem_ptr =
        unsafe { builder.build_in_bounds_gep(array_data_ptr, &[elem_index], "list_get_element") };

    let result = load_roc_value(env, *element_layout, elem_ptr, "list_get_load_element");

    increment_refcount_layout(env, parent, layout_ids, 1, result, element_layout);

    result
}

/// List.append : List elem, elem -> List elem
pub fn list_append<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    original_wrapper: StructValue<'ctx>,
    element: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
    update_mode: UpdateMode,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, original_wrapper.into()).into(),
            env.alignment_intvalue(element_layout),
            pass_element_as_opaque(env, element, *element_layout),
            layout_width(env, element_layout),
            pass_update_mode(env, update_mode),
        ],
        bitcode::LIST_APPEND,
    )
}

/// List.prepend : List elem, elem -> List elem
pub fn list_prepend<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    original_wrapper: StructValue<'ctx>,
    element: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, original_wrapper.into()).into(),
            env.alignment_intvalue(element_layout),
            pass_element_as_opaque(env, element, *element_layout),
            layout_width(env, element_layout),
        ],
        bitcode::LIST_PREPEND,
    )
}

/// List.swap : List elem, Nat, Nat -> List elem
pub fn list_swap<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    original_wrapper: StructValue<'ctx>,
    index_1: IntValue<'ctx>,
    index_2: IntValue<'ctx>,
    element_layout: &Layout<'a>,
    update_mode: UpdateMode,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, original_wrapper.into()).into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
            index_1.into(),
            index_2.into(),
            pass_update_mode(env, update_mode),
        ],
        bitcode::LIST_SWAP,
    )
}

/// List.sublist : List elem, { start : Nat, len : Nat } -> List elem
pub fn list_sublist<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    original_wrapper: StructValue<'ctx>,
    start: IntValue<'ctx>,
    len: IntValue<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let dec_element_fn = build_dec_wrapper(env, layout_ids, element_layout);
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, original_wrapper.into()).into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
            start.into(),
            len.into(),
            dec_element_fn.as_global_value().as_pointer_value().into(),
        ],
        bitcode::LIST_SUBLIST,
    )
}

/// List.dropAt : List elem, Nat -> List elem
pub fn list_drop_at<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    original_wrapper: StructValue<'ctx>,
    count: IntValue<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let dec_element_fn = build_dec_wrapper(env, layout_ids, element_layout);
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, original_wrapper.into()).into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
            count.into(),
            dec_element_fn.as_global_value().as_pointer_value().into(),
        ],
        bitcode::LIST_DROP_AT,
    )
}

/// List.replace_unsafe : List elem, Nat, elem -> { list: List elem, value: elem }
pub fn list_replace_unsafe<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    _layout_ids: &mut LayoutIds<'a>,
    list: BasicValueEnum<'ctx>,
    index: IntValue<'ctx>,
    element: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
    update_mode: UpdateMode,
) -> BasicValueEnum<'ctx> {
    let element_type = basic_type_from_layout(env, element_layout);
    let element_ptr = env
        .builder
        .build_alloca(element_type, "output_element_as_opaque");

    // Assume the bounds have already been checked earlier
    // (e.g. by List.replace or List.set, which wrap List.#replaceUnsafe)
    let new_list = match update_mode {
        UpdateMode::InPlace => call_list_bitcode_fn(
            env,
            &[
                list_to_c_abi(env, list).into(),
                index.into(),
                pass_element_as_opaque(env, element, *element_layout),
                layout_width(env, element_layout),
                pass_as_opaque(env, element_ptr),
            ],
            bitcode::LIST_REPLACE_IN_PLACE,
        ),
        UpdateMode::Immutable => call_list_bitcode_fn(
            env,
            &[
                list_to_c_abi(env, list).into(),
                env.alignment_intvalue(element_layout),
                index.into(),
                pass_element_as_opaque(env, element, *element_layout),
                layout_width(env, element_layout),
                pass_as_opaque(env, element_ptr),
            ],
            bitcode::LIST_REPLACE,
        ),
    };

    // Load the element and returned list into a struct.
    let old_element = env.builder.build_load(element_ptr, "load_element");

    let result = env
        .context
        .struct_type(
            &[super::convert::zig_list_type(env).into(), element_type],
            false,
        )
        .const_zero();

    let result = env
        .builder
        .build_insert_value(result, new_list, 0, "insert_list")
        .unwrap();

    env.builder
        .build_insert_value(result, old_element, 1, "insert_value")
        .unwrap()
        .into_struct_value()
        .into()
}

fn bounds_check_comparison<'ctx>(
    builder: &Builder<'ctx>,
    elem_index: IntValue<'ctx>,
    len: IntValue<'ctx>,
) -> IntValue<'ctx> {
    // Note: Check for index < length as the "true" condition,
    // to avoid misprediction. (In practice this should usually pass,
    // and CPUs generally default to predicting that a forward jump
    // shouldn't be taken; that is, they predict "else" won't be taken.)
    builder.build_int_compare(IntPredicate::ULT, elem_index, len, "bounds_check")
}

/// List.len : List elem -> Int
pub fn list_len<'ctx>(
    builder: &Builder<'ctx>,
    wrapper_struct: StructValue<'ctx>,
) -> IntValue<'ctx> {
    builder
        .build_extract_value(wrapper_struct, Builtin::WRAPPER_LEN, "list_len")
        .unwrap()
        .into_int_value()
}

/// List.sortWith : List a, (a, a -> Ordering) -> List a
pub fn list_sort_with<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    roc_function_call: RocFunctionCall<'ctx>,
    compare_wrapper: PointerValue<'ctx>,
    list: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, list).into(),
            compare_wrapper.into(),
            pass_as_opaque(env, roc_function_call.data),
            roc_function_call.inc_n_data.into(),
            roc_function_call.data_is_owned.into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
        ],
        bitcode::LIST_SORT_WITH,
    )
}

/// List.map : List before, (before -> after) -> List after
pub fn list_map<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    roc_function_call: RocFunctionCall<'ctx>,
    list: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
    return_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, list).into(),
            roc_function_call.caller.into(),
            pass_as_opaque(env, roc_function_call.data),
            roc_function_call.inc_n_data.into(),
            roc_function_call.data_is_owned.into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
            layout_width(env, return_layout),
        ],
        bitcode::LIST_MAP,
    )
}

pub fn list_map2<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    roc_function_call: RocFunctionCall<'ctx>,
    list1: BasicValueEnum<'ctx>,
    list2: BasicValueEnum<'ctx>,
    element1_layout: &Layout<'a>,
    element2_layout: &Layout<'a>,
    return_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let dec_a = build_dec_wrapper(env, layout_ids, element1_layout);
    let dec_b = build_dec_wrapper(env, layout_ids, element2_layout);

    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, list1).into(),
            list_to_c_abi(env, list2).into(),
            roc_function_call.caller.into(),
            pass_as_opaque(env, roc_function_call.data),
            roc_function_call.inc_n_data.into(),
            roc_function_call.data_is_owned.into(),
            env.alignment_intvalue(return_layout),
            layout_width(env, element1_layout),
            layout_width(env, element2_layout),
            layout_width(env, return_layout),
            dec_a.as_global_value().as_pointer_value().into(),
            dec_b.as_global_value().as_pointer_value().into(),
        ],
        bitcode::LIST_MAP2,
    )
}

pub fn list_map3<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    roc_function_call: RocFunctionCall<'ctx>,
    list1: BasicValueEnum<'ctx>,
    list2: BasicValueEnum<'ctx>,
    list3: BasicValueEnum<'ctx>,
    element1_layout: &Layout<'a>,
    element2_layout: &Layout<'a>,
    element3_layout: &Layout<'a>,
    result_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let dec_a = build_dec_wrapper(env, layout_ids, element1_layout);
    let dec_b = build_dec_wrapper(env, layout_ids, element2_layout);
    let dec_c = build_dec_wrapper(env, layout_ids, element3_layout);

    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, list1).into(),
            list_to_c_abi(env, list2).into(),
            list_to_c_abi(env, list3).into(),
            roc_function_call.caller.into(),
            pass_as_opaque(env, roc_function_call.data),
            roc_function_call.inc_n_data.into(),
            roc_function_call.data_is_owned.into(),
            env.alignment_intvalue(result_layout),
            layout_width(env, element1_layout),
            layout_width(env, element2_layout),
            layout_width(env, element3_layout),
            layout_width(env, result_layout),
            dec_a.as_global_value().as_pointer_value().into(),
            dec_b.as_global_value().as_pointer_value().into(),
            dec_c.as_global_value().as_pointer_value().into(),
        ],
        bitcode::LIST_MAP3,
    )
}

pub fn list_map4<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    layout_ids: &mut LayoutIds<'a>,
    roc_function_call: RocFunctionCall<'ctx>,
    list1: BasicValueEnum<'ctx>,
    list2: BasicValueEnum<'ctx>,
    list3: BasicValueEnum<'ctx>,
    list4: BasicValueEnum<'ctx>,
    element1_layout: &Layout<'a>,
    element2_layout: &Layout<'a>,
    element3_layout: &Layout<'a>,
    element4_layout: &Layout<'a>,
    result_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    let dec_a = build_dec_wrapper(env, layout_ids, element1_layout);
    let dec_b = build_dec_wrapper(env, layout_ids, element2_layout);
    let dec_c = build_dec_wrapper(env, layout_ids, element3_layout);
    let dec_d = build_dec_wrapper(env, layout_ids, element4_layout);

    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, list1).into(),
            list_to_c_abi(env, list2).into(),
            list_to_c_abi(env, list3).into(),
            list_to_c_abi(env, list4).into(),
            roc_function_call.caller.into(),
            pass_as_opaque(env, roc_function_call.data),
            roc_function_call.inc_n_data.into(),
            roc_function_call.data_is_owned.into(),
            env.alignment_intvalue(result_layout),
            layout_width(env, element1_layout),
            layout_width(env, element2_layout),
            layout_width(env, element3_layout),
            layout_width(env, element4_layout),
            layout_width(env, result_layout),
            dec_a.as_global_value().as_pointer_value().into(),
            dec_b.as_global_value().as_pointer_value().into(),
            dec_c.as_global_value().as_pointer_value().into(),
            dec_d.as_global_value().as_pointer_value().into(),
        ],
        bitcode::LIST_MAP4,
    )
}

/// List.concat : List elem, List elem -> List elem
pub fn list_concat<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    first_list: BasicValueEnum<'ctx>,
    second_list: BasicValueEnum<'ctx>,
    element_layout: &Layout<'a>,
) -> BasicValueEnum<'ctx> {
    call_list_bitcode_fn(
        env,
        &[
            list_to_c_abi(env, first_list).into(),
            list_to_c_abi(env, second_list).into(),
            env.alignment_intvalue(element_layout),
            layout_width(env, element_layout),
        ],
        bitcode::LIST_CONCAT,
    )
}

pub fn decrementing_elem_loop<'ctx, LoopFn>(
    builder: &Builder<'ctx>,
    ctx: &'ctx Context,
    parent: FunctionValue<'ctx>,
    ptr: PointerValue<'ctx>,
    len: IntValue<'ctx>,
    index_name: &str,
    mut loop_fn: LoopFn,
) -> PointerValue<'ctx>
where
    LoopFn: FnMut(IntValue<'ctx>, BasicValueEnum<'ctx>),
{
    decrementing_index_loop(builder, ctx, parent, len, index_name, |index| {
        // The pointer to the element in the list
        let elem_ptr = unsafe { builder.build_in_bounds_gep(ptr, &[index], "load_index") };

        let elem = builder.build_load(elem_ptr, "get_elem");

        loop_fn(index, elem);
    })
}

// a for-loop from the back to the front
fn decrementing_index_loop<'ctx, LoopFn>(
    builder: &Builder<'ctx>,
    ctx: &'ctx Context,
    parent: FunctionValue<'ctx>,
    end: IntValue<'ctx>,
    index_name: &str,
    mut loop_fn: LoopFn,
) -> PointerValue<'ctx>
where
    LoopFn: FnMut(IntValue<'ctx>),
{
    // constant 1i64
    let one = ctx.i64_type().const_int(1, false);

    // allocate a stack slot for the current index
    let index_alloca = builder.build_alloca(ctx.i64_type(), index_name);

    // we assume `end` is the length of the list
    // the final index is therefore `end - 1`
    let end_index = builder.build_int_sub(end, one, "end_index");
    builder.build_store(index_alloca, end_index);

    let loop_bb = ctx.append_basic_block(parent, "loop");
    builder.build_unconditional_branch(loop_bb);
    builder.position_at_end(loop_bb);

    let current_index = builder
        .build_load(index_alloca, index_name)
        .into_int_value();

    let next_index = builder.build_int_sub(current_index, one, "nextindex");

    builder.build_store(index_alloca, next_index);

    // The body of the loop
    loop_fn(current_index);

    // #index >= 0
    let condition = builder.build_int_compare(
        IntPredicate::SGE,
        next_index,
        ctx.i64_type().const_zero(),
        "bounds_check",
    );

    let after_loop_bb = ctx.append_basic_block(parent, "after_outer_loop_1");

    builder.build_conditional_branch(condition, loop_bb, after_loop_bb);
    builder.position_at_end(after_loop_bb);

    index_alloca
}

pub fn incrementing_elem_loop<'a, 'ctx, 'env, LoopFn>(
    env: &Env<'a, 'ctx, 'env>,
    parent: FunctionValue<'ctx>,
    element_layout: Layout<'a>,
    ptr: PointerValue<'ctx>,
    len: IntValue<'ctx>,
    index_name: &str,
    mut loop_fn: LoopFn,
) -> PointerValue<'ctx>
where
    LoopFn: FnMut(IntValue<'ctx>, BasicValueEnum<'ctx>),
{
    let builder = env.builder;

    incrementing_index_loop(env, parent, len, index_name, |index| {
        // The pointer to the element in the list
        let element_ptr = unsafe { builder.build_in_bounds_gep(ptr, &[index], "load_index") };

        let elem = load_roc_value(
            env,
            element_layout,
            element_ptr,
            "incrementing_element_loop_load",
        );

        loop_fn(index, elem);
    })
}

// This helper simulates a basic for loop, where
// and index increments up from 0 to some end value
pub fn incrementing_index_loop<'a, 'ctx, 'env, LoopFn>(
    env: &Env<'a, 'ctx, 'env>,
    parent: FunctionValue<'ctx>,
    end: IntValue<'ctx>,
    index_name: &str,
    mut loop_fn: LoopFn,
) -> PointerValue<'ctx>
where
    LoopFn: FnMut(IntValue<'ctx>),
{
    let ctx = env.context;
    let builder = env.builder;

    let entry = env.builder.get_insert_block().unwrap();

    // constant 1i64
    let one = env.ptr_int().const_int(1, false);

    // allocate a stack slot for the current index
    let index_alloca = builder.build_alloca(env.ptr_int(), index_name);
    builder.build_store(index_alloca, env.ptr_int().const_zero());

    let loop_bb = ctx.append_basic_block(parent, "loop");
    builder.build_unconditional_branch(loop_bb);
    builder.position_at_end(loop_bb);

    let current_index_phi = env.builder.build_phi(env.ptr_int(), "current_index");
    let current_index = current_index_phi.as_basic_value().into_int_value();

    let next_index = builder.build_int_add(current_index, one, "next_index");

    current_index_phi.add_incoming(&[(&next_index, loop_bb), (&env.ptr_int().const_zero(), entry)]);

    // The body of the loop
    loop_fn(current_index);

    // #index < end
    let loop_end_cond = bounds_check_comparison(builder, next_index, end);

    let after_loop_bb = ctx.append_basic_block(parent, "after_outer_loop_2");

    builder.build_conditional_branch(loop_end_cond, loop_bb, after_loop_bb);
    builder.position_at_end(after_loop_bb);

    index_alloca
}

pub fn build_basic_phi2<'a, 'ctx, 'env, PassFn, FailFn>(
    env: &Env<'a, 'ctx, 'env>,
    parent: FunctionValue<'ctx>,
    comparison: IntValue<'ctx>,
    mut build_pass: PassFn,
    mut build_fail: FailFn,
    ret_type: BasicTypeEnum<'ctx>,
) -> BasicValueEnum<'ctx>
where
    PassFn: FnMut() -> BasicValueEnum<'ctx>,
    FailFn: FnMut() -> BasicValueEnum<'ctx>,
{
    let builder = env.builder;
    let context = env.context;

    // build blocks
    let then_block = context.append_basic_block(parent, "then");
    let else_block = context.append_basic_block(parent, "else");
    let cont_block = context.append_basic_block(parent, "branchcont");

    builder.build_conditional_branch(comparison, then_block, else_block);

    // build then block
    builder.position_at_end(then_block);
    let then_val = build_pass();
    builder.build_unconditional_branch(cont_block);

    let then_block = builder.get_insert_block().unwrap();

    // build else block
    builder.position_at_end(else_block);
    let else_val = build_fail();
    builder.build_unconditional_branch(cont_block);

    let else_block = builder.get_insert_block().unwrap();

    // emit merge block
    builder.position_at_end(cont_block);

    let phi = builder.build_phi(ret_type, "branch");

    phi.add_incoming(&[(&then_val, then_block), (&else_val, else_block)]);

    phi.as_basic_value()
}

pub fn empty_polymorphic_list<'a, 'ctx, 'env>(env: &Env<'a, 'ctx, 'env>) -> BasicValueEnum<'ctx> {
    let struct_type = super::convert::zig_list_type(env);

    // The pointer should be null (aka zero) and the length should be zero,
    // so the whole struct should be a const_zero
    BasicValueEnum::StructValue(struct_type.const_zero())
}

pub fn load_list<'ctx>(
    builder: &Builder<'ctx>,
    wrapper_struct: StructValue<'ctx>,
    ptr_type: PointerType<'ctx>,
) -> (IntValue<'ctx>, PointerValue<'ctx>) {
    let ptr = load_list_ptr(builder, wrapper_struct, ptr_type);

    let length = builder
        .build_extract_value(wrapper_struct, Builtin::WRAPPER_LEN, "list_len")
        .unwrap()
        .into_int_value();

    (length, ptr)
}

pub fn load_list_ptr<'ctx>(
    builder: &Builder<'ctx>,
    wrapper_struct: StructValue<'ctx>,
    ptr_type: PointerType<'ctx>,
) -> PointerValue<'ctx> {
    // a `*mut u8` pointer
    let generic_ptr = builder
        .build_extract_value(wrapper_struct, Builtin::WRAPPER_PTR, "read_list_ptr")
        .unwrap()
        .into_pointer_value();

    // cast to the expected pointer type
    cast_basic_basic(builder, generic_ptr.into(), ptr_type.into()).into_pointer_value()
}

pub fn allocate_list<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    elem_layout: &Layout<'a>,
    number_of_elements: IntValue<'ctx>,
) -> PointerValue<'ctx> {
    let builder = env.builder;

    let len_type = env.ptr_int();
    let elem_bytes = elem_layout.stack_size(env.target_info) as u64;
    let bytes_per_element = len_type.const_int(elem_bytes, false);
    let number_of_data_bytes =
        builder.build_int_mul(bytes_per_element, number_of_elements, "data_length");

    let basic_type = basic_type_from_layout(env, elem_layout);
    let alignment_bytes = elem_layout.alignment_bytes(env.target_info);
    allocate_with_refcount_help(env, basic_type, alignment_bytes, number_of_data_bytes)
}

pub fn store_list<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    pointer_to_first_element: PointerValue<'ctx>,
    len: IntValue<'ctx>,
) -> BasicValueEnum<'ctx> {
    let builder = env.builder;

    let struct_type = super::convert::zig_list_type(env);

    // Store the pointer
    let mut struct_val = builder
        .build_insert_value(
            struct_type.get_undef(),
            pass_as_opaque(env, pointer_to_first_element),
            Builtin::WRAPPER_PTR,
            "insert_ptr_store_list",
        )
        .unwrap();

    // Store the length
    struct_val = builder
        .build_insert_value(struct_val, len, Builtin::WRAPPER_LEN, "insert_len")
        .unwrap();

    builder.build_bitcast(
        struct_val.into_struct_value(),
        super::convert::zig_list_type(env),
        "cast_collection",
    )
}

pub fn decref<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    wrapper_struct: StructValue<'ctx>,
    alignment: u32,
) {
    let (_, pointer) = load_list(
        env.builder,
        wrapper_struct,
        env.context.i8_type().ptr_type(AddressSpace::Generic),
    );

    crate::llvm::refcounting::decref_pointer_check_null(env, pointer, alignment);
}
