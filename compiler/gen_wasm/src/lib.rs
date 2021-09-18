mod backend;
pub mod from_wasm32_memory;
mod layout;

use bumpalo::Bump;
use parity_wasm::builder;
use parity_wasm::elements::{Instruction, Instruction::*, Internal, ValueType};

use roc_collections::all::{MutMap, MutSet};
use roc_module::symbol::{Interns, Symbol};
use roc_mono::ir::{Proc, ProcLayout};
use roc_mono::layout::LayoutIds;

use crate::backend::WasmBackend;

const PTR_SIZE: u32 = 4;
const PTR_TYPE: ValueType = ValueType::I32;

// All usages of these alignment constants take u32, so an enum wouldn't add any safety.
pub const ALIGN_1: u32 = 0;
pub const ALIGN_2: u32 = 1;
pub const ALIGN_4: u32 = 2;
pub const ALIGN_8: u32 = 3;

pub const STACK_POINTER_GLOBAL_ID: u32 = 0;
pub const STACK_ALIGNMENT_BYTES: i32 = 16;

#[derive(Clone, Copy, Debug)]
pub struct LocalId(pub u32);

pub struct Env<'a> {
    pub arena: &'a Bump, // not really using this much, parity_wasm works with std::vec a lot
    pub interns: Interns,
    pub exposed_to_host: MutSet<Symbol>,
}

pub fn build_module<'a>(
    env: &'a Env,
    procedures: MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
) -> Result<Vec<u8>, String> {
    let (builder, _) = build_module_help(env, procedures)?;
    let module = builder.build();
    module
        .to_bytes()
        .map_err(|e| -> String { format!("Error serialising Wasm module {:?}", e) })
}

pub fn build_module_help<'a>(
    env: &'a Env,
    procedures: MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
) -> Result<(builder::ModuleBuilder, u32), String> {
    let mut backend = WasmBackend::new();
    let mut layout_ids = LayoutIds::default();

    // Sort procedures by occurrence order
    //
    // We sort by the "name", but those are interned strings, and the name that is
    // interned first will have a lower number.
    //
    // But, the name that occurs first is always `main` because it is in the (implicit)
    // file header. Therefore sorting high to low will put other functions before main
    //
    // This means that for now other functions in the file have to be ordered "in reverse": if A
    // uses B, then the name of A must first occur after the first occurrence of the name of B
    let mut procedures: std::vec::Vec<_> = procedures.into_iter().collect();
    procedures.sort_by(|a, b| b.0 .0.cmp(&a.0 .0));

    let mut function_index: u32 = 0;
    for ((sym, layout), proc) in procedures {
        function_index = backend.build_proc(proc, sym)?;
        if env.exposed_to_host.contains(&sym) {
            let fn_name = layout_ids
                .get_toplevel(sym, &layout)
                .to_symbol_string(sym, &env.interns);

            let export = builder::export()
                .field(fn_name.as_str())
                .with_internal(Internal::Function(function_index))
                .build();

            backend.builder.push_export(export);
        }
    }

    // Because of the sorting above, we know the last function in the `for` is the main function.
    // Here we grab its index and return it, so that the test_wrapper is able to call it.
    // This is a workaround until we implement object files with symbols and relocations.
    let main_function_index = function_index;

    const MIN_MEMORY_SIZE_KB: u32 = 1024;
    const PAGE_SIZE_KB: u32 = 64;

    let memory = builder::MemoryBuilder::new()
        .with_min(MIN_MEMORY_SIZE_KB / PAGE_SIZE_KB)
        .build();
    backend.builder.push_memory(memory);
    let memory_export = builder::export()
        .field("memory")
        .with_internal(Internal::Memory(0))
        .build();
    backend.builder.push_export(memory_export);

    let stack_pointer_global = builder::global()
        .with_type(PTR_TYPE)
        .mutable()
        .init_expr(Instruction::I32Const((MIN_MEMORY_SIZE_KB * 1024) as i32))
        .build();
    backend.builder.push_global(stack_pointer_global);

    Ok((backend.builder, main_function_index))
}

fn encode_alignment(bytes: u32) -> Result<u32, String> {
    match bytes {
        1 => Ok(ALIGN_1),
        2 => Ok(ALIGN_2),
        4 => Ok(ALIGN_4),
        8 => Ok(ALIGN_8),
        _ => Err(format!("{:?}-byte alignment is not supported", bytes)),
    }
}

fn copy_memory(
    instructions: &mut Vec<Instruction>,
    from_ptr: LocalId,
    to_ptr: LocalId,
    size_with_alignment: u32,
    alignment_bytes: u32,
) -> Result<(), String> {
    let alignment_flag = encode_alignment(alignment_bytes)?;
    let size = size_with_alignment - alignment_bytes;
    let mut offset = 0;
    while size - offset >= 8 {
        instructions.push(GetLocal(to_ptr.0));
        instructions.push(GetLocal(from_ptr.0));
        instructions.push(I64Load(alignment_flag, offset));
        instructions.push(I64Store(alignment_flag, offset));
        offset += 8;
    }
    if size - offset >= 4 {
        instructions.push(GetLocal(to_ptr.0));
        instructions.push(GetLocal(from_ptr.0));
        instructions.push(I32Load(alignment_flag, offset));
        instructions.push(I32Store(alignment_flag, offset));
        offset += 4;
    }
    while size - offset > 0 {
        instructions.push(GetLocal(to_ptr.0));
        instructions.push(GetLocal(from_ptr.0));
        instructions.push(I32Load8U(alignment_flag, offset));
        instructions.push(I32Store8(alignment_flag, offset));
        offset += 1;
    }
    Ok(())
}

pub fn allocate_stack_frame(
    instructions: &mut Vec<Instruction>,
    size: i32,
    local_frame_pointer: LocalId,
) {
    let aligned_size = (size + STACK_ALIGNMENT_BYTES - 1) & (-STACK_ALIGNMENT_BYTES);
    instructions.extend([
        GetGlobal(STACK_POINTER_GLOBAL_ID),
        I32Const(aligned_size),
        I32Sub,
        TeeLocal(local_frame_pointer.0),
        SetGlobal(STACK_POINTER_GLOBAL_ID),
    ]);
}

pub fn free_stack_frame(
    instructions: &mut Vec<Instruction>,
    size: i32,
    local_frame_pointer: LocalId,
) {
    let aligned_size = (size + STACK_ALIGNMENT_BYTES - 1) & (-STACK_ALIGNMENT_BYTES);
    instructions.extend([
        GetLocal(local_frame_pointer.0),
        I32Const(aligned_size),
        I32Add,
        SetGlobal(STACK_POINTER_GLOBAL_ID),
    ]);
}
