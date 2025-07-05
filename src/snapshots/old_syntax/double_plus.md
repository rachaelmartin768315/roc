# META
~~~ini
description=double_plus fail
type=expr
~~~
# SOURCE
~~~roc
main =
    [] ++ []
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `main` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
LowerIdent(1:1-1:5),OpAssign(1:6-1:7),Newline(1:1-1:1),
OpenSquare(2:5-2:6),CloseSquare(2:6-2:7),OpPlus(2:8-2:9),OpPlus(2:9-2:10),OpenSquare(2:11-2:12),CloseSquare(2:12-2:13),Newline(1:1-1:1),
MalformedUnknownToken(3:1-3:2),MalformedUnknownToken(3:2-3:3),MalformedUnknownToken(3:3-3:4),EndOfFile(3:4-3:4),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.5 (raw "main"))
~~~
# FORMATTED
~~~roc
main
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.5 (type "Error"))
~~~
