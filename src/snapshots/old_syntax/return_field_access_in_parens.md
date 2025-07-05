# META
~~~ini
description=return_field_access_in_parens
type=expr
~~~
# SOURCE
~~~roc
(return.o)
ss
~~~
~~~
# EXPECTED
UNEXPECTED TOKEN IN EXPRESSION - return_field_access_in_parens.md:1:2:1:10
PARSE ERROR - return_field_access_in_parens.md:1:10:1:10
# PROBLEMS
**UNEXPECTED TOKEN IN EXPRESSION**
The token **return.o** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**return_field_access_in_parens.md:1:2:1:10:**
```roc
(return.o)
```
 ^^^^^^^^


**PARSE ERROR**
A parsing error occurred: `expected_expr_close_round_or_comma`
This is an unexpected parsing error. Please check your syntax.

Here is the problematic code:
**return_field_access_in_parens.md:1:10:1:10:**
```roc
(return.o)
```
         


# TOKENS
~~~zig
OpenRound(1:1-1:2),KwReturn(1:2-1:8),NoSpaceDotLowerIdent(1:8-1:10),CloseRound(1:10-1:11),Newline(1:1-1:1),
LowerIdent(2:1-2:3),Newline(1:1-1:1),
MalformedUnknownToken(3:1-3:2),MalformedUnknownToken(3:2-3:3),MalformedUnknownToken(3:3-3:4),EndOfFile(3:4-3:4),
~~~
# PARSE
~~~clojure
(e-malformed @1.1-1.1 (reason "expected_expr_close_round_or_comma"))
~~~
# FORMATTED
~~~roc

~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
