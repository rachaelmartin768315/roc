# META
~~~ini
description=Dot access expression
type=expr
~~~
# SOURCE
~~~roc
list.map(fn)
~~~
# EXPECTED
UNDEFINED VARIABLE - can_dot_access.md:1:1:1:5
UNDEFINED VARIABLE - can_dot_access.md:1:10:1:12
# PROBLEMS
NIL
# TOKENS
~~~zig
LowerIdent(1:1-1:5),NoSpaceDotLowerIdent(1:5-1:9),NoSpaceOpenRound(1:9-1:10),LowerIdent(1:10-1:12),CloseRound(1:12-1:13),EndOfFile(1:13-1:13),
~~~
# PARSE
~~~clojure
(e-field-access @1.1-1.13
	(e-ident @1.1-1.5 (raw "list"))
	(e-apply @1.5-1.13
		(e-ident @1.5-1.9 (raw "map"))
		(e-ident @1.10-1.12 (raw "fn"))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(e-dot-access @1.1-1.13 (field "Box")
	(receiver
		(e-lookup-local @1.1-1.5
			(p-assign @1.1-1.1 (ident "Bool"))))
	(args
		(e-lookup-local @1.10-1.12
			(p-assign @1.1-1.1 (ident "Decode")))))
~~~
# TYPES
~~~clojure
(expr @1.1-1.13 (type "Error"))
~~~
