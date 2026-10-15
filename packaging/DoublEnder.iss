; DoublEnder-Setup.exe: the one file a Windows guest downloads. Inno Setup 6
; (preinstalled on GitHub's windows-2025 runner) compiles it from the folder
; scripts/package-windows.ps1 stages, which runs it as:
;
;   ISCC /DAppVersion=2.6.0x /DFileVersion=2.6.0.0 /DStageDir=<folder> /DOutputDir=dist packaging\DoublEnder.iss
;
; It installs for the current user only, into %LOCALAPPDATA%\Programs\DoublEnder,
; so it never asks for an administrator: a guest on a work laptop can run it.
; Settings (%APPDATA%\DoublEnder), the log (%LOCALAPPDATA%\DoublEnder) and the
; recordings on the Desktop are the app's, never the installer's, so an
; upgrade or an uninstall leaves them alone.
;
; DoublEnder.ico is app_icon.png at 16 to 256 px, for Setup, the shortcuts and
; Settings > Apps; the running window sets its own icon from the PNG.

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef FileVersion
  #error Pass /DFileVersion=<numeric version>
#endif
#ifndef StageDir
  #error Pass /DStageDir=<the folder package-windows.ps1 staged>
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
; Never change AppId: it is how a newer Setup finds the install to upgrade.
AppId={{0D27D1E9-E677-4B5C-B9B4-4B9775F742D6}
AppName=DoublEnder
AppVersion={#AppVersion}
AppVerName=DoublEnder {#AppVersion}
AppPublisher=Seven Morris
AppPublisherURL=https://github.com/sevmorris/DoublEnder-Windows
AppSupportURL=https://github.com/sevmorris/DoublEnder-Windows
AppUpdatesURL=https://github.com/sevmorris/DoublEnder-Windows/releases/latest
; SignPath checks the signed file's product name and version: DoublEnder,
; and the four-part version, the same in every field of one build.
VersionInfoVersion={#FileVersion}
VersionInfoProductName=DoublEnder
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#FileVersion}
VersionInfoDescription=DoublEnder Setup
VersionInfoCompany=Seven Morris
VersionInfoCopyright=Copyright (c) 2026 Seven Morris
; Per user, no elevation: {autopf} is then %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\DoublEnder
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; The app's single-instance mutex. Setup and the uninstaller wait for it to be
; closed, rather than replace files under a recording (and nothing is ever
; closed for the user: a take could be running).
AppMutex=Local\DoublEnder.instance
CloseApplications=no
RestartApplications=no
SetupIconFile=DoublEnder.ico
UninstallDisplayIcon={app}\DoublEnder.ico
UninstallDisplayName=DoublEnder
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=DoublEnder-Setup

[Tasks]
; On by default: the recordings land on the Desktop, and so does the app.
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; What an older version installed and this one might not: the runtime DLLs
; change with the Swift toolchain. Only the folders and files Setup itself put
; in its own directory.
Type: files; Name: "{app}\*.dll"
Type: filesandordirs; Name: "{app}\Resources"
Type: filesandordirs; Name: "{app}\licenses"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "DoublEnder.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\DoublEnder"; Filename: "{app}\DoublEnder.exe"; IconFilename: "{app}\DoublEnder.ico"
Name: "{autodesktop}\DoublEnder"; Filename: "{app}\DoublEnder.exe"; IconFilename: "{app}\DoublEnder.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\DoublEnder.exe"; Description: "{cm:LaunchProgram,DoublEnder}"; Flags: nowait postinstall skipifsilent
