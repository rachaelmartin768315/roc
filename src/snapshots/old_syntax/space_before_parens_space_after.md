# META
~~~ini
description=space_before_parens_space_after
type=expr
~~~
# SOURCE
~~~roc
i
(4
)#(
~~~
# EXPECTED
UNDEFINED VARIABLE - space_before_parens_space_after.md:1:1:1:2
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:2),Newline(1:1-1:1),
OpenRound(2:1-2:2),Int(2:2-2:3),Newline(1:1-1:1),
CloseRound(3:1-3:2),EndOfFile(3:4-3:4),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "i"))
~~~
# FORMATTED
~~~roc
i
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
