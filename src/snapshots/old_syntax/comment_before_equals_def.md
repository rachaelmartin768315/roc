# META
~~~ini
description=comment_before_equals_def
type=expr
~~~
# SOURCE
~~~roc
t#
=3
e
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `t` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
LowerIdent(1:1-1:2),Newline(1:3-1:3),
OpAssign(2:1-2:2),Int(2:2-2:3),Newline(1:1-1:1),
LowerIdent(3:1-3:2),Newline(1:1-1:1),
MalformedUnknownToken(4:1-4:2),MalformedUnknownToken(4:2-4:3),MalformedUnknownToken(4:3-4:4),EndOfFile(4:4-4:4),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "t"))
~~~
# FORMATTED
~~~roc
t
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
