@echo off
setlocal
for %%I in ("%~dp0..") do set "DIR=%%~fI"
node "%DIR%\dist\index.js" %*
