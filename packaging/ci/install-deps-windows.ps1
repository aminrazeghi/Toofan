# Installs what packaging/package-windows.ps1 needs on a GitHub Windows runner (windows-2022,
# with Visual Studio 2022, CMake, Python, 7-Zip, curl and Chocolatey):
#
#   - Qt from the official binaries (aqtinstall, MSVC 2022 64-bit), into $DEPS_DIR\Qt
#   - VTK built from source with only the modules the app uses, into $DEPS_DIR\vtk
#   - OpenFOAM for Windows (OpenCFD's MinGW build) and the MS-MPI it uses, unpacked from
#     OpenCFD's installer without running it, into $DEPS_DIR\openfoam
#   - Inno Setup, if the runner does not have it
#
# Each part is skipped when already present in $DEPS_DIR, so that directory can be cached.
# Environment: QT_VERSION, VTK_VERSION, OPENFOAM_VERSION, DEPS_DIR (defaults below); QT_BASE: a
# Qt mirror for aqt instead of the redirector; OPENFOAM_INSTALLER: an already downloaded
# OpenFOAM-v<version>-windows-mingw.exe. Prints the variables package-windows.ps1 needs
# and, on GitHub Actions, adds them to $GITHUB_ENV.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$QtVersion = $env:QT_VERSION ?? '6.10.2'
$VtkVersion = $env:VTK_VERSION ?? '9.6.2'
$OpenFoamVersion = $env:OPENFOAM_VERSION ?? '2606'
$DepsDir = $env:DEPS_DIR ?? 'C:\deps'

function Log($message) { Write-Host "==> $message" -ForegroundColor Cyan }
New-Item -ItemType Directory -Force -Path $DepsDir | Out-Null
$work = Join-Path ([System.IO.Path]::GetTempPath()) "toofan-deps"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# ---------------------------------------------------------------------------------------------
$QtPrefix = Join-Path $DepsDir "Qt\$QtVersion\msvc2022_64"
Log "Qt $QtVersion"
if (-not (Test-Path "$QtPrefix\bin\windeployqt.exe")) {
    python -m venv "$DepsDir\aqt"
    & "$DepsDir\aqt\Scripts\pip.exe" install -q aqtinstall
    $baseArgs = if ($env:QT_BASE) { @('--base', $env:QT_BASE) } else { @() }
    # Qt's mirrors time out now and then: retry (each try starts over).
    for ($attempt = 1; ; $attempt++) {
        try {
            & "$DepsDir\aqt\Scripts\aqt.exe" install-qt windows desktop $QtVersion win64_msvc2022_64 --outputdir "$DepsDir\Qt" @baseArgs
            break
        } catch {
            if ($attempt -ge 3) { throw }
            Log "Qt download failed, retrying ($attempt/3)"
            Remove-Item -Recurse -Force "$DepsDir\Qt\$QtVersion" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
        }
    }
}
if (-not (Test-Path "$QtPrefix\bin\windeployqt.exe")) { throw "Qt install failed: $QtPrefix\bin\windeployqt.exe missing" }

# ---------------------------------------------------------------------------------------------
$VtkPrefix = Join-Path $DepsDir 'vtk'
$VtkSeries = $VtkVersion -replace '\.\d+$', ''
Log "VTK $VtkVersion"
if (-not (Test-Path "$VtkPrefix\lib\cmake\vtk-$VtkSeries")) {
    $src = Join-Path $work 'vtk-src'
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    curl.exe -fsSL --retry 5 -o "$work\vtk.tar.gz" "https://vtk.org/files/release/$VtkSeries/VTK-$VtkVersion.tar.gz"
    tar -xzf "$work\vtk.tar.gz" -C $src
    # The same modules as packaging/ci/install-deps.sh (Linux): those CMakeLists.txt asks for,
    # plus OpenGL rendering.
    $modules = 'CommonCore', 'CommonDataModel', 'FiltersCore', 'FiltersFlowPaths', 'FiltersSources', 'FiltersGeneral',
               'IOGeometry', 'IOParallel', 'IOXML', 'RenderingAnnotation', 'RenderingCore', 'RenderingFreeType',
               'RenderingOpenGL2', 'InteractionStyle', 'GUISupportQtQuick'
    $moduleArgs = $modules | ForEach-Object { "-DVTK_MODULE_ENABLE_VTK_$_=YES" }
    cmake -S "$src\VTK-$VtkVersion" -B "$work\vtk-build" -G 'Visual Studio 17 2022' -A x64 `
        "-DCMAKE_INSTALL_PREFIX=$VtkPrefix" "-DCMAKE_PREFIX_PATH=$QtPrefix" `
        -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DVTK_BUILD_TESTING=OFF -DVTK_BUILD_EXAMPLES=OFF `
        -DVTK_BUILD_DOCUMENTATION=OFF -DVTK_WRAP_PYTHON=OFF -DVTK_QT_VERSION=6 `
        -DVTK_GROUP_ENABLE_StandAlone=DONT_WANT -DVTK_GROUP_ENABLE_Rendering=DONT_WANT `
        -DVTK_GROUP_ENABLE_Imaging=DONT_WANT -DVTK_GROUP_ENABLE_Views=DONT_WANT `
        -DVTK_GROUP_ENABLE_Web=DONT_WANT -DVTK_GROUP_ENABLE_MPI=DONT_WANT @moduleArgs
    cmake --build "$work\vtk-build" --config Release --parallel
    cmake --install "$work\vtk-build" --config Release | Out-Null
    Remove-Item -Recurse -Force $src, "$work\vtk-build", "$work\vtk.tar.gz"
}

# ---------------------------------------------------------------------------------------------
$OpenFoamName = "OpenFOAM-v$OpenFoamVersion"
$OpenFoamDest = Join-Path $DepsDir 'openfoam'
Log "OpenFOAM v$OpenFoamVersion for Windows and MS-MPI"
if (-not (Test-Path "$OpenFoamDest\$OpenFoamName\etc\controlDict") -or -not (Test-Path "$OpenFoamDest\msmpi\mpiexec.exe")) {
    Remove-Item -Recurse -Force $OpenFoamDest -ErrorAction SilentlyContinue
    $installer = Join-Path $work 'openfoam-installer'
    New-Item -ItemType Directory -Force -Path $installer | Out-Null
    $url = "https://sourceforge.net/projects/openfoam/files/v$OpenFoamVersion/$OpenFoamName-windows-mingw.exe/download"
    if ($env:OPENFOAM_INSTALLER) { Copy-Item $env:OPENFOAM_INSTALLER "$installer\setup.exe" }
    else { curl.exe -fsSL --retry 5 -o "$installer\setup.exe" $url }
    # An NSIS installer: msys64.7z holds MSYS2 with OpenFOAM in home\ofuser\OpenFOAM, and
    # thirdParty\msmpisetup.exe is Microsoft's MS-MPI redistributable.
    7z x -y "-o$installer" "$installer\setup.exe" msys64.7z thirdParty\msmpisetup.exe licenses | Out-Null
    7z x -y "-o$installer\msys" "$installer\msys64.7z" "msys64\home\ofuser\OpenFOAM\$OpenFoamName\*" -r | Out-Null
    $tree = "$installer\msys\msys64\home\ofuser\OpenFOAM\$OpenFoamName"
    if (-not (Test-Path "$tree\etc\controlDict")) { throw "$OpenFoamName not found in the installer" }
    New-Item -ItemType Directory -Force -Path $OpenFoamDest | Out-Null
    Move-Item $tree "$OpenFoamDest\$OpenFoamName"
    Copy-Item "$installer\licenses\License.txt" "$OpenFoamDest\License.txt"

    # MS-MPI: msmpisetup.exe bundles an x86 and an x64 MSI; the x64 one has msmpi64.dll (installed
    # as System32\msmpi.dll), msmpires64.dll, mpiexec.exe and smpd.exe.
    $msmpi = Join-Path $installer 'msmpi'
    7z x -y -t# "-o$msmpi" "$installer\thirdParty\msmpisetup.exe" | Out-Null
    $x64 = $null
    foreach ($msi in Get-ChildItem $msmpi -Filter *.msi) {
        $dir = Join-Path $msmpi $msi.BaseName
        7z x -y "-o$dir" $msi.FullName | Out-Null
        if (Test-Path "$dir\msmpi64.dll") { $x64 = $dir }
    }
    if (-not $x64) { throw 'no x64 MS-MPI found in msmpisetup.exe' }
    New-Item -ItemType Directory -Force -Path "$OpenFoamDest\msmpi" | Out-Null
    foreach ($file in 'msmpi64.dll', 'msmpires64.dll', 'mpiexec.exe', 'smpd.exe', 'MicrosoftMPI_Redistributable_EULA.rtf', 'MPI_Redistributables_TPN.txt') {
        Copy-Item "$x64\$file" "$OpenFoamDest\msmpi\$file"
    }
    Remove-Item -Recurse -Force $installer
}

# ---------------------------------------------------------------------------------------------
Log 'Inno Setup'
$innoFound = Get-ChildItem "$env:ProgramFiles\Inno Setup *\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup *\ISCC.exe" -ErrorAction SilentlyContinue
if (-not (Get-Command ISCC.exe -ErrorAction SilentlyContinue) -and -not $innoFound) {
    choco install innosetup -y --no-progress | Out-Null
}

# ---------------------------------------------------------------------------------------------
Log 'Environment for package-windows.ps1'
$environment = @(
    "QTDIR=$QtPrefix"
    "VTK_DIR=$VtkPrefix\lib\cmake\vtk-$VtkSeries"
    "OPENFOAM_DIR=$OpenFoamDest\$OpenFoamName"
    "MSMPI_DIR=$OpenFoamDest\msmpi"
)
$environment | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_ENV) { $environment | Add-Content -Path $env:GITHUB_ENV }
