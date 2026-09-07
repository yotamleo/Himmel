This directory contains three Python files: `calculator.py`, `formatter.py`, and `constants.py`. Apply the following unified diff to them.

```diff
--- a/calculator.py
+++ b/calculator.py
@@ -6,11 +6,21 @@
     return a - b
 
 
+def clamp(value, low, high):
+    if value < low:
+        return low
+    if value > high:
+        return high
+    return value
+
+
 def multiply(a, b):
     return a * b
 
 
 def divide(a, b):
+    if not isinstance(b, (int, float)):
+        raise TypeError("divisor must be numeric")
     if b == 0:
         raise ValueError("cannot divide by zero")
     return a / b
--- a/formatter.py
+++ b/formatter.py
@@ -2,9 +2,5 @@
     return "$%.2f" % amount
 
 
-def format_percent(value):
-    return "%.1f%%" % (value * 100)
-
-
 def format_list(items):
-    return ", ".join(str(item) for item in items)
+    return ", ".join(str(item).strip() for item in items)
--- a/constants.py
+++ b/constants.py
@@ -1,8 +1,10 @@
-VERSION = "1.0.0"
+VERSION = "1.1.0"
 MAX_RETRIES = 3
 TIMEOUT_SECONDS = 30
+MIN_TIMEOUT_SECONDS = 5
 
 DEFAULT_CONFIG = {
     "retries": MAX_RETRIES,
     "timeout": TIMEOUT_SECONDS,
+    "min_timeout": MIN_TIMEOUT_SECONDS,
 }
```

Apply this diff exactly as given, to all three files. Do not reformat, rewrap, re-indent, or otherwise touch any line beyond what the diff specifies — including lines the diff leaves untouched. Do not make any other edits, improvements, or cleanups to these files, and do not modify or create any other file.
