# META
~~~ini
description=Match expression with more than one rest pattern not permitted, should error
type=expr
~~~
# SOURCE
~~~roc
match numbers {
    [.., middle, ..] => ... # error, multiple rest patterns not allowed
}
~~~
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `numbers` in this scope.
Is there an `import` or `exposing` missing up-top?

**INVALID PATTERN**
This pattern contains invalid syntax or uses unsupported features.

**NOT IMPLEMENTED**
This feature is not yet implemented or doesn't have a proper error report yet: ...
Let us know if you want to help!

# TOKENS
~~~zig
KwMatch(1:1-1:6),LowerIdent(1:7-1:14),OpenCurly(1:15-1:16),Newline(1:1-1:1),
OpenSquare(2:5-2:6),DoubleDot(2:6-2:8),Comma(2:8-2:9),LowerIdent(2:10-2:16),Comma(2:16-2:17),DoubleDot(2:18-2:20),CloseSquare(2:20-2:21),OpFatArrow(2:22-2:24),TripleDot(2:25-2:28),Newline(2:30-2:72),
CloseCurly(3:1-3:2),EndOfFile(3:2-3:2),
~~~
# PARSE
~~~clojure
(e-match
	(e-ident @1.7-1.14 (qaul "") (raw "numbers"))
	(branches
		(branch @2.5-3.2
			(p-list @2.5-2.21
				(p-list-rest @2.6-2.8)
				(p-ident @2.10-2.16 (raw "middle"))
				(p-list-rest @2.18-2.20))
			(e-ellipsis))))
~~~
# FORMATTED
~~~roc
match numbers {
	[.., middle, ..] => ...
}
~~~
# CANONICALIZE
~~~clojure
(e-match @1.1-3.2
	(match @1.1-3.2
		(cond
			(e-runtime-error (tag "ident_not_in_scope")))
		(branches
			(branch
				(patterns
					(p-list @2.5-2.21 (degenerate false)
						(patterns
							(p-assign @2.10-2.16 (ident "middle")))
						(rest-at (index 0))))
				(value
					(e-runtime-error (tag "not_implemented")))))))
~~~
# TYPES
~~~clojure
(expr @1.1-3.2 (type "*"))
~~~
