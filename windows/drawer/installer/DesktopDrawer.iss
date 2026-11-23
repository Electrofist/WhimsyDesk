; Desktop Drawer for Windows installer (Inno Setup 6).
; Installs for the current user only (no admin prompt), adds a Start menu entry, can start the
; drawer with Windows, and opens it when done. Uninstalling never touches the Desktop Drawer
; folder or the index that remembers where each file came from.
;
; Build: iscc /DAppVersion=0.1.0 /DSourceDir=..\target\release DesktopDrawer.iss

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
AppId={{AB4A7CFF-F2F2-44AC-B7D4-5E9640811D68}
AppName=Desktop Drawer
AppVersion={#AppVersion} (build {#Build})
AppPublisher=WhimsyDesk
AppPublisherURL=https://whimsydesk.art
AppSupportURL=https://github.com/Electrofist/WhimsyDesk
DefaultDirName={localappdata}\Programs\Desktop Drawer
DefaultGroupName=Desktop Drawer
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=Desktop-Drawer-Setup-{#Build}
SetupIconFile=..\app\icon.ico
UninstallDisplayIcon={app}\DesktopDrawer.exe
UninstallDisplayName=Desktop Drawer
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Start Desktop Drawer when Windows starts"; Flags: checkedonce

[Files]
Source: "{#SourceDir}\DesktopDrawer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Desktop Drawer"; Filename: "{app}\DesktopDrawer.exe"; Comment: "A drawer on your desktop that holds your files"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Desktop Drawer"; ValueData: """{app}\DesktopDrawer.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\DesktopDrawer.exe"; Description: "Open Desktop Drawer now"; Flags: nowait postinstall

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM DesktopDrawer.exe /F"; Flags: runhidden; RunOnceId: "StopDrawer"

[Messages]
FinishedLabel=Desktop Drawer is installed. It sits along the bottom of your screen, behind your windows: press Win+D or minimise your windows to see it.%n%nYour files go into a Desktop Drawer folder in your user folder (next to your Desktop folder if OneDrive syncs your Desktop). Uninstalling never deletes them.
