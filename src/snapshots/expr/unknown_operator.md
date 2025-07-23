# META
~~~ini
description=Unknown operator, should produce an error
type=expr
~~~
# SOURCE
~~~roc
1 ++ 2
~~~
# EXPECTED
UNEXPECTED TOKEN IN EXPRESSION - unknown_operator.md:1:4:1:5
COMPILER DIAGNOSTIC - unknown_operator.md:0:0:0:0
# PROBLEMS
**UNEXPECTED TOKEN IN EXPRESSION**
The token **+** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**unknown_operator.md:1:4:1:5:**
```roc
1 ++ 2
```
   ^


**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'expr_not_canonicalized' is not yet handled in report generation.
**unknown_operator.md:0:0:0:0**

# TOKENS
~~~zig
Int(1:1-1:2),OpPlus(1:3-1:4),OpPlus(1:4-1:5),Int(1:6-1:7),EndOfFile(1:7-1:7),
~~~
# PARSE
~~~clojure
(e-binop @1.1-1.5 (op "+")
	(e-int @1.1-1.2 (raw "1"))
	(e-malformed @1.4-1.5 (reason "expr_unexpected_token")))
~~~
# FORMATTED
~~~roc
1 + 
~~~
# CANONICALIZE
~~~clojure
(e-binop @1.1-1.5 (op "add")
	(e-int @1.1-1.2 (value "1"))
	(e-runtime-error (tag "expr_not_canonicalized")))
~~~
# TYPES
~~~clojure
(expr @1.1-1.5 (type "Error"))
~~~
