# META
~~~ini
description=fuzz crash
type=file
~~~
# SOURCE
~~~roc
0{
~~~
~~~
# EXPECTED
MISSING HEADER - fuzz_crash_013.md:1:1:1:3
UNEXPECTED TOKEN IN EXPRESSION - fuzz_crash_013.md:2:1:2:3
UNEXPECTED TOKEN IN EXPRESSION - fuzz_crash_013.md:2:2:2:4
UNEXPECTED TOKEN IN EXPRESSION - fuzz_crash_013.md:2:3:2:4
# PROBLEMS
**MISSING HEADER**
Roc files must start with a module header.

For example:
        module [main]
or for an app:
        app [main!] { pf: platform "../basic-cli/platform.roc" }

Here is the problematic code:
**fuzz_crash_013.md:1:1:1:3:**
```roc
0{
```
^^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **~~** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**fuzz_crash_013.md:2:1:2:3:**
```roc
~~~
```
^^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **~~** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**fuzz_crash_013.md:2:2:2:4:**
```roc
~~~
```
 ^^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **~** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**fuzz_crash_013.md:2:3:2:4:**
```roc
~~~
```
  ^


**INVALID STATEMENT**
The statement **expression** is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

# TOKENS
~~~zig
Int(1:1-1:2),OpenCurly(1:2-1:3),Newline(1:1-1:1),
MalformedUnknownToken(2:1-2:2),MalformedUnknownToken(2:2-2:3),MalformedUnknownToken(2:3-2:4),EndOfFile(2:4-2:4),
~~~
# PARSE
~~~clojure
(file @1.1-2.4
	(malformed-header @1.1-1.3 (tag "missing_header"))
	(statements
		(e-block @1.2-2.4
			(statements
				(e-malformed @2.1-2.3 (reason "expr_unexpected_token"))
				(e-malformed @2.2-2.4 (reason "expr_unexpected_token"))
				(e-malformed @2.3-2.4 (reason "expr_unexpected_token"))))))
~~~
# FORMATTED
~~~roc
{
	
	
	
}
~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
