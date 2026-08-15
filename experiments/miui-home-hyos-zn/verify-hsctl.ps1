[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Paths = @{
    Cli = Join-Path $PSScriptRoot 'bin\hsctl'
    Deploy = Join-Path $PSScriptRoot 'safe-device-test.ps1'
    Native = Join-Path $PSScriptRoot 'zn_module.cpp'
    Readme = Join-Path $PSScriptRoot 'README.md'
    Customize = Join-Path $PSScriptRoot 'customize.sh.in'
    Uninstall = Join-Path $PSScriptRoot 'uninstall.sh'
}
foreach ($Path in $Paths.Values) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
}

$Text = @{}
foreach ($Entry in $Paths.GetEnumerator()) {
    $Text[$Entry.Key] = Get-Content -LiteralPath $Entry.Value -Raw
}

$RequiredCli = @(
    '#!/system/bin/sh',
    'activate --confirm',
    'rollback --confirm',
    'hsctl counters',
    'znmod enable "$MODULE_ID" svc',
    'znmod disable "$MODULE_ID" svc',
    'znmod reload "$MODULE_ID" svc',
    'kill -TERM "$old_pid"',
    'am start -W -a android.intent.action.MAIN',
    'mapped_module_pids',
    'timeout -k 1 1 "$ZNCTL" dump-zn -sa',
    'rollback_runtime activation-',
    'activation_state=ready-for-one-gesture'
)
foreach ($Needle in $RequiredCli) {
    if (-not $Text.Cli.Contains($Needle)) {
        throw "hsctl contract is missing: $Needle"
    }
}

$RequiredDeploy = @(
    "[ValidateSet('Status', 'Deploy', 'Rollback', 'Capture')]",
    "ExpectedVersionCode = '801024371'",
    'Get-FileHash -Algorithm SHA256',
    '.next-$ShortHash',
    'Get-ModuleMappedPids',
    'Show-HostStatus',
    'Stop-ExactSpawner',
    'Restore-CleanHome',
    'znmod disable',
    "Invoke-Hsctl -Command 'activate --confirm'",
    "Invoke-Hsctl -Command 'rollback --confirm'",
    'Get-LatestTombstone',
    'native-counters.txt',
    'crash-logcat.txt',
    'process-events.txt',
    'diagnostics.map',
    "Write-Evidence -Phase 'activated-before-gesture'"
)
foreach ($Needle in $RequiredDeploy) {
    if (-not $Text.Deploy.Contains($Needle)) {
        throw "safe deployment contract is missing: $Needle"
    }
}

$Forbidden = @(
    'set' + 'prop',
    '/system/bin/hsctl',
    'killall ',
    'am force-stop ',
    'reboot',
    'business-enable',
    'bridge-enable',
    'ENABLE_MARKER=',
    'ARBITER_BRIDGE_MARKER='
)
foreach ($Key in @('Cli', 'Deploy', 'Customize', 'Uninstall')) {
    foreach ($Needle in $Forbidden) {
        if ($Text[$Key].Contains($Needle)) {
            throw "$Key contains forbidden deployment behavior: $Needle"
        }
    }
}

if ($Text.Customize.Contains('$MODPATH/system')) {
    throw 'Installer must not create a system overlay.'
}
if ($Text.Native.Contains('__system_property')) {
    throw 'Native experiment must not read Android properties.'
}
if (-not $Text.Native.Contains('bool IsExplicitlyEnabled()') -or
        -not $Text.Native.Contains('bool IsArbiterBridgeEnabled()')) {
    throw 'Native ZN-state gate contract is missing.'
}
$minimalStart = $Text.Native.IndexOf('bool InstallClaimedBusinessHooks4371(')
$minimalEnd = $Text.Native.IndexOf('void ObserveLauncherHandle(', $minimalStart)
if ($minimalStart -lt 0 -or $minimalEnd -le $minimalStart) {
    throw 'Cannot isolate the 4371 business hook installer.'
}
$minimalInstaller = $Text.Native.Substring($minimalStart, $minimalEnd - $minimalStart)
foreach ($Needle in @(
        'HookBackCallbackQuery', 'HookBackSwipeStart', 'HookBackCancelled',
        'HookBackInvoke', 'HookInterruptOpenPoll',
        'MiuiHomeHyosAcceptedLogBoundaryHook')) {
    if ($minimalInstaller.Contains($Needle)) {
        throw "Minimal handoff installer contains an out-of-scope hook: $Needle"
    }
}
if (-not $minimalInstaller.Contains('HookGestureBackTouchProcessor') -or
        -not $minimalInstaller.Contains('HookGestureStubBackHandler') -or
        -not $minimalInstaller.Contains('TryInstallArbiterBridge')) {
    throw 'Minimal handoff installer is missing its side boundary, diagnostics, or bridge.'
}
foreach ($Needle in @(
        'void RepairBusinessHooksIfRemapped(',
        'outer_original != inner_original',
        'outer_original != stub_back_handler_original',
        'kGestureStubPointerHandlerPrologue4371',
        'kGestureBackTouchProcessorPrologue4371',
        'kGestureStubBackHandlerPrologue4371',
        'g_api.inlineUnhook(',
        'g_business_repair_success_count')) {
    if (-not $minimalInstaller.Contains($Needle)) {
        throw "Launcher remap repair contract is missing: $Needle"
    }
}
foreach ($Needle in @(
        'kGestureStubBackHandlerOffset4371',
        'g_pending_down.edge != stub_edge',
        'CurrentEventMatchesOwnedStream(event)',
        'published GestureStubView accepted Back DOWN',
        'preventing only GestureInputBackHelper::on_touch_event')) {
    if (-not $Text.Native.Contains($Needle)) {
        throw "GestureStubView Back-only handoff contract is missing: $Needle"
    }
}
if ($Text.Native.Contains('gesture_type == kGestureTypeBack4371') -or
        $Text.Native.Contains('published classified Back DOWN at processor boundary')) {
    throw 'Shared GestureInputMonitor still owns the retired classified handoff.'
}
if ($Text.Native.Contains('published accepted DOWN at processor boundary')) {
    throw 'Shared GestureInputMonitor outer still publishes an unclassified DOWN.'
}
if (-not $Text.Readme.Contains('[safe-device-test.ps1](safe-device-test.ps1)') -or
        -not $Text.Readme.Contains('exactly one formal side gesture') -or
        -not $Text.Readme.Contains('readiness warmup')) {
    throw 'README does not document the only approved deployment/test flow.'
}

[pscustomobject]@{
    Controller = $Paths.Cli
    HostDeployment = $Paths.Deploy
    Commands = 'status, activate --confirm, rollback --confirm, counters, logs, help'
    RuntimeGate = 'Zygisk Next module enabled state'
    Result = 'PASS'
}
