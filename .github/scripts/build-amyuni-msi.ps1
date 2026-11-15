$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = (Get-Location).Path
$windowsBundle = Join-Path $repo 'windows-bundle'
$logDirectory = Join-Path $repo 'windows-msi-logs'
$releaseDirectory = Join-Path $repo 'windows-release'
New-Item -ItemType Directory -Path $logDirectory, $releaseDirectory -Force | Out-Null

function Install-Msi([string] $package, [string] $logName) {
    $log = Join-Path $logDirectory "$logName.log"
    $arguments = "/i ""$package"" /qn /norestart /l*v ""$log"" PRINTER=0"
    $process = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" -ArgumentList $arguments -PassThru -Wait
    if ($process.ExitCode -notin 0, 3010) {
        Get-Content -LiteralPath $log -Tail 100 -ErrorAction SilentlyContinue
        throw "MSI installation failed with exit code $($process.ExitCode)"
    }
}

if ($env:WINDOWS_BUILD_COMMIT -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Windows build commit' }
$recordedCommit = (Get-Content -LiteralPath (Join-Path $windowsBundle 'build-commit.txt') -Raw).Trim()
if ($recordedCommit -cne $env:WINDOWS_BUILD_COMMIT) { throw 'Unexpected Windows bundle commit' }
git fetch origin $recordedCommit
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch bundle source commit' }
git merge-base --is-ancestor 51e3963f $recordedCommit
if ($LASTEXITCODE -ne 0) { throw 'Windows bundle does not contain the preferred privacy resolution' }
Remove-Item -LiteralPath (Join-Path $windowsBundle 'build-commit.txt')

$previousMsi = Join-Path $repo 'rustdesk-1.5.3-amyuni.1-x86_64.msi'
Invoke-WebRequest 'https://github.com/doubleauu/rustdesk/releases/download/v1.5.3-amyuni.1/rustdesk-1.5.3-amyuni.1-x86_64.msi' -OutFile $previousMsi
if ((Get-FileHash -LiteralPath $previousMsi).Hash -ine 'c9f7ec8b32e3a9200f04630bb26fe796a2574cc88a4a63c0e4a46cd8a70fc124') {
    throw 'Previous MSI digest differs from the pinned release asset'
}
Install-Msi $previousMsi '01-previous-release-install'

$stateKey = 'HKLM:\SOFTWARE\RustDesk\InstallState\RustDesk'
$initial = Get-ItemProperty -LiteralPath $stateKey
$installDir = $initial.InstallLocation
$oldProduct = $initial.MsiProductCode
if (!$oldProduct -or !$installDir) { throw 'Previous MSI did not register its installation' }
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
if (!(Test-Path -LiteralPath (Join-Path $uninstallKey $oldProduct))) { throw 'Missing previous product registration' }

# This Flutter artifact omits the drivers and Windows helper binaries. Take them
# from the verified, installed x64 distribution. Runtime-only helpers may be absent.
foreach ($relative in 'usbmmidd_v2', 'drivers', 'printer_driver_adapter.dll', 'WindowInjection.dll', 'RuntimeBroker_rustdesk.exe') {
    $source = Join-Path $installDir $relative
    $destination = Join-Path $windowsBundle $relative
    if ((Test-Path -LiteralPath $source) -and !(Test-Path -LiteralPath $destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    }
}
if (!(Test-Path -LiteralPath (Join-Path $windowsBundle 'usbmmidd_v2\usbmmIdd.inf'))) {
    throw 'Missing Amyuni driver bundle'
}
$expectedDll = (Get-FileHash -LiteralPath (Join-Path $windowsBundle 'librustdesk.dll')).Hash
$expectedExe = (Get-FileHash -LiteralPath (Join-Path $windowsBundle 'rustdesk.exe')).Hash

Push-Location (Join-Path $repo 'res\msi')
try {
    python preprocess.py -d $windowsBundle --manufacturer doubleauu
    if ($LASTEXITCODE -ne 0) { throw 'WiX preprocessing failed' }
    nuget restore msi.sln
    if ($LASTEXITCODE -ne 0) { throw 'NuGet restore failed' }
    msbuild msi.sln -restore -p:Configuration=Release -p:Platform=x64 -p:TargetVersion=Windows10
    if ($LASTEXITCODE -ne 0) { throw 'WiX package build failed' }
    $built = @(Get-ChildItem -Path 'Package/bin/*/Release/en-us/Package.msi' -File)
    if ($built.Count -ne 1) { throw 'Expected a single built x64 MSI' }
    $msi = Join-Path $releaseDirectory 'rustdesk-1.5.3-amyuni.2-x86_64.msi'
    Copy-Item -LiteralPath $built[0].FullName -Destination $msi
} finally {
    Pop-Location
}

# Seed user and service profiles after terminating RustDesk so the previous
# process does not overwrite fixtures during the upgrade.
Stop-Service RustDesk
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
$configDirectories = @(
    (Join-Path $env:APPDATA 'RustDesk\config'),
    (Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config')
)
foreach ($dir in $configDirectories) {
    New-Item -ItemType Directory -Path (Join-Path $dir 'peers') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'RustDesk.toml') -Value "id = '721234567'" -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'RustDesk2.toml') -Value @(
        '[options]',
        "custom-rendezvous-server = '127.0.0.1:21116'",
        "relay-server = '127.0.0.1:21117'",
        "privacy-mode-2-resolution = '3048x2032'"
    ) -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'peers\754321012.toml') -Value "alias = 'upgrade-smoke-test'" -Encoding ascii
}
Start-Service RustDesk
Install-Msi $msi '02-fork-upgrade'

$upgraded = Get-ItemProperty -LiteralPath $stateKey
if ($upgraded.InstallLocation -ine $installDir) { throw 'The upgrade moved the installation' }
if (!$upgraded.MsiProductCode -or $upgraded.MsiProductCode -eq $oldProduct) { throw 'MSI product registration did not upgrade' }
if (Test-Path -LiteralPath (Join-Path $uninstallKey $oldProduct)) { throw 'The previous MSI was left registered alongside the upgrade' }
if ((Get-FileHash -LiteralPath (Join-Path $installDir 'librustdesk.dll')).Hash -ne $expectedDll) { throw 'Patched DLL was not installed' }
$installedExe = Join-Path $installDir 'rustdesk.exe'
if ((Get-FileHash -LiteralPath $installedExe).Hash -ne $expectedExe) { throw 'Patched executable was not installed' }
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $installedExe
$start.WorkingDirectory = $installDir
$start.Arguments = '--build-date'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$probe = [Diagnostics.Process]::Start($start)
if (!$probe.WaitForExit(10000)) { $probe.Kill(); throw 'Installed executable did not answer its build-date query' }
$appBuildDate = $probe.StandardOutput.ReadToEnd().Trim()
if ($probe.ExitCode -ne 0 -or !$appBuildDate -or $appBuildDate -ne $upgraded.BuildDate) { throw 'Installed build-date metadata is stale' }
(Get-Service RustDesk).WaitForStatus('Running', [timespan]::FromSeconds(15))

foreach ($dir in $configDirectories) {
    if (!(Select-String -Quiet -SimpleMatch '721234567' -LiteralPath (Join-Path $dir 'RustDesk.toml'))) { throw "Device ID was lost from $dir" }
    if (!(Select-String -Quiet -SimpleMatch '127.0.0.1:21116' -LiteralPath (Join-Path $dir 'RustDesk2.toml'))) { throw "Server settings were lost from $dir" }
    if (!(Select-String -Quiet -SimpleMatch '3048x2032' -LiteralPath (Join-Path $dir 'RustDesk2.toml'))) { throw "Privacy mode resolution was lost from $dir" }
    if (!(Select-String -Quiet -SimpleMatch 'upgrade-smoke-test' -LiteralPath (Join-Path $dir 'peers\754321012.toml'))) { throw "Peer history was lost from $dir" }
}
Write-Host "Upgraded $oldProduct to $($upgraded.MsiProductCode) at $installDir"
Write-Host "Verified patched files, build date $appBuildDate, service startup and saved settings"
