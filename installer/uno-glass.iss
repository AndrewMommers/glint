; Inno Setup script for UNO Glass. Built by release.ps1:
;   ISCC.exe /DVersion=0.9.0-beta.1 /DBuildDir=..\build /DReadme=..\dist\...\README.txt installer\uno-glass.iss
; Installs per-user (no admin needed) with Start menu + optional desktop
; shortcut and an uninstaller in Windows "Apps".

#ifndef Version
  #define Version "0.9.0-dev"
#endif
#ifndef BuildDir
  #define BuildDir "..\build"
#endif
#ifndef Readme
  #define Readme "..\beta\TESTER-README.txt"
#endif
#define AppName "UNO Glass"
#define AppExe "UNO.exe"
; Windows version resources must be numeric: 0.9.0-beta.1 -> 0.9.0
#if Pos("-", Version) > 0
  #define NumVersion Copy(Version, 1, Pos("-", Version) - 1)
#else
  #define NumVersion Version
#endif

[Setup]
AppId={{8C4F3A2E-6B1D-4E7A-9F3C-5D2E1B7A9C40}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher=Andrew Mommers
AppPublisherURL=https://github.com/AndrewMommers/uno-glass-beta
AppSupportURL=https://github.com/AndrewMommers/uno-glass-beta/releases
AppUpdatesURL=https://github.com/AndrewMommers/uno-glass-beta/releases/latest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=UNO-Glass-Setup-{#Version}
SetupIconFile=..\client\branding\icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
VersionInfoVersion={#NumVersion}
VersionInfoProductVersion={#NumVersion}
VersionInfoTextVersion={#Version}
VersionInfoProductTextVersion={#Version}
VersionInfoDescription={#AppName} Setup
VersionInfoCompany=Andrew Mommers
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=yes
; Branded dark wizard
WizardStyle=modern dark
WizardImageFile=..\branding\png\installer-side.png
WizardSmallImageFile=..\branding\png\installer-small.png
WizardBackImageFile=..\branding\png\installer-back.png
InfoBeforeFile=beta-notice.txt
DisableWelcomePage=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\UNO.pck"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\uno-server.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Readme}"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
