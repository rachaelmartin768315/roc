# META
~~~ini
description=Match expression with boolean-like tag patterns
type=expr
~~~
# SOURCE
~~~roc
match isReady {
	True => "ready to go!"
	False => "not ready yet"
}
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `isReady` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
KwMatch(1:1-1:6),LowerIdent(1:7-1:14),OpenCurly(1:15-1:16),Newline(1:1-1:1),
UpperIdent(2:2-2:6),OpFatArrow(2:7-2:9),StringStart(2:10-2:11),StringPart(2:11-2:23),StringEnd(2:23-2:24),Newline(1:1-1:1),
UpperIdent(3:2-3:7),OpFatArrow(3:8-3:10),StringStart(3:11-3:12),StringPart(3:12-3:25),StringEnd(3:25-3:26),Newline(1:1-1:1),
CloseCurly(4:1-4:2),Newline(1:1-1:1),
MalformedUnknownToken(5:1-5:2),MalformedUnknownToken(5:2-5:3),MalformedUnknownToken(5:3-5:4),EndOfFile(5:4-5:4),
~~~
# PARSE
~~~clojure
(e-match
	(e-ident @1.7-1.14 (raw "isReady"))
	(branches
		(branch @1.1-1.1
			(p-tag @2.2-2.6 (raw "True"))
			(e-string @2.10-2.24
				(e-string-part @2.11-2.23 (raw "ready to go!"))))
		(branch @1.1-1.1
			(p-tag @3.2-3.7 (raw "False"))
			(e-string @3.11-3.26
				(e-string-part @3.12-3.25 (raw "not ready yet"))))))
~~~
# FORMATTED
~~~roc
match isReady {
	True => "ready to go!"
	False => "not ready yet"
}
~~~
# CANONICALIZE
~~~clojure
(e-match @1.1-4.2
	(match @1.1-4.2
		(cond
			(e-runtime-error (tag "ident_not_in_scope")))
		(branches
			(branch
				(patterns
					(p-applied-tag @2.2-2.6 (degenerate false)))
				(value
					(e-string @2.10-2.24
						(e-literal @2.11-2.23 (string "ready to go!")))))
			(branch
				(patterns
					(p-applied-tag @3.2-3.7 (degenerate false)))
				(value
					(e-string @3.11-3.26
						(e-literal @3.12-3.25 (string "not ready yet"))))))))
~~~
# TYPES
~~~clojure
(expr @1.1-4.2 (type "Str"))
~~~
