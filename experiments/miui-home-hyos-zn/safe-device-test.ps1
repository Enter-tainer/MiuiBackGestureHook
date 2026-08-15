[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy', 'Rollback', 'Capture')]
    [string]$Action = 'Status',
    [Parameter(Mandatory = $true)]
    [string]$Serial,
    [string]$PackageZip,
    [switch]$Confirm4371,
    [switch]$Confirm5334
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Nl = [Environment]::NewLine
$ModuleId = 'miui-home-hyos-zn'
$ModuleDir = "/data/adb/modules/$ModuleId"
$ModuleSo = "$ModuleDir/lib/libmiui_home_hyos_zn.so"
$Hsctl = "$ModuleDir/bin/hsctl"
$Znctl = '/data/adb/modules/zygisksu/bin/zygiskd'
$ExpectedVersionCode = '801024371'
$ExpectedVersionName = 'RELEASE-8.01.02.4371-260727-08131546-R'
$ExpectedVersionCode5334 = '801025334'
$ExpectedVersionName5334 = 'RELEASE-8.01.02.5334-260807-08151151-R'
$ExpectedNativeSha256 =
    '10388972d3fed052285710d7b3de8b895f3f6bac71f711fee9dab32530599d78'
$EvidenceRoot = Join-Path $PSScriptRoot 'out\device-tests'

function Invoke-Adb {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $lines = @(& adb -s $Serial @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "adb failed ($exitCode): $($Arguments -join ' ')$Nl$($lines -join $Nl)"
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $lines
        Text = $lines -join $Nl
    }
}

function Invoke-Root {
    param([string]$Command, [switch]$AllowFailure)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $quoteEscape = -join @(
        $singleQuote, $doubleQuote, $singleQuote, $doubleQuote, $singleQuote)
    # PowerShell here-strings use CRLF on Windows. Android mksh treats the
    # retained carriage return as a command name after a semicolon, so every
    # root script must be normalized before it is quoted for `su -c`.
    $normalized = $Command.Replace("`r`n", "`n").Trim()
    $escaped = $normalized.Replace($singleQuote.ToString(), $quoteEscape)
    $remote = [string]::Concat('su -c ', $singleQuote, $escaped, $singleQuote)
    Invoke-Adb -Arguments @('shell', $remote) -AllowFailure:$AllowFailure
}

function Invoke-Hsctl {
    param([string]$Command, [switch]$AllowFailure)
    $seconds = if ($Command.StartsWith('activate')) {
        55
    } elseif ($Command.StartsWith('rollback')) {
        40
    } else {
        8
    }
    Invoke-Root -Command "timeout $seconds $Hsctl $Command" -AllowFailure:$AllowFailure
}

function Assert-Device {
    if ((Invoke-Adb -Arguments @('get-state')).Text.Trim() -ne 'device') {
        throw "Device $Serial is not online."
    }
    if ((Invoke-Root -Command 'id -u').Text.Trim() -ne '0') {
        throw "Device $Serial has no adb-accessible root shell."
    }
}

function Get-ConfirmedProfile {
    if ($Confirm4371 -eq $Confirm5334) {
        throw 'Mutation requires exactly one of -Confirm4371 or -Confirm5334.'
    }
    if ($Confirm4371) {
        return [pscustomobject]@{
            Id = '4371'
            VersionCode = $ExpectedVersionCode
            VersionName = $ExpectedVersionName
        }
    }
    [pscustomobject]@{
        Id = '5334'
        VersionCode = $ExpectedVersionCode5334
        VersionName = $ExpectedVersionName5334
    }
}

function Assert-ExactMiuiHome {
    param([pscustomobject]$Profile)
    $package = (Invoke-Adb -Arguments @(
        'shell', 'dumpsys', 'package', 'com.miui.home')).Text
    $namePattern = [regex]::Escape($Profile.VersionName)
    if ($package -notmatch "versionCode=$($Profile.VersionCode)(?:\s|$)" -or
            $package -notmatch "versionName=$namePattern(?:\s|$)") {
        throw "Refusing mutation: installed MiuiHome is not exact approved $($Profile.Id)."
    }
}

function Get-ExactSpawnerPid {
    $command = @'
for pid in $(ps -A -o USER,PID,PPID | awk '$1 == "root" && $3 == 1 {print $2}'); do [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "/system_ext/bin/hyos_spawner" ] || continue; echo "$pid"; exit 0; done; exit 1
'@
    $result = Invoke-Root -Command $command -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Text.Trim() -notmatch '^\d+$') {
        return $null
    }
    [int]$result.Text.Trim()
}

function Get-ModuleMappedPids {
    $spawner = Get-ExactSpawnerPid
    if ($null -eq $spawner) { return @() }
    $command = @'
for pid in __SPAWNER__ $(ps -A -o PID,PPID | awk -v owner=__SPAWNER__ '$2 == owner {print $1}'); do maps="/proc/$pid/maps"; [ -r "$maps" ] || continue; grep -F "/data/adb/modules/miui-home-hyos-zn/lib/libmiui_home_hyos_zn.so" "$maps" >/dev/null 2>&1 && echo "$pid"; done; true
'@
    $command = $command.Replace('__SPAWNER__', $spawner.ToString())
    $result = Invoke-Root -Command $command
    @($result.Lines | Where-Object { $_ -match '^\d+$' })
}

function Get-LatestTombstone {
    $command = @'
for item in /data/tombstones/tombstone_*; do [ -f "$item" ] && stat -c '%Y:%s:%n' "$item"; done | sort -n | tail -n 1
'@
    (Invoke-Root -Command $command).Text.Trim()
}

function Show-HostStatus {
    "hyos_pid=$(Get-ExactSpawnerPid)"
    $launcher = (Invoke-Adb -Arguments @(
        'shell', 'pidof', 'com.miui.home') -AllowFailure).Text.Trim()
    "launcher_pid=$launcher"
    $mapped = @(Get-ModuleMappedPids)
    "module_mapped_pids=$(if ($mapped.Count) { $mapped -join ',' } else { 'none' })"
    $zn = Invoke-Root -Command "timeout -k 1 2 $Znctl dump-zn -sa" -AllowFailure
    if ($zn.ExitCode -eq 0) {
        @($zn.Lines | Where-Object {
            $_ -match 'miui-home-hyos-zn|/system_ext/bin/hyos_spawner|can_load='
        })
    } else {
        "zn_status=unavailable,exit=$($zn.ExitCode)"
    }
}

function Stop-ExactSpawner {
    param([int]$OldPid)
    if ((Get-ExactSpawnerPid) -ne $OldPid) {
        throw "PID $OldPid is no longer the exact root hyos_spawner."
    }
    Invoke-Root -Command "kill -TERM $OldPid" | Out-Null
    for ($attempt = 0; $attempt -lt 150; $attempt++) {
        $newPid = Get-ExactSpawnerPid
        if ($null -ne $newPid -and $newPid -ne $OldPid) { return $newPid }
        Start-Sleep -Milliseconds 100
    }
    throw 'hyos_spawner did not reach a replacement PID within 15 seconds.'
}

function Read-NativeCounters {
    $launcherText = (Invoke-Adb -Arguments @(
        'shell', 'pidof', 'com.miui.home') -AllowFailure).Text.Trim()
    $launcher = $launcherText.Split(' ')[0]
    if ($launcher -notmatch '^\d+$') { return 'counter_error=launcher-unavailable' }
    $baseCommand = @'
awk -v target="/data/adb/modules/miui-home-hyos-zn/lib/libmiui_home_hyos_zn.so" 'index($0, target) && $3 == "00000000" {split($1, range, "-"); print range[1]; exit}' /proc/__PID__/maps
'@.Replace('__PID__', $launcher)
    $baseHex = (Invoke-Root -Command $baseCommand -AllowFailure).Text.Trim()
    if ($baseHex -notmatch '^[0-9a-fA-F]+$') { return 'counter_error=module-base-unavailable' }
    $map = Invoke-Root -Command "cat $ModuleDir/diagnostics.map" -AllowFailure
    if ($map.ExitCode -ne 0) { return 'counter_error=diagnostics-map-unavailable' }
    $base = [Convert]::ToInt64($baseHex, 16)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $map.Lines) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -ne 3 -or $parts[1] -notmatch '^0x[0-9a-fA-F]+$' -or
                $parts[2] -notin @('u4', 'u8')) { continue }
        $offset = [Convert]::ToInt64($parts[1].Substring(2), 16)
        $bytes = if ($parts[2] -eq 'u4') { 4 } else { 8 }
        $address = $base + $offset
        $value = (Invoke-Root -Command "od -A n -t $($parts[2]) -j $address -N $bytes /proc/$launcher/mem" -AllowFailure).Text.Trim()
        $result.Add("$($parts[0])=$value")
    }
    $nativeDigest = (Invoke-Root -Command "sha256sum $ModuleSo" -AllowFailure).Text
    if (($nativeDigest -match '^([0-9a-fA-F]{64})(?:\s|$)') -and
            ($Matches[1].ToLowerInvariant() -eq $ExpectedNativeSha256)) {
        # Exact 0.8.24-only extensions. These immutable offsets diagnose which
        # Xiaomi InputMonitor owner pilfered a stream without changing the active
        # package or reading Shell/MotionEvent state from the wrong thread.
        $extraCounters = @(
            @('pilfer_last_return_offset', '0x13458', 'u8'),
            @('pilfer_caller_be8e98', '0x13460', 'u4'),
            @('pilfer_caller_bf07b4', '0x13464', 'u4'),
            @('pilfer_caller_c11a7c', '0x13468', 'u4'),
            @('pilfer_caller_c12e2c', '0x1346c', 'u4'),
            @('pilfer_observation_sequence', '0x13480', 'u8')
        )
        foreach ($spec in $extraCounters) {
            $offset = [Convert]::ToInt64($spec[1].Substring(2), 16)
            $bytes = if ($spec[2] -eq 'u4') { 4 } else { 8 }
            $address = $base + $offset
            $readCommand =
                "od -A n -t $($spec[2]) -j $address -N $bytes /proc/$launcher/mem"
            $value = (Invoke-Root -Command $readCommand -AllowFailure).Text.Trim()
            $result.Add("$($spec[0])=$value")
        }
    }
    $result
}

function Restore-CleanHome {
    Invoke-Root -Command "timeout -k 1 5 $Znctl znmod disable $ModuleId svc" -AllowFailure | Out-Null
    $mapped = @(Get-ModuleMappedPids)
    if ($mapped.Count -ne 0) {
        $oldPid = Get-ExactSpawnerPid
        if ($null -eq $oldPid) {
            throw 'Recovery cannot resolve the exact root hyos_spawner.'
        }
        Stop-ExactSpawner -OldPid $oldPid | Out-Null
    }
    $spawnerPid = Get-ExactSpawnerPid
    if ($null -eq $spawnerPid) {
        throw 'Recovery has no running root hyos_spawner.'
    }
    Invoke-Adb -Arguments @(
        'shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
        '-c', 'android.intent.category.HOME') -AllowFailure | Out-Null
    for ($attempt = 0; $attempt -lt 200; $attempt++) {
        $launcher = (Invoke-Adb -Arguments @(
            'shell', 'pidof', 'com.miui.home') -AllowFailure).Text.Trim().Split(' ')[0]
        if ($launcher -match '^\d+$') {
            $parent = (Invoke-Root -Command "sed -n 's/^PPid:[[:space:]]*//p' /proc/$launcher/status" -AllowFailure).Text.Trim()
            if ($parent -eq $spawnerPid.ToString() -and @(Get-ModuleMappedPids).Count -eq 0) {
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Recovery did not produce a clean normal MiuiHome process within 20 seconds.'
}

function Write-Evidence {
    param([string]$Phase)
    $target = Join-Path $EvidenceRoot "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Phase"
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
    $status = @(Show-HostStatus) -join $Nl
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'device-status.txt'), $status + $Nl)
    $counters = @(Read-NativeCounters) -join $Nl
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'native-counters.txt'), $counters + $Nl)
    $logs = Invoke-Adb -Arguments @(
        'shell', 'logcat', '-d', '-v', 'threadtime', '-t', '2500') -AllowFailure
    $selected = @($logs.Lines | Where-Object {
        $_ -match 'MiuiHomeHyosZn|MiuiBackGestureHook|SystemUiInputRuntime|SystemUiHookRuntime|BackAnimation|GestureInputMonitor|GesturesBackTouchProcessor|GestureBackArrow|BackGesture|gesture_type|home_region'
    })
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'gesture-logcat.txt'), ($selected -join $Nl) + $Nl)
    $crashLogs = Invoke-Adb -Arguments @(
        'shell', 'logcat', '-b', 'crash', '-d', '-v', 'threadtime', '-t', '1200') `
        -AllowFailure
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'crash-logcat.txt'), $crashLogs.Text + $Nl)
    $eventLogs = Invoke-Adb -Arguments @(
        'shell', 'logcat', '-b', 'events', '-d', '-v', 'threadtime', '-t', '3000') `
        -AllowFailure
    $processEvents = @($eventLogs.Lines | Where-Object {
        $_ -match 'am_crash|am_anr|am_kill|am_proc_died|am_proc_start|com\.miui\.home|com\.android\.systemui'
    })
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'process-events.txt'),
        ($processEvents -join $Nl) + $Nl)
    $latestLsposed = (Invoke-Root -Command `
        "ls -1t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -n 1" `
        -AllowFailure).Text.Trim()
    $lsposedSelected = @()
    if ($latestLsposed -match '^/data/adb/lspd/log/modules_[^/]+\.log$') {
        $lsposed = Invoke-Root -Command "tail -n 5000 '$latestLsposed'" -AllowFailure
        $lsposedSelected = @($lsposed.Lines | Where-Object {
            $_ -match 'MiuiHomeHyosZn|MiuiBackGestureHook|SystemUiInputRuntime|SystemUiHookRuntime|BackAnimation|GestureInputMonitor|GesturesBackTouchProcessor|GestureBackArrow|BackGesture|gesture_type|home_region|input.arbiter|MiuiHome acceptance'
        })
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'lsposed-module-log.txt'),
        ($lsposedSelected -join $Nl) + $Nl)
    $tombstoneCommand = @'
for item in /data/tombstones/tombstone_*; do [ -f "$item" ] && stat -c '%Y %s %n' "$item"; done
'@
    $tombstones = Invoke-Root -Command $tombstoneCommand -AllowFailure
    [System.IO.File]::WriteAllText(
        (Join-Path $target 'tombstones.txt'), $tombstones.Text + $Nl)
    $target
}

function Assert-Zip {
    param([string]$Root)
    $required = @(
        'module.prop', 'zn_modules.txt', 'diagnostics.map', 'uninstall.sh', 'README.md',
        'bin\hsctl', 'lib\arm64\libmiui_home_hyos_zn.so'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) {
            throw "Package is missing $relative."
        }
    }
    $forbidden = @('set' + 'prop', '/system/bin/hsctl', '$MODPATH/system')
    foreach ($relative in @('uninstall.sh', 'bin\hsctl')) {
        $text = Get-Content -LiteralPath (Join-Path $Root $relative) -Raw
        foreach ($needle in $forbidden) {
            if ($text.Contains($needle)) {
                throw "Package $relative contains forbidden content: $needle"
            }
        }
    }
}

function Install-StagedPayload {
    param([string]$Root, [string]$ShortHash)
    $remote = "/data/local/tmp/miui-home-hyos-zn-$ShortHash"
    if ($remote -notmatch '^/data/local/tmp/miui-home-hyos-zn-[0-9a-f]{12}$') {
        throw "Unsafe remote path: $remote"
    }
    Invoke-Adb -Arguments @('shell', 'rm', '-rf', $remote) | Out-Null
    Invoke-Adb -Arguments @('shell', 'mkdir', '-p', $remote) | Out-Null
    $files = [ordered]@{
        'module.prop' = 'module.prop'
        'zn_modules.txt' = 'zn_modules.txt'
        'diagnostics.map' = 'diagnostics.map'
        'uninstall.sh' = 'uninstall.sh'
        'README.md' = 'README.md'
        'bin\hsctl' = 'hsctl'
        'lib\arm64\libmiui_home_hyos_zn.so' = 'module.so'
    }
    foreach ($entry in $files.GetEnumerator()) {
        Invoke-Adb -Arguments @(
            'push', (Join-Path $Root $entry.Key), "$remote/$($entry.Value)") | Out-Null
    }
    if ((Invoke-Root -Command "[ -d '$ModuleDir' ]" -AllowFailure).ExitCode -ne 0) {
        throw 'Module is not installed; first install must occur with its ZN scope disabled.'
    }

    $suffix = ".next-$ShortHash"
    $stage = @"
set -eu;
mkdir -p '$ModuleDir/bin' '$ModuleDir/lib';
cp '$remote/module.prop' '$ModuleDir/module.prop$suffix';
cp '$remote/zn_modules.txt' '$ModuleDir/zn_modules.txt$suffix';
cp '$remote/diagnostics.map' '$ModuleDir/diagnostics.map$suffix';
cp '$remote/uninstall.sh' '$ModuleDir/uninstall.sh$suffix';
cp '$remote/README.md' '$ModuleDir/README.md$suffix';
cp '$remote/hsctl' '$ModuleDir/bin/hsctl$suffix';
cp '$remote/module.so' '$ModuleDir/lib/libmiui_home_hyos_zn.so$suffix';
chown 0:0 '$ModuleDir/module.prop$suffix' '$ModuleDir/zn_modules.txt$suffix' '$ModuleDir/diagnostics.map$suffix' '$ModuleDir/uninstall.sh$suffix' '$ModuleDir/README.md$suffix' '$ModuleDir/bin/hsctl$suffix' '$ModuleDir/lib/libmiui_home_hyos_zn.so$suffix';
chmod 0644 '$ModuleDir/module.prop$suffix' '$ModuleDir/zn_modules.txt$suffix' '$ModuleDir/diagnostics.map$suffix' '$ModuleDir/uninstall.sh$suffix' '$ModuleDir/README.md$suffix' '$ModuleDir/lib/libmiui_home_hyos_zn.so$suffix';
chmod 0755 '$ModuleDir/bin/hsctl$suffix';
"@
    Invoke-Root -Command $stage | Out-Null
    $native = Join-Path $Root 'lib\arm64\libmiui_home_hyos_zn.so'
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $native).Hash.ToLowerInvariant()
    $remoteHash = (Invoke-Root -Command "sha256sum '$ModuleDir/lib/libmiui_home_hyos_zn.so$suffix' | cut -d' ' -f1").Text.Trim()
    if ($localHash -ne $remoteHash) { throw 'Staged native hash mismatch.' }

    Invoke-Root -Command "timeout -k 1 5 $Znctl znmod disable $ModuleId svc" | Out-Null
    $oldPid = Get-ExactSpawnerPid
    if ($null -eq $oldPid) { throw 'Exact root hyos_spawner is unavailable.' }
    $mapped = @(Get-ModuleMappedPids)
    if ($mapped.Count -ne 0) {
        $newPid = Stop-ExactSpawner -OldPid $oldPid
        $mapped = @(Get-ModuleMappedPids)
        if ($mapped.Count -ne 0) {
            throw "Module remains mapped after deactivation: $($mapped -join ',')"
        }
    } else {
        $newPid = $oldPid
    }

    $activate = @"
set -eu;
mv -f '$ModuleDir/module.prop$suffix' '$ModuleDir/module.prop';
mv -f '$ModuleDir/zn_modules.txt$suffix' '$ModuleDir/zn_modules.txt';
mv -f '$ModuleDir/diagnostics.map$suffix' '$ModuleDir/diagnostics.map';
mv -f '$ModuleDir/uninstall.sh$suffix' '$ModuleDir/uninstall.sh';
mv -f '$ModuleDir/README.md$suffix' '$ModuleDir/README.md';
mv -f '$ModuleDir/bin/hsctl$suffix' '$ModuleDir/bin/hsctl';
mv -f '$ModuleDir/lib/libmiui_home_hyos_zn.so$suffix' '$ModuleSo';
"@
    Invoke-Root -Command $activate | Out-Null
    Invoke-Adb -Arguments @('shell', 'rm', '-rf', $remote) | Out-Null
    [pscustomobject]@{ UninjectedSpawnerPid = $newPid; NativeSha256 = $localHash }
}

Assert-Device
switch ($Action) {
    'Status' {
        Show-HostStatus
    }
    'Capture' {
        "evidence=$(Write-Evidence -Phase 'gesture')"
    }
    'Rollback' {
        $profile = Get-ConfirmedProfile
        Assert-ExactMiuiHome -Profile $profile
        (Invoke-Hsctl -Command 'rollback --confirm').Text
        "evidence=$(Write-Evidence -Phase "rollback-$($profile.Id)")"
    }
    'Deploy' {
        $profile = Get-ConfirmedProfile
        if ([string]::IsNullOrWhiteSpace($PackageZip)) {
            throw 'Deploy requires -PackageZip.'
        }
        Assert-ExactMiuiHome -Profile $profile
        $zip = (Resolve-Path -LiteralPath $PackageZip).Path
        $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
        $shortHash = $zipHash.Substring(0, 12)
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) "miui-home-hyos-zn-$shortHash-$([guid]::NewGuid().ToString('N'))"
        [System.IO.Directory]::CreateDirectory($temp) | Out-Null
        $mutationStarted = $false
        try {
            Expand-Archive -LiteralPath $zip -DestinationPath $temp
            Assert-Zip -Root $temp
            $before = Get-LatestTombstone
            $mutationStarted = $true
            $staged = Install-StagedPayload -Root $temp -ShortHash $shortHash
            "package_sha256=$zipHash"
            "native_sha256=$($staged.NativeSha256)"
            "uninjected_spawner_pid=$($staged.UninjectedSpawnerPid)"
            $activation = Invoke-Hsctl -Command 'activate --confirm' -AllowFailure
            $activation.Text
            if ($activation.ExitCode -ne 0) {
                Invoke-Hsctl -Command 'rollback --confirm' -AllowFailure | Out-Null
                throw 'Activation failed; rollback was requested.'
            }
            Start-Sleep -Milliseconds 1500
            $after = Get-LatestTombstone
            if ($after -ne $before) {
                Invoke-Hsctl -Command 'rollback --confirm' -AllowFailure | Out-Null
                throw "New tombstone detected; rolled back: $after"
            }
            "profile=$($profile.Id)"
            "evidence=$(Write-Evidence -Phase "activated-$($profile.Id)-before-gesture")"
            'next_step=perform exactly one fresh side-back gesture, then run Capture'
        }
        catch {
            if ($mutationStarted) {
                Restore-CleanHome
                Write-Evidence -Phase 'automatic-rollback' | Out-Null
            }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Recurse -Force
            }
        }
    }
}
