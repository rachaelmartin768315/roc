# META
~~~ini
description=Match expression with list patterns including empty list and rest patterns
type=expr
~~~
# SOURCE
~~~roc
match numbers {
    [] => acc
    [first, .. as rest] => first + acc
}
~~~
# PROBLEMS
**NOT IMPLEMENTED**
This feature is not yet implemented or doesn't have a proper error report yet: canonicalize match expression
Let us know if you want to help!

# TOKENS
~~~zig
KwMatch(1:1-1:6),LowerIdent(1:7-1:14),OpenCurly(1:15-1:16),Newline(1:1-1:1),
OpenSquare(2:5-2:6),CloseSquare(2:6-2:7),OpFatArrow(2:8-2:10),LowerIdent(2:11-2:14),Newline(1:1-1:1),
OpenSquare(3:5-3:6),LowerIdent(3:6-3:11),Comma(3:11-3:12),DoubleDot(3:13-3:15),KwAs(3:16-3:18),LowerIdent(3:19-3:23),CloseSquare(3:23-3:24),OpFatArrow(3:25-3:27),LowerIdent(3:28-3:33),OpPlus(3:34-3:35),LowerIdent(3:36-3:39),Newline(1:1-1:1),
CloseCurly(4:1-4:2),EndOfFile(4:2-4:2),
~~~
# PARSE
~~~clojure
(e-match
	(e-ident @1.7-1.14 (qaul "") (raw "numbers"))
	(branches
		(branch @2.5-3.6
			(p-list @2.5-2.7)
			(e-ident @2.11-2.14 (qaul "") (raw "acc")))
		(branch @3.5-4.2
			(p-list @3.5-3.24
				(p-ident @3.6-3.11 (raw "first"))
				(p-list-rest @3.13-3.23 (name "rest")))
			(e-binop @3.28-4.2 (op "+")
				(e-ident @3.28-3.33 (qaul "") (raw "first"))
				(e-ident @3.36-3.39 (qaul "") (raw "acc"))))))
~~~
# FORMATTED
~~~roc
match numbers {
	[] => acc
	[first, .. as rest] => first + acc
}
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "not_implemented"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.1 (type "Error"))
~~~
