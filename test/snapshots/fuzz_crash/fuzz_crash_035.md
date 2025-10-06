# META
~~~ini
description=fuzz crash
type=file:FuzzCrash035.roc
~~~
# SOURCE
~~~roc
FuzzCrash035 := {}

 
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
UpperIdent(1:1-1:13),OpColonEqual(1:14-1:16),OpenCurly(1:17-1:18),CloseCurly(1:18-1:19),
EndOfFile(4:1-4:1),
~~~
# PARSE
~~~clojure
(file @1.1-1.19
	(type-module @1.1-1.13)
	(statements
		(s-type-decl @1.1-1.19
			(header @1.1-1.13 (name "FuzzCrash035")
				(args))
			(ty-record @1.17-1.19))))
~~~
# FORMATTED
~~~roc
FuzzCrash035 := {}
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(s-nominal-decl @1.1-1.19
		(ty-header @1.1-1.13 (name "FuzzCrash035"))
		(ty-record @1.17-1.19)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(type_decls
		(nominal @1.1-1.19 (type "FuzzCrash035")
			(ty-header @1.1-1.13 (name "FuzzCrash035"))))
	(expressions))
~~~
