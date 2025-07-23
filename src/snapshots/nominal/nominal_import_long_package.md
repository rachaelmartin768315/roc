# META
~~~ini
description=Example of importing a nominal tag union from a module within a package, and renaming it using `as`
type=file
~~~
# SOURCE
~~~roc
module [red]

import design.Styles.Color exposing [Encoder as CE]

red : CE
red = ... # not implemented
~~~
# EXPECTED
UNEXPECTED TOKEN IN EXPRESSION - nominal_import_long_package.md:3:21:3:27
UNEXPECTED TOKEN IN EXPRESSION - nominal_import_long_package.md:3:28:3:36
LIST NOT CLOSED - nominal_import_long_package.md:3:51:3:52
COMPILER DIAGNOSTIC - nominal_import_long_package.md:0:0:0:0
COMPILER DIAGNOSTIC - nominal_import_long_package.md:0:0:0:0
COMPILER DIAGNOSTIC - nominal_import_long_package.md:0:0:0:0
COMPILER DIAGNOSTIC - nominal_import_long_package.md:0:0:0:0
# PROBLEMS
**UNEXPECTED TOKEN IN EXPRESSION**
The token **.Color** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**nominal_import_long_package.md:3:21:3:27:**
```roc
import design.Styles.Color exposing [Encoder as CE]
```
                    ^^^^^^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **exposing** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**nominal_import_long_package.md:3:28:3:36:**
```roc
import design.Styles.Color exposing [Encoder as CE]
```
                           ^^^^^^^^


**LIST NOT CLOSED**
This list is missing a closing bracket or has a syntax error.
Lists must be closed with **]** and list items must be separated by commas.
For example:     [1, 2, 3]

Here is the problematic code:
**nominal_import_long_package.md:3:51:3:52:**
```roc
import design.Styles.Color exposing [Encoder as CE]
```
                                                  ^


**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'invalid_top_level_statement' is not yet handled in report generation.
**nominal_import_long_package.md:0:0:0:0**

**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'invalid_top_level_statement' is not yet handled in report generation.
**nominal_import_long_package.md:0:0:0:0**

**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'invalid_top_level_statement' is not yet handled in report generation.
**nominal_import_long_package.md:0:0:0:0**

**COMPILER DIAGNOSTIC**

**Compiler Diagnostic**
Diagnostic type 'undeclared_type' is not yet handled in report generation.
**nominal_import_long_package.md:0:0:0:0**

# TOKENS
~~~zig
KwModule(1:1-1:7),OpenSquare(1:8-1:9),LowerIdent(1:9-1:12),CloseSquare(1:12-1:13),
KwImport(3:1-3:7),LowerIdent(3:8-3:14),NoSpaceDotUpperIdent(3:14-3:21),NoSpaceDotUpperIdent(3:21-3:27),KwExposing(3:28-3:36),OpenSquare(3:37-3:38),UpperIdent(3:38-3:45),KwAs(3:46-3:48),UpperIdent(3:49-3:51),CloseSquare(3:51-3:52),
LowerIdent(5:1-5:4),OpColon(5:5-5:6),UpperIdent(5:7-5:9),
LowerIdent(6:1-6:4),OpAssign(6:5-6:6),TripleDot(6:7-6:10),EndOfFile(6:28-6:28),
~~~
# PARSE
~~~clojure
(file @1.1-6.10
	(module @1.1-1.13
		(exposes @1.8-1.13
			(exposed-lower-ident @1.9-1.12
				(text "red"))))
	(statements
		(s-import @3.1-3.21 (raw "design.Styles"))
		(e-malformed @3.21-3.27 (reason "expr_unexpected_token"))
		(e-malformed @3.28-3.36 (reason "expr_unexpected_token"))
		(e-malformed @3.51-3.52 (reason "expected_expr_close_square_or_comma"))
		(s-type-anno @5.1-5.9 (name "red")
			(ty @5.7-5.9 (name "CE")))
		(s-decl @6.1-6.10
			(p-ident @6.1-6.4 (raw "red"))
			(e-ellipsis))))
~~~
# FORMATTED
~~~roc
module [red]

import design.Styles


red : CE
red = ... # not implemented

~~~
# CANONICALIZE
~~~clojure
(can-ir
	(def
		(pattern
			(p-assign @6.1-6.4 (ident "red")))
		(expr
			(e-not-implemented @1.1-1.1))
		(annotation
			(annotation
				(type-anno
					(ty @5.7-5.9 (name "CE"))))))
	(s-import @3.1-3.21 (module "design.Styles") (qualifier "design")
		(exposes)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt @6.1-6.4 (type "Error")))
	(expressions
		(expr @1.1-1.1 (type "Error"))))
~~~
