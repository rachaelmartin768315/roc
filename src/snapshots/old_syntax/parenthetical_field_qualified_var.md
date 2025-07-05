# META
~~~ini
description=parenthetical_field_qualified_var
type=expr
~~~
# SOURCE
~~~roc
(One.Two.rec).field
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `rec` in this scope.
Is there an `import` or `exposing` missing up-top?

# TOKENS
~~~zig
OpenRound(1:1-1:2),UpperIdent(1:2-1:5),NoSpaceDotUpperIdent(1:5-1:9),NoSpaceDotLowerIdent(1:9-1:13),CloseRound(1:13-1:14),NoSpaceDotLowerIdent(1:14-1:20),Newline(1:1-1:1),
MalformedUnknownToken(2:1-2:2),MalformedUnknownToken(2:2-2:3),MalformedUnknownToken(2:3-2:4),EndOfFile(2:4-2:4),
~~~
# PARSE
~~~clojure
(e-field-access @1.1-2.2
	(e-tuple @1.1-1.14
		(e-ident @1.2-1.13 (raw "One.Two.rec")))
	(e-ident @1.14-1.20 (raw "field")))
~~~
# FORMATTED
~~~roc
(One.rec).field
~~~
# CANONICALIZE
~~~clojure
(e-dot-access @1.1-2.2 (field "field")
	(receiver
		(e-runtime-error (tag "ident_not_in_scope"))))
~~~
# TYPES
~~~clojure
(expr @1.1-2.2 (type "*"))
~~~
