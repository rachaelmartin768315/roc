# META
~~~ini
description=A primitive
type=file:StmtTypeDecl.roc
~~~
# SOURCE
~~~roc
StmtTypeDecl := {}

Foo(a,b) : (a,b,Str,U64)
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
UpperIdent(1:1-1:13),OpColonEqual(1:14-1:16),OpenCurly(1:17-1:18),CloseCurly(1:18-1:19),
UpperIdent(3:1-3:4),NoSpaceOpenRound(3:4-3:5),LowerIdent(3:5-3:6),Comma(3:6-3:7),LowerIdent(3:7-3:8),CloseRound(3:8-3:9),OpColon(3:10-3:11),OpenRound(3:12-3:13),LowerIdent(3:13-3:14),Comma(3:14-3:15),LowerIdent(3:15-3:16),Comma(3:16-3:17),UpperIdent(3:17-3:20),Comma(3:20-3:21),UpperIdent(3:21-3:24),CloseRound(3:24-3:25),
EndOfFile(4:1-4:1),
~~~
# PARSE
~~~clojure
(file @1.1-3.25
	(type-module @1.1-1.13)
	(statements
		(s-type-decl @1.1-1.19
			(header @1.1-1.13 (name "StmtTypeDecl")
				(args))
			(ty-record @1.17-1.19))
		(s-type-decl @3.1-3.25
			(header @3.1-3.9 (name "Foo")
				(args
					(ty-var @3.5-3.6 (raw "a"))
					(ty-var @3.7-3.8 (raw "b"))))
			(ty-tuple @3.12-3.25
				(ty-var @3.13-3.14 (raw "a"))
				(ty-var @3.15-3.16 (raw "b"))
				(ty @3.17-3.20 (name "Str"))
				(ty @3.21-3.24 (name "U64"))))))
~~~
# FORMATTED
~~~roc
StmtTypeDecl := {}

Foo(a, b) : (a, b, Str, U64)
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(s-nominal-decl @1.1-1.19
		(ty-header @1.1-1.13 (name "StmtTypeDecl"))
		(ty-record @1.17-1.19))
	(s-alias-decl @3.1-3.25
		(ty-header @3.1-3.9 (name "Foo")
			(ty-args
				(ty-rigid-var @3.5-3.6 (name "a"))
				(ty-rigid-var @3.7-3.8 (name "b"))))
		(ty-tuple @3.12-3.25
			(ty-rigid-var-lookup (ty-rigid-var @3.5-3.6 (name "a")))
			(ty-rigid-var-lookup (ty-rigid-var @3.7-3.8 (name "b")))
			(ty-lookup @3.17-3.20 (name "Str") (builtin))
			(ty-lookup @3.21-3.24 (name "U64") (builtin)))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(type_decls
		(nominal @1.1-1.19 (type "StmtTypeDecl")
			(ty-header @1.1-1.13 (name "StmtTypeDecl")))
		(alias @3.1-3.25 (type "Foo(a, b)")
			(ty-header @3.1-3.9 (name "Foo")
				(ty-args
					(ty-rigid-var @3.5-3.6 (name "a"))
					(ty-rigid-var @3.7-3.8 (name "b"))))))
	(expressions))
~~~
