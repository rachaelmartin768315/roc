# META
~~~ini
description=multiline_type_signature_with_comment
type=expr
~~~
# SOURCE
~~~roc
f :# comment
    {}

42
~~~
# EXPECTED
UNDEFINED VARIABLE - multiline_type_signature_with_comment.md:1:1:1:2
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:2),OpColon(1:3-1:4),Newline(1:5-1:13),
OpenCurly(2:5-2:6),CloseCurly(2:6-2:7),Newline(1:1-1:1),
Newline(1:1-1:1),
Int(4:1-4:3),EndOfFile(4:3-4:3),
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
