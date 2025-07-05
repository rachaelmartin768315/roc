# META
~~~ini
description=dbg_double_newline
type=expr
~~~
# SOURCE
~~~roc
dbg dbg
 a g
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**NOT IMPLEMENTED**
This feature is not yet implemented or doesn't have a proper error report yet: canonicalize dbg expression
Let us know if you want to help!

# TOKENS
~~~zig
KwDbg(1:1-1:4),KwDbg(1:5-1:8),Newline(1:1-1:1),
LowerIdent(2:2-2:3),LowerIdent(2:4-2:5),Newline(1:1-1:1),
MalformedUnknownToken(3:1-3:2),MalformedUnknownToken(3:2-3:3),MalformedUnknownToken(3:3-3:4),EndOfFile(3:4-3:4),
~~~
# PARSE
~~~clojure
(e-dbg
	(e-dbg
		(e-ident @2.2-2.3 (raw "a"))))
~~~
# FORMATTED
~~~roc
dbg dbg
	a
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "not_implemented"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.1 (type "Error"))
~~~
