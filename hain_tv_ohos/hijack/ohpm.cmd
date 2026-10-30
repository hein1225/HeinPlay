@echo off
rem OHPM shim: bypass DevEco ohpm.bat delayexpansion recursion (OS!=Windows_NT bug).
echo OHPM-SHIM CWD=[%CD%] ARGS=[%*] OS=[%OS%] >> "E:\code\HeinPlay\hain_tv\hijack\log.txt"
"D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "D:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\pm-cli.js" %*
exit /b %errorlevel%
