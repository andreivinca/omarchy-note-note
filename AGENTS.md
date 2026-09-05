# Code style

- No spaghetti code, no hacky code, no workarounds. If a proper fix requires touching more code, do the proper fix.
- Write clean code: easy to read, easy to understand, easy to change.
- Every `if`, `else`, `for`, `while`, etc. must use braces `{ }`, even when the body is a single line.
- Never put an `if`, `else`, `for` or `while` and its body on the same line. The body goes on its own lines between the braces, one statement per line — `if (x) { a() }` is not allowed, and neither is a one-line function body that holds one.
