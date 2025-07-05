# META
~~~ini
description=negative_in_apply_def
type=expr
~~~
# SOURCE
~~~roc
a=A
 -g a
a
~~~
# EXPECTED
UNDEFINED VARIABLE - negative_in_apply_def.md:1:1:1:2
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:2),OpAssign(1:2-1:3),UpperIdent(1:3-1:4),Newline(1:1-1:1),
OpUnaryMinus(2:2-2:3),LowerIdent(2:3-2:4),LowerIdent(2:5-2:6),Newline(1:1-1:1),
LowerIdent(3:1-3:2),EndOfFile(3:2-3:2),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "a"))
~~~
# FORMATTED
~~~roc
a
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
