# META
~~~ini
description=implements_after_comment_with_newline malformed
type=expr
~~~
# SOURCE
~~~roc
C 4 #
 implements e:m
C
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
UpperIdent(1:1-1:2),Int(1:3-1:4),Newline(1:6-1:6),
KwImplements(2:2-2:12),LowerIdent(2:13-2:14),OpColon(2:14-2:15),LowerIdent(2:15-2:16),Newline(1:1-1:1),
UpperIdent(3:1-3:2),Newline(1:1-1:1),
MalformedUnknownToken(4:1-4:2),MalformedUnknownToken(4:2-4:3),MalformedUnknownToken(4:3-4:4),EndOfFile(4:4-4:4),
~~~
# PARSE
~~~clojure
(e-tag @1.1-1.2 (raw "C"))
~~~
# FORMATTED
~~~roc
C
~~~
# CANONICALIZE
~~~clojure
(e-tag @1.1-1.2 (name "C"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.2 (type "[C]*"))
~~~
