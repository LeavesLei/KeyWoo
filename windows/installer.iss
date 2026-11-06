; Compile only through build.ps1, which supplies verified staging and version.
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppBuild
  #error AppBuild is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppIcon
  #error AppIcon is required
#endif

[Setup]
AppId={{B608FC98-62B3-4B21-B82A-BB660B9C3051}
AppName=KeyWoo
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.{#AppBuild}
AppPublisher=KeyWoo
AppPublisherURL=https://github.com/LeavesLei/KeyWoo
AppSupportURL=https://github.com/LeavesLei/KeyWoo/issues
DefaultDirName={localappdata}\Programs\KeyWoo
DefaultGroupName=KeyWoo
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
AppMutex=Local\KeyWoo.Windows
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\KeyWoo.exe
SetupIconFile={#AppIcon}
OutputDir={#OutputDir}
OutputBaseFilename=KeyWoo-{#AppVersion}-win-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=no
ChangesEnvironment=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\KeyWoo"; Filename: "{app}\KeyWoo.exe"
Name: "{autodesktop}\KeyWoo"; Filename: "{app}\KeyWoo.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\KeyWoo.exe"; Description: "{cm:LaunchProgram,KeyWoo}"; Flags: nowait postinstall skipifsilent

; User settings and statistics live outside {app}, under LocalAppData\KeyWoo.
; Deliberately no UninstallDelete section: upgrades/uninstalls preserve them.
