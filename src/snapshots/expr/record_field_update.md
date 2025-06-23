# META
~~~ini
description=Record with field update
type=expr
~~~
# SOURCE
~~~roc
{ person & age: 31 }
~~~
# PROBLEMS
PARSER: expr_unexpected_token
PARSER: ty_anno_unexpected_token
**UNDEFINED VARIABLE**
Nothing is named ``person`` in this scope.
Is there an `import` or `exposing` missing up-top?
**NOT IMPLEMENTED**
This feature is not yet implemented: statement type in block
# TOKENS
~~~zig
OpenCurly(1:1-1:2),LowerIdent(1:3-1:9),OpAmpersand(1:10-1:11),LowerIdent(1:12-1:15),OpColon(1:15-1:16),Int(1:17-1:19),CloseCurly(1:20-1:21),EndOfFile(1:21-1:21),
~~~
# PARSE
~~~clojure
(block (1:1-1:21)
	(statements
		(ident (1:3-1:9) "" "person")
		(malformed_expr (1:10-1:11) "expr_unexpected_token")
		(type_anno (1:12-1:21)
			"age"
			(malformed_expr (1:17-1:19) "ty_anno_unexpected_token"))))
~~~
# FORMATTED
~~~roc
{
	person
	
	age : 
}
~~~
# CANONICALIZE
~~~clojure
(e_block (1:1-1:21)
	(s_expr (1:3-1:11) "TODO")
	(e_runtime_error (1:1-1:1) "not_implemented"))
~~~
# TYPES
~~~clojure
(expr 17 (type "*"))
~~~