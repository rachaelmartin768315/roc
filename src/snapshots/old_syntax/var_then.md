# META
~~~ini
description=var_then
type=expr
~~~
# SOURCE
~~~roc
thenever
~~~
# EXPECTED
UNDEFINED VARIABLE - var_then.md:1:1:1:9
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:9),EndOfFile(1:9-1:9),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.9 (raw "thenever"))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.9 (type "Error"))
~~~
