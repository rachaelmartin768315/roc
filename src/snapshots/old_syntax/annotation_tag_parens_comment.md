# META
~~~ini
description=annotation_tag_parens_comment
type=expr
~~~
# SOURCE
~~~roc
g:[T(T#
)]
D
~~~
# EXPECTED
UNDEFINED VARIABLE - annotation_tag_parens_comment.md:1:1:1:2
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:2),OpColon(1:2-1:3),OpenSquare(1:3-1:4),UpperIdent(1:4-1:5),NoSpaceOpenRound(1:5-1:6),UpperIdent(1:6-1:7),Newline(1:8-1:8),
CloseRound(2:1-2:2),CloseSquare(2:2-2:3),Newline(1:1-1:1),
UpperIdent(3:1-3:2),EndOfFile(3:2-3:2),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "g"))
~~~
# FORMATTED
~~~roc
g
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
