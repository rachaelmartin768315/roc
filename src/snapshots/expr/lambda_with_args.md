# META
~~~ini
description=Lambda with multiple arguments
type=expr
~~~
# SOURCE
~~~roc
|x, y| x + y
~~~
# PROBLEMS
NIL
# TOKENS
~~~zig
OpBar(1:1-1:2),LowerIdent(1:2-1:3),Comma(1:3-1:4),LowerIdent(1:5-1:6),OpBar(1:6-1:7),LowerIdent(1:8-1:9),OpPlus(1:10-1:11),LowerIdent(1:12-1:13),EndOfFile(1:13-1:13),
~~~
# PARSE
~~~clojure
(e-lambda @1-1-1-13
	(args
		(p-ident @1-2-1-3 (raw "x"))
		(p-ident @1-5-1-6 (raw "y")))
	(e-binop @1-8-1-13 (op "+")
		(e-ident @1-8-1-9 (qaul "") (raw "x"))
		(e-ident @1-12-1-13 (qaul "") (raw "y"))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(e-lambda @1-1-1-13 (id 78)
	(args
		(p-assign @1-2-1-3 (ident "x") (id 72))
		(p-assign @1-5-1-6 (ident "y") (id 73)))
	(e-binop @1-8-1-13 (op "add")
		(e-lookup-local @1-8-1-9
			(pattern (id 72)))
		(e-lookup-local @1-12-1-13
			(pattern (id 73)))))
~~~
# TYPES
~~~clojure
(expr (id 78) (type "*, * ? *"))
~~~
