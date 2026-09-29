@echo off
rem =====================================================================
rem  SnapIt - lanzador del instalador grafico
rem  Doble clic en este archivo. No necesita permisos de administrador.
rem =====================================================================
setlocal
set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"

echo.
echo   Abriendo el instalador de SnapIt...
echo.

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%installer\SnapIt-Setup.ps1" %*
set "CODE=%ERRORLEVEL%"

if not "%CODE%"=="0" (
    echo.
    echo   El instalador termino con codigo %CODE%.
    echo   Puedes probar la instalacion sin interfaz:
    echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%installer\SnapIt-Setup.ps1" -Unattended
    echo.
    pause
)
endlocal
