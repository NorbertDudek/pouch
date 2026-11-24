@echo off
setlocal
rem Pouch - first push to https://github.com/NorbertDudek/pouch
rem Run this file from the root folder of the project (P:\Projects\Pouch).

cd /d "%~dp0"
where git >nul 2>&1 || (echo [ERROR] Git is not installed or not in PATH. & exit /b 1)

if not exist ".git" (
    git init -b main || exit /b 1
) else (
    git branch -M main
)

git add -A

rem Safety check: nothing secret may end up in the commit
git diff --cached --name-only | findstr /i /r "config\.php$ \.sqlite$ \.sqlite3$ \.db$ \.jks$ \.keystore$" | findstr /v /i "config\.example\.php" >nul
if not errorlevel 1 (
    echo [STOP] A secret or database file is staged:
    git diff --cached --name-only | findstr /i /r "config\.php$ \.sqlite$ \.sqlite3$ \.db$ \.jks$ \.keystore$" | findstr /v /i "config\.example\.php"
    echo Remove it or add it to .gitignore, then run this script again.
    exit /b 1
)

echo.
echo Files to be committed:
git diff --cached --stat
echo.
choice /m "Commit and push to GitHub"
if errorlevel 2 exit /b 0

git commit -m "Initial public release" || exit /b 1
git remote get-url origin >nul 2>&1 || git remote add origin https://github.com/NorbertDudek/pouch.git
git push -u origin main || exit /b 1

choice /m "Create tag v1.0.0 (starts the Release workflow)"
if errorlevel 2 goto :done
git tag -a v1.0.0 -m "Pouch 1.0.0"
git push origin v1.0.0

:done
echo.
echo Done: https://github.com/NorbertDudek/pouch
endlocal
