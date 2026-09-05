# Whitespace Diff Repro   

This note pins down the exact bytes our terminal-capture diff tool has
to reproduce. The trailing spaces inside the fenced block below are
the test fixture itself — they represent real trailing spaces a
terminal emitted after each line, and the diff tool is validated
against these exact bytes. Do not strip them.  

```text
$ ls -la   
total 24   
drwxr-xr-x  5 op  staff  160 Jan  1 00:00 .   
drwxr-xr-x  9 op  staff  288 Jan  1 00:00 ..  
```

Everything outside the fenced block above is ordinary prose and can
be cleaned up normally.  