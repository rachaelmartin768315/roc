# META
~~~ini
description=fuzz crash
type=file
~~~
# SOURCE
~~~roc
0o0.0
0_0
0u8.0
0_
~~~
# PROBLEMS
TOKENIZE: (2:3-2:3) LeadingZero:
0_0
  ^PARSER: missing_header
PARSER: expr_unexpected_token
PARSER: expr_no_space_dot_int
**INVALID STATEMENT**
The statement **expr** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**INVALID STATEMENT**
The statement **expr** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**INVALID STATEMENT**
The statement **expr** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**INVALID STATEMENT**
The statement **expr** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

# TOKENS
~~~zig
Int(1:1-1:4),NoSpaceDotInt(1:4-1:6),Newline(1:1-1:1),
Int(2:1-2:4),Newline(1:1-1:1),
Int(3:1-3:4),NoSpaceDotInt(3:4-3:6),Newline(1:1-1:1),
Int(4:1-4:3),EndOfFile(4:3-4:3),
~~~
# PARSE
~~~clojure
(file (1:1-4:3)
	(malformed_header (1:1-1:4) "missing_header")
	(statements
		(malformed_expr (1:4-1:6) "expr_unexpected_token")
		(int (2:1-2:4) "0_0")
		(malformed_expr (3:4-3:6) "expr_no_space_dot_int")
		(int (4:1-4:3) "0_")))
~~~
# FORMATTED
~~~roc

0_0

0_
~~~
# CANONICALIZE
~~~clojure
(can_ir "empty")
~~~
# TYPES
~~~clojure
(inferred_types (defs) (expressions))
~~~