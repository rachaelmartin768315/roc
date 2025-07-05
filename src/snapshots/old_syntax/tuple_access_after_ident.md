# META
~~~ini
description=tuple_access_after_ident
type=expr
~~~
# SOURCE
~~~roc
abc = (1, 2, 3)
abc.0
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `abc` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
LowerIdent(1:1-1:4),OpAssign(1:5-1:6),OpenRound(1:7-1:8),Int(1:8-1:9),Comma(1:9-1:10),Int(1:11-1:12),Comma(1:12-1:13),Int(1:14-1:15),CloseRound(1:15-1:16),Newline(1:1-1:1),
LowerIdent(2:1-2:4),NoSpaceDotInt(2:4-2:6),Newline(1:1-1:1),
MalformedUnknownToken(3:1-3:2),MalformedUnknownToken(3:2-3:3),MalformedUnknownToken(3:3-3:4),EndOfFile(3:4-3:4),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.4 (raw "abc"))
~~~
# FORMATTED
~~~roc
abc
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.4 (type "Error"))
~~~
