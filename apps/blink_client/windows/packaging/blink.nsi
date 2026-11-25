; BLINK per-user installer (NSIS 3.13), compiled by scripts/package.py with
;   makensis -INPUTCHARSET UTF8 -DBLINK_IDENTITY=... blink.nsi
; (DEC-029, engineering.md "Packaging and install").
;
; Command line: /S installs silently; /D=<folder> (last, unquoted) picks the
; folder; /RELAUNCH starts BLINK once a silent update is done; /NODESKTOP
; keeps a silent first install off the desktop (the rehearsal uses it).
; The uninstall entry is HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<app id>.
; An update goes into the installed folder (no folder page); a /D= naming
; another folder moves the installation there (the old copy is uninstalled).
; A folder holding another program's Uninstall.exe is refused (exit code 7).
; User data lives outside the install folder and is never removed here.

!if "${NSIS_VERSION}" != "v3.13"
  !error "BLINK installer requires NSIS 3.13, not ${NSIS_VERSION}; scripts/package.py fetches the pinned build"
!endif

!macro BLINK_REQUIRE NAME
  !ifndef ${NAME}
    !error "${NAME} must be defined (scripts/package.py passes it)"
  !endif
!macroend
!insertmacro BLINK_REQUIRE BLINK_IDENTITY        ; blink, blink-dev, blink-test, blink-dev-test
!insertmacro BLINK_REQUIRE BLINK_APP_ID          ; io.github.chialecode.<identity>
!insertmacro BLINK_REQUIRE BLINK_PRODUCT_NAME    ; BLINK, BLINK Dev, ...
!insertmacro BLINK_REQUIRE BLINK_VERSION         ; DisplayVersion, e.g. 0.1.0-dev.202611230000
!insertmacro BLINK_REQUIRE BLINK_FILE_VERSION    ; four numbers, e.g. 0.1.0.0
!insertmacro BLINK_REQUIRE BLINK_SOURCE_DIR      ; staged app folder
!insertmacro BLINK_REQUIRE BLINK_ICON            ; channel icon
!insertmacro BLINK_REQUIRE BLINK_OUT_FILE        ; installer path
!insertmacro BLINK_REQUIRE BLINK_FILES_NSH       ; generated: BLINK_REMOVE_INSTALLED_FILES

!define BLINK_EXE "${BLINK_IDENTITY}.exe"
!define BLINK_MUTEX "${BLINK_IDENTITY}-instance"
!define BLINK_UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${BLINK_APP_ID}"
; 120 x 250 ms = 30 s, the wait scripts/package.py allows for a quit-for-update.
!define BLINK_QUIT_WAIT_TICKS 120

; Exit codes besides NSIS's own (0 done, 1 cancelled, 2 aborted).
!define BLINK_EXIT_BUSY 3          ; BLINK reported busy and kept running
!define BLINK_EXIT_QUIT_TIMEOUT 4  ; BLINK did not exit, or its exe stayed in use, within 30 s
!define BLINK_EXIT_QUIT_FAILED 5   ; BLINK runs, but asking it to quit failed
!define BLINK_EXIT_FOLDER_TAKEN 7  ; the folder holds another program's Uninstall.exe
!define BLINK_EXIT_FILES_NOT_WRITTEN 8 ; some files could not be written; the uninstall entry is left as it was

Unicode true
ManifestDPIAware true
; zlib: its module is under the zlib/libpng licence like the rest of the stub
; (NSIS's LZMA module is CPL-1.0; see docs/research/2026-11-24-nsis-installer.md).
SetCompressor /SOLID zlib
RequestExecutionLevel user
Name "${BLINK_PRODUCT_NAME}"
OutFile "${BLINK_OUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\${BLINK_IDENTITY}"
; An update goes into the folder of the installed version.
InstallDirRegKey HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"
BrandingText " "
ShowInstDetails nevershow
ShowUninstDetails nevershow

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

!define MUI_ICON "${BLINK_ICON}"
!define MUI_UNICON "${BLINK_ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${BLINK_EXE}"
; The finish page offers the desktop shortcut, unticked as before; silent
; installs make it on a first install only (see the install section).
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_TEXT "创建桌面快捷方式"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut
!define MUI_PAGE_CUSTOMFUNCTION_PRE BlinkDirectoryPre
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE BlinkDirectoryLeave
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

VIProductVersion "${BLINK_FILE_VERSION}"
VIFileVersion "${BLINK_FILE_VERSION}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "ProductName" "${BLINK_PRODUCT_NAME}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "ProductVersion" "${BLINK_VERSION}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "FileVersion" "${BLINK_FILE_VERSION}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "FileDescription" "${BLINK_PRODUCT_NAME} Setup"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "CompanyName" "BLINK"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "LegalCopyright" "Apache-2.0"

; BLINK_REMOVE_INSTALLED_FILES: deletes exactly the files this version
; installs, then the folders it made when they are empty.
!include "${BLINK_FILES_NSH}"

Var FirstInstall

; Leaves "1" on the stack when BLINK of this identity runs (its
; single-instance mutex exists, or exists and cannot be opened), else "0".
!macro BLINK_IS_RUNNING_FUNCTION UN
Function ${UN}BlinkIsRunning
  Push $0
  Push $1
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${BLINK_MUTEX}") p.r0 ?e'
  Pop $1
  ${If} $0 <> 0
    System::Call 'kernel32::CloseHandle(p r0)'
    StrCpy $1 "1"
  ${ElseIf} $1 = 5
    StrCpy $1 "1"
  ${Else}
    StrCpy $1 "0"
  ${EndIf}
  Exch $1
  Exch
  Pop $0
FunctionEnd
!macroend
!insertmacro BLINK_IS_RUNNING_FUNCTION ""
!insertmacro BLINK_IS_RUNNING_FUNCTION "un."

; Asks a running BLINK to save and quit (--quit-for-update) and waits up to
; 30 s for it to exit; it is never ended by force. Silent runs go ahead
; without asking, the others ask first. When BLINK keeps running, the
; installer or uninstaller quits with one of the BLINK_EXIT_* codes.
!macro BLINK_CLOSE_APP_FUNCTION UN
Function ${UN}BlinkCloseApp
  Push $0
  Push $1
  Push $2
  Push $3
  ; The running copy is the installed one, wherever it was installed.
  ReadRegStr $1 HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"
  ${If} $1 == ""
    StrCpy $1 "$INSTDIR"
  ${EndIf}
  StrCpy $1 "$1\${BLINK_EXE}"
  StrCpy $2 0
  Call ${UN}BlinkIsRunning
  Pop $0
  ${If} $0 == "1"
    MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION "${BLINK_PRODUCT_NAME} 正在运行。点“确定”让它保存后退出并继续，点“取消”退出。" /SD IDOK IDOK blink_quit
    SetErrorLevel 1
    Quit
    blink_quit:
    ${IfNot} ${FileExists} "$1"
      MessageBox MB_OK|MB_ICONSTOP "${BLINK_PRODUCT_NAME} 正在运行，但找不到 $1 来请它退出。请先从托盘退出 ${BLINK_PRODUCT_NAME} 再试。" /SD IDOK
      SetErrorLevel ${BLINK_EXIT_QUIT_FAILED}
      Quit
    ${EndIf}
    ClearErrors
    ExecWait '"$1" --quit-for-update' $2
    ${If} ${Errors}
      MessageBox MB_OK|MB_ICONSTOP "无法请 ${BLINK_PRODUCT_NAME} 退出。请先从托盘退出它再试。" /SD IDOK
      SetErrorLevel ${BLINK_EXIT_QUIT_FAILED}
      Quit
    ${EndIf}
    ${If} $2 = 2
      MessageBox MB_OK|MB_ICONSTOP "${BLINK_PRODUCT_NAME} 正在处理任务，暂时不能退出。请稍后再试。" /SD IDOK
      SetErrorLevel ${BLINK_EXIT_BUSY}
      Quit
    ${EndIf}
    ${If} $2 <> 0
      ; The request did not get through (pipe or protocol error). Unless BLINK
      ; happened to exit meanwhile, there is nothing to wait for.
      Call ${UN}BlinkIsRunning
      Pop $0
      ${If} $0 == "1"
        MessageBox MB_OK|MB_ICONSTOP "无法请 ${BLINK_PRODUCT_NAME} 退出。请先从托盘退出它再试。" /SD IDOK
        SetErrorLevel ${BLINK_EXIT_QUIT_FAILED}
        Quit
      ${EndIf}
    ${EndIf}
    StrCpy $2 0
    ${Do}
      Call ${UN}BlinkIsRunning
      Pop $0
      ${If} $0 != "1"
        ${Break}
      ${EndIf}
      ${If} $2 >= ${BLINK_QUIT_WAIT_TICKS}
        MessageBox MB_OK|MB_ICONSTOP "${BLINK_PRODUCT_NAME} 在 30 秒内没有退出（没有强制结束它）。请稍后再试。" /SD IDOK
        SetErrorLevel ${BLINK_EXIT_QUIT_TIMEOUT}
        Quit
      ${EndIf}
      Sleep 250
      IntOp $2 $2 + 1
    ${Loop}
  ${EndIf}
  ; The mutex goes before the process has ended and let go of its files, and
  ; a copy without the mutex (still exiting, or hung) holds them too: within
  ; the same 30 s, wait until the installed exe can be opened for writing,
  ; which a running image refuses with a sharing violation (32). Any other
  ; refusal (read-only, no access) is left to File and Delete. OPEN_EXISTING
  ; never creates the file.
  ${If} ${FileExists} "$1"
    ${Do}
      System::Call 'kernel32::CreateFileW(w r1, i 0x40000000, i 7, p 0, i 3, i 0x80, p 0) p.r0 ?e'
      Pop $3
      ${If} $0 != -1
        System::Call 'kernel32::CloseHandle(p r0)'
        ${Break}
      ${EndIf}
      ${If} $3 <> 32
        ${Break}
      ${EndIf}
      ${If} $2 >= ${BLINK_QUIT_WAIT_TICKS}
        MessageBox MB_OK|MB_ICONSTOP "$1 仍在使用中（${BLINK_PRODUCT_NAME} 可能还在退出），30 秒后仍未释放，没有强制结束它。请稍后再试。" /SD IDOK
        SetErrorLevel ${BLINK_EXIT_QUIT_TIMEOUT}
        Quit
      ${EndIf}
      Sleep 250
      IntOp $2 $2 + 1
    ${Loop}
  ${EndIf}
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd
!macroend
!insertmacro BLINK_CLOSE_APP_FUNCTION ""
!insertmacro BLINK_CLOSE_APP_FUNCTION "un."

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "${BLINK_PRODUCT_NAME} 只支持 64 位 Windows。" /SD IDOK
    Abort
  ${EndIf}
FunctionEnd

; Leaves "1" on the stack when $INSTDIR holds an Uninstall.exe that is not
; this identity's installed copy (another program, or another BLINK channel),
; else "0". Such an uninstaller is never run or overwritten.
Function BlinkFolderTaken
  Push $0
  Push $1
  StrCpy $1 "0"
  ${If} ${FileExists} "$INSTDIR\Uninstall.exe"
    ReadRegStr $0 HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"
    ${If} $0 != $INSTDIR
      StrCpy $1 "1"
      ; Our own copy whose uninstall entry is gone (an interrupted install, a
      ; registry cleaner) is updated in place instead.
      ${If} $0 == ""
      ${AndIf} ${FileExists} "$INSTDIR\${BLINK_EXE}"
        StrCpy $1 "0"
      ${EndIf}
    ${EndIf}
  ${EndIf}
  Exch $1
  Exch
  Pop $0
FunctionEnd

; An update goes into the installed folder: no folder page then.
Function BlinkDirectoryPre
  ReadRegStr $0 HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"
  ${If} $0 != ""
    Abort
  ${EndIf}
FunctionEnd

Function BlinkDirectoryLeave
  Call BlinkFolderTaken
  Pop $0
  ${If} $0 == "1"
    MessageBox MB_OK|MB_ICONSTOP "$INSTDIR 里已装有别的程序。请换一个文件夹。"
    Abort
  ${EndIf}
FunctionEnd

Function CreateDesktopShortcut
  SetOutPath "$INSTDIR"
  CreateShortCut "$DESKTOP\${BLINK_PRODUCT_NAME}.lnk" "$INSTDIR\${BLINK_EXE}"
FunctionEnd

Section "Install"
  ; Silent installs (and anything past the folder page) check the folder here.
  Call BlinkFolderTaken
  Pop $0
  ${If} $0 == "1"
    MessageBox MB_OK|MB_ICONSTOP "$INSTDIR 里已装有别的程序。请换一个文件夹再安装 ${BLINK_PRODUCT_NAME}。" /SD IDOK
    SetErrorLevel ${BLINK_EXIT_FOLDER_TAKEN}
    Quit
  ${EndIf}
  Call BlinkCloseApp

  StrCpy $FirstInstall "1"
  ReadRegStr $0 HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"
  ${If} $0 == ""
  ${OrIf} $0 == $INSTDIR
    ; Installed here (or our own copy here lost its entry; the folder check refused anything else).
    ${If} ${FileExists} "$INSTDIR\Uninstall.exe"
      StrCpy $FirstInstall "0"
      ; The installed version's uninstaller removes exactly its own files
      ; (/UPDATE keeps the shortcuts and the uninstall entry), so files this
      ; version no longer ships do not linger. _?= runs it in place and waits.
      ClearErrors
      ExecWait '"$INSTDIR\Uninstall.exe" /S /UPDATE _?=$INSTDIR'
      ${If} ${Errors}
        DetailPrint "旧版本的卸载程序没能运行，旧版本独有的文件可能留在 $INSTDIR。"
      ${EndIf}
    ${EndIf}
  ${ElseIf} ${FileExists} "$0\Uninstall.exe"
    ; Installed in another folder (a different /D=): uninstall that copy
    ; completely first, so one copy and one uninstall entry remain.
    ClearErrors
    ExecWait '"$0\Uninstall.exe" /S _?=$0' $1
    ${If} ${Errors}
    ${OrIf} $1 <> 0
      ; Keep its uninstaller: the old copy is still there and can be removed later.
      DetailPrint "没能卸载 $0 里的旧副本。"
    ${Else}
      Delete "$0\Uninstall.exe"
      RMDir "$0"
    ${EndIf}
  ${EndIf}

  SetOutPath "$INSTDIR"
  ; Under /S, File skips a file it cannot write (held open, no write
  ; permission) and only sets the error flag. Stop before the uninstaller, the
  ; shortcuts and the entry: the entry is left as it was (the old version on an
  ; update, none on a first install or a move to another folder), so the next
  ; install into this folder runs the old uninstaller when there is one
  ; (/UPDATE keeps it) and writes everything again.
  ClearErrors
  File /r "${BLINK_SOURCE_DIR}\*"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONSTOP "有文件没能写入 $INSTDIR（可能被别的程序占用）。请关闭占用的程序后重新安装 ${BLINK_PRODUCT_NAME}。" /SD IDOK
    SetErrorLevel ${BLINK_EXIT_FILES_NOT_WRITTEN}
    Quit
  ${EndIf}
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortCut "$SMPROGRAMS\${BLINK_PRODUCT_NAME}.lnk" "$INSTDIR\${BLINK_EXE}"
  ${If} ${Silent}
  ${AndIf} $FirstInstall == "1"
    ${GetParameters} $0
    ClearErrors
    ${GetOptions} $0 "/NODESKTOP" $1
    ${If} ${Errors}
      Call CreateDesktopShortcut
    ${EndIf}
  ${EndIf}

  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "DisplayName" "${BLINK_PRODUCT_NAME}"
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "DisplayVersion" "${BLINK_VERSION}"
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "DisplayIcon" '"$INSTDIR\${BLINK_EXE}"'
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "Publisher" "BLINK"
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/chialecode/blink"
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${BLINK_UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${BLINK_UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${BLINK_UNINSTALL_KEY}" "EstimatedSize" "$0"

  ${If} ${Silent}
    ${GetParameters} $0
    ClearErrors
    ${GetOptions} $0 "/RELAUNCH" $1
    ${IfNot} ${Errors}
      Exec '"$INSTDIR\${BLINK_EXE}"'
    ${EndIf}
  ${EndIf}
SectionEnd

; Deletes the shortcut on the stack, trying again for 5 s while Explorer
; still holds a new shortcut open; succeeds when there is none.
Function un.BlinkDeleteShortcut
  Exch $0
  Push $1
  StrCpy $1 50
  ${Do}
    ClearErrors
    Delete "$0"
    ${IfNot} ${Errors}
      ${Break}
    ${EndIf}
    IntOp $1 $1 - 1
    ${If} $1 <= 0
      ${Break}
    ${EndIf}
    Sleep 100
  ${Loop}
  Pop $1
  Pop $0
FunctionEnd

Section "Uninstall"
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/UPDATE" $1
  ${If} ${Errors}
    Call un.BlinkCloseApp
  ${EndIf}

  !insertmacro BLINK_REMOVE_INSTALLED_FILES

  ; An update (run by the next installer) stops here: the installer then
  ; writes the new files, the uninstaller, the shortcuts and the entry.
  ClearErrors
  ${GetOptions} $0 "/UPDATE" $1
  ${If} ${Errors}
    Push "$SMPROGRAMS\${BLINK_PRODUCT_NAME}.lnk"
    Call un.BlinkDeleteShortcut
    Push "$DESKTOP\${BLINK_PRODUCT_NAME}.lnk"
    Call un.BlinkDeleteShortcut
    DeleteRegKey HKCU "${BLINK_UNINSTALL_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    ; Only when empty: anything the user put there stays.
    RMDir "$INSTDIR"
  ${EndIf}
SectionEnd
