# META
~~~ini
description=type_in_parens_end fail
type=expr
~~~
# SOURCE
~~~roc
f : ( I64
~~~
# EXPECTED
UNDEFINED VARIABLE - type_in_parens_end.md:1:1:1:2
# PROBLEMS
**UNDEFINED VARIABLE**
Nothing is named `f` in this scope.
Is there an `import` or `exposing` missing up-top?

**type_in_parens_end.md:1:1:1:2:**
```roc
f : ( I64
```
^


# TOKENS
~~~zig
LowerIdent(1:1-1:2),OpColon(1:3-1:4),OpenRound(1:5-1:6),UpperIdent(1:7-1:10),EndOfFile(1:10-1:10),
~~~
# PARSE
~~~clojure
(e-ident @1.1-1.2 (raw "f"))
~~~
# FORMATTED
~~~roc
f
~~~
# CANONICALIZE
~~~clojure
(e-runtime-error (tag "ident_not_in_scope"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "Error"))
~~~
