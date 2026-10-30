#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up Prism Launcher for local splitscreen Minecraft Java (1-4 players,
    one controller each) on Windows.

.DESCRIPTION
    1. Installs Prism Launcher via winget if missing
    2. Picks the newest Minecraft release supported by every core mod
    3. Downloads Fabric mods (+ required dependencies) from Modrinth:
         core: fabric-api, controlify (or midnightcontrols), mc-splitscreen, sodium
               (+ offlinelan when offline accounts are used)
         perf: lithium, ferrite-core, modernfix, immediatelyfast, entityculling
    4. Creates one Prism instance per player with RAM sized to this machine and
       low-end-friendly options.txt (no pause on lost focus, music only on P1)
    5. Writes %USERPROFILE%\MinecraftSplitscreen\Launch-Splitscreen.ps1 and a
       desktop shortcut

    Players without their own Microsoft account get an offline Prism account
    (Player2, Player3, ... or -OfflineNames), and OfflineLAN is added so the host
    can turn off online-mode when opening to LAN. -NoOffline disables this.

    Re-running is safe: existing instances are skipped unless -Force is given.
    -Force replaces mod jars and instance config but never touches saves or
    options.txt.

.EXAMPLE
    .\Setup-MCSplitscreen.ps1
.EXAMPLE
    .\Setup-MCSplitscreen.ps1 -Players 2 -Accounts Steve,Alex -MemoryMB 2048
.EXAMPLE
    .\Setup-MCSplitscreen.ps1 -Players 3 -OfflineNames Sam,Riley
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 4)][int]$Players = 4,
    [string]$MinecraftVersion,
    [int]$MemoryMB,
    [string[]]$Accounts = @(),
    [string[]]$OfflineNames = @(),
    [switch]$NoOffline,
    [ValidateSet('controlify', 'midnightcontrols')][string]$ControllerMod = 'controlify',
    [string]$PrismDataDir,
    [string]$PrismExe,
    [string]$Prefix = 'Splitscreen-P',
    [int]$LaunchDelay = 20,
    [switch]$Force,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much faster without it
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Api = 'https://api.modrinth.com/v2'
$UA = 'mc-splitscreen-setup/1.0 (Prism Launcher splitscreen helper)'
$CoreMods = @('fabric-api', $ControllerMod, 'mc-splitscreen', 'sodium')
$PerfMods = @('lithium', 'ferrite-core', 'modernfix', 'immediatelyfast', 'entityculling')
$OutDir = Join-Path $env:USERPROFILE 'MinecraftSplitscreen'

# ---------------------------- helpers ----------------------------------------
function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Note([string]$m) { Write-Host "!!  $m" -ForegroundColor Yellow }

function Invoke-Api([string]$Url) { Invoke-RestMethod -Uri $Url -UserAgent $UA }

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # Prism's JSON parser dislikes BOMs, and PS 5.1's UTF8 encoding adds one
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

function Get-ModVersions([string]$Id, [string]$Mc) {
    $q = 'loaders=' + [uri]::EscapeDataString('["fabric"]')
    if ($Mc) { $q += '&game_versions=' + [uri]::EscapeDataString("[`"$Mc`"]") }
    $r = Invoke-Api "$Api/project/$Id/version?$q"
    $r   # emitting the variable enumerates the array (PS 5.1-safe)
}

# ---------------------------- 1. Prism Launcher ------------------------------
function Find-Prism {
    if ($PrismExe -and (Test-Path $PrismExe)) { return (Resolve-Path $PrismExe).Path }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\PrismLauncher\prismlauncher.exe",
        "$env:ProgramFiles\PrismLauncher\prismlauncher.exe",
        "${env:ProgramFiles(x86)}\PrismLauncher\prismlauncher.exe"
    )
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $uninstallKeys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Prism Launcher*' -and $_.InstallLocation } |
            ForEach-Object { $candidates += (Join-Path $_.InstallLocation 'prismlauncher.exe') }
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command prismlauncher.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$prism = Find-Prism
if (-not $prism -and -not $SkipInstall) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget not found. Install Prism Launcher from https://prismlauncher.org and re-run.'
    }
    Write-Step 'Installing Prism Launcher (winget)'
    winget install --id PrismLauncher.PrismLauncher -e --accept-source-agreements --accept-package-agreements
    $prism = Find-Prism
}
if (-not $prism) { throw 'Prism Launcher not found. Use -PrismExe to point at prismlauncher.exe.' }
Write-Step "Prism Launcher: $prism"

# ---------------------------- 2. Prism data / accounts -----------------------
if (-not $PrismDataDir) {
    $exeDir = Split-Path $prism -Parent
    if (Test-Path (Join-Path $exeDir 'portable.txt')) { $PrismDataDir = $exeDir }
    else { $PrismDataDir = Join-Path $env:APPDATA 'PrismLauncher' }
}
$accountsFile = Join-Path $PrismDataDir 'accounts.json'

function Get-PrismAccountList {
    if (-not (Test-Path $accountsFile)) { return @() }
    $j = Get-Content $accountsFile -Raw | ConvertFrom-Json
    $all = @($j.accounts) | Where-Object { $_.profile.name }
    # Microsoft accounts first so P1 (the LAN host) gets a real account
    @($all | Where-Object { $_.type -ne 'Offline' }) + @($all | Where-Object { $_.type -eq 'Offline' })
}

function Get-PrismAccounts { Get-PrismAccountList | ForEach-Object { $_.profile.name } }

function Get-OfflineUuid([string]$Name) {
    # Java's UUID.nameUUIDFromBytes("OfflinePlayer:<name>"), same as Prism and the server
    $b = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$Name"))
    $b[6] = ($b[6] -band 0x0f) -bor 0x30
    $b[8] = ($b[8] -band 0x3f) -bor 0x80
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Add-OfflineAccounts([string[]]$Names) {
    if (Get-Process -Name prismlauncher -ErrorAction SilentlyContinue) {
        throw 'Close Prism Launcher first (it rewrites accounts.json on exit), then re-run.'
    }
    $now = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
    # Same shape Prism saves for Settings > Accounts > Add Offline
    $entries = foreach ($n in $Names) {
        @"
        {
            "type": "Offline",
            "ygg": { "iat": $now, "token": "0", "extra": { "clientToken": "$([guid]::NewGuid().ToString('N'))", "userName": "$n" } },
            "profile": { "id": "$(Get-OfflineUuid $n)", "name": "$n", "skin": { "id": "", "url": "", "variant": "" }, "capes": [] },
            "entitlement": { "canPlayMinecraft": true, "ownsMinecraft": true }
        }
"@
    }
    # Splice text in rather than round-tripping through ConvertTo-Json, which
    # PS 5.1 can mangle (and these entries sit next to MSA tokens)
    $text = Get-Content $accountsFile -Raw
    $m = [regex]::Match($text, '"accounts"\s*:\s*\[')
    if (-not $m.Success) { throw "Unexpected format in $accountsFile" }
    $at = $m.Index + $m.Length
    $sep = if ($text.Substring($at) -match '^\s*\]') { '' } else { ',' }
    Copy-Item $accountsFile "$accountsFile.bak" -Force
    Write-Utf8NoBom $accountsFile $text.Insert($at, "`n" + ($entries -join ",`n") + $sep)
}

if (@(Get-PrismAccounts).Count -eq 0) {
    Write-Note 'Prism has no accounts yet.'
    Write-Step "Opening Prism. Finish the first-run wizard, add each player's Microsoft account"
    Write-Step '(Settings > Accounts), then CLOSE Prism to continue.'
    Start-Process $prism -Wait
    if (@(Get-PrismAccounts).Count -eq 0) { throw "Still no accounts in $accountsFile" }
}

# Instance folder (respects a custom InstanceDir in prismlauncher.cfg)
$instDir = Join-Path $PrismDataDir 'instances'
$cfg = Join-Path $PrismDataDir 'prismlauncher.cfg'
if (Test-Path $cfg) {
    $line = Select-String -Path $cfg -Pattern '^InstanceDir=(.+)$' | Select-Object -First 1
    if ($line) {
        $custom = $line.Matches[0].Groups[1].Value.Trim()
        if ([IO.Path]::IsPathRooted($custom)) { $instDir = $custom } else { $instDir = Join-Path $PrismDataDir $custom }
    }
}
New-Item -ItemType Directory -Force -Path $instDir | Out-Null

if ($Accounts.Count -eq 0) { $Accounts = @(Get-PrismAccounts) }
if ($Accounts.Count -lt $Players -and -not $NoOffline) {
    $known = @(Get-PrismAccounts)
    $toAdd = @()
    $j = 0
    while ($Accounts.Count -lt $Players) {
        $n = if ($j -lt $OfflineNames.Count) { $OfflineNames[$j] } else { "Player$($Accounts.Count + 1)" }
        $j++
        if ($n -notmatch '^[A-Za-z0-9_]{3,16}$') { throw "Offline name '$n' must be 3-16 letters, digits or _" }
        if ($Accounts -contains $n) { throw "Account '$n' is already assigned to another player" }
        if ($known -notcontains $n) { $toAdd += $n }
        $Accounts += $n
    }
    if ($toAdd.Count -gt 0) {
        Write-Step "Adding offline Prism accounts: $($toAdd -join ', ')"
        Add-OfflineAccounts $toAdd
    }
}
if ($Accounts.Count -lt $Players) {
    Write-Note "Only $($Accounts.Count) account(s) for $Players players. Each player needs their own account"
    Write-Note 'to join the LAN world; add more in Prism and re-run, or edit the launcher script later.'
}

$offlineNamesInPrism = @(Get-PrismAccountList | Where-Object { $_.type -eq 'Offline' } | ForEach-Object { $_.profile.name })
$usesOffline = @($Accounts | Select-Object -First $Players | Where-Object { $offlineNamesInPrism -contains $_ }).Count -gt 0
if ($usesOffline) {
    if (@(Get-PrismAccountList | Where-Object { $_.type -eq 'MSA' }).Count -eq 0) {
        Write-Note 'Prism needs at least one Microsoft account that owns Minecraft, or offline accounts launch in demo mode.'
    }
    # Lets the host turn off online-mode in the Open to LAN screen so offline players can join
    $CoreMods += 'offlinelan'
}

# ---------------------------- 3. versions ------------------------------------
function Get-BestMcVersion {
    $tags = Invoke-Api "$Api/tag/game_version"
    $releases = @($tags) | Where-Object { $_.version_type -eq 'release' } |
        Sort-Object { [datetime]$_.date } -Descending | ForEach-Object { $_.version }
    $sets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($m in $CoreMods) {
        $hs = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($v in @(Get-ModVersions $m)) { foreach ($g in $v.game_versions) { [void]$hs.Add($g) } }
        $sets.Add($hs)
    }
    foreach ($r in $releases) {
        $ok = $true
        foreach ($hs in $sets) { if (-not $hs.Contains($r)) { $ok = $false; break } }
        if ($ok) { return $r }
    }
    throw 'No Minecraft release is supported by all core mods.'
}

if (-not $MinecraftVersion) {
    Write-Step "Finding newest Minecraft version supported by: $($CoreMods -join ', ')"
    $MinecraftVersion = Get-BestMcVersion
}
$loaders = Invoke-Api 'https://meta.fabricmc.net/v2/versions/loader'
$loader = (@($loaders) | Where-Object { $_.stable } | Select-Object -First 1).version
if (-not $loader) { throw 'Could not get Fabric loader version.' }
Write-Step "Minecraft $MinecraftVersion, Fabric loader $loader"

# ---------------------------- 4. memory --------------------------------------
$totalMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
if (-not $MemoryMB) {
    # Windows itself needs more headroom than a light Linux desktop
    $MemoryMB = [int][math]::Floor(($totalMB - 4096) / $Players)
    if ($MemoryMB -gt 3072) { $MemoryMB = 3072 }
}
if ($MemoryMB -lt 2048) {
    Write-Note "Only ~$MemoryMB MB per instance ($totalMB MB total). Consider fewer players."
    if ($MemoryMB -lt 1536) { $MemoryMB = 1536 }
}
$hostMem = [math]::Min($MemoryMB + 512, 3584)
Write-Step "RAM: host $hostMem MB, others $MemoryMB MB (system $totalMB MB)"

# ---------------------------- 5. mods ----------------------------------------
$cache = Join-Path ([IO.Path]::GetTempPath()) ("mc-splitscreen-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $cache | Out-Null
$seen = @{}

function Save-Mod([string]$Id, [bool]$Required) {
    try { $versions = @(Get-ModVersions $Id $MinecraftVersion) }
    catch {
        if ($Required) { throw "Mod '$Id' not found on Modrinth." }
        Write-Note "Skipping '$Id' (not found)"; return
    }
    if ($versions.Count -eq 0) {
        if ($Required) { throw "No Fabric build of '$Id' for $MinecraftVersion." }
        Write-Note "Skipping '$Id' (no build for $MinecraftVersion)"; return
    }
    $ver = $versions | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1
    if (-not $ver) { $ver = $versions[0] }
    if ($script:seen.ContainsKey($ver.project_id)) { return }
    $script:seen[$ver.project_id] = $true

    $file = @($ver.files) | Where-Object { $_.primary } | Select-Object -First 1
    if (-not $file) { $file = @($ver.files)[0] }
    Write-Host ('    {0,-18} {1}' -f $Id, $file.filename)
    Invoke-WebRequest -Uri $file.url -OutFile (Join-Path $cache $file.filename) -UserAgent $UA -UseBasicParsing

    foreach ($d in @($ver.dependencies)) {
        if ($d -and $d.dependency_type -eq 'required' -and $d.project_id) { Save-Mod $d.project_id $true }
    }
}

try {
    Write-Step 'Downloading mods'
    foreach ($m in $CoreMods) { Save-Mod $m $true }
    foreach ($m in $PerfMods) { Save-Mod $m $false }

    # ------------------------ 6. instances -----------------------------------
    $instances = @()
    for ($i = 1; $i -le $Players; $i++) {
        $id = "$Prefix$i"
        $dir = Join-Path $instDir $id
        $instances += $id

        if ((Test-Path $dir) -and -not $Force) {
            Write-Note "$id already exists, skipping (use -Force to rebuild)"
            continue
        }
        Write-Step "Creating instance $id"

        $gameDir = Join-Path $dir 'minecraft'
        if (Test-Path (Join-Path $dir '.minecraft')) { $gameDir = Join-Path $dir '.minecraft' }
        $modsDir = Join-Path $gameDir 'mods'
        New-Item -ItemType Directory -Force -Path $modsDir | Out-Null
        Get-ChildItem $modsDir -Filter *.jar -ErrorAction SilentlyContinue | Remove-Item -Force
        Copy-Item (Join-Path $cache '*.jar') $modsDir

        $mem = if ($i -eq 1) { $hostMem } else { $MemoryMB }

        Write-Utf8NoBom (Join-Path $dir 'instance.cfg') @"
[General]
ConfigVersion=1.3
InstanceType=OneSix
name=Splitscreen P$i
iconKey=default
OverrideMemory=true
MinMemAlloc=512
MaxMemAlloc=$mem
OverrideJavaArgs=true
JvmArgs=-XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:+ParallelRefProcEnabled
"@

        Write-Utf8NoBom (Join-Path $dir 'mmc-pack.json') @"
{
    "components": [
        { "important": true, "uid": "net.minecraft", "version": "$MinecraftVersion" },
        { "uid": "net.fabricmc.fabric-loader", "version": "$loader" }
    ],
    "formatVersion": 1
}
"@

        $opts = Join-Path $gameDir 'options.txt'
        if (-not (Test-Path $opts)) {
            $music = if ($i -eq 1) { '1.0' } else { '0.0' }
            Write-Utf8NoBom $opts @"
pauseOnLostFocus:false
fullscreen:false
renderDistance:8
simulationDistance:6
maxFps:60
enableVsync:false
graphicsMode:0
renderClouds:"false"
ao:false
entityShadows:false
particles:2
biomeBlendRadius:0
soundCategory_music:$music
onboardAccessibility:false
skipMultiplayerWarnings:true
joinedFirstServer:true
tutorialStep:none
narrator:0
"@
        }
    }
}
finally {
    Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------- 7. launcher ------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
function ConvertTo-PsArray([string[]]$items) {
    if (-not $items -or $items.Count -eq 0) { return '@()' }
    '@(' + (($items | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')'
}

$launcher = Join-Path $OutDir 'Launch-Splitscreen.ps1'
Write-Utf8NoBom $launcher @"
# Generated by Setup-MCSplitscreen.ps1. Edit `$Accounts if player accounts change.
`$Prism     = '$($prism -replace "'", "''")'
`$Instances = $(ConvertTo-PsArray $instances)
`$Accounts  = $(ConvertTo-PsArray $Accounts)
`$Delay     = $LaunchDelay

for (`$i = 0; `$i -lt `$Instances.Count; `$i++) {
    `$launchArgs = @('-l', `$Instances[`$i])
    if (`$i -lt `$Accounts.Count -and `$Accounts[`$i]) { `$launchArgs += @('-a', `$Accounts[`$i]) }
    Start-Process -FilePath `$Prism -ArgumentList `$launchArgs
    # Stagger launches so RAM/disk don't spike all at once
    if (`$i -lt `$Instances.Count - 1) { Start-Sleep -Seconds `$Delay }
}
"@

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Minecraft Splitscreen.lnk'
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
$sc.IconLocation = "$prism,0"
$sc.WorkingDirectory = $OutDir
$sc.Save()

# ---------------------------- done -------------------------------------------
$lanStep = if ($usesOffline) { 'Open to LAN, and switch Online Mode OFF there (offline players get kicked otherwise).' } else { 'Open to LAN.' }
Write-Step 'Done!'
Write-Host @"
  Instances : $($instances -join ', ')  (in $instDir)
  Launcher  : $launcher
  Shortcut  : $shortcutPath

First-time setup in each window (settings are saved afterwards):
  1. Press F11 until the window snaps to its quarter of the screen.
  2. Open $ControllerMod settings, pick that player's controller, and turn on
     out-of-focus / unfocused input.
  3. Player 1: create a world, then Pause > $lanStep
  4. Players 2-${Players}: Multiplayer > the LAN world should appear (or Direct Connect
     to localhost:<port shown in P1's chat>).

Tip: if Steam is running, disable Steam Input for Prism so it doesn't
create duplicate virtual controllers.
"@
