# The harness's own helpers: a check that fails gives its name, and checkEq names both values.
{ check, checkEq, ... }:
[
  (check "check: a false check gives its name" (check "x" false == "x"))
  (check "check: a true check is true" (check "x" true == true))
  (check "checkEq: equal values are true" (checkEq "y" [ 1 ] [ 1 ] == true))
  (check "checkEq: other values give the name and both values" (
    checkEq "y" { a = 1; } { a = 2; } == ''y: expected {"a":1}, got {"a":2}''
  ))
]
