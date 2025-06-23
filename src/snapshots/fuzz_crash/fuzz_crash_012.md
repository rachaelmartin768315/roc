# META
~~~ini
description=fuzz crash
type=file
~~~
# SOURCE
~~~roc
||(|(l888888888|
~~~
# PROBLEMS
**MISSING HEADER**
Roc files must start with a module header like 'module [main]' or 'app [main] { pf: platform "..." }'.

**UNEXPECTED TOKEN IN PATTERN**
This token is not expected in a pattern.

**UNEXPECTED TOKEN IN PATTERN**
This token is not expected in a pattern.

**PARSE ERROR**
A parsing error occurred.

**INVALID STATEMENT**
The statement **expr** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

# TOKENS
~~~zig
OpBar(1:1-1:2),OpBar(1:2-1:3),NoSpaceOpenRound(1:3-1:4),OpBar(1:4-1:5),NoSpaceOpenRound(1:5-1:6),LowerIdent(1:6-1:16),OpBar(1:16-1:17),EndOfFile(1:17-1:17),
~~~
# PARSE
~~~clojure
(file (1:1-1:17)
	(malformed_header (1:1-1:2) "missing_header")
	(statements (malformed_expr (1:17-1:17) "expected_expr_bar")))
~~~
# FORMATTED
~~~roc

~~~
# CANONICALIZE
~~~clojure
(can_ir "empty")
~~~
# TYPES
~~~clojure
(inferred_types (defs) (expressions))
~~~