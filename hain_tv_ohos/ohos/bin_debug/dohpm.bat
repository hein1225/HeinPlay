@rem Copyright (c) Huawei Technologies Co., Ltd. 2020-2030. All rights reserved.
@rem
@rem ----------------------------------------------------------------------------
@rem  OHPM startup script for Windows, version 1.0.0
@rem
@rem  Required ENV vars:
@rem  ------------------
@rem    NODE_HOME - location of a Node home dir
@rem    or
@rem    Add %NODE_HOME%/bin to the PATH environment variable
@rem ----------------------------------------------------------------------------
@rem
@echo off

@rem Set local scope for the variables with windows NT shell
if "%OS%"=="Windows_NT" setlocal enabledelayedexpansion

@rem Init params
set OHPM_NAME="ohpm"
set OHPM_SCRIPT_DIRNAME=%~dp0
set OHPM_FIRST_PARAM=%1
set OHPM_PARAMS=%*
set /a OHPM_FIRST_PARAM_LEN=0
@rem the execute result of bat
set EXECUTE_RESULT=0

@rem If the first parameter is not defined, it is assigned a "" value.
if NOT defined OHPM_FIRST_PARAM (
  set OHPM_FIRST_PARAM=""
)

@rem Check whether the first parameter contains the character string "ohpm"
echo M0 SCRIPT_DIRNAME="%OHPM_SCRIPT_DIRNAME%" FIRST=[!OHPM_FIRST_PARAM!] PARAMS=[!OHPM_PARAMS!]
echo !OHPM_FIRST_PARAM! | findstr /I /C:"%OHPM_NAME%" >NUL 2>&1
echo M1 findstr_errorlevel=%errorlevel%
if "%errorlevel%" == "0" (
  echo M2 -> calculateFirstParamLen
  call :calculateFirstParamLen
) else (
  echo M3 -> nodeEnvTest
  call :nodeEnvTest
)
@rem It must be set; otherwise, the external calling program will not be able
@rem to obtain the correct script execution result.
exit /b %EXECUTE_RESULT%

:calculateFirstParamLen
echo M10 calc LEN=!OHPM_FIRST_PARAM_LEN! FIRST=[!OHPM_FIRST_PARAM!] PARAMS=[!OHPM_PARAMS!]
if "!OHPM_FIRST_PARAM!"=="" (
  call :removeFirstParam
) else (
  set /a OHPM_FIRST_PARAM_LEN+=1
  @rem Remove the last char of OHPM_FIRST_PARAM
  set OHPM_FIRST_PARAM=!OHPM_FIRST_PARAM:~0,-1!
  if "!OHPM_FIRST_PARAM!" == "" (
    call :removeFirstParam
  ) else (
    call :calculateFirstParamLen
  )
)
exit /b

@rem Remove if the first param is script path
:removeFirstParam
echo M20 rem LEN=!OHPM_FIRST_PARAM_LEN! PARAMS=[!OHPM_PARAMS!]
if %OHPM_FIRST_PARAM_LEN% == 0 (
  call :nodeEnvTest
) else (
   set /a OHPM_FIRST_PARAM_LEN-=1
   @rem Remove the first char of OHPM_PARAMS
   set OHPM_PARAMS=%OHPM_PARAMS:~1%
   if %OHPM_FIRST_PARAM_LEN% == 0 (
     call :nodeEnvTest
   ) else (
     call :removeFirstParam
   )
)
exit /b

:nodeEnvTest
echo M30 nodeEnvTest PARAMS=[!OHPM_PARAMS!] SCRIPT_DIRNAME=[!OHPM_SCRIPT_DIRNAME!]
@rem if params is empty then show: ohpm -h
if "!OHPM_PARAMS!" == "" (
  set OHPM_PARAMS="-h"
)

if "%OHPM_SCRIPT_DIRNAME%" == "" set OHPM_SCRIPT_DIRNAME=.
set PM_CLI_PATH=%OHPM_SCRIPT_DIRNAME%\pm-cli.js
set NODE_EXE=node.exe

%NODE_EXE% --version >NUL 2>&1
if "%ERRORLEVEL%" == "0" (
  call :ohpmStart
  exit /b
)

if defined NODE_HOME (
  set NODE_HOME=!NODE_HOME:"=!
  set "PATH=!PATH!;!NODE_HOME!"
  set NODE_EXE=!NODE_HOME!/!NODE_EXE!

  !NODE_EXE! --version >NUL 2>&1
  if "%ERRORLEVEL%" == "0" (
    call :ohpmStart
    exit /b
  )

  set END_WORD=!NODE_HOME:~-3,3!
  if "!END_WORD!" == "bin" (
    set NODE_EXE=!NODE_HOME:~0,-4!/node.exe
  ) else (
    set NODE_EXE=!NODE_HOME!/bin/node.exe
  )

  !NODE_EXE! --version >NUL 2>&1
  if "!ERRORLEVEL!" == "0" (
    call :ohpmStart
    exit /b
  )
)

@rem Node environment test fail
echo.
echo [31mERROR: Failed to find the executable 'node' command, please check the following possible causes:[0m
echo.
echo [31m       1. NodeJs is not installed.[0m
echo.
echo [31m       2. 'node' command not added to PATH[0m
echo.
echo [31m       and the 'NODE_HOME' variable is not set in the environment variables to match your NodeJs installation location.[0m
echo.
set EXECUTE_RESULT=1
call :end
exit /b

:ohpmStart
echo M40 ohpmStart NODE_EXE=[!NODE_EXE!] PM_CLI=[!PM_CLI_PATH!]
"%NODE_EXE%" "%PM_CLI_PATH%" %OHPM_PARAMS%
set EXECUTE_RESULT=%ERRORLEVEL%
call :end
exit /b

:end
if "%ERRORLEVEL%" == "0" (
  if "%OS%" == "Windows_NT" endlocal
)
exit /b
