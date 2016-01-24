@echo off
set THEIRS=%1
set YOURS=%2
start /max gvim -d %YOURS% %THEIRS%