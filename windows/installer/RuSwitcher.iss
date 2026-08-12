; Inno Setup script for RuSwitcher (Windows).
; Packages the self-contained single-file exe into a per-user installer with a Start-Menu
; shortcut and an uninstaller. Autostart is handled by the app itself (Settings → "Launch at
; startup"), so the installer does not add a Run key. Compiled by the windows-release CI (ISCC).
;
; Expected defines (passed by CI with /D...):
;   MyAppVersion  — e.g. 0.9.0
;   SourceExe     — path to the published RuSwitcher.exe
; Falls back to sensible defaults for a local compile.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\..\.artifacts\native-x64\RuSwitcher.exe"
#endif
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif

#define MyAppName "RuSwitcher"
#define MyAppPublisher "RuSwitcher"
#define MyAppURL "https://github.com/rashn/RuSwitcher"
#define MyAppExeName "RuSwitcher.exe"

[Setup]
; A stable AppId ties upgrades/uninstalls together across versions — never change it.
AppId={{A3F5C1E2-7B94-4D6A-9E31-2C8F5A1B6D40}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Per-user install → no UAC elevation needed (matches a menu-bar utility's footprint).
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=RuSwitcher-Setup-{#MyAppVersion}-{#MyAppArch}
SetupIconFile=..\src\RuSwitcher.Win\Assets\RuSwitcher.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
AppMutex=RuSwitcher
#if MyAppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
