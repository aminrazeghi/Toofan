; Inno Setup script for the Toofan installer; run by packaging/package-windows.ps1, which
; passes AppVersion, SourceDir (the assembled app), OutputDir and RepoRoot.
;
; Installs per user without administrator rights. OpenFOAM cannot run from a path with spaces
; or non-ASCII characters, so the default folder avoids them and the folder page refuses them.
; The license page shows the MS-MPI redistributable terms, which users must accept.

#ifndef AppVersion
  #error AppVersion is not defined
#endif

[Setup]
AppId={{6F0C9C1E-5B7B-4D7A-9C55-2D1E8A3F4B10}
AppName=Toofan
AppVersion={#AppVersion}
AppVerName=Toofan {#AppVersion}
AppPublisher=amin razeghiyadaki
AppPublisherURL=https://github.com/aminrazeghi/Toofan
DefaultDirName={code:DefaultInstallDir}
DefaultGroupName=Toofan
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=toofan-{#AppVersion}-windows-x86_64-setup
SetupIconFile={#RepoRoot}\assets\toofan.ico
UninstallDisplayIcon={app}\toofan.exe
LicenseFile={#SourceDir}\licenses\MS-MPI\MicrosoftMPI_Redistributable_EULA.rtf
InfoBeforeFile={#SourceDir}\licenses\README.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Toofan"; Filename: "{app}\toofan.exe"
Name: "{autodesktop}\Toofan"; Filename: "{app}\toofan.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\toofan.exe"; Description: "Start Toofan"; Flags: nowait postinstall skipifsilent

[Code]
// True when OpenFOAM cannot use Path: spaces or characters outside printable ASCII.
function PathProblem(Path: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(Path) do
    if (Ord(Path[I]) <= 32) or (Ord(Path[I]) > 126) then
    begin
      Result := True;
      Exit;
    end;
end;

// %LOCALAPPDATA%\Programs\Toofan, unless the user name puts a space or non-ASCII character in
// it; then C:\Toofan.
function DefaultInstallDir(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := ExpandConstant('{sd}\Toofan')
  else
    Result := ExpandConstant('{localappdata}\Programs\Toofan');
  if PathProblem(Result) then
    Result := ExpandConstant('{sd}\Toofan');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and PathProblem(WizardDirValue) then
  begin
    MsgBox('OpenFOAM, which Toofan runs, cannot work from a folder whose path contains spaces or ' +
           'non-ASCII characters.' + #13#10#13#10 + 'Choose a folder such as ' + ExpandConstant('{sd}') + '\Toofan.',
           mbError, MB_OK);
    Result := False;
  end;
end;

// Also for silent installs (/DIR=...), which skip the folder page.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if PathProblem(ExpandConstant('{app}')) then
    Result := 'OpenFOAM cannot work from ' + ExpandConstant('{app}') + ': choose a folder without spaces or non-ASCII characters.';
end;
