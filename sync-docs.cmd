@echo off
rem Keeps the GitHub Pages copy of the page in sync (Pages is served from /docs).
copy /y "%~dp0index.html" "%~dp0docs\index.html"
