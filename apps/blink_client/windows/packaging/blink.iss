; BLINK Windows Per-User Installer Script (Inno Setup 7.1.x)
; Compiled by scripts/package.py with /D defines.

#if Ver < EncodeVer(7, 1, 0) || Ver >= EncodeVer(7, 2, 0)
  #error "BLINK installer requires Inno Setup 7.1.x"
#endif

#ifndef BlinkIdentity
  #error "BlinkIdentity must be defined (e.g. blink, blink-dev, blink-dev-test)"
#endif
#ifndef BlinkAppId
  #error "BlinkAppId must be defined (e.g. io.github.chialecode.blink-dev)"
#endif
#ifndef BlinkProductName
  #error "BlinkProductName must be defined (e.g. BLINK, BLINK Dev)"
#endif
#ifndef BlinkVersion
  #error "BlinkVersion must be defined (e.g. 0.1.0-dev.202611230000)"
#endif
#ifndef BlinkFileVersionStr
  #define BlinkFileVersionStr "0.1.0.0"
#endif
#ifndef BlinkSourceDir
  #error "BlinkSourceDir must be defined"
#endif
#ifndef BlinkIconFile
  #error "BlinkIconFile must be defined"
#endif
#ifndef BlinkOutputDir
  #error "BlinkOutputDir must be defined"
#endif
#ifndef BlinkOutputBaseFilename
  #define BlinkOutputBaseFilename BlinkIdentity + "-setup-" + BlinkVersion
#endif

[Setup]
AppId={#BlinkAppId}
AppName={#BlinkProductName}
AppVersion={#BlinkVersion}
AppVerName={#BlinkProductName} {#BlinkVersion}
AppPublisher=BLINK
AppPublisherURL=https://github.com/chialecode/blink
AppSupportURL=https://github.com/chialecode/blink/discussions
DefaultDirName={userpf}\{#BlinkIdentity}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex={#BlinkIdentity}-instance
CloseApplications=no
RestartApplications=no
OutputDir={#BlinkOutputDir}
OutputBaseFilename={#BlinkOutputBaseFilename}
SetupIconFile={#BlinkIconFile}
UninstallDisplayIcon={app}\{#BlinkIdentity}.exe
UninstallDisplayName={#BlinkProductName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
VersionInfoVersion={#BlinkFileVersionStr}
VersionInfoProductName={#BlinkProductName}
VersionInfoProductTextVersion={#BlinkVersion}
VersionInfoDescription={#BlinkProductName} Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BlinkSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\{#BlinkProductName}"; Filename: "{app}\{#BlinkIdentity}.exe"; AppUserModelID: "{#BlinkAppId}"
Name: "{userdesktop}\{#BlinkProductName}"; Filename: "{app}\{#BlinkIdentity}.exe"; AppUserModelID: "{#BlinkAppId}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#BlinkIdentity}.exe"; Description: "{cm:LaunchProgram,{#StringChange(BlinkProductName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
