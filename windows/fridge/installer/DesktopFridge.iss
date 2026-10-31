; Desktop Fridge for Windows installer (Inno Setup 6).
; Installs for the current user only (no admin prompt), adds a Start menu entry, can start the
; fridge with Windows, and opens it when done. Uninstalling never touches the Fridge folder.
;
; Build: iscc /DAppVersion=0.1.0 /DSourceDir=..\target\release DesktopFridge.iss

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Build
  #define Build "local"
#endif
#ifndef SourceDir
  #define SourceDir "..\target\release"
#endif

[Setup]
AppId={{8F3D2A61-5C4B-4E7A-9B1D-6A2F0C9E4D17}
AppName=Desktop Fridge
AppVersion={#AppVersion} (build {#Build})
AppPublisher=WhimsyDesk
AppPublisherURL=https://whimsydesk.art
AppSupportURL=https://github.com/Electrofist/WhimsyDesk
DefaultDirName={localappdata}\Programs\Desktop Fridge
DefaultGroupName=Desktop Fridge
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=Desktop-Fridge-Setup-{#Build}
SetupIconFile=..\app\icon.ico
UninstallDisplayIcon={app}\DesktopFridge.exe
UninstallDisplayName=Desktop Fridge
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Start Desktop Fridge when Windows starts"; Flags: checkedonce

[Files]
Source: "{#SourceDir}\DesktopFridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Desktop Fridge"; Filename: "{app}\DesktopFridge.exe"; Comment: "A fridge on your desktop that holds your files"

[Registry]
; Same value the app's "Start with Windows" menu item uses.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Desktop Fridge"; ValueData: """{app}\DesktopFridge.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\DesktopFridge.exe"; Description: "Open Desktop Fridge now"; Flags: nowait postinstall

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM DesktopFridge.exe /F"; Flags: runhidden; RunOnceId: "StopFridge"

[UninstallDelete]
; Settings and the log. Your stored files in the Fridge folder are left alone.
Type: filesandordirs; Name: "{userappdata}\WhimsyDesk\Desktop Fridge"
Type: filesandordirs; Name: "{localappdata}\WhimsyDesk\Desktop Fridge"

[Messages]
FinishedLabel=Desktop Fridge is installed. It sits on your desktop, behind your windows: press Win+D or minimise your windows to see it.%n%nYour files go into a Fridge folder next to your Desktop folder (inside OneDrive if OneDrive syncs your Desktop). Uninstalling never deletes them.
