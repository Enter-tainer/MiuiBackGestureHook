# MIUI SystemUI Back Gesture Hook

LSPosed module using modern Xposed API 102 for SystemUI-side MIUI back gesture research.

## Build

```powershell
.\gradlew.bat assembleDebug
```

The debug APK is generated at:

```text
app/build/outputs/apk/debug/app-debug.apk
```

## AOSP References

Checked-in AOSP reference snippets live under:

```text
refs/android16/aosp_back_16/
```

The directory is split by component:

```text
refs/android16/aosp_back_16/shell/
refs/android16/aosp_back_16/systemui/
```

Xiaomi APKs, JARs, native libraries, decompilation, and device evidence remain local-only
under ignored `refs/android17` paths and must not be committed. See `refs/README.md`.

The native `hyos_spawner` research module source and safe deployment tooling live under:

```text
experiments/miui-home-hyos-zn/
```

## Scope

The static scope is declared in:

```text
app/src/main/resources/META-INF/xposed/scope.list
```

Current scopes:

```text
com.android.systemui
com.miui.home
system
```

## Compatibility

The Android 17 native MiuiHome integration targets Xiaomi System Launcher build `4371` only.

## Hot Reload

API 102 hot reload is enabled through:

```text
autoHotReload=true
```

The module implements `onHotReloading(...)` and `onHotReloaded(...)`.

## Entry

The module entry is:

```text
dev.codex.miuibackgesturehook.MiuiBackGestureHook
```

Registered through:

```text
app/src/main/resources/META-INF/xposed/java_init.list
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
