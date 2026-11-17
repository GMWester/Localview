; Localview Windows installer (Inno Setup 6).
; iscc /DAppLabel=LAN /DAppMode=lan /DAppVersion=1.0.0 /DSourceDir=path\to\Release /DOutputBase=name [/DVigemInstaller=path\ViGEmBus.exe] windows.iss

#define AppName "Localview " + AppLabel
#define ExeName "Localview " + AppLabel + ".exe"

[Setup]
AppId=io.localview.{#AppMode}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Localview
AppPublisherURL=https://github.com/GMWester/Localview
DefaultDirName={autopf}\{#AppName}
DefaultGroupName=Localview
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={#OutputBase}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "autostart"; Description: "Start Localview when I sign in (so this PC can be reached)"; GroupDescription: "Options:"; Flags: unchecked
Name: "firewall"; Description: "Allow Localview through Windows Firewall"; GroupDescription: "Options:"
#ifdef VigemInstaller
Name: "vigem"; Description: "Install the ViGEmBus driver (lets games see streamed controllers as Xbox controllers)"; GroupDescription: "Game streaming:"
#endif

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
#ifdef VigemInstaller
Source: "{#VigemInstaller}"; DestDir: "{tmp}"; DestName: "ViGEmBusSetup.exe"; Flags: deleteafterinstall; Tasks: vigem
#endif

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#ExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: autostart

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#AppName}"" dir=in action=allow program=""{app}\{#ExeName}"" enable=yes profile=any"; Flags: runhidden; Tasks: firewall; StatusMsg: "Adding firewall rule..."
#ifdef VigemInstaller
Filename: "{tmp}\ViGEmBusSetup.exe"; Parameters: "/passive /norestart"; Flags: waituntilterminated; Tasks: vigem; StatusMsg: "Installing the ViGEmBus controller driver..."
#endif
Filename: "{app}\{#ExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden; RunOnceId: "LocalviewFirewall"
