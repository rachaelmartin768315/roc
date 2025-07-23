# META
~~~ini
description=fuzz crash
type=file
~~~
# SOURCE
~~~roc
module[]r:a	where
module(a).h:s
~~~
# EXPECTED
COMPILER DIAGNOSTIC - fuzz_crash_055.md:0:0:0:0
# PROBLEMS
**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'undeclared_type_var' is not yet handled in report generation.
**fuzz_crash_055.md:0:0:0:0**

# TOKENS
~~~zig
KwModule(1:1-1:7),OpenSquare(1:7-1:8),CloseSquare(1:8-1:9),LowerIdent(1:9-1:10),OpColon(1:10-1:11),LowerIdent(1:11-1:12),KwWhere(1:13-1:18),
KwModule(2:1-2:7),NoSpaceOpenRound(2:7-2:8),LowerIdent(2:8-2:9),CloseRound(2:9-2:10),NoSpaceDotLowerIdent(2:10-2:12),OpColon(2:12-2:13),LowerIdent(2:13-2:14),EndOfFile(2:14-2:14),
~~~
# PARSE
~~~clojure
(file @1.1-2.14
	(module @1.1-1.9
		(exposes @1.7-1.9))
	(statements
		(s-type-anno @1.9-2.14 (name "r")
			(ty-var @1.11-1.12 (raw "a"))
			(where
				(method @2.1-2.14 (module-of "a") (name "h")
					(args)
					(ty-var @2.13-2.14 (raw "s")))))))
~~~
# FORMATTED
~~~roc
module []
r : a
	where
		module(a).h : s
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(s-type-anno @1.9-2.14 (name "r")
		(ty-var @1.11-1.12 (name "a"))
		(where
			(where-clause
				(type "mod-method")
				(var-name "a")
				(method-name "h"))))
	(external-decl (qualified-name "module(a).h") (module-name "module(a)") (local-name "h") (kind "value")))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
