use crate::llvm::build::Env;
use inkwell::values::{BasicValueEnum, PointerValue, StructValue};
use inkwell::AddressSpace;
use roc_builtins::bitcode;
use roc_mono::layout::{InLayout, Layout};
use roc_target::PtrWidth;

use super::bitcode::{call_str_bitcode_fn, BitcodeReturns};
use super::build::BuilderExt;

pub static CHAR_LAYOUT: InLayout = Layout::U8;

pub(crate) fn decode_from_utf8_result<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    pointer: PointerValue<'ctx>,
) -> StructValue<'ctx> {
    let builder = env.builder;
    let ctx = env.context;

    let fields = match env.target_info.ptr_width() {
        PtrWidth::Bytes4 | PtrWidth::Bytes8 => [
            env.ptr_int().into(),
            super::convert::zig_str_type(env).into(),
            env.context.bool_type().into(),
            ctx.i8_type().into(),
        ],
    };

    let record_type = env.context.struct_type(&fields, false);

    match env.target_info.ptr_width() {
        PtrWidth::Bytes4 | PtrWidth::Bytes8 => {
            let result_ptr_cast = env.builder.build_pointer_cast(
                pointer,
                record_type.ptr_type(AddressSpace::default()),
                "to_unnamed",
            );

            builder
                .new_build_load(
                    record_type,
                    result_ptr_cast,
                    "load_utf8_validate_bytes_result",
                )
                .into_struct_value()
        }
    }
}

/// Dec.toStr : Dec -> Str

/// Str.equal : Str, Str -> Bool
pub(crate) fn str_equal<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    value1: BasicValueEnum<'ctx>,
    value2: BasicValueEnum<'ctx>,
) -> BasicValueEnum<'ctx> {
    call_str_bitcode_fn(
        env,
        &[value1, value2],
        &[],
        BitcodeReturns::Basic,
        bitcode::STR_EQUAL,
    )
}

// Gets a pointer to just after the refcount for a list or seamless slice.
// The value is just after the refcount so that normal lists and seamless slices can share code paths easily.
pub(crate) fn str_refcount_ptr<'a, 'ctx, 'env>(
    env: &Env<'a, 'ctx, 'env>,
    value: BasicValueEnum<'ctx>,
) -> PointerValue<'ctx> {
    call_str_bitcode_fn(
        env,
        &[value],
        &[],
        BitcodeReturns::Basic,
        bitcode::STR_REFCOUNT_PTR,
    )
    .into_pointer_value()
}
