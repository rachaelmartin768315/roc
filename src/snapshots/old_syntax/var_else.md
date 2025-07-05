# META
~~~ini
description=var_else
type=expr
~~~
# SOURCE
~~~roc
elsewhere
~~~
# EXPECTED
UNDEFINED VARIABLE - var_else.md:1:1:1:10
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:10),EndOfFile(1:10-1:10),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.10 (raw "elsewhere"))
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
(expr @1.1-1.10 (type "Error"))
~~~
