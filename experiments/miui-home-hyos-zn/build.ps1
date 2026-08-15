[CmdletBinding()]
param(
    [string]$NdkPath = 'D:\env\AndroidSDK\ndk\30.0.14904198',
    [string]$CMakePath = 'D:\env\AndroidSDK\cmake\3.22.1\bin\cmake.exe',
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceRoot = $PSScriptRoot
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $SourceRoot '..\..')).Path
$BuildRoot = Join-Path $RepoRoot "out\miui-home-hyos-zn\$Configuration"
$Toolchain = Join-Path $NdkPath 'build\cmake\android.toolchain.cmake'
$NinjaPath = Join-Path (Split-Path -Parent $CMakePath) 'ninja.exe'
$HostBin = Join-Path $NdkPath 'toolchains\llvm\prebuilt\windows-x86_64\bin'
$ReadElf = Join-Path $HostBin 'llvm-readelf.exe'
$Nm = Join-Path $HostBin 'llvm-nm.exe'
$ObjDump = Join-Path $HostBin 'llvm-objdump.exe'

foreach ($Path in @($CMakePath, $Toolchain, $NinjaPath, $ReadElf, $Nm, $ObjDump)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required build tool does not exist: $Path"
    }
}

& (Join-Path $SourceRoot 'verify-hsctl.ps1') | Out-Host

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$GeneratedInclude = Join-Path $BuildRoot 'generated\launcher_profiles.generated.h'
$Python = (Get-Command python -ErrorAction Stop).Source
& $Python (Join-Path $SourceRoot 'generate-launcher-profiles.py') `
    --output $GeneratedInclude
if ($LASTEXITCODE -ne 0) { throw "Launcher profile generation failed: $LASTEXITCODE" }
& $CMakePath -S $SourceRoot -B $BuildRoot -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$NinjaPath" `
    "-DCMAKE_TOOLCHAIN_FILE=$Toolchain" `
    '-DANDROID_ABI=arm64-v8a' `
    '-DANDROID_PLATFORM=android-35' `
    '-DANDROID_STL=none' `
    "-DLAUNCHER_PROFILE_INCLUDE_DIR=$(Split-Path -Parent $GeneratedInclude)" `
    "-DCMAKE_BUILD_TYPE=$Configuration"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed: $LASTEXITCODE" }

& $CMakePath --build $BuildRoot --parallel
if ($LASTEXITCODE -ne 0) { throw "CMake build failed: $LASTEXITCODE" }

$Library = Join-Path $BuildRoot 'libmiui_home_hyos_zn.so'
if (-not (Test-Path -LiteralPath $Library -PathType Leaf)) {
    throw "Expected native library was not produced: $Library"
}

$Header = (& $ReadElf -h $Library) -join [Environment]::NewLine
if ($Header -notmatch 'Class:\s+ELF64' -or
        $Header -notmatch 'Machine:\s+AArch64') {
    throw 'Native output is not ELF64 AArch64.'
}

$Exports = @(& $Nm -D --defined-only --extern-only $Library |
    ForEach-Object {
        if ($_ -match '\s[A-Za-z]\s+(\S+?)(?:@@\S+)?$') { $Matches[1] }
    }) | Sort-Object -Unique
if (@(Compare-Object @('zn_module') $Exports).Count -ne 0) {
    throw "Unexpected exports: $($Exports -join ', ')"
}

$Notes = (& $ReadElf -n $Library) -join [Environment]::NewLine
if ($Notes -notmatch 'aarch64 feature: BTI, PAC') {
    throw 'Native output does not advertise BTI/PAC.'
}

$TailHook = (& $ObjDump `
    '--disassemble-symbols=MiuiHomeHyosBroadcastOptionsTailHook' `
    $Library) -join [Environment]::NewLine
if ($TailHook -notmatch '<MiuiHomeHyosBroadcastOptionsTailHook>:' -or
        $TailHook -notmatch '\bbti\s+c\b' -or
        $TailHook -notmatch '\bbr\s+x16\b' -or
        $TailHook -match '\b(?:bl|blr|ret)\b' -or
        $TailHook -match '\b(?:add|sub)\s+sp\b') {
    throw 'Private broadcast tail hook no longer preserves the raw call frame.'
}
$StackAccesses = @($TailHook -split "`r?`n" |
    Where-Object { $_ -match '\[(?:sp|wsp),' })
if ($StackAccesses.Count -ne 2 -or
        @($StackAccesses | Where-Object {
            $_ -notmatch '\[sp,\s*#0x58\]'
        }).Count -ne 0 -or
        @($StackAccesses | Where-Object { $_ -match '\bstr\b' }).Count -ne 1) {
    throw 'Private broadcast tail hook has an unexpected stack access.'
}

$PilferHook = (& $ObjDump `
    '--disassemble-symbols=MiuiHomeHyosInputMonitorPilferHook' `
    $Library) -join [Environment]::NewLine
if ($PilferHook -notmatch '<MiuiHomeHyosInputMonitorPilferHook>:' -or
        $PilferHook -notmatch '\bbti\s+c\b' -or
        $PilferHook -notmatch '\bmov\s+x1,\s*x30\b' -or
        $PilferHook -notmatch '\bb\s+0x[0-9a-f]+\s+<MiuiHomeHyosInputMonitorPilferImpl>' -or
        $PilferHook -match '\b(?:bl|blr|ret|paci|auti|xpac)\w*\b' -or
        $PilferHook -match '\b(?:add|sub)\s+sp\b') {
    throw 'InputMonitor pilfer hook no longer captures the raw caller LR as a tail shim.'
}

$Dynamic = (& $ReadElf -d $Library) -join [Environment]::NewLine
if ($Dynamic -match 'NEEDED.*(?:libc\+\+|libstdc\+\+)') {
    throw 'Native output has an unexpected shared C++ runtime dependency.'
}

$AppBuildGradle = Get-Content -LiteralPath (Join-Path $RepoRoot 'app\build.gradle') -Raw
$VersionMatches = [regex]::Matches(
    $AppBuildGradle, '(?m)^\s*versionName\s+"([^"]+)"\s*$')
if ($VersionMatches.Count -ne 1) {
    throw 'Unable to resolve one canonical app versionName from app/build.gradle.'
}
$Version = $VersionMatches[0].Groups[1].Value
$VersionCode = (& git -C $RepoRoot rev-list --count HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $VersionCode -notmatch '^\d+$') {
    throw 'Unable to derive the canonical versionCode from the Git commit count.'
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Stage = Join-Path $RepoRoot "out\miui-home-hyos-zn\package-$Stamp"
$StageLib = Join-Path $Stage 'lib\arm64'
$StageBin = Join-Path $Stage 'bin'
New-Item -ItemType Directory -Force -Path $StageLib, $StageBin | Out-Null
Copy-Item -LiteralPath $Library -Destination (Join-Path $StageLib 'libmiui_home_hyos_zn.so')

$CounterSpecs = [ordered]@{
    send_count = @('g_native_broadcast_send_count', 'u4')
    send_kind = @('g_native_broadcast_send_kind', 'u4')
    send_state = @('g_native_broadcast_send_state', 'u4')
    result_tag = @('g_native_broadcast_result_tag', 'u4')
    options_consumed = @('g_native_broadcast_options_consumed', 'u4')
    query_attempts = @('g_arbiter_query_attempts', 'u4')
    state_marked = @('g_arbiter_state_marked_count', 'u4')
    state_passthrough = @('g_arbiter_state_passthrough_count', 'u4')
    accepted_count = @('g_accepted_processor_down_count', 'u4')
    publish_count = @('g_accepted_processor_publish_count', 'u4')
    processor_suppressed = @('g_gesture_processor_suppressed_count', 'u4')
    processor_boundary_return = @('g_gesture_processor_boundary_return_count', 'u4')
    processor_entry = @('g_gesture_processor_entry_count', 'u4')
    inner_gesture_type_last = @('g_inner_gesture_type_last', 'u4')
    inner_gesture_type_1 = @('g_inner_gesture_type_1_count', 'u4')
    inner_gesture_type_2 = @('g_inner_gesture_type_2_count', 'u4')
    outer_down_post_type_last = @('g_outer_down_post_type_last', 'u4')
    outer_down_post_type_0 = @('g_outer_down_post_type_0_count', 'u4')
    outer_down_post_type_1 = @('g_outer_down_post_type_1_count', 'u4')
    outer_down_post_type_2 = @('g_outer_down_post_type_2_count', 'u4')
    outer_down_post_type_3 = @('g_outer_down_post_type_3_count', 'u4')
    ownership_enabled = @('g_enable_systemui_ownership', 'u4')
    stub_back_count = @('g_stub_back_handler_count', 'u4')
    stub_back_action_last = @('g_stub_back_action_last', 'u4')
    stub_back_down = @('g_stub_back_down_count', 'u4')
    stub_back_move = @('g_stub_back_move_count', 'u4')
    stub_back_up = @('g_stub_back_up_count', 'u4')
    stub_back_cancel = @('g_stub_back_cancel_count', 'u4')
    stub_back_edge_last = @('g_stub_back_edge_last', 'u4')
    pilfer_hook_count = @('g_pilfer_hook_count', 'u4')
    owned_pilfer_suppressed = @('g_owned_stream_pilfer_suppressed_count', 'u4')
    down_capture = @('g_motion_down_capture_count', 'u4')
    business_repair_attempts = @('g_business_repair_attempt_count', 'u4')
    business_repair_successes = @('g_business_repair_success_count', 'u4')
    business_repair_failures = @('g_business_repair_failure_count', 'u4')
    business_repair_stage = @('g_business_repair_stage', 'u4')
    bridge_state = @('g_arbiter_bridge_hook_state', 'u4')
    arbiter_ready = @('g_systemui_arbiter_ready', 'u4')
    business_state = @('g_business_hook_state', 'u4')
    generation = @('g_systemui_arbiter_generation', 'u8')
}
$AllSymbols = @(& $Nm -a -n $Library)
$CounterLines = foreach ($Entry in $CounterSpecs.GetEnumerator()) {
    $symbol = [regex]::Escape($Entry.Value[0])
    $match = @($AllSymbols | Where-Object { $_ -match "^([0-9a-fA-F]+)\s+\S\s+.*$symbol" })
    if ($match.Count -ne 1 -or $match[0] -notmatch '^([0-9a-fA-F]+)') {
        throw "Unable to resolve unique diagnostic counter: $($Entry.Key)"
    }
    "$($Entry.Key) 0x$($Matches[1]) $($Entry.Value[1])"
}
[IO.File]::WriteAllText(
    (Join-Path $Stage 'diagnostics.map'),
    ($CounterLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $SourceRoot 'README.md') -Destination $Stage
Copy-Item -LiteralPath (Join-Path $SourceRoot 'verify.sh') -Destination $Stage
Copy-Item -LiteralPath (Join-Path $SourceRoot 'uninstall.sh') -Destination $Stage
Copy-Item -LiteralPath (Join-Path $SourceRoot 'META-INF') -Destination $Stage -Recurse
Copy-Item -LiteralPath (Join-Path $SourceRoot 'bin\hsctl') -Destination $StageBin

$ModuleProp = Get-Content -Raw (Join-Path $SourceRoot 'module.prop.in')
$ModuleProp = $ModuleProp.Replace('@MODULE_ID@', 'miui-home-hyos-zn')
$ModuleProp = $ModuleProp.Replace('@MODULE_NAME@', 'MiuiHome hyos_spawner ZN Observer')
$ModuleProp = $ModuleProp.Replace('@VERSION_NAME@', $Version)
$ModuleProp = $ModuleProp.Replace('@VERSION_CODE@', $VersionCode)
[IO.File]::WriteAllText(
    (Join-Path $Stage 'module.prop'), $ModuleProp, [Text.UTF8Encoding]::new($false))

Copy-Item -LiteralPath (Join-Path $SourceRoot 'zn_modules.txt') -Destination $Stage
$Customize = Get-Content -Raw (Join-Path $SourceRoot 'customize.sh.in')
[IO.File]::WriteAllText(
    (Join-Path $Stage 'customize.sh'), $Customize, [Text.UTF8Encoding]::new($false))

$FilesToHash = @(Get-ChildItem -LiteralPath $Stage -Recurse -File)
foreach ($File in $FilesToHash) {
    $Digest = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        "$($File.FullName).sha256", $Digest, [Text.UTF8Encoding]::new($false))
}

$Zip = Join-Path $RepoRoot "out\packages\miui-home-hyos-zn-$Stamp.zip"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Zip) | Out-Null
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force

[pscustomobject]@{
    Library = $Library
    Sha256 = (Get-FileHash -LiteralPath $Library -Algorithm SHA256).Hash.ToLowerInvariant()
    Exports = ($Exports -join ', ')
    Injection = '/system_ext/bin/hyos_spawner'
    RuntimeGate = 'Zygisk Next module enabled state'
    Package = $Zip
    PackageSha256 = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Packaged = $true
    Installed = $false
}
