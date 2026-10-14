; ==============================================================================
; AeroVPN Commercial Windows Installer (Inno Setup 6)
; Automatic Windows Service Registration & Complete Driver Bundling
; ==============================================================================

#define MyAppName "AeroVPN"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Aero Technologies Inc."
#define MyAppURL "https://www.aerovpn.com"
#define MyAppExeName "aerovpn_client.exe"

[Setup]
AppId={{5E973B5B-883C-4D2A-B981-F09C2AE17D31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=AeroVPN_Setup_v1.0.0
SetupIconFile=..\client\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Client application files
Source: "..\client\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Privileged daemon, sing-box core, and wintun driver
Source: "..\core\daemon\vpn-daemon.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\core\daemon\sing-box.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\core\daemon\wintun.dll"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\client\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\app_icon.ico"

[Run]
; Install & start the privileged Windows background service on setup completion
; The daemon resolves the interactive shell user's profile and SID itself. This stays
; correct when UAC credentials belong to a different administrator account.
Filename: "{app}\bin\vpn-daemon.exe"; Parameters: "service install"; StatusMsg: "Registering privileged VPN service..."; Flags: runhidden waituntilterminated
Filename: "{app}\bin\vpn-daemon.exe"; Parameters: "service start"; StatusMsg: "Starting privileged VPN service..."; Flags: runhidden waituntilterminated
; Run user application
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall runasoriginaluser skipifsilent

[UninstallRun]
; Stop & remove the privileged Windows background service on uninstall
Filename: "{app}\bin\vpn-daemon.exe"; Parameters: "service stop"; Flags: runhidden waituntilterminated
Filename: "{app}\bin\vpn-daemon.exe"; Parameters: "service uninstall"; Flags: runhidden waituntilterminated
