# META
~~~ini
description=f_not_not_f
type=expr
~~~
# SOURCE
~~~roc
f
!
!f
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `f` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
LowerIdent(1:1-1:2),Newline(1:1-1:1),
OpBang(2:1-2:2),Newline(1:1-1:1),
OpBang(3:1-3:2),LowerIdent(3:2-3:3),Newline(1:1-1:1),
MalformedUnknownToken(4:1-4:2),MalformedUnknownToken(4:2-4:3),MalformedUnknownToken(4:3-4:4),EndOfFile(4:4-4:4),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "f"))
~~~
# FORMATTED
~~~roc
f
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
