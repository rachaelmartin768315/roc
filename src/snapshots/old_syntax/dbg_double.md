# META
~~~ini
description=dbg_double
type=expr
~~~
# SOURCE
~~~roc
dbg dbg g g
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
KwDbg(1:1-1:4),KwDbg(1:5-1:8),LowerIdent(1:9-1:10),LowerIdent(1:11-1:12),Newline(1:1-1:1),
MalformedUnknownToken(2:1-2:2),MalformedUnknownToken(2:2-2:3),MalformedUnknownToken(2:3-2:4),EndOfFile(2:4-2:4),
~~~
# PARSE
~~~clojure
(e-dbg
	(e-dbg
		(e-ident @1.9-1.10 (raw "g"))))
~~~
# FORMATTED
~~~roc
dbg dbg g
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "not_implemented"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.1 (type "Error"))
~~~
