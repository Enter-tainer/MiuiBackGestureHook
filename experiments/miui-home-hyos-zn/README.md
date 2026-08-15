# MiuiHome `hyos_spawner` Zygisk Next experiment

This is a minimal, default-off Zygisk Next service module for the Android 17
HyperOS native launcher runtime.

It targets only:

```text
/system_ext/bin/hyos_spawner
```

The first revision is an observation probe. When explicitly enabled, it:

1. verifies the exact `hyos_spawner` GNU Build ID;
2. hooks only the `dlopen` and `dlsym` PLT entries owned by that executable;
3. after the exact `libhyper_os_shell.so` load, hooks only that caller's
   `android_dlopen_ext` and `dlsym` PLT slots;
4. recognizes the stable MiuiHome process identity and terminal launcher
   library name while allowing randomized `/data/app` install directories;
5. records when the matching handle resolves `app_entry_point`;
6. always returns the original loader results unchanged.

It does not hook the system linker globally, alter MiuiHome behavior, start a
thread, connect a companion, retain a cross-fork file descriptor, or install
an inline hook in `libapp_launcher.so`. A fixed-size in-memory filename ring is
used only by this observation build to identify the stable loader argument;
it performs no allocation or file write.

The confirmed ownership chain is:

```text
hyos_spawner
  dlopen("libhyper_os_shell.so")
  dlsym(handle, "launch_main_thread")
    -> libhyper_os_shell.so
         android_dlopen_ext(...)
         dlsym(...)
           -> APK libapp_launcher.so / app_entry_point
```

The final launcher identity is captured at the exact
`libhyper_os_app_public.so` caller-oriented `dlsym("app_entry_point")`
boundary. The incoming handle is retained only for observation. This avoids
depending on the APK code path, randomized install token, native library hash,
or the private Rust `dlopen_ext` wrapper signature.

## Confirmed target identities

```text
hyos_spawner path:
  /system_ext/bin/hyos_spawner

hyos_spawner GNU Build ID:
  87f2632e7d68fda0226366fda5346c2d

hyos_spawner SHA-256 (supporting evidence):
  d2eaaf55ac1f35540dc639af9d87ecdb32e524b637efdf843bed1ee4a7951be5

MiuiHome process identity:
  /proc/self/cmdline == com.miui.home

accepted native entry containers:
  /data/app/.../base.apk!/lib/arm64-v8a/libapp_launcher.so
  /product/priv-app/MiuiHome/MiuiHome.apk!/lib/arm64-v8a/libapp_launcher.so

libapp_launcher.so SHA-256 (supporting evidence):
  a84365f864f88f85165b086bc03ba563efd09386c72f0c21926788fd90a028f9

entry symbol:
  app_entry_point (ELF value 0x885d00, size 1712)
```

`libapp_launcher.so` has no GNU Build ID in the investigated APK. A future
revision that modifies launcher execution must validate its complete identity
(for example the APK/library digest plus symbol layout) before using an offset.
The loader matcher deliberately does not bind to a `/data/app` random token,
APK container path, launcher version, or library digest. The investigated `4371`
library exports `app_entry_point` at ELF value `0x885d00` with size 1712; the
loader probe still uses the symbol name rather than that offset.

The optional business observer is intentionally narrower. It supports only the
investigated `4371` library and validates the entry offset plus four independent
32-byte function prologues before installing any business hook. It observes, but
does not alter, the OPEN-break callback result and the back start/cancel/invoke
boundaries. A mismatch fails closed.

## Runtime gate and bridge lease

The Zygisk Next enabled state of `miui-home-hyos-zn` is the sole runtime gate.
`hyos_spawner` and MiuiHome cannot read module-directory marker files under their
SELinux domains, so marker-based controls are forbidden. The exact 4371 business
hooks and SystemUI input-arbiter bridge are compiled in when the ZN module is
enabled. The rejected native-receiver experiment remains compile-time disabled.

The private-broadcast bridge's first implementation reached the intended 4371 boundary
but caused repeated Scudo `invalid chunk state when deallocating` aborts. Static
instruction-level analysis isolated the fault: the private
`broadcastIntentWithFeature` writes a 16-byte Rust Result through hidden `x8`,
while the rejected C++ hook returned the public wrapper's 48-byte `NativeResult`.
The direct caller reserves only 16 bytes, so the hook overwrote the following 32
bytes of its frame. Runtime state `198` means the current explicit attempt was
already consumed and the replacement process performed no bridge mutation;
`199` is retained for builds where the implementation is compile-time disabled.

It reuses MiuiHome's existing `com.android.systemui.fsgesture` dynamic receiver,
accepts only module-tagged arbiter state after shared-caller UID/package
validation, and adds the platform share-identity BroadcastOptions flag only to
the module's own outbound accepted-DOWN/query intents. It does not register a
receiver or alter MiuiHome's native receiver filter. A tagged state intent is
observed but still passed unchanged to Xiaomi's original receiver callback;
that callback owns launcher-side FSG-region refresh and must not be consumed by
the module. The replacement is a raw
AArch64 tail-call shim: it preserves the original `x8`, `x0-x8`, and stack
pointer, conditionally changes only the 4371 caller's options slot at `sp+0x58`,
then branches directly to the original Rust method. A thread-scoped arm keeps
unrelated and nested broadcasts out. Local disassembly confirms that the shim
has `bti c`, no frame, call, or return instruction, and only the intended stack
write.

Bridge installation is process-local. The atomic installation state prevents
duplicate mutation inside one process, while the exact Launcher process,
library Build ID, resolved address, untouched GOT value, and code fingerprints
remain fail-closed guards. A Launcher replacement forked by the same injected
spawner installs a fresh bridge instead of being rejected by stale filesystem
state. A failed controlled activation still enters `rollback`.

The 0.8.3 single-attempt device run proved the tail shim reached SystemUI's
reply, then caught a separate ownership bug in the receiver hook. Exact 4371
`Intent_get_action` and `Intent_get_sender_package_name` return a 24-byte
borrowed `{tag, data, length}` view into the Intent; they do not allocate an
owned `RString`. The rejected code called `free(data)` and its tombstone points
directly to that call. 0.8.4 models these getters with a distinct
`BorrowedROptionRString` and never frees their data. Owned strings constructed
for Intent setters remain on the separate 40-byte `ROptionRString` path.

Because the exported private trait shim is too short for a ZN inline hook and
ZN also rejects the library's self-referencing PLT relocation, the bridge
validates the private library Build ID, verifies the slot still points to the
exact resolved symbol, then atomically replaces only its existing
`R_AARCH64_JUMP_SLOT` at `0x14ed0`. The RELRO page is writable only for that
checked swap and is restored read-only immediately; no executable page is
changed.

The rejected receiver-filter/receiver-ABI experiments are not exposed through
`hsctl`. Repeated MiuiHome native crashes can replace the normal Launcher with
`SafeLauncher`, invalidating input observations. Do not restore those modes.

`hyos_spawner` is a critical Rust-app process factory. Live deployment and
runtime verification must use [safe-device-test.ps1](safe-device-test.ps1); the
build script never restarts it.

## Build

```powershell
.\experiments\miui-home-hyos-zn\build.ps1
```

The output is written under:

```text
out/miui-home-hyos-zn/<Configuration>/libmiui_home_hyos_zn.so
```

The build verifies ELF64/AArch64, BTI/PAC, and that `zn_module` is the only
export. It creates a package but does not install it, reload Zygisk Next, or
restart a process.

## `hsctl`

The root control script is [bin/hsctl](bin/hsctl). Its interface is:

```text
hsctl status
hsctl activate --confirm
hsctl rollback --confirm
hsctl counters
hsctl logs [count]
hsctl help
```

`status` reports ZN module state, the exact root/PPID-1 `hyos_spawner`, the
MiuiHome PID/parent, all module mappings, and the matching ZN service state.
`counters` reads only the build-generated `diagnostics.map` offsets from the
current Launcher mapping and records the bounded native handoff state; it does
not change runtime state.

Zygisk Next 1.4.5 counts an intentional `hyos_spawner` stop as a service death.
After three such deaths its per-service fuse becomes `can_load=false`, even
though a reload request may print success. `activate` checks that budget before
touching the process, enables/reloads only this ZN module, terminates only the
exact root `hyos_spawner`, verifies the replacement injection, explicitly starts
the normal Home Activity, and verifies that Launcher maps the active module. Any
failure immediately enters `rollback`.

`rollback` disables only this ZN module, replaces only the exact root spawner,
explicitly starts Home, and verifies that no process maps the module. It does
not clear RescueParty state, clear application data, reinstall MiuiHome, or
reboot Android. If Launcher has actually entered persistent SafeLauncher, stop
and ask the operator to reinstall exact approved 4371 once.

The controller remains module-local at
`/data/adb/modules/miui-home-hyos-zn/bin/hsctl`. The package does not create a
`/system/bin` overlay.

## Safe deployment and test capture

All live updates must use the repository host script:

```powershell
.\experiments\miui-home-hyos-zn\safe-device-test.ps1 -Action Deploy -Serial <adb-serial> -PackageZip <module.zip> -Confirm4371
```

It verifies exact MiuiHome 4371, expands and checks one ZIP, stages every file at
a distinct path, verifies the staged native SHA-256, disables the ZN module,
replaces the exact spawner whenever an old mapping exists, proves no old module
mapping remains, and only then atomically renames the staged ELF into place. It activates through `hsctl`,
checks for a new tombstone, records pre-gesture evidence, and rolls back on any
failed invariant. Direct package installation, hand-written reload sequences,
and in-place copying over the active library are not valid test procedures.

After activation, perform exactly one formal side gesture and capture evidence.
If the build reports no arbiter generation until MiuiHome first enters its
processor, label one earlier gesture as a readiness warmup and capture it
separately; the warmup is never handoff evidence:

```powershell
.\experiments\miui-home-hyos-zn\safe-device-test.ps1 -Action Capture -Serial <adb-serial>
```

The test succeeds only when one session contains the native accepted-DOWN
publication, SystemUI's matching acceptance/pilfer, and Shell navigation start.
Gesture appearance alone is not evidence of ownership.

0.8.5 keeps the first shared-identity arbiter query at bridge installation and
permits exactly one retry at the next native `swipe_start` boundary if no
authenticated SystemUI generation has arrived. The current retrying stream
stays on Xiaomi's native path. Exported-in-BSS diagnostic counters record the
send kind, terminal stage, native result tag, options-consumption result, and
query-attempt count so a lost startup log does not erase the failure boundary.

0.8.6 moves ordinary-back acceptance to launcher 4371's exact
`GestureInputMonitor -> input_InputMonitor_pilferPointers` callsite. The shared
PLT import is filtered by its immutable return PC so overview, dock, and other
input monitors stay native. After a matching identity token is published, the
module leaves pilfering to SystemUI's existing spy monitor and suppresses only
the paired native back-touch processor for that thread-local stream. Xiaomi's
OPEN-interruption callbacks remain separate.

0.8.7 also moves the one permitted startup-query retry to that same proven
ordinary-back boundary. The retrying stream remains completely Xiaomi-native;
only a later new stream may publish accepted-DOWN.

0.8.8 removes the remaining ownership transfer from Xiaomi's native
`BackSwipeStart` callback. Device traces proved that callback belongs to the
launcher OPEN-interruption path and can run before the ordinary input monitor
pilfers. Publishing there cleared the captured DOWN too early and raced
SystemUI's pending spy stream. It now stays fully Xiaomi-native; the exact
4371 ordinary `pilferPointers` return PC is the sole accepted-DOWN publisher
and the sole point allowed to suppress the paired native touch processor.

0.8.9 captures that return PC in a BTI-only AArch64 tail shim before the C++
PAC prologue can sign `x30`. The build rejects any shim that gains a frame,
call, return, PAC instruction, or a path other than `x1 = x30` followed by the
tail branch. BSS counters retain the total hook count and latest raw/relative
return address for device verification.

0.8.10 hooks the resolved `input_InputMonitor_pilferPointers` implementation
instead of one launcher image's PLT relocation. HyperOS 4371 can execute the
ordinary gesture monitor from another private loader image even while the
first image's GOT is patched. Every call remains transparent; ownership is
allowed only when the raw caller LR is surrounded by the exact 16-byte 4371
ordinary-back instruction fingerprint.

0.8.11 treats every private-loader `app_entry_point` result as a distinct
launcher image. It installs slot-bound Action/ActionMasked/pilfer PLT hooks for
each validated 4371 base. MotionEvent capture calls the original belonging to
that slot, while the raw pilfer LR selects the same slot for transparent
fallback. No original function or input identity crosses loader instances.

0.8.12 corrects the ordinary-boundary hypothesis. Static relocation and
format-table reconstruction proves the runtime message `back gesture detected,
pilfer_pointers` returns from the shared Rust formatter at launcher offset
`0xbf4bc8`; it is not evidence that the direct PLT call at `0xbf07b0` ran. A
raw AArch64 tail probe now counts only that exact immutable formatter caller,
then branches to the untouched formatter trampoline. This revision is
observation-only at the corrected boundary: it does not publish accepted-DOWN
or suppress Xiaomi's processor.

0.8.13 records the owner of each native `InputMonitor.pilferPointers()` call
without altering delivery. Device evidence from 0.8.12 showed that a tested
return gesture called `libapp_launcher + 0xc11a78` twice, while neither the old
`0xbf07b0` candidate nor the `0xbf3684` processor ran. Static analysis places
`0xc11a78` inside `gesture_input_home_helper.rs`, so it is not yet accepted as
the ordinary-back boundary. The bounded observation ring captures its caller,
monitor, thread, most recent MotionEvent action, and pending DOWN identity to
separate a shared edge arbiter from Home/Recents-only traffic before any input
takeover is enabled.

0.8.14 uses the resulting paired trace. One physical stream first reached
`0xbf07b0` on `ACTION_DOWN`, then `0xc11a78` on `ACTION_MOVE`, with the same
MotionEvent ID, down time, device, source, thread, and InputMonitor. The first
caller is therefore retained as the authenticated accepted-DOWN boundary. On
a successful SystemUI publication the module freezes that complete identity;
only a later pilfer from the same monitor and exact stream is suppressed. A
repeated getter call for the same DOWN cannot clear ownership, while a genuinely
new DOWN invalidates it. Missing identity data, a different monitor, or any
publication failure remains fully Xiaomi-native.

0.8.15 removes Android-property control completely. Native gates now read only
module-local marker files, installation removes the staged markers, and
`hsctl` creates/removes only those exact files. Reload and refresh resolve the
real `/system_ext/bin/hyos_spawner` PID, check the existing Zygisk Next restart
budget, then use `SIGTERM` and let init restart the service. Recovery likewise
does not mutate RescueParty or any other property.

0.8.16 corrects the marker-gate assumption. Device BSS showed a cleanly
injected 0.8.15 launcher with every gate and hook state still zero: the
hyos_spawner/MiuiHome SELinux domains cannot `access()` the module directory,
although Zygisk Next can inject an already-open module FD. The Zygisk Next
module enabled state is now the sole runtime gate. The validated 4371 business
and identity bridge are compiled in whenever that module is enabled; the
rejected native-receiver experiment is permanently disabled. Android
properties remain unused.

0.8.18 is the first constrained handoff package. It does not install the
OPEN-interruption, callback-query, swipe-start, cancel, invoke, or Rust log
formatter observation hooks. The only launcher business inline hook is the
exact 4371 `GesturesBackTouchProcessor` boundary, and it suppresses Xiaomi only
after a successfully published accepted-DOWN. MotionEvent identity and the
exact `0xbf07b0` pilfer remain PLT hooks, and the authenticated broadcast bridge
remains the only transport to SystemUI. Publication failure always calls the
original Xiaomi pilfer and processor path.

0.8.19 keeps that exact hook surface and moves no ownership boundary. Device
BSS from the first 0.8.18 gesture proved bridge installation succeeded but its
startup query ran before launcher Runtime state became ready (`send_state=2`,
generation zero). After the already-required processor original returns, the
module now permits the existing bounded query helper's sole second attempt.
That current stream remains Xiaomi-native; only a later new DOWN may publish an
accepted token.

0.8.20 preserves the same hook surface and changes only the Android 17 state
carrier consumption rule. 4371 registers its protected one-action
`com.android.systemui.fsgesture` receiver at `libapp_launcher + 0xbda130`.
0.8.19 observed a valid reply and returned before Xiaomi's callback; subsequent
Settings gestures were redirected before `GesturesBackTouchProcessor`, while a
clean rollback immediately restored navigation. 0.8.20 authenticates and
records the module extras, then invokes the original receiver with the exact
unchanged intent. `state_marked` and `state_passthrough` counters must advance
together before any formal takeover result is accepted.

0.8.21 corrects the accepted-input boundary using the 0.8.20 formal device
trace and exact 4371 disassembly. With `GestureStubView` still the physical
DOWN owner, the tested Settings stream entered
`GesturesBackTouchProcessor` 55 times without calling either launcher
`InputMonitor.pilferPointers` site. At `libapp_launcher + 0xbf3684`, argument
`x1` is the `MotionEvent` and the native body first reads
`getActionMasked()` at `+0xbf3784`. A redirected or excluded stream never
reaches this function, so only its real `ACTION_DOWN` now publishes the frozen
accepted identity. Publication success suppresses the processor only for that
authenticated pointer stream through its terminal action. `eventId` is used
only to authenticate the exact DOWN: Android assigns a new ID to each later
MOVE/UP/CANCEL `MotionEvent`, while `downTime`/device/source identify stream
continuity. The pilfer PLT hook remains
transparent observation and may suppress only a later call already proven to
belong to that owned stream; it no longer publishes or retries readiness.

0.8.22 removes the obsolete process-independent bridge lease. The first
0.8.21 formal handoff matched the accepted token, pilfered in SystemUI, and
started Shell, then MiuiHome was normally replaced without a native tombstone.
The replacement inherited the injected module but was permanently rejected by
the stale cache lease (`bridge_state=4`). Bridge installation is now once per
Launcher process, guarded by its process-local atomic state and the existing
exact process/build/address/GOT/code validation. Normal Launcher replacement
can therefore re-register the bridge without widening module scope.

The approved capture flow also writes the bounded Android crash buffer and
filtered process lifecycle events to `crash-logcat.txt` and
`process-events.txt`. A Launcher restart without a native tombstone is no
longer diagnosed from PID changes alone.

0.8.23 tested the stream-continuity bug exposed by the first working Android 17
panel test. 0.8.22 compared every later event's `getId()` with the DOWN ID, so
it suppressed only DOWN and then re-entered Xiaomi's processor at MOVE without
the state initialization that DOWN normally performs. The resulting invalid
native state eventually blocked MiuiHome's `[Gesture Monitor] swipe-up` input
channel and produced a 5-second input-dispatch ANR. The processor caller ignores
the function return value, so this is not a return-ABI issue. 0.8.23 kept exact
event-ID matching for the cross-process accepted-DOWN token, but follows the
owned native stream by unchanged `downTime`, device, and source until
UP/CANCEL.

That test exposed a deeper ownership rule: `+0xbf3684` receives an x2 Rust
borrow acquired by its caller and releases it only in the unified tail at
`+0xbf52f0`. Returning from the whole function leaks that borrow. A cancelled
AOSP gesture then ANR'd the exact `GestureStubRight` input channel five seconds
after DOWN; commit merely made the launcher replacement more visible. 0.8.24
therefore always runs `+0xbf3684` to completion. It hooks only its private
business dispatcher at `+0xc0fe28`, which has exactly four callsites and all
return into the outer cleanup path. Exact owned events return at this inner
boundary; unowned events call Xiaomi unchanged. Both entrypoints have immutable
4371 prologue fingerprints, and the transparent inner hook is installed before
the ownership-publishing outer hook.

0.8.25 repairs a later Launcher-generation fault without changing that input
boundary. On the observed 4371 spawner lifecycle, the final Launcher child can
remap the APK-backed `libapp_launcher` text after the module has already saved
`business_state=3` and two inline-hook trampolines. The PLT MotionEvent hooks
remain live, but both target entries contain their original prologues again;
the stale installed state then prevents normal reinstallation. A surviving
MotionEvent PLT hook now recognizes only the exact two-prologue loss, claims a
single repair, and reinstalls the inner hook before the outer hook. The stream
that discovers the remap remains Xiaomi-native because the outer handler may
already be on its stack. A one-sided or non-4371 code shape fails closed.
`business_repair_attempts`, `business_repair_successes`, and
`business_repair_failures` make this lifecycle visible to the standard capture
script.

The first 0.8.25 device run proved that restoring the target text does not
remove Zygisk Next's stale inline-hook registrations: a second `inlineHook`
was rejected while both exact entrypoints still contained their original
4371 prologues. 0.8.26 first unregisters both stale targets through the Zygisk
Next `inlineUnhook` API, requires both unregister operations to succeed, and
then reinstalls inner before outer. It never writes mapped executable text
directly. `business_repair_stage` records detection (1), stale-registration
removal (2), success (3), unregister failure (4), reinstall failure (5), or
an inconsistent one-sided code shape (6).

0.8.27 corrects the ownership boundary after a raw-input trace proved that
`+0xbf3684` is the shared `GestureInputMonitor` dispatcher, not a side-only
GestureStub entry. It receives bottom Home streams too; claiming every DOWN
there caused a center-bottom `(566, 2607)` stream to be published as a false
right-edge token and made every later Home MOVE skip Xiaomi's dispatcher.
The outer hook now captures identity and always runs native cleanup. The inner
`+0xc0fe28` dispatcher exposes Xiaomi's already-classified gesture type at
`x0+0x130` (`1=Home`; type 2 is not yet proven to be the ordinary side Back
accepted path): only an independently proven Back DOWN may publish ownership and
only exact Back events can be suppressed. Home and unknown types remain fully
native. This same classified boundary prevents the repaired remap generation
from leaking Xiaomi's arrow before SystemUI ownership.

0.8.28 tested the tentative reversed mapping but was immediately rolled back.
The first separated bottom gesture produced eleven exact type-1 inner entries;
it remained functional only because that stream was the readiness warmup and
therefore published no ownership. This proves type 1 is Home and disproves the
reversed mapping before a second bottom stream could be harmed. Read-only
counters retain the last inner type and the number of type-1/type-2 entries,
but the side accepted boundary must be found elsewhere in the outer dispatcher.

0.8.29 locked runtime ownership to zero and added an outer post-DOWN state
counter. Separated tests showed Home returning from the shared outer dispatcher
as type 1, while side Back returned as type 0 and never entered the inner
type-1/type-2 business path. Because that type 0 may already be a reset value,
it is evidence against the inner hook point, not an accepted-side classifier.
0.8.30 transparently tested the suspected `+0xc12e38` helper; neither Home nor
side Back called it, so it was removed rather than retained as another hook.

0.8.31 instead observes the exact `+0xc12504` DOWN-time region classifier. It
calls the original first and then reads `processor+0x130`, before the enclosing
outer dispatcher can reset the field. The build exports only per-type read-only
counters, keeps `ownership_enabled=0`, and neither publishes an accepted token
nor suppresses Xiaomi gesture handling. Its third inline target replaces the
disproved helper, so the remap repair remains an all-or-nothing three-hook
lifecycle.

Separated 0.8.31 evidence showed side Back returning from `init_gesture_type`
as type 0, a value also used by ordinary non-gesture touches. Static symbol and
xref analysis then identified the independent physical side path:

```text
UiWindow::on_window_motion_event
  -> GestureStubViewWindow::handle_back_gesture (+0xc6e954)
       -> GestureInputBackHelper::on_touch_event (+0xc073e0)
```

0.8.32 replaced the region classifier with a transparent probe at that exact
`handle_back_gesture` entry. One cancelled side stream produced one DOWN, 103
MOVE events, and one UP with a stable edge, while a complete bottom Home stream
left every new counter unchanged. This proves the entry is side-only and owns
the complete Xiaomi BackHelper stream.

0.8.33 enables ownership only at that proven entry. It recaptures the immutable
DOWN identity, requires the GestureStub edge to match the coordinate-derived
edge, and preserves a Xiaomi-native readiness warmup. A successful explicit
accepted-token broadcast freezes the current generation and suppresses only
the same physical stream before `GestureInputBackHelper::on_touch_event`; it
returns to the existing `UiWindow` caller so native event cleanup remains
intact. The shared `GestureInputMonitor::trigger_gesture` hook is now strictly
diagnostic and always calls Xiaomi. Replacement input and terminal UP/CANCEL
invalidate ownership. Missing readiness, identity mismatch, edge mismatch, or
publication failure leaves Xiaomi unchanged.

## Fork boundary

Zygisk Next loads this module into the `hyos_spawner` service process. Its code
and already-installed PLT hooks are then inherited by forked Rust-app children.
`onModuleLoaded()` is not assumed to run again in each child, and parent
threads/companion state are not assumed to survive fork. This is why the probe
uses no worker or companion connection.
