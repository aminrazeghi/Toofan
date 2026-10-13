# Builds Toofan and packages it for Windows x64 as an installer (Inno Setup), with Qt, VTK,
# the OpenFOAM programs it runs (OpenCFD's MinGW build) and MS-MPI for parallel runs bundled.
#
#   packaging/package-windows.ps1 [-OutDir DIR] [-SkipBuild]
#
# Environment (packaging/ci/install-deps-windows.ps1 prints these):
#   QTDIR          Qt prefix (MSVC 2022 64-bit), e.g. C:\deps\Qt\6.10.2\msvc2022_64
#   VTK_DIR        VTK's CMake directory, <prefix>\lib\cmake\vtk-X.Y
#   OPENFOAM_DIR   an OpenFOAM-v<version> directory of the Windows (MinGW) build
#   MSMPI_DIR      msmpi64.dll, msmpires64.dll, mpiexec.exe, smpd.exe and MS-MPI's license files
#   ISCC           Inno Setup compiler (default: ISCC.exe on PATH or in Program Files)
#
# Needs Visual Studio 2022 (C++), CMake and 7-Zip. The installer installs per user without
# administrator rights, into a folder without spaces (OpenFOAM cannot run from one).
param(
    [string]$OutDir = 'dist',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Root = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $Root 'build-release'
$OutDir = [System.IO.Path]::GetFullPath($OutDir, (Get-Location).Path)
$Work = Join-Path $OutDir 'work'
$Stage = Join-Path $Work 'Toofan'

# OpenFOAM programs the app runs; all of OpenFOAM's DLLs come along (solvers load function
# objects, models and boundary conditions at run time).
$OpenFoamPrograms = 'blockMesh', 'surfaceFeatureExtract', 'snappyHexMesh', 'pimpleFoam', 'rhoPimpleFoam', 'checkMesh',
                    'foamDictionary', 'decomposePar', 'reconstructPar', 'reconstructParMesh', 'extrudeMesh'

function Log($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Info($message) { Write-Host "    $message" }
function Require-Env($name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value) { throw "$name is not set (see packaging/ci/install-deps-windows.ps1)" }
    return $value
}

$QtDir = Require-Env 'QTDIR'
$VtkDir = Require-Env 'VTK_DIR'
$OpenFoamDir = Require-Env 'OPENFOAM_DIR'
$MsMpiDir = Require-Env 'MSMPI_DIR'
$VtkPrefix = (Resolve-Path "$VtkDir\..\..\..").Path
$OpenFoamName = Split-Path -Leaf $OpenFoamDir
$OpenFoamBin = Get-ChildItem "$OpenFoamDir\platforms\*\bin" -Directory | Where-Object { Test-Path "$($_.FullName)\blockMesh.exe" } | Select-Object -First 1
if (-not $OpenFoamBin) { throw "no platforms\*\bin\blockMesh.exe in $OpenFoamDir" }
$Arch = Split-Path -Leaf (Split-Path -Parent $OpenFoamBin.FullName)

$Version = [regex]::Match((Get-Content -Raw "$Root\qml\AboutDialog.qml"), 'readonly property string version: "([^"]*)"').Groups[1].Value
if (-not $Version) { throw 'cannot read the version from qml/AboutDialog.qml' }

Log "Toofan $Version for Windows x64"
Info "Qt:       $QtDir"
Info "VTK:      $VtkPrefix"
Info "OpenFOAM: $OpenFoamDir ($Arch)"
Info "MS-MPI:   $MsMpiDir"

# ---------------------------------------------------------------------------------------------
# 1. Release build
if (-not $SkipBuild) {
    Log "Building (Release) in $BuildDir"
    cmake -S $Root -B $BuildDir -G 'Visual Studio 17 2022' -A x64 "-DCMAKE_PREFIX_PATH=$QtDir" "-DVTK_DIR=$VtkDir" | Out-Null
    cmake --build $BuildDir --config Release --parallel
}
$Exe = Join-Path $BuildDir 'Release\toofan.exe'
if (-not (Test-Path $Exe)) { throw "$Exe not found (build first or drop -SkipBuild)" }

# ---------------------------------------------------------------------------------------------
# 2. The application, Qt and VTK
Log "Assembling $Stage"
Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item $Exe $Stage

Log 'Copying VTK libraries'
Copy-Item "$VtkPrefix\bin\*.dll" $Stage

# windeployqt only follows the imports of the binaries it is given: toofan.exe does not use Qt
# Widgets, but VTK's Qt module does (Qt6Widgets, Qt6OpenGLWidgets), so it gets the VTK DLLs too.
Log 'Deploying Qt (windeployqt)'
$vtkQt = Get-ChildItem "$Stage\vtk*Qt*.dll" | ForEach-Object FullName
& "$QtDir\bin\windeployqt.exe" --release --qmldir "$Root\qml" --no-translations --no-system-d3d-compiler "$Stage\toofan.exe" @vtkQt | Out-Null

# The MSVC runtime, next to the executable: no Visual C++ Redistributable install needed.
Log 'Copying the Visual C++ runtime'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "Visual C++ runtime not found under $vs\VC\Redist\MSVC" }
Copy-Item "$($crt.FullName)\*.dll" $Stage
Info $crt.FullName

# Every DLL that the app, its DLLs and Qt's plugins import must be in the package or in Windows:
# a missing one only shows up as an error dialog when the app starts.
Log 'Checking DLL imports'
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" | Select-Object -Last 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vs" }
$system32 = Join-Path $env:SystemRoot 'System32'
$missing = @()
foreach ($binary in Get-ChildItem -Recurse $Stage -Include *.exe, *.dll) {
    $imports = & $dumpbin.FullName /nologo /dependents $binary.FullName | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
    foreach ($dll in $imports) {
        if ($dll -match '^(api|ext)-ms-') { continue }
        if ((Test-Path "$Stage\$dll") -or (Test-Path "$($binary.DirectoryName)\$dll") -or (Test-Path "$system32\$dll")) { continue }
        $missing += "$($binary.FullName.Substring($Stage.Length + 1)) -> $dll"
    }
}
if ($missing) { $missing | ForEach-Object { Info $_ }; throw "$($missing.Count) DLL import(s) not in the package" }

# ---------------------------------------------------------------------------------------------
# 3. OpenFOAM: etc, the programs the app runs, all DLLs; MS-MPI in the same bin directory, so
# OpenFOAM's programs find msmpi.dll next to them and the app finds mpiexec and smpd there.
Log "Copying OpenFOAM from $OpenFoamDir"
$OfDest = Join-Path $Stage $OpenFoamName
$OfBin = Join-Path $OfDest "platforms\$Arch\bin"
New-Item -ItemType Directory -Force -Path $OfBin | Out-Null
Copy-Item -Recurse "$OpenFoamDir\etc" $OfDest
if (Test-Path "$OpenFoamDir\META-INFO") { Copy-Item -Recurse "$OpenFoamDir\META-INFO" $OfDest }
foreach ($program in $OpenFoamPrograms) {
    $file = Join-Path $OpenFoamBin.FullName "$program.exe"
    if (-not (Test-Path $file)) { throw "OpenFOAM program not found: $program" }
    Copy-Item $file $OfBin
}
Copy-Item "$($OpenFoamBin.FullName)\*.dll" $OfBin

Log "Copying MS-MPI from $MsMpiDir"
Copy-Item "$MsMpiDir\msmpi64.dll" "$OfBin\msmpi.dll"
Copy-Item "$MsMpiDir\msmpires64.dll" "$OfBin\msmpires.dll"
Copy-Item "$MsMpiDir\mpiexec.exe", "$MsMpiDir\smpd.exe" $OfBin

# ---------------------------------------------------------------------------------------------
# 4. Licenses
Log 'Writing licenses'
$Licenses = Join-Path $Stage 'licenses'
foreach ($dir in 'OpenFOAM', 'MS-MPI', 'Qt', 'VTK', 'inja', 'nlohmann-json') { New-Item -ItemType Directory -Force -Path "$Licenses\$dir" | Out-Null }
$ofLicense = Join-Path (Split-Path -Parent $OpenFoamDir) 'License.txt'
if (Test-Path $ofLicense) { Copy-Item $ofLicense "$Licenses\OpenFOAM\" }
Copy-Item "$MsMpiDir\MicrosoftMPI_Redistributable_EULA.rtf", "$MsMpiDir\MPI_Redistributables_TPN.txt" "$Licenses\MS-MPI\"
$qtLicenses = Join-Path (Split-Path -Parent (Split-Path -Parent $QtDir)) 'Licenses'
if (Test-Path $qtLicenses) { Copy-Item "$qtLicenses\*" "$Licenses\Qt\" }
$vtkLicense = Get-ChildItem -Recurse "$VtkPrefix\share" -Filter 'Copyright.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vtkLicense) { Copy-Item $vtkLicense.FullName "$Licenses\VTK\" }
Copy-Item "$Root\external\inja\LICENSE" "$Licenses\inja\"
Copy-Item "$Root\external\inja\third_party\include\nlohmann\LICENSE.MIT" "$Licenses\nlohmann-json\"
$QtVersion = Split-Path -Leaf (Split-Path -Parent $QtDir)
@"
Toofan $Version bundles third-party software under its own licenses:

  OpenFOAM ($OpenFoamName, OpenCFD's Windows build)   GPL-3.0-or-later   $OpenFoamName
      Source: https://develop.openfoam.com/Development/openfoam
  Microsoft MPI (MS-MPI)    Microsoft MPI Redistributable license   $OpenFoamName\platforms\$Arch\bin
      msmpi.dll, msmpires.dll, mpiexec.exe, smpd.exe
  Qt $QtVersion              LGPL-3.0 (Qt open source)
      Source: https://download.qt.io/official_releases/qt/
  VTK                       BSD-3-Clause
  inja, nlohmann/json       MIT
  Microsoft Visual C++ runtime   Visual Studio redistributable files

Each directory here holds the license of the corresponding component.

This project is not approved or endorsed by OpenCFD Limited, producer and distributor of the
OpenFOAM software via www.openfoam.com, and owner of the OPENFOAM(R) and OpenCFD(R) trademarks.
"@ | Set-Content -Encoding utf8 "$Licenses\README.txt"

# ---------------------------------------------------------------------------------------------
# 5. Check: the bundled OpenFOAM meshes a tiny case (a cube of 8 cells), decomposes it in two
# and checks it with 2 MPI processes, started the way the app starts them.
Log 'Checking the bundle'
$Test = Join-Path $Work 'mpi-test'
New-Item -ItemType Directory -Force -Path "$Test\system" | Out-Null
function Write-Dict($name, $body) {
    "FoamFile { version 2.0; format ascii; class dictionary; object $name; }`n$body" | Set-Content -Encoding ascii "$Test\system\$name"
}
Write-Dict 'controlDict' 'application checkMesh; startFrom startTime; startTime 0; stopAt endTime; endTime 1; deltaT 1; writeControl timeStep; writeInterval 1;'
Write-Dict 'fvSchemes' 'ddtSchemes {} gradSchemes {} divSchemes {} laplacianSchemes {} interpolationSchemes {} snGradSchemes {}'
Write-Dict 'fvSolution' ''
Write-Dict 'decomposeParDict' 'numberOfSubdomains 2; method scotch;'
Write-Dict 'blockMeshDict' @'
vertices ((0 0 0) (1 0 0) (1 1 0) (0 1 0) (0 0 1) (1 0 1) (1 1 1) (0 1 1));
blocks (hex (0 1 2 3 4 5 6 7) (2 2 2) simpleGrading (1 1 1));
boundary (walls { type wall; faces ((0 3 2 1) (4 5 6 7) (0 4 7 3) (1 2 6 5) (0 1 5 4) (3 7 6 2)); });
'@
# The variables src/OpenFoamEnvironment.cpp sets; nothing from a system MS-MPI or OpenFOAM.
$env:WM_PROJECT_DIR = $OfDest
$env:WM_PROJECT = 'OpenFOAM'
$env:WM_PROJECT_VERSION = $OpenFoamName -replace '^OpenFOAM-', ''
$env:FOAM_SIGFPE = '1'
$env:PATH = "$OfBin;$env:PATH"
function Run-Step($name, $exe, [string[]]$arguments) {
    $log = Join-Path $Test "log.$name"
    Push-Location $Test
    try { & $exe @arguments *> $log }
    catch { Get-Content $log -Tail 30 | Write-Host; throw "$name failed: $_" }
    finally { Pop-Location }
    return $log
}
Run-Step 'blockMesh' "$OfBin\blockMesh.exe" @() | Out-Null
Run-Step 'decomposePar' "$OfBin\decomposePar.exe" @() | Out-Null
$log = Run-Step 'checkMesh' "$OfBin\mpiexec.exe" @('-n', '2', "$OfBin\checkMesh.exe", '-parallel')
if (-not (Select-String -Path $log -Pattern '^nProcs\s*:\s*2' -Quiet)) {
    Get-Content $log -Tail 30 | Write-Host
    throw 'checkMesh did not run on 2 processes'
}
Info 'OpenFOAM: programs run from the bundle, parallel run with the bundled MS-MPI'
Remove-Item -Recurse -Force $Test
Info ("bundle size: {0:N0} MB" -f ((Get-ChildItem -Recurse $Stage | Measure-Object Length -Sum).Sum / 1MB))

# ---------------------------------------------------------------------------------------------
# 6. Installer
Log 'Creating the installer'
$iscc = $env:ISCC
if (-not $iscc) { $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
if (-not $iscc) {
    $iscc = Get-ChildItem "$env:ProgramFiles\Inno Setup *\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup *\ISCC.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $iscc -or -not (Test-Path $iscc)) { throw 'Inno Setup (ISCC.exe) not found; install it or set ISCC' }
& $iscc /Q "/DAppVersion=$Version" "/DSourceDir=$Stage" "/DOutputDir=$OutDir" "/DRepoRoot=$Root" "$Root\packaging\windows\toofan.iss"
$Setup = Join-Path $OutDir "toofan-$Version-windows-x86_64-setup.exe"
if (-not (Test-Path $Setup)) { throw "installer not created: $Setup" }
Info ("{0:N0} MB  {1}" -f ((Get-Item $Setup).Length / 1MB), $Setup)
Log 'Done'
