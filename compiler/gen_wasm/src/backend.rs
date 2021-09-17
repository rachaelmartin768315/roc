use parity_wasm::builder;
use parity_wasm::builder::{CodeLocation, ModuleBuilder};
use parity_wasm::elements::{
    BlockType, Instruction, Instruction::*, Instructions, Local, ValueType,
};

use roc_collections::all::MutMap;
use roc_module::low_level::LowLevel;
use roc_module::symbol::Symbol;
use roc_mono::ir::{CallType, Expr, JoinPointId, Literal, Proc, Stmt};
use roc_mono::layout::{Builtin, Layout};

use crate::layout::WasmLayout;
use crate::{allocate_stack_frame, copy_memory, free_stack_frame, LocalId, PTR_TYPE};

// Don't allocate any constant data at address zero or near it. Would be valid, but bug-prone.
// Follow Emscripten's example by using 1kB (4 bytes would probably do)
const UNUSED_DATA_SECTION_BYTES: u32 = 1024;

#[derive(Clone, Copy, Debug)]
struct LabelId(u32);

#[derive(Debug)]
struct SymbolStorage(LocalId, WasmLayout);

enum LocalKind {
    Parameter,
    Variable,
}

// TODO: use Bumpalo Vec once parity_wasm supports general iterators (>=0.43)
pub struct WasmBackend<'a> {
    // Module: Wasm AST
    pub builder: ModuleBuilder,

    // Module: internal state & IR mappings
    _data_offset_map: MutMap<Literal<'a>, u32>,
    _data_offset_next: u32,
    proc_symbol_map: MutMap<Symbol, CodeLocation>,

    // Functions: Wasm AST
    instructions: std::vec::Vec<Instruction>,
    arg_types: std::vec::Vec<ValueType>,
    locals: std::vec::Vec<Local>,

    // Functions: internal state & IR mappings
    next_local_index: u32,
    stack_memory: u32,
    symbol_storage_map: MutMap<Symbol, SymbolStorage>,
    /// how many blocks deep are we (used for jumps)
    block_depth: u32,
    joinpoint_label_map: MutMap<JoinPointId, (u32, std::vec::Vec<LocalId>)>,
}

impl<'a> WasmBackend<'a> {
    pub fn new() -> Self {
        WasmBackend {
            // Module: Wasm AST
            builder: builder::module(),

            // Module: internal state & IR mappings
            _data_offset_map: MutMap::default(),
            _data_offset_next: UNUSED_DATA_SECTION_BYTES,
            proc_symbol_map: MutMap::default(),

            // Functions: Wasm AST
            instructions: std::vec::Vec::with_capacity(256),
            arg_types: std::vec::Vec::with_capacity(8),
            locals: std::vec::Vec::with_capacity(32),

            // Functions: internal state & IR mappings
            next_local_index: 0,
            stack_memory: 0,
            symbol_storage_map: MutMap::default(),
            block_depth: 0,
            joinpoint_label_map: MutMap::default(),
        }
    }

    fn reset(&mut self) {
        // Functions: Wasm AST
        self.instructions.clear();
        self.arg_types.clear();
        self.locals.clear();

        // Functions: internal state & IR mappings
        self.next_local_index = 0;
        self.stack_memory = 0;
        self.symbol_storage_map.clear();
        self.joinpoint_label_map.clear();
        assert_eq!(self.block_depth, 0);
    }

    pub fn build_proc(&mut self, proc: Proc<'a>, sym: Symbol) -> Result<u32, String> {
        let ret_layout = WasmLayout::new(&proc.ret_layout);

        let sig_builder = if let WasmLayout::StackMemory { .. } = ret_layout {
            self.arg_types.push(PTR_TYPE);
            self.next_local_index += 1;
            builder::signature()
        } else {
            builder::signature().with_result(ret_layout.value_type())
        };

        for (layout, symbol) in proc.args {
            self.insert_local(WasmLayout::new(layout), *symbol, LocalKind::Parameter);
        }

        let signature = sig_builder.with_params(self.arg_types.clone()).build_sig();

        self.build_stmt(&proc.body, &proc.ret_layout)?;

        let mut final_instructions = Vec::with_capacity(self.instructions.len() + 10);
        allocate_stack_frame(&mut final_instructions, self.stack_memory as i32);
        final_instructions.extend(self.instructions.clone());
        free_stack_frame(&mut final_instructions, self.stack_memory as i32);
        final_instructions.push(Instruction::End);

        let function_def = builder::function()
            .with_signature(signature)
            .body()
            .with_locals(self.locals.clone())
            .with_instructions(Instructions::new(final_instructions))
            .build() // body
            .build(); // function

        let location = self.builder.push_function(function_def);
        let function_index = location.body;
        self.proc_symbol_map.insert(sym, location);
        self.reset();

        Ok(function_index)
    }

    fn insert_local(&mut self, layout: WasmLayout, symbol: Symbol, kind: LocalKind) -> LocalId {
        match kind {
            LocalKind::Parameter => {
                // Don't increment stack_memory! Structs are allocated in caller's stack memory and passed as pointers.
                self.arg_types.push(layout.value_type());
            }
            LocalKind::Variable => {
                self.stack_memory += layout.stack_memory();
                self.locals.push(Local::new(1, layout.value_type()));
            }
        }

        let local_id = LocalId(self.next_local_index);
        self.next_local_index += 1;

        let storage = SymbolStorage(local_id, layout);
        self.symbol_storage_map.insert(symbol, storage);

        local_id
    }

    fn get_symbol_storage(&self, sym: &Symbol) -> Result<&SymbolStorage, String> {
        self.symbol_storage_map.get(sym).ok_or_else(|| {
            format!(
                "Symbol {:?} not found in function scope:\n{:?}",
                sym, self.symbol_storage_map
            )
        })
    }

    fn load_from_symbol(&mut self, sym: &Symbol) -> Result<(), String> {
        let SymbolStorage(LocalId(local_id), _) = self.get_symbol_storage(sym)?;
        let id: u32 = *local_id;
        self.instructions.push(GetLocal(id));
        Ok(())
    }

    /// start a loop that leaves a value on the stack
    fn start_loop_with_return(&mut self, value_type: ValueType) {
        self.block_depth += 1;

        // self.instructions.push(Loop(BlockType::NoResult));
        self.instructions.push(Loop(BlockType::Value(value_type)));
    }

    fn start_block(&mut self) {
        self.block_depth += 1;

        // Our blocks always end with a `return` or `br`,
        // so they never leave extra values on the stack
        self.instructions.push(Block(BlockType::NoResult));
    }

    fn end_block(&mut self) {
        self.block_depth -= 1;
        self.instructions.push(End);
    }

    fn build_stmt(&mut self, stmt: &Stmt<'a>, ret_layout: &Layout<'a>) -> Result<(), String> {
        match stmt {
            // This pattern is a simple optimisation to get rid of one local and two instructions per proc.
            // If we are just returning the expression result, then don't SetLocal and immediately GetLocal
            Stmt::Let(let_sym, expr, layout, Stmt::Ret(ret_sym)) if let_sym == ret_sym => {
                self.build_expr(let_sym, expr, layout)?;
                self.instructions.push(Return);
                Ok(())
            }

            Stmt::Let(sym, expr, layout, following) => {
                let wasm_layout = WasmLayout::new(layout);
                let local_id = self.insert_local(wasm_layout, *sym, LocalKind::Variable);

                self.build_expr(sym, expr, layout)?;
                self.instructions.push(SetLocal(local_id.0));

                self.build_stmt(following, ret_layout)?;
                Ok(())
            }

            Stmt::Ret(sym) => {
                use crate::layout::WasmLayout::*;

                let SymbolStorage(local_id, wasm_layout) =
                    self.symbol_storage_map.get(sym).unwrap();

                match wasm_layout {
                    LocalOnly(_, _) | HeapMemory => {
                        self.instructions.push(GetLocal(local_id.0));
                        self.instructions.push(Return);
                    }

                    StackMemory {
                        size,
                        alignment_bytes,
                    } => {
                        let from = local_id.clone();
                        let to = LocalId(0);
                        let copy_size: u32 = *size;
                        let copy_alignment_bytes: u32 = *alignment_bytes;
                        copy_memory(
                            &mut self.instructions,
                            from,
                            to,
                            copy_size,
                            copy_alignment_bytes,
                        )?;
                    }
                }

                Ok(())
            }

            Stmt::Switch {
                cond_symbol,
                cond_layout: _,
                branches,
                default_branch,
                ret_layout: _,
            } => {
                // NOTE currently implemented as a series of conditional jumps
                // We may be able to improve this in the future with `Select`
                // or `BrTable`

                // create (number_of_branches - 1) new blocks.
                for _ in 0..branches.len() {
                    self.start_block()
                }

                // the LocalId of the symbol that we match on
                let matched_on = match self.symbol_storage_map.get(cond_symbol) {
                    Some(SymbolStorage(local_id, _)) => local_id.0,
                    None => unreachable!("symbol not defined: {:?}", cond_symbol),
                };

                // then, we jump whenever the value under scrutiny is equal to the value of a branch
                for (i, (value, _, _)) in branches.iter().enumerate() {
                    // put the cond_symbol on the top of the stack
                    self.instructions.push(GetLocal(matched_on));

                    self.instructions.push(I32Const(*value as i32));

                    // compare the 2 topmost values
                    self.instructions.push(I32Eq);

                    // "break" out of `i` surrounding blocks
                    self.instructions.push(BrIf(i as u32));
                }

                // if we never jumped because a value matched, we're in the default case
                self.build_stmt(default_branch.1, ret_layout)?;

                // now put in the actual body of each branch in order
                // (the first branch would have broken out of 1 block,
                // hence we must generate its code first)
                for (_, _, branch) in branches.iter() {
                    self.end_block();

                    self.build_stmt(branch, ret_layout)?;
                }

                Ok(())
            }
            Stmt::Join {
                id,
                parameters,
                body,
                remainder,
            } => {
                // make locals for join pointer parameters
                let mut jp_parameter_local_ids = std::vec::Vec::with_capacity(parameters.len());
                for parameter in parameters.iter() {
                    let wasm_layout = WasmLayout::new(&parameter.layout);
                    let local_id =
                        self.insert_local(wasm_layout, parameter.symbol, LocalKind::Variable);

                    jp_parameter_local_ids.push(local_id);
                }

                self.start_block();

                self.joinpoint_label_map
                    .insert(*id, (self.block_depth, jp_parameter_local_ids));

                self.build_stmt(remainder, ret_layout)?;

                self.end_block();

                // A `return` inside of a `loop` seems to make it so that the `loop` itself
                // also "returns" (so, leaves on the stack) a value of the return type.
                let return_wasm_layout = WasmLayout::new(ret_layout);
                self.start_loop_with_return(return_wasm_layout.value_type());

                self.build_stmt(body, ret_layout)?;

                // ends the loop
                self.end_block();

                Ok(())
            }
            Stmt::Jump(id, arguments) => {
                let (target, locals) = &self.joinpoint_label_map[id];

                // put the arguments on the stack
                for (symbol, local_id) in arguments.iter().zip(locals.iter()) {
                    let argument = match self.symbol_storage_map.get(symbol) {
                        Some(SymbolStorage(local_id, _)) => local_id.0,
                        None => unreachable!("symbol not defined: {:?}", symbol),
                    };

                    self.instructions.push(GetLocal(argument));
                    self.instructions.push(SetLocal(local_id.0));
                }

                // jump
                let levels = self.block_depth - target;
                self.instructions.push(Br(levels));

                Ok(())
            }
            x => Err(format!("statement not yet implemented: {:?}", x)),
        }
    }

    fn build_expr(
        &mut self,
        sym: &Symbol,
        expr: &Expr<'a>,
        layout: &Layout<'a>,
    ) -> Result<(), String> {
        match expr {
            Expr::Literal(lit) => self.load_literal(lit, layout),

            Expr::Call(roc_mono::ir::Call {
                call_type,
                arguments,
            }) => match call_type {
                CallType::ByName { name: func_sym, .. } => {
                    for arg in *arguments {
                        self.load_from_symbol(arg)?;
                    }
                    let function_location = self.proc_symbol_map.get(func_sym).ok_or(format!(
                        "Cannot find function {:?} called from {:?}",
                        func_sym, sym
                    ))?;
                    self.instructions.push(Call(function_location.body));
                    Ok(())
                }

                CallType::LowLevel { op: lowlevel, .. } => {
                    self.build_call_low_level(lowlevel, arguments, layout)
                }
                x => Err(format!("the call type, {:?}, is not yet implemented", x)),
            },

            x => Err(format!("Expression is not yet implemented {:?}", x)),
        }
    }

    fn load_literal(&mut self, lit: &Literal<'a>, layout: &Layout<'a>) -> Result<(), String> {
        match lit {
            Literal::Bool(x) => {
                self.instructions.push(I32Const(*x as i32));
                Ok(())
            }
            Literal::Byte(x) => {
                self.instructions.push(I32Const(*x as i32));
                Ok(())
            }
            Literal::Int(x) => {
                let instruction = match layout {
                    Layout::Builtin(Builtin::Int64) => I64Const(*x as i64),
                    Layout::Builtin(
                        Builtin::Int32
                        | Builtin::Int16
                        | Builtin::Int8
                        | Builtin::Int1
                        | Builtin::Usize,
                    ) => I32Const(*x as i32),
                    x => panic!("loading literal, {:?}, is not yet implemented", x),
                };
                self.instructions.push(instruction);
                Ok(())
            }
            Literal::Float(x) => {
                let instruction = match layout {
                    Layout::Builtin(Builtin::Float64) => F64Const((*x as f64).to_bits()),
                    Layout::Builtin(Builtin::Float32) => F32Const((*x as f32).to_bits()),
                    x => panic!("loading literal, {:?}, is not yet implemented", x),
                };
                self.instructions.push(instruction);
                Ok(())
            }
            x => Err(format!("loading literal, {:?}, is not yet implemented", x)),
        }
    }

    fn build_call_low_level(
        &mut self,
        lowlevel: &LowLevel,
        args: &'a [Symbol],
        return_layout: &Layout<'a>,
    ) -> Result<(), String> {
        for arg in args {
            self.load_from_symbol(arg)?;
        }
        let wasm_layout = WasmLayout::new(return_layout);
        self.build_instructions_lowlevel(lowlevel, wasm_layout.value_type())?;
        Ok(())
    }

    fn build_instructions_lowlevel(
        &mut self,
        lowlevel: &LowLevel,
        return_value_type: ValueType,
    ) -> Result<(), String> {
        // TODO:  Find a way to organise all the lowlevel ops and layouts! There's lots!
        //
        // Some Roc low-level ops care about wrapping, clipping, sign-extending...
        // For those, we'll need to pre-process each argument before the main op,
        // so simple arrays of instructions won't work. But there are common patterns.
        let instructions: &[Instruction] = match lowlevel {
            // Wasm type might not be enough, may need to sign-extend i8 etc. Maybe in load_from_symbol?
            LowLevel::NumAdd => match return_value_type {
                ValueType::I32 => &[I32Add],
                ValueType::I64 => &[I64Add],
                ValueType::F32 => &[F32Add],
                ValueType::F64 => &[F64Add],
            },
            LowLevel::NumSub => match return_value_type {
                ValueType::I32 => &[I32Sub],
                ValueType::I64 => &[I64Sub],
                ValueType::F32 => &[F32Sub],
                ValueType::F64 => &[F64Sub],
            },
            LowLevel::NumMul => match return_value_type {
                ValueType::I32 => &[I32Mul],
                ValueType::I64 => &[I64Mul],
                ValueType::F32 => &[F32Mul],
                ValueType::F64 => &[F64Mul],
            },
            LowLevel::NumGt => {
                // needs layout of the argument to be implemented fully
                &[I32GtS]
            }
            _ => {
                return Err(format!("unsupported low-level op {:?}", lowlevel));
            }
        };
        self.instructions.extend_from_slice(instructions);
        Ok(())
    }
}
