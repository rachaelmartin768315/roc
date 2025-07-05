# META
~~~ini
description=negative_single_quote
type=expr
~~~
# SOURCE
~~~roc
-'i'
~~~
~~~
# EXPECTED
UNEXPECTED TOKEN IN EXPRESSION - negative_single_quote.md:1:1:1:5
# PROBLEMS
**UNEXPECTED TOKEN IN EXPRESSION**
The token **-'i'** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**negative_single_quote.md:1:1:1:5:**
```roc
-'i'
```
^^^^


# TOKENS
~~~zig
OpUnaryMinus(1:1-1:2),SingleQuote(1:2-1:5),Newline(1:1-1:1),
MalformedUnknownToken(2:1-2:2),MalformedUnknownToken(2:2-2:3),MalformedUnknownToken(2:3-2:4),EndOfFile(2:4-2:4),
~~~
# PARSE
~~~clojure
(e-malformed @1.1-1.5 (reason "expr_unexpected_token"))
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
