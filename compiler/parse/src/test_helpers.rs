use crate::ast::{self, Attempting};
use crate::blankspace::space0_before;
use crate::expr::expr;
use crate::module::{header, module_defs};
use crate::parser::{loc, Parser, State, SyntaxError};
use bumpalo::collections::Vec;
use bumpalo::Bump;
use roc_region::all::Located;

#[allow(dead_code)]
pub fn parse_expr_with<'a>(
    arena: &'a Bump,
    input: &'a str,
) -> Result<ast::Expr<'a>, SyntaxError<'a>> {
    parse_loc_with(arena, input).map(|loc_expr| loc_expr.value)
}

pub fn parse_header_with<'a>(
    arena: &'a Bump,
    input: &'a str,
) -> Result<ast::Module<'a>, SyntaxError<'a>> {
    let state = State::new_in(arena, input.trim().as_bytes(), Attempting::Module);
    let answer = header().parse(arena, state);

    answer
        .map(|(_, loc_expr, _)| loc_expr)
        .map_err(|(_, fail, _)| fail)
}

#[allow(dead_code)]
pub fn parse_defs_with<'a>(
    arena: &'a Bump,
    input: &'a str,
) -> Result<Vec<'a, Located<ast::Def<'a>>>, SyntaxError<'a>> {
    let state = State::new_in(arena, input.trim().as_bytes(), Attempting::Module);
    let answer = module_defs().parse(arena, state);
    answer
        .map(|(_, loc_expr, _)| loc_expr)
        .map_err(|(_, fail, _)| fail)
}

#[allow(dead_code)]
pub fn parse_loc_with<'a>(
    arena: &'a Bump,
    input: &'a str,
) -> Result<Located<ast::Expr<'a>>, SyntaxError<'a>> {
    let state = State::new_in(arena, input.trim().as_bytes(), Attempting::Module);
    let parser = space0_before(loc(expr(0)), 0);
    let answer = parser.parse(&arena, state);

    answer
        .map(|(_, loc_expr, _)| loc_expr)
        .map_err(|(_, fail, _)| fail)
}
