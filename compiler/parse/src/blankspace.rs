use crate::ast::CommentOrNewline;
use crate::ast::Spaceable;
use crate::parser::{self, and, backtrackable, BadInputError, Parser, Progress::*};
use crate::state::State;
use bumpalo::collections::vec::Vec;
use bumpalo::Bump;
use roc_region::all::Loc;
use roc_region::all::Position;

pub fn space0_around_ee<'a, P, S, E>(
    parser: P,
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_before_problem: fn(Position) -> E,
    indent_after_problem: fn(Position) -> E,
) -> impl Parser<'a, Loc<S>, E>
where
    S: Spaceable<'a>,
    S: 'a,
    P: Parser<'a, Loc<S>, E>,
    P: 'a,
    E: 'a,
{
    parser::map_with_arena(
        and(
            space0_e(min_indent, space_problem, indent_before_problem),
            and(
                parser,
                space0_e(min_indent, space_problem, indent_after_problem),
            ),
        ),
        spaces_around_help,
    )
}

pub fn space0_before_optional_after<'a, P, S, E>(
    parser: P,
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_before_problem: fn(Position) -> E,
    indent_after_problem: fn(Position) -> E,
) -> impl Parser<'a, Loc<S>, E>
where
    S: Spaceable<'a>,
    S: 'a,
    P: Parser<'a, Loc<S>, E>,
    P: 'a,
    E: 'a,
{
    parser::map_with_arena(
        and(
            space0_e(min_indent, space_problem, indent_before_problem),
            and(
                parser,
                one_of![
                    backtrackable(space0_e(min_indent, space_problem, indent_after_problem)),
                    succeed!(&[] as &[_]),
                ],
            ),
        ),
        spaces_around_help,
    )
}

fn spaces_around_help<'a, S>(
    arena: &'a Bump,
    tuples: (
        &'a [CommentOrNewline<'a>],
        (Loc<S>, &'a [CommentOrNewline<'a>]),
    ),
) -> Loc<S>
where
    S: Spaceable<'a>,
    S: 'a,
{
    let (spaces_before, (loc_val, spaces_after)) = tuples;

    if spaces_before.is_empty() {
        if spaces_after.is_empty() {
            loc_val
        } else {
            arena
                .alloc(loc_val.value)
                .with_spaces_after(spaces_after, loc_val.region)
        }
    } else if spaces_after.is_empty() {
        arena
            .alloc(loc_val.value)
            .with_spaces_before(spaces_before, loc_val.region)
    } else {
        let wrapped_expr = arena
            .alloc(loc_val.value)
            .with_spaces_after(spaces_after, loc_val.region);

        arena
            .alloc(wrapped_expr.value)
            .with_spaces_before(spaces_before, wrapped_expr.region)
    }
}

pub fn space0_before_e<'a, P, S, E>(
    parser: P,
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_problem: fn(Position) -> E,
) -> impl Parser<'a, Loc<S>, E>
where
    S: Spaceable<'a>,
    S: 'a,
    P: Parser<'a, Loc<S>, E>,
    P: 'a,
    E: 'a,
{
    parser::map_with_arena(
        and!(space0_e(min_indent, space_problem, indent_problem), parser),
        |arena: &'a Bump, (space_list, loc_expr): (&'a [CommentOrNewline<'a>], Loc<S>)| {
            if space_list.is_empty() {
                loc_expr
            } else {
                arena
                    .alloc(loc_expr.value)
                    .with_spaces_before(space_list, loc_expr.region)
            }
        },
    )
}

pub fn space0_after_e<'a, P, S, E>(
    parser: P,
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_problem: fn(Position) -> E,
) -> impl Parser<'a, Loc<S>, E>
where
    S: Spaceable<'a>,
    S: 'a,
    P: Parser<'a, Loc<S>, E>,
    P: 'a,
    E: 'a,
{
    parser::map_with_arena(
        and!(parser, space0_e(min_indent, space_problem, indent_problem)),
        |arena: &'a Bump, (loc_expr, space_list): (Loc<S>, &'a [CommentOrNewline<'a>])| {
            if space_list.is_empty() {
                loc_expr
            } else {
                arena
                    .alloc(loc_expr.value)
                    .with_spaces_after(space_list, loc_expr.region)
            }
        },
    )
}

pub fn check_indent<'a, E>(
    min_indent: u16,
    indent_problem: fn(Position) -> E,
) -> impl Parser<'a, (), E>
where
    E: 'a,
{
    move |_, state: State<'a>| {
        if state.pos.column >= min_indent {
            Ok((NoProgress, (), state))
        } else {
            Err((NoProgress, indent_problem(state.pos), state))
        }
    }
}

pub fn space0_e<'a, E>(
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_problem: fn(Position) -> E,
) -> impl Parser<'a, &'a [CommentOrNewline<'a>], E>
where
    E: 'a,
{
    spaces_help_help(min_indent, space_problem, indent_problem)
}

#[inline(always)]
fn spaces_help_help<'a, E>(
    min_indent: u16,
    space_problem: fn(BadInputError, Position) -> E,
    indent_problem: fn(Position) -> E,
) -> impl Parser<'a, &'a [CommentOrNewline<'a>], E>
where
    E: 'a,
{
    use SpaceState::*;

    move |arena, mut state: State<'a>| {
        let comments_and_newlines = Vec::new_in(arena);

        match eat_spaces(state.bytes(), state.pos, comments_and_newlines) {
            HasTab(pos) => {
                // there was a tab character
                let mut state = state;
                state.pos = pos;
                // TODO: it _seems_ like if we're changing the line/column, we should also be
                // advancing the state by the corresponding number of bytes.
                // Not doing this is likely a bug!
                // state = state.advance(<something>);
                Err((
                    MadeProgress,
                    space_problem(BadInputError::HasTab, pos),
                    state,
                ))
            }
            Good {
                pos,
                bytes,
                comments_and_newlines,
            } => {
                if bytes == state.bytes() {
                    Ok((NoProgress, &[] as &[_], state))
                } else if state.pos.line != pos.line {
                    // we parsed at least one newline

                    state.indent_column = pos.column;

                    if pos.column >= min_indent {
                        state.pos = pos;
                        state = state.advance(state.bytes().len() - bytes.len());

                        Ok((MadeProgress, comments_and_newlines.into_bump_slice(), state))
                    } else {
                        Err((MadeProgress, indent_problem(state.pos), state))
                    }
                } else {
                    state.pos.column = pos.column;
                    state = state.advance(state.bytes().len() - bytes.len());

                    Ok((MadeProgress, comments_and_newlines.into_bump_slice(), state))
                }
            }
        }
    }
}

enum SpaceState<'a> {
    Good {
        pos: Position,
        bytes: &'a [u8],
        comments_and_newlines: Vec<'a, CommentOrNewline<'a>>,
    },
    HasTab(Position),
}

fn eat_spaces<'a>(
    mut bytes: &'a [u8],
    mut pos: Position,
    mut comments_and_newlines: Vec<'a, CommentOrNewline<'a>>,
) -> SpaceState<'a> {
    use SpaceState::*;

    for c in bytes {
        match c {
            b' ' => {
                bytes = &bytes[1..];
                pos.column += 1;
            }
            b'\n' => {
                bytes = &bytes[1..];
                pos.line += 1;
                pos.column = 0;
                comments_and_newlines.push(CommentOrNewline::Newline);
            }
            b'\r' => {
                bytes = &bytes[1..];
            }
            b'\t' => {
                return HasTab(pos);
            }
            b'#' => {
                pos.column += 1;
                return eat_line_comment(&bytes[1..], pos, comments_and_newlines);
            }
            _ => break,
        }
    }

    Good {
        pos,
        bytes,
        comments_and_newlines,
    }
}

fn eat_line_comment<'a>(
    mut bytes: &'a [u8],
    mut pos: Position,
    mut comments_and_newlines: Vec<'a, CommentOrNewline<'a>>,
) -> SpaceState<'a> {
    use SpaceState::*;

    let is_doc_comment = if let Some(b'#') = bytes.get(0) {
        match bytes.get(1) {
            Some(b' ') => {
                bytes = &bytes[2..];
                pos.column += 2;

                true
            }
            Some(b'\n') => {
                // consume the second # and the \n
                bytes = &bytes[2..];

                comments_and_newlines.push(CommentOrNewline::DocComment(""));
                pos.line += 1;
                pos.column = 0;
                return eat_spaces(bytes, pos, comments_and_newlines);
            }
            None => {
                // consume the second #
                pos.column += 1;
                bytes = &bytes[1..];

                return Good {
                    pos,
                    bytes,
                    comments_and_newlines,
                };
            }

            _ => false,
        }
    } else {
        false
    };

    let initial = bytes;
    let initial_column = pos.column;

    for c in bytes {
        match c {
            b'\t' => return HasTab(pos),
            b'\n' => {
                let delta = (pos.column - initial_column) as usize;
                let comment = unsafe { std::str::from_utf8_unchecked(&initial[..delta]) };

                if is_doc_comment {
                    comments_and_newlines.push(CommentOrNewline::DocComment(comment));
                } else {
                    comments_and_newlines.push(CommentOrNewline::LineComment(comment));
                }
                pos.line += 1;
                pos.column = 0;
                return eat_spaces(&bytes[1..], pos, comments_and_newlines);
            }
            _ => {
                bytes = &bytes[1..];
                pos.column += 1;
            }
        }
    }

    // We made it to the end of the bytes. This means there's a comment without a trailing newline.
    let delta = (pos.column - initial_column) as usize;
    let comment = unsafe { std::str::from_utf8_unchecked(&initial[..delta]) };

    if is_doc_comment {
        comments_and_newlines.push(CommentOrNewline::DocComment(comment));
    } else {
        comments_and_newlines.push(CommentOrNewline::LineComment(comment));
    }

    Good {
        pos,
        bytes,
        comments_and_newlines,
    }
}
