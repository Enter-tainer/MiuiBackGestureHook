# Android 17 小米桌面 Native 加载链调查报告

## 1. 调查目标

确认 Android 17 / HyperOS 4 中纯 Native 版 `com.miui.home` 的进程由谁创建、入口库由谁装载，以及它是否经过传统 ART zygote、Android 17 `zygote_next` 或小米自有加载器。

调查日期：2026-08-14
设备：Xiaomi `popsicle`
系统：Android 17（SDK 37）
系统版本：`OS4.0.0.20.XPBCNXM`
初始桌面版本：`RELEASE-8.01.02.4349-260727-08072050-R`
当前唯一目标版本：`RELEASE-8.01.02.4371-260727-08131546-R`

分析 APK：

```text
D:\code\jadx\系统桌面_RELEASE-8.01.02.4349-260727-08072050-R.apk
```

## 2. 结论

Android 17 的该版小米桌面由小米 HyperOS Rust Runtime 的 `/system_ext/bin/hyos_spawner` 创建并装载，不经过传统的 ART `app_process64` zygote 应用启动路径，也没有使用设备上并行存在的 Android 17 `zygote_next --species android-native-app`。

完整分流链为：

```text
PackageManager 解析 MiuiHome Manifest
  -> RustPackageInfoUtilsImpl.setPackageExt()
  -> 将包标记为 Rust Package
  -> 激活 rust.runtime_active=1
  -> ActivityManager/ProcessList.startProcess()
  -> RustProcessManagerImpl.startProcess()
  -> RustProcessImpl 连接 reserved socket "hyos_spawner"
  -> /system_ext/bin/hyos_spawner 的 USAP 式进程池 fork
  -> 从 APK ZIP 直接映射并装载 libapp_launcher.so
  -> 子进程改名为 com.miui.home
```

因此，从架构意义上说，MiuiHome 仍由一个具有 zygote/USAP 语义的进程池 fork，但这个进程池是小米的 `hyos_spawner`，不是 ART zygote。这正是传统 LSPosed Java 注入未进入该进程的主要原因。

## 3. APK 静态证据

### 3.1 APK 不含 Java/Dex 代码

APK 共 931 个 ZIP 条目，没有 `classes.dex`。主要 Native 库包括：

```text
lib/arm64-v8a/libapp.so                 27,552,488 bytes
lib/arm64-v8a/libapp_launcher.so        21,173,824 bytes
lib/arm64-v8a/libnative_widget_sdk.so    2,514,984 bytes
lib/arm64-v8a/libresources_frb.so        1,777,072 bytes
```

Manifest 的 `application` 明确声明：

```xml
<application
    android:hasCode="false"
    android:extractNativeLibs="false"
    ...>

    <meta-data
        android:name="hyperos_package"
        android:value="true" />

    <meta-data
        android:name="hyperos_app_lib_name"
        android:value="libapp_launcher.so" />
</application>
```

其中：

- `android:hasCode="false"` 表示系统不应按普通 APK 的 Dex/ClassLoader 路径寻找应用代码。
- `hyperos_package=true` 是 HyperOS Rust Package 的选择标记。
- `hyperos_app_lib_name=libapp_launcher.so` 指定 Native 应用入口库。
- `android:extractNativeLibs="false"` 使入口库能够直接从 APK ZIP 路径映射，而不是先解压到 `nativeLibraryDir`。

### 3.2 Native 实现形态

`libapp_launcher.so` 中存在大量 Rust、Flutter 和 `flutter_rust_bridge` 符号/字符串，例如：

```text
flutter_rust_bridge
Flutter framework
package:hyper_launcher_ui/main.dart
com.rust.hyper_launcher.recents.TouchInteractionService
```

这表明桌面业务主体采用 Rust 与 Flutter/Dart 组合，并通过 HyperOS 自有 Native Android 桥接层访问 Activity、Window、Binder、资源及系统服务。

Manifest 中仍保留诸如 `com.miui.home.launcher.Launcher` 的组件名，但这些名称不能再解释为 APK Dex 中可由 `PathClassLoader` 加载的 Java 类；APK 本身没有 Dex。它们由 HyperOS Native component/runtime 桥接层承接。

## 4. Framework / system_server 分流链

以下类来自设备的系统框架 JADX 工作区。

### 4.1 包解析：`RustPackageInfoUtilsImpl`

类：

```text
com.android.server.pm.RustPackageInfoUtilsImpl
```

核心方法：

```java
public void setPackageExt(ParsedPackage parsedPackage) {
    Bundle metaData = parsedPackage.getMetaData();
    if (metaData != null) {
        boolean isRustPackage = metaData.getBoolean("hyperos_package", false);
        parsedPackage.setRustPackage(isRustPackage);
        if (isRustPackage) {
            parsedPackage
                .setRustApplicationEntry(
                    metaData.getString("hyperos_application_entry", ""))
                .setRustAppLibName(
                    metaData.getString("hyperos_app_lib_name", "libapp.dylib.so"));
            RustProcessManagerImpl.activeRustRuntime();
        }
    }
}
```

该类负责把 Manifest 元数据写入 `ParsedPackage`，并调用 `activeRustRuntime()` 激活运行时。

它还在应用扩展私有标志中使用 `0x08000000` 表示 Rust Package：

```java
return flag(pkg.isRustPackage(), 134217728) | pkgWithoutStateFlags;
```

### 4.2 ApplicationInfo 构造：`RustPackageImpl`

类：

```text
com.android.internal.pm.parsing.pkg.RustPackageImpl
```

`updateApplicationInfo()` 再次读取相同元数据，设置：

```text
ApplicationInfo.rustApplicationEntry
ApplicationInfo.rustAppLibName
ApplicationInfo.privateFlagsExt |= 0x08000000
```

若系统启用了 Rust 应用签名验证且验证失败，它会禁用应用并清空进程名、类名和 Native 库目录。

### 4.3 AMS 初始化：`RustProcessManagerImpl`

类：

```text
com.android.server.am.RustProcessManagerImpl
```

`ActivityManagerService` 构造时在 `Flags.enableRustRuntime()` 为真时执行：

```java
RustProcessManagerStub.getInstance().init(this, this.mUiContext);
```

`RustProcessManagerImpl.init()` 创建 `android.os.RustProcessImpl`。允许 Rust Runtime 的条件是：

```java
Flags.enableRustRuntime()
    && app.info != null
    && app.info.isRustPackage()
    && SystemProperties.get("rust.runtime_active").equals("1")
```

### 4.4 关键分流点：`ProcessList.startProcess()`

类：

```text
com.android.server.am.ProcessList
```

Rust 分支位于 WebView zygote/AppZygote 处理之后、普通 `Process.start()` 之前：

```java
if (hostingRecord.usesWebviewZygote()) {
    // WebView zygote
} else if (hostingRecord.usesAppZygote()) {
    // AppZygote
} else if (RustProcessManagerStub.getInstance().allowRustRuntime(app)) {
    result = RustProcessManagerStub.getInstance().startProcess(...);
} else {
    result = Process.start(...); // 传统 zygote 路径
}
```

这证明“谁来决定使用自有加载器”的答案是 `system_server` 中的 `ProcessList` 与 `RustProcessManagerImpl`。

### 4.5 入口库路径构造

`RustProcessManagerImpl.obtainSuitableLibPath()` 根据 `extractNativeLibs`、`sourceDir` 和 ABI 生成入口路径。

MiuiHome 的实际条件为：

```text
extractNativeLibs=false
sourceDir=/product/priv-app/MiuiHome/MiuiHome.apk
ABI=arm64-v8a
rustAppLibName=libapp_launcher.so
```

最终路径为：

```text
/product/priv-app/MiuiHome/MiuiHome.apk!/lib/arm64-v8a/libapp_launcher.so
```

### 4.6 与 `hyos_spawner` 通信

类：

```text
android.os.RustProcessImpl
```

它连接 Android reserved namespace 中名为 `hyos_spawner` 的 LocalSocket：

```java
private static final String RUST_SOCKET_NAME = "hyos_spawner";

new LocalSocketAddress(
    RUST_SOCKET_NAME,
    LocalSocketAddress.Namespace.RESERVED);
```

发送的启动请求格式包括：

```text
--start-child
--process-name=com.miui.home
--package-name=com.miui.home
--binary-path=/product/priv-app/MiuiHome/MiuiHome.apk!/lib/arm64-v8a/libapp_launcher.so
--uid=10146
--gid=10146
--gids=...
--runtime-flags=...
--target-sdk-version=36
--abi=arm64-v8a
--app-data-dir=/data/user/0/com.miui.home
--seq=...
```

`RustProcessImpl` 等待 spawner 返回 PID，并以 `rust fork success` 记录成功结果。

## 5. `hyos_spawner` 的启动与职责

init 配置位于：

```text
/system_ext/etc/init/init.hyos_spawner.rc
```

核心内容：

```rc
service hyos_spawner /system_ext/bin/hyos_spawner /system_ext/bin --spawner --start-spawner-server
    user root
    group system
    socket hyos_spawner stream 0660 root system
    disabled

on property:init.svc.zygote=running
    setprop rust.runtime_version 3.1.0

on property:init.svc.zygote=running && property:rust.runtime_active=1
    start hyos_spawner
```

设备实时属性为：

```text
init.svc.hyos_spawner=running
rust.runtime_active=1
rust.runtime_version=3.1.0
```

`hyos_spawner` 自身的字符串暴露了以下源码模块和职责：

```text
rust/core/runtime/hyos_spawner/src/main.rs
rust/core/runtime/hyos_spawner/src/fork_loop.rs
rust/core/runtime/hyos_spawner/src/runtime_preload.rs
rust/core/runtime/hyos_spawner/src/environment.rs
rust/core/runtime/hyos_spawner/src/shell_loader.rs
rust/core/runtime/hyos_spawner/src/storage.rs
```

其预加载集合包括 HyperOS Flutter/UI 和系统桥接库，例如：

```text
/system_ext/lib64/libhyper_os_flutter.so
libhyper_os_shell.so
/system_ext/lib64/libmigui.so
/system_ext/lib64/libmiinput.so
```

这说明它不仅是简单的 `dlopen()` 包装器，而是为 HyperOS Rust/Flutter 应用提供预热、fork、SELinux 身份切换、存储挂载、系统调用及 UI/runtime 预加载的完整应用进程孵化器。

## 6. 设备动态证据

调查时桌面进程状态：

```text
USER       PID   PPID  NAME
u0_a146    6951  4694  com.miui.home
```

可执行文件：

```text
/proc/6951/exe -> /system_ext/bin/hyos_spawner
/proc/4694/exe -> /system_ext/bin/hyos_spawner
```

父进程 PID 4694 的信息：

```text
Name:       usap64
PPid:       1
Uid:        0
SELinux:    u:r:zygote:s0
Threads:    1
```

这表明 PID 4694 是 `hyos_spawner` 维护的 USAP/zygote 式进程池成员或服务进程。MiuiHome 由它 fork 并完成 uid、gid、SELinux、存储和进程名 specialize。

同一个 PID 4694 还孵化了其他 HyperOS/Rust 应用进程，例如调查时可见：

```text
com.miui.weather2
com.miui.gallery:provideData
```

MiuiHome 进程映射具有以下特征：

- `/proc/6951/exe` 为 `hyos_spawner`，不是 `app_process64`。
- 映射了 `/system/lib64/libandroid_runtime.so`，用于访问 Android Native runtime 能力。
- 未发现 `libart.so`，符合无 Dex、无 ART 应用运行时的设计。
- `MiuiHome.apk` 的多个区段被直接映射到进程，符合未解压 Native 库的 ZIP 直接装载方式。

## 7. 与 Android 17 `zygote_next` 的区别

设备同时运行：

```text
PID 3126
/system/bin/zygote_next
zygote_next --name zygote_next --species android-native-app --log-level INFO
```

对应 init 文件：

```text
/system/etc/init/zygote_next.rc
```

但是 MiuiHome 没有走这条路径，依据是：

1. MiuiHome 的直接父进程是 PID 4694，而不是 PID 3126。
2. MiuiHome 与父进程的 `/proc/*/exe` 都指向 `/system_ext/bin/hyos_spawner`。
3. Framework 的实际启动分支调用 `RustProcessImpl` 并连接 `hyos_spawner` socket。
4. MiuiHome Manifest 使用的是小米 `hyperos_package`/`hyperos_app_lib_name` 元数据。

因此不能把 `zygote_next` 和小米 Rust Runtime 混为一谈。当前系统中它们是两套并行存在的 Native 应用孵化机制；MiuiHome 使用后者。

## 8. 对 LSPosed 模块的影响

传统 LSPosed Java hook 无法直接进入这版 MiuiHome，原因包括：

1. 进程不是从传统 ART zygote 应用路径 fork。
2. APK `hasCode=false` 且没有 Dex。
3. 进程没有 ART `libart.so`。
4. 不存在普通 `Application`/Activity Java 类装载生命周期供 Xposed 回调和 Java hook 使用。
5. 静态 scope 中加入 `com.miui.home` 也不能自动使传统 Xposed 注入适配 `hyos_spawner`。

对本项目当前 SystemUI-first 架构的直接含义：

- `com.android.systemui` 和 `system` 仍走正常 ART 路径，现有 Java hook 研究方向仍成立。
- 旧版依赖 MiuiHome Java 类（例如 `GestureStubView`、`StateManager`、`WindowElement`）的 hook 在该版本上不能直接复用。
- Shell 标准 Binder 接口、显式跨进程通信和 system_server/SystemUI 侧观测仍是优先兼容方向。
- 若必须修改新桌面内部行为，需要另行研究 `hyos_spawner` 的 Native 注入生命周期，或对 `libapp_launcher.so`/HyperOS Native bridge 做符号、Binder 与动态调用分析；这已经不是常规 LSPosed Java hook 问题。

## 9. 建议的后续研究入口

按优先级建议：

1. 在 `libapp_launcher.so` 中定位 Shell back/launcher callback、remote animation 和 `IBackAnimation` Binder 相关字符串及注册点。
2. 分析 `libhyper_os_shell.so` 提供的 Activity/Service/Binder 桥接 ABI，确认 Native component 的创建和生命周期分发方式。
3. 抓取 MiuiHome 冷启动时 `RustProcessImpl` 与 `hyos_spawner` 的完整日志，验证入口导出符号、参数和运行时初始化顺序。
4. 调查 LSPosed/zygisk 是否能够识别或扩展到 `/system_ext/bin/hyos_spawner` 的 fork/specialize 边界；在此之前不要假定仅增加 scope 即可注入。
5. 保持 SystemUI-first 方案，将必须由 launcher 完成的功能限制在标准 Shell/Binder 协议范围内，减少对桌面实现细节的依赖。

### 9.1 本地 Zygisk Next 实验入口

仓库已建立默认关闭的最小观察探针：

```text
experiments/miui-home-hyos-zn
```

它通过 Zygisk Next 的 service scope 精确指向
`/system_ext/bin/hyos_spawner`，验证 Build ID 后仅 hook 该可执行文件自身的
`dlopen`/`dlsym` PLT，再沿已确认的系统 Shell 调用链安装 caller-oriented
PLT 观察点。当前探针不修改 loader 返回值、不安装桌面业务 inline hook、
不启动线程、不连接 companion，并且默认不安装任何 hook。设备侧已经验证
ZN 注入、fork 继承、受控 `hyos_spawner` 重载和入口解析。

### 9.2 设备侧确认的最终加载链

当前运行的桌面不是预装 `4349`，而是 `/data/app` 覆盖安装的 `4371`：

```text
RELEASE-8.01.02.4371-260727-08131546-R
/data/app/~~<random>/com.miui.home-<random>/base.apk
```

因此不能将观察逻辑绑定到 `/product/priv-app` 或随机安装目录。设备进程内存、
ELF 导入和 PLT 观察共同确认实际链路为：

```text
hyos_spawner
  dlopen("libhyper_os_shell.so")
  dlsym(handle, "launch_main_thread")
    -> /system_ext/lib64/libhyper_os_shell.so
         android_dlopen_ext("libhyper_os_app_public.so", ...)
         dlsym(handle, "run_application")
           -> /system_ext/lib64/libhyper_os_app_public.so
                hyper_os_sys::ld_android::android::dl_ext::dlopen_ext(...)
                dlsym(handle, "app_entry_point")
                  -> base.apk 内的 libapp_launcher.so
```

关键 ELF 证据：

- `libhyper_os_shell.so` 导出 `launch_main_thread`，并具有
  `android_dlopen_ext` 与 `dlsym` 的 `JUMP_SLOT`。
- `libhyper_os_app_public.so` 导出 `run_application`，导入 HyperOS Rust
  `dlopen_ext` wrapper，并具有 `dlsym` 的 `JUMP_SLOT`。
- 设备捕获到的符号顺序为 `launch_main_thread`、`run_application`、
  `app_entry_point`。
- `app_entry_point` 解析成功后，模块状态为非空 launcher handle 且
  `entry_reported=1`。

桌面更新兼容边界因此选择精确进程名 `com.miui.home`、系统运行时 caller
`libhyper_os_app_public.so` 及稳定导出名 `app_entry_point`，不依赖 APK 路径、
版本号、随机 token 或 launcher ELF 哈希。`hyos_spawner` Build ID 仍严格固定；
系统运行时升级后必须重新验证，不能盲目沿用。

曾测试进程级全局 `dlopen`/`android_dlopen_ext`/`dlsym` inline hook；该版本
导致 MiuiHome 退出，已立即回滚，未纳入安装包。最终版本仅使用调用方定向的
PLT hook。

### 9.3 `4371` Native 手势业务边界

`libapp_launcher.so` 表面上已经 stripped，但其 `.gnu_debugdata` 保存了一份
XZ 压缩的 mini debug ELF。解压后可以恢复内部 Rust 函数名、地址和大小，
因此当前版本无需用字符串附近的猜测偏移作为第一依据。`4371` 的库 SHA-256
为：

```text
a84365f864f88f85165b086bc03ba563efd09386c72f0c21926788fd90a028f9
```

旧 Java 返回手势链在 Rust 中的直接对应关系已经确认：

| 旧语义 | `4371` Native 对应物 | ELF 虚拟地址 | 大小 |
| --- | --- | ---: | ---: |
| GestureStub 接收后的业务边界 | `GestureStubViewWindow::handle_back_gesture` | `0xc6e954` | `0xec` |
| 返回手势主处理器 | `GestureInputBackHelper::on_touch_event` | `0xc073e0` | `0x3f78` |
| 手势开始 | `GestureInputBackHelper::on_swipe_start` | `0xc0b440` | `0xebc` |
| 手势进度 | `GestureInputBackHelper::on_swipe_process` | `0xc0c2fc` | `0x1544` |
| 取消 | `GestureInputBackHelper::on_back_cancelled` | `0xc0d840` | `0x3b8` |
| 提交 | `GestureInputBackHelper::on_back_invoke` | `0xc0df2c` | `0xb78` |
| 普通 BACK fallback | `GestureInputBackHelper::perform_fallback_back_navigation` | `0xc0eaa4` | `0x324` |

`GestureStubViewWindow::handle_back_gesture(this, event)` 保留了 native Stub 的
窗口、触摸区域与重定向判定；进入该函数后，它把 `this + 0xb8` 的
`GestureInputBackHelper`、左右边信息和原始 MotionEvent 交给
`on_touch_event(...)`。这使该函数成为将来发布 accepted-DOWN 身份令牌并在
边界处阻止旧 launcher 手势处理器的首选点：它不会提前破坏 Stub 初始化或
`request_redirect(...)`。

`on_touch_event(...)` 内部已经确认存在完整的 Native predictive-back 链：

```text
BackMotionEvent_new
BackAnimationAdapter_new
ActivityTaskManager_start_back_navigation
  -> on_swipe_start / on_swipe_process
  -> on_back_cancelled 或 on_back_invoke
```

因此“小米只是把旧逻辑换语言重写”的判断基本成立，但 Native MiuiHome 自己
也会启动一条 back navigation；SystemUI-first 实现必须在 accepted-input
边界仲裁，不能让 launcher 与 SystemUI 同时启动 Shell navigation。

OPEN 打断逻辑也仍在。`BackControllApi` 保留
`can_use_break_open_anim [default]` 回调，`on_touch_event(...)` 通过
`app_launcher::api::back_controll::call_dart_fn_with_timeout` 查询它，并把成功
结果写入 helper 状态。另一个同类查询名为
`is_back_gesture_anim_running`。实际执行侧可见：

```text
app_launcher::api::back_controll::interrupt_app_hero_animation_if_running_async
```

该函数是异步状态机 closure，不适合作为第一批 inline hook；优先观察回调
查询结果与 start/cancel/invoke 边界，可以在不解释 Rust Future 内存布局的
情况下还原 OPEN 可逆性和最终提交顺序。

标准 return-to-home 方向也有明确基础：库导入
`BackAnimationAdapter_new`、`ActivityTaskManager_start_back_navigation` 和
`BackNavigationInfo`/`IOnBackInvokedCallback` 全套 ABI，同时包含
`hyper_os_ui::window::back_gesture::back_animation_runner::sabi::IBackAnimationRunner_trait`。
后续应从 adapter 构造时传入的 runner/vtable 身份向 launcher 的 closing
Surface 消费侧追踪，而不是复活旧 Java `BackAnimationAdapter` 注入路径。

上述地址仅是 `4371` 的研究坐标。实际模块必须先以当前加载库基址加地址定位，
并校验多个函数前导指令/结构特征；任何校验失败均不安装业务 hook。将来的桌面
更新应重新解析 `.gnu_debugdata` 或按调用结构生成签名，不能直接沿用这些偏移。

实验模块 `0.5.1-back-boundary-counters` 已加入独立且默认关闭的
`persist.sys.miui_home_hyos_zn_business` 开关。当前只透明观察
`call_dart_fn_with_timeout` 的两个 back callback 结果，以及
`on_swipe_start`、`on_back_cancelled`、`on_back_invoke` 三个生命周期边界；
不改返回值、不跳过原函数，也不 hook 高频 MOVE 进度。安装业务 hook 前会同时
校验 `app_entry_point == base + 0x885d00` 和四个候选函数各自的 32 字节前导
指令，任一不匹配即失败关闭。
由于当前 Native 子进程的自定义 log tag 未进入 logd，测试版同时保留模块内
原子命中计数：OPEN 查询次数/最后结果、swipe start、cancel、invoke 次数以及
invoke 的原始第二 ABI 参数。该参数尚未证明是 tracker trigger，不能按布尔值
或提交判定解释。所有计数只用于验证 observer 命中，不参与业务决策。

第一轮真实边缘手势验证得到 `start=8`、`cancel=3`、`invoke=5`，满足
`start == cancel + invoke`，且 MiuiHome PID 未变化。普通应用内返回没有进入
OPEN 查询。launcher 点击应用后立即返回的首次测试也没有经过该 helper，因而
`0.6.0-open-interrupt-observer` 进一步透明观察共享的
`interrupt_app_hero_animation_if_running_async` poll 状态机；该点同时被 FRB
async executor 与 `AppWidgetLaunchCallback::start_activity` 调用。

## 10. 复核命令

以下只读命令可用于在同一设备上复核：

```powershell
adb shell "ps -A -o USER,PID,PPID,NAME,ARGS | grep -E 'usap|zygote|com.miui.home'"
adb shell pidof com.miui.home
adb shell su -c "readlink /proc/$(pidof com.miui.home)/exe"
adb shell su -c "cat /proc/$(pidof com.miui.home)/status"
adb shell su -c "grep -E 'libart|libandroid_runtime|MiuiHome.apk' /proc/$(pidof com.miui.home)/maps"
adb shell getprop init.svc.hyos_spawner
adb shell getprop rust.runtime_active
adb shell getprop rust.runtime_version
adb shell su -c "cat /system_ext/etc/init/init.hyos_spawner.rc"
adb shell su -c "cat /system/etc/init/zygote_next.rc"
```

注意：PowerShell 对 `$()` 和管道的转义可能影响 `adb shell su -c`；必要时先取得 PID，再用常量 PID 执行 `/proc` 查询。

## 11. 4371 实机推进状态（2026-08-14）

设备曾仍在运行产品分区的 `4349`，虽然本地已经有 `4371` APK；这可由
`dumpsys package com.miui.home` 的 active `versionName` 直接确认。现已通过
`adb install -r` 安装数据分区更新，并复核 active code path 与版本：

```text
codePath=/data/app/.../com.miui.home-.../
versionCode=801024371
versionName=RELEASE-8.01.02.4371-260727-08131546-R
```

为防止 Android 16/17 参考物混淆，当前提取物独立放在：

```text
refs/android17/miui-home-4371/lib/arm64-v8a/libapp_launcher.so
refs/android17/hyperos-framework/
```

`libapp_launcher.so` SHA-256 为：

```text
a84365f864f88f85165b086bc03ba563efd09386c72f0c21926788fd90a028f9
```

### 11.1 SystemUI Android 17 崩溃已修复

旧实现只在 `mIsBackGestureAllowed=true` 后给 system-gesture provider 添加
`TYPE_INPUT_METHOD -> Insets.NONE` override。Android 17 可能先以不含 override
的 LayoutParams 添加 NavigationBar 窗口，随后 relayout 才进入允许状态；WMS
因此抛出：

```text
IllegalArgumentException: Insets override types can not be changed after the window is added.
```

修复仅由 `SystemUiAndroid17Impl.requiresStableGestureInsetsOverrideTypes()` 开启：
第一次生成 NavigationBar LayoutParams 时就预声明 override type 和零 cutout-safe
minimum，后续 eligibility 变化只更新尺寸。Android 16 实现保持原行为。新 APK
安装后 SystemUI PID `29212` 连续复核稳定，Android 17 implementation、原生
BackPanel、input monitor 与 arbiter generation 均成功建立。

### 11.2 Native accepted-DOWN 广播桥当前结论

纯 Native MiuiHome 不加载 `libart.so`，因此 JNI 桥不可用。实验改为调用
HyperOS 的 `Broadcast`、`Intent`、`Bundle` 和 PackageManager Native ABI，
并确认 `Broadcast_register_receiver` 的 hidden-sret 调用约定以及 4371 两套
不同的 RString allocator/vtable：

```text
Intent/Bundle RString: base + 0x133cf20
IntentFilter action RString: base + 0x133bdb0
```

但把 SystemUI arbiter action 直接追加到 MiuiHome 已有 receiver filter 后，
原始 `Broadcast_register_receiver` 路径仍在 `rt-launcher-main` 线程跳转到空地址。
最新 tombstone 特征稳定为：

```text
signal 11 (SIGSEGV), fault addr 0x0
pc=0, lr=0
```

早期实验即使在 `Intent_get_action` 边界消费模块 action 仍会崩溃，但后续把两个
PLT hook 拆成独立诊断模式后，发现该证据不足以证明故障一定发生在注册阶段：
短时的 register-only 模式没有崩溃，也尚未命中目标注册点；此前的组合模式可能
同时受 `Intent_get_action` 返回 ABI、原 receiver 时序或第二次注册所有权影响。
因此当前能确定的结论只有：不能修改 launcher 原 receiver 的 filter；独立 Native
receiver/trait object 仍是正确方向，但在构造它之前必须先单独证明每个 ABI 边界。

设备已回滚到保留的稳定模块二进制：

```text
8c94f610ae76301b34f5803432a58a3734b5d0c77ade56abe009b1691827b581
```

回滚只替换模块目录内的 `.so` 并 reload `miui-home-hyos-zn`/重载
`hyos_spawner`，未写入 `/system/bin`，未重启 Android。源码中保留后续独立
receiver 研究所需的 ABI 骨架，但当前崩溃版没有留在设备上。
崩溃复现代码还受独立属性
`persist.sys.miui_home_hyos_zn_native_receiver` 保护；该属性默认关闭，并在安装与
卸载时强制写回 `0`，普通构建不会进入被否决的 filter 扩展路径。

### 11.3 RescueParty 对 Native 调试的影响

连续秒级崩溃会触发 Xiaomi 的 MiuiHome 自救路径。实机日志已经出现：

```text
SafeModeManager: entering safe mode via rescue party
com.miui.home.safemode.SafeLauncher
sys.rescuepartyplus.temp_mitigation_count=11
```

这会改变 Launcher Activity、初始化顺序和 receiver 注册时机，所以进入该状态后
得到的 Native hook 结果不能作为正常 4371 的行为证据。当前已关闭实验属性、恢复
上述稳定 `.so`；只读复核显示前台重新是
`com.miui.home/.launcher.Launcher`，没有 `com.miui.home:safe_mode` 进程，但临时
mitigation count 仍为 `11`。在该计数通过正常系统恢复流程清除前，不再执行任何
会主动造成 MiuiHome 崩溃的测试。

### 11.4 独立 receiver 的 callback 消费边界

对 `libhyper_os_broadcast_private.dylib.so` 的静态反汇编确认，导出函数
`BroadcastHolder::on_receive`（`0xec20`）先调用 abi_stable 的泛型 trait 分派，
随后继续执行 pending-result 收尾；其中真实 callback 的分派入口为：

```text
BroadcastReceiver_TO::on_receive = 0xe814
```

`0xe814` 从 RObject vtable 的 `+0x18` 取真实 `on_receive` 并 tail-call，原始
context/intent 参数保持透传。因此默认关闭的实验源码已改为在这一层只识别模块
arbiter action：先完成发送包和 UID 校验，命中时不进入 MiuiHome 的 generated
action switch，返回后仍由外层 `BroadcastHolder` 完成广播收尾；其他 action 调用
原函数。它取代了全局 PLT 替换 `Intent_get_action` 的方案，避免其 40-byte
hidden-sret/所有权风险。

该改动仅完成本地 ARM64 编译验证，未部署设备。当前设备仍运行稳定 `.so`，实验
属性为 `0`；必须等 RescueParty 状态恢复后才允许做一次受控验证。

### 11.5 Zygisk Next service-death 熔断

后续受控验证没有进入实验代码。`dump-zn -sa` 揭示 Zygisk Next 1.4.5 把每次由
`hsctl` 主动停止 `hyperos_spawner` 产生的 SIGKILL 也计为 service death；第三次后
该 service scope 变为：

```text
enabled=false
can_load=false
death_count=3
```

此时 `znmod reload miui-home-hyos-zn svc` 仍会输出 success，但新 spawner 实际未
注入模块。它解释了实验 marker、模块日志和 maps 均不存在的现象，并不构成 hook
成功或失败证据。

`hsctl reload/refresh` 已增加两层校验：操作前读取 service state，在
`can_load=false` 或下一次 stop 将耗尽预算时拒绝重载；启动后还必须在 Zygisk Next
的 injected-process 记录中找到新 spawner PID，才报告成功。设备模块目录里的
`hsctl` 已更新并实测会拒绝当前熔断状态，没有再次停止进程。实验属性已恢复为
`0`，设备 `.so` 仍为稳定版本。该 fuse 无法通过 module enable/reload 清除，下一次
动态验证应在受控重启设备、确认 `can_load=true death_count=0` 后进行。

### 11.6 重启后旧 staged 模块导致的桌面崩溃

设备重启后 MiuiHome 立即进入连续 native crash。现场确认并非当前源码或 4371
本身：KernelSU 在启动阶段激活了模块目录此前残留的 staged update，把运行中手工
替换的稳定 `.so` 和备份覆盖为旧包：

```text
version=0.6.0-open-interrupt-observer
active SHA-256=7a8d4a1b53c3d432c8ee59050cf8a602f9904caafc7ba995a03c2d7b33084185
```

该旧版本早于 native-receiver 独立默认关闭门。即使
`persist.sys.miui_home_hyos_zn_native_receiver=0`，它仍无条件修改 launcher 原
receiver filter。开机日志给出直接因果序列：

```text
MiuiHomeHyosZn: extended native receiver with arbiter state action
MiuiHomeHyosZn: queried SystemUI native input arbiter
NativeCrashHandler: crash_handler INTERCEPTED SIGSEGV
```

随后 `sys.rescueparty.home.level` 升至 `9`，桌面切到
`com.miui.home/.safemode.SafeLauncher`。

止损与恢复步骤如下：

1. 将三个模块属性全部置 `0`，并在 Zygisk Next 中禁用
   `miui-home-hyos-zn`；只重启一次 `hyperos_spawner`，崩溃循环结束。
2. 用当前 `0.7.0-android17-4371` 覆盖模块目录和模块内备份，两者 SHA-256
   均为 `d1a7eb3d9adafa37e82ceb88d4e0db08dc52e13a6e6a67c95957da381bca69e1`；
   同步新版 `hsctl/module.prop`，确认不再有 `update` 标记。
3. 清除本次故障产生的 `sys.rescueparty.home.level`，发送 4371 自带的
   `com.miui.home.safemode.exit_safeMode`，由桌面原生 `clearSafeModeState` 路径
   恢复设置。正常 `.launcher.Launcher` 已重新置顶，SafeLauncher 进程退出。

ZN 模块当前继续保持全局禁用，不能自动恢复实验。`hsctl reload/refresh` 也新增
全局 enabled 检查；模块禁用时直接拒绝重启，避免“PID 变化但未注入”的假成功。

上述恢复流程已固化在模块目录内，不挂载到 `/system/bin`：

```sh
/data/adb/modules/miui-home-hyos-zn/bin/hsctl rescue-home --confirm
```

该命令会先关闭四个实验属性并在 Zygisk Next 中禁用本模块，然后只重启一次
`hyos_spawner`，清除 Home 专属 RescueParty 状态，最后调用 4371 原生
`exit_safeMode` 动作并启动正常 Launcher。它不会清除桌面数据，也不会重启系统；
执行后模块保持禁用，必须由人工确认现场稳定后再启用实验。

### 11.7 Android 17 身份桥首轮验证与 PLT 修正

SystemUI 侧已拆出 `SystemUiAndroid17Impl`，Android 16 继续走独立实现。实机热重载
确认选中 `android17`，原生 `BackPanelController`、spy `InputMonitor` 和
`miuihome-accepted-token` 仲裁模型均已恢复。Android 17 还要求
`InputEventReceiver.dispose()` 在其 owner Looper 执行；热重载清理现已先发布
arbiter unavailable，再按主 Looper FIFO 销毁旧 receiver，之后才恢复新 monitor。
连续热重载已确认不再遗留重复 receiver。

MiuiHome 侧新增独立且默认关闭的：

```text
persist.sys.miui_home_hyos_zn_arbiter_bridge
```

该桥不注册 receiver、不修改 filter，而是复用 4371 已注册且 SystemUI 持有权限的
`com.android.systemui.fsgesture` action。只有带模块 generation marker 的状态才会
进入模块解析，普通小米广播仍完整透传。双向模块广播都要求 share-identity，接收端
继续同时验证共享 caller package 和发送 UID 的包所有权。

首轮受控加载没有造成桌面崩溃，正常 Launcher PID 保持运行；内存状态显示
MotionEvent identity 与 `BroadcastReceiver_TO::on_receive` hook 已成功，但
`broadcastIntentWithFeature` 的 inline hook 被 ZN 拒绝，business state 以 `6`
fail-closed，因而尚未安装手势边界 hook，也没有发布 accepted-DOWN。原因不是 ABI
参数错误，而是导出的 Rust trait shim 短于 ZN inline-hook 的最小覆盖范围。

静态 relocation 复核确认私有广播库自己已有精确入口：

```text
offset 0x14ed0
R_AARCH64_JUMP_SLOT
ActivityManagerServiceProxyImpl::broadcastIntentWithFeature
```

因此下一版改为对
`/system_ext/lib64/libhyper_os_broadcast_private.dylib.so` 的这一个 PLT relocation
执行 `pltHook`，不再覆盖短 shim。raw arm64 转发仍只在模块 query/accepted intent
上把 options 栈槽 `sp+0x58` 从 null 换成包含
`android:broadcast.flags=16` 的 Bundle，其余寄存器、栈参数和返回对象原样转发。
本地 native 构建和脚本契约检查已通过；由于本轮设备只剩一次受控 spawner 刷新
额度且已使用，PLT 修正版尚未二次动态加载，必须在下一次重启恢复 Zygisk Next
service-death 预算后验证。

重启后的第二次现场确认 ZN 对该私有库的 self-referencing PLT 也返回失败；内存中
`g_original_broadcast_receiver_on_receive` 非空，而
`g_original_broadcast_intent_with_feature` 仍为空，business state 仍为 `6`，因此
“手势无效果”发生在 accepted-DOWN 之前。现场同时验证了当前私有库：

```text
Build ID = 7f186b331ec39d84e6016daeba65366f
load base = 0x77e3f89000
GOT slot  = base + 0x14ed0
slot value = 0x77e3f99d74 = base + 0x10d74
```

后续实现不再依赖 ZN 对这条 self-PLT 的支持：它先校验上述 Build ID，再要求 GOT
当前值严格等于 `dlsym` 解析到的原函数，短暂将该 RELRO 数据页改为可写，使用原子
CAS 只替换这一个 slot，随即恢复只读。任何 Build ID、地址、当前值、`mprotect` 或
CAS 不匹配都 fail-closed；receiver hook 后续若失败还会回滚该 slot。该方案不写
代码页，也不扩大 receiver 或进程范围。

### 11.8 SafeLauncher 恢复约束修正

后续一次 native 版本在启动阶段触发连续 `SIGABRT`，模块已通过 `rescue-home`
关闭四个 gate、禁用 ZN、只重启 `hyos_spawner` 并将 Home RescueParty level 清零，
崩溃循环随即停止。但 4371 的 SafeLauncher 选择没有被重复
`exit_safeMode` 广播或直接启动 `.launcher.Launcher` 清除；这两种操作不再作为
可靠恢复路径。

恢复约束现改为：先由模块完成 fail-closed 止损，确认 SafeLauncher 稳定后，明确
通知操作者把唯一批准的 MiuiHome 4371 安装包重装一次。模块不得自行重装桌面，
也不得循环发送退出广播。操作者完成重装后，必须先核对 4371 版本、正常 Launcher
置顶、无继续 native crash、所有实验 gate 为 0，才能开始下一轮测试。

本次崩溃的 allocator 证据为：

```text
Scudo ERROR: invalid chunk state when deallocating address ...
```

它说明 direct-GOT 已到达目标私有广播调用，但 raw Rust 参数、Bundle 或返回对象的
所有权仍不成立，不能通过调整时序继续试。该 bridge 实现现已 compile-time
fail-closed；请求时只记录 native state `199`，不改 GOT、不 hook receiver、不发送
query。设备侧 active `.so` 已回滚到稳定 SHA-256
`d1a7eb3d9adafa37e82ceb88d4e0db08dc52e13a6e6a67c95957da381bca69e1`，
ZN 全局禁用，所有 gate 为 `0`。

### 11.9 4371 私有广播返回 ABI 根因与本地修正

对 exact 4371 的 `libhyper_os_broadcast_private.dylib.so` 做指令级复核后，
Scudo 崩溃已经定位到返回 ABI，而不是广播时序：

1. `ActivityManagerServiceProxyImpl::broadcastIntentWithFeature` 从 `x8` 取得
   Rust sret 地址，成功和错误分支最多只写 `+0x0`、`+0x4`、`+0x8`，结果对象为
   16 字节。
2. 它的直接 GOT caller 只为该结果保留 16 字节局部空间。
3. 旧 C++ hook 复用了 public `Broadcast_send_broadcast` 的 48 字节
   `NativeResult` 声明。该 hook 返回时通过同一个 `x8` 写出 48 字节，越过 caller
   的结果槽 32 字节，随后被破坏的 Rust owner 在析构时触发
   `Scudo ERROR: invalid chunk state`。
4. 不能把 C++ 结构简单改成 16 字节：AAPCS64 会让普通 16 字节 C++ aggregate
   走 `x0/x1`，而这条 Rust ABI 仍要求 hidden `x8` sret。

本地实现已改为独立 AArch64 tail-call shim。它不声明或复制返回对象，保持原始
`x8`、`x0-x8` 和 `sp`，仅在 exact module-owned 广播的线程独占 arm 生效时，
将 caller 的 null options 槽 `[sp,#0x58]` 替换为
`android:broadcast.flags=16` 的 Bundle，然后直接 `br` 原函数。同线程嵌套广播由
消费状态挡住，其他 launcher 线程无法取得该 Bundle；发送结束后才解除 owner。

最终 `.so` 反汇编已确认 shim：

```text
入口: bti c
建栈/退栈: 无
调用/返回: 无 bl、无 ret；末尾 br 原函数
入参和 sret: x0-x8 未改
栈写入: 仅 [sp,#0x58]
动态导出: 仅 zn_module
```

ZN native 构建、BTI/PAC 检查、模块内 `hsctl` 契约检查，以及主工程
`:app:assembleDebug` 均已通过。随后继续复核 exact public wrapper：它先在自己的
`sp+0x8` 保留 16 字节 private Result，调用 `scene::impls::send_broadcast`，再显式
转换为写入 public `x8` 目标的 48 字节 Result；因此两层 ABI 的边界已经闭环。
私有代理只把 options 指针继续转发给 Binder 调用，返回后不 drop，模块在 public
wrapper 完整返回之后才 `Bundle_drop`，借用生命周期也已闭环。

为进入实机阶段又增加了独立单次租约
`miui_home_hyos_zn_arbiter_bridge_once`。每次 `hsctl bridge-enable --confirm` 只清除
这一个精确文件；native 模块在首次 GOT/receiver mutation 前以
`O_CREAT|O_EXCL` 消费它。若该 MiuiHome 进程崩溃，替代进程看到租约已存在便以 state
`198` fail-closed，不会因持久属性仍为 `1` 而再次安装并形成 crash loop。再次测试
必须重新显式执行 `bridge-enable`。

完成上述静态审计后，`kArbiterBridgeImplementationReady` 已改为 `true`，但三层
runtime gate 默认仍为 `0`，安装脚本也会重置为 `0`。候选包只完成本地构建，没有
安装、没有 reload、没有修改设备属性。本结论本身不需要 Ghidra；Ghidra 更适合
后续恢复 4371 的状态对象、虚表和复杂交叉引用。

### 11.10 单次实机候选与安装前状态

当前本地候选为：

```text
version=0.8.3-android17-4371-arbiter-tail-once
versionCode=13
package=out/packages/miui-home-hyos-zn-20260815-005622.zip
package SHA-256=afda430e6db19b9d954a93f944d06b373dbe7a27a64853ef76db20432caa90f3
native SHA-256=4412110a9148668978ef7a8491cbddda45d3d073ef9ffb9ff32384e8e92a86b5
installed=false
```

安装前只读预检确认：设备仍为 exact 4371，Home 解析到正常
`com.miui.home/.launcher.Launcher`，Launcher PID 6848，四个实验 gate 均为 `0`，
没有新的 Scudo 或 SafeLauncher 记录。当前活动模块仍是回滚后的 0.8.1 壳和稳定
native SHA-256
`d1a7eb3d9adafa37e82ceb88d4e0db08dc52e13a6e6a67c95957da381bca69e1`；
单次 bridge lease 不存在。ZN 对 `/system_ext/bin/hyos_spawner` 报告
`can_load=true, death_count=0`，因此保留完整的一次受控 refresh/reload 预算。

下一步只安装 0.8.3 包。安装脚本会再次把 main/business/bridge/diagnostic 四个 gate
清零且不重启任何进程，所以安装完成后仍不应直接测试手势。先核对活动文件和 gate，
再依次显式 arm 三层 gate 与单次 lease，并只 refresh/reload 一次。

### 11.11 0.8.3 单次实机结果：borrowed Intent 字符串

0.8.3 通过模块目录原位切换后，使用 `hsctl refresh` 只重载
`hyos_spawner`。ZN 确认新 spawner PID 15383 已注入，首个 Launcher PID 15753
消费单次 bridge lease，随后在 tokio worker 上触发一次 SIGABRT。替代 Launcher
PID 16069 因 lease 已存在而没有再次安装桥，桌面保持正常，没有形成 crash loop。
模块随即把 main/business/bridge 三个持久 gate 全部归零，未再次 reload。

本次 tombstone 已保存为：

```text
out/analysis/miui-home-0.8.3-crash/tombstone_29.txt
SHA-256=427fa8607c5fa4273dfa2d1a11235c48a97df58ca099082f0ba6317039a17cd8
Abort=Scudo ERROR: invalid chunk state when deallocating
module frame=file pc 0x2db4 -> loaded text vaddr 0x8db4
source=IntentActionEquals(), free(action.value.data)
```

这次栈不再落在 private Result 转发。桥已完成 query，并进入 SystemUI 状态回包的
receiver dispatch；崩溃发生于模块解析 action 时。exact 4371
`libhyper_os_schema_public.so` 指令确认：

- `Intent_get_action` 只把 BinderString 的 deref `data/length` 写入 sret 的 `+8/+16`；
- `Intent_get_sender_package_name` 直接从 Intent `+0x270/+0x278` 复制
  `data/length`；
- 两个 getter 都不分配、不复制、也不返回 capacity/vtable，所得字符串是 Intent
  内部 borrowed view。

旧代码把该 view 声明成 owned 40 字节 `ROptionRString` 并调用 `free(data)`，因此
Scudo 正确报告 invalid chunk。0.8.4 已拆出精确 24 字节
`BorrowedROptionRString { tag, data, length }`，action/sender 只比较、不释放；供
Intent setter 使用的 owned 40 字节结构保持独立。按恢复约束，设备在下一次实验前
必须由操作者重装唯一批准的 MiuiHome 4371 一次，并先确认正常 Launcher 与四个 gate
为 0。

修正后的本地候选：

```text
version=0.8.4-android17-4371-arbiter-borrowed-once
versionCode=14
package=out/packages/miui-home-hyos-zn-20260815-010848.zip
package SHA-256=083bacab0f56a7abd15832e5051f95722dcdea51962f80103973ff73c54b3851
native SHA-256=757410fef25dcaa56350b982cb4b7e1eba8fe359bb4d4497399d81124b75a36a
installed=false
```

构建继续强制校验 tail shim 的 BTI、无 frame/call/return 和唯一 `sp+0x58`
访问；`BorrowedROptionRString` 与 owned `ROptionRString` 分别有 24/40 字节
`static_assert`。0.8.4 尚未下发，必须等待 4371 重装后的状态核对。

### 11.12 0.8.4 实机结果：桥稳定、首次查询缺少可观测性

操作者重装 exact MiuiHome 4371 并重启确认恢复后，0.8.4 通过
`ksud module install` 安装。由于 KernelSU 将 native 更新留在
`modules_update`，本次只把已校验的 `.so` 同步到模块自身目录，再使用模块内
`hsctl refresh` 重载 `hyos_spawner`；没有重启 Android，也没有向
`/system/bin` 写文件。

0.8.4 Launcher PID 29253 持续稳定，最新 tombstone 仍是旧的 29，证明 borrowed
Intent 修正关闭了 Scudo 故障。实测 native receiver/GOT/bridge 分别到达成功状态，
但 `g_systemui_arbiter_generation` 仍为 0；当时只有发送函数的布尔返回，启动日志又被
大量 Launcher 输出挤掉，无法区分 Intent、options、public wrapper 或回包阶段。

### 11.13 0.8.5 查询诊断与受控重试

0.8.5 为 native 广播链增加模块 BSS 诊断：发送次数、action 类别、终止阶段、public
Rust Result tag、共享身份 options 是否消费，以及 query attempt 数。首次 query
仍只在 bridge 安装完成后发送；generation 未建立时，最多允许在下一次 exact native
`swipe_start` 再查询一次。触发重试的当前物理流仍归小米原生路径，只有后续新流才可
发布 accepted-DOWN。

候选与实机安装值：

```text
version=0.8.5-android17-4371-arbiter-query-diag
versionCode=15
package=out/packages/miui-home-hyos-zn-20260815-012137.zip
package SHA-256=32bcc9b703b4f5587e4de12a355d42926064272e27b5f21419546c9618b9fdb7
native SHA-256=9e49447c4ee5fb299718f7ecd95def28a680b47f82c01634a0cd5a8941ff6582
installed=true
```

`ksud module install` 的逐文件 hash 校验、native 构建、BTI/PAC、tail shim 和
`hsctl` 检查均通过。受控 refresh 得到 spawner PID 9395、Launcher PID 9748，未
产生新 tombstone。第二次 query 的终态为：

```text
send_count=2
send_kind=1 (arbiter query)
send_state=14 (success)
result_tag=0
options_consumed=1
query_attempts=2
bridge_state=3
arbiter_ready=1
generation=34683115350
```

这证明 native public wrapper、private tail options 注入、SystemUI 收件与认证回包
已经闭环。第二次 query 与当次 `swipe_start` 同步触发，因此该流按设计保留给 Xiaomi；
下一条新手势才是 accepted-DOWN/SystemUI pilfer 的首个有效验证样本。

### 11.14 4371 普通返回的两阶段 pilfer 已确认

0.8.13 的 bounded ring 在同一条物理左边缘流中记录到：

```text
ACTION_DOWN: libapp_launcher + 0xbf07b0 -> pilferPointers
ACTION_MOVE: libapp_launcher + 0xc11a78 -> pilferPointers
monitor、MotionEvent ID、downTime、device、source、tid 全部相同
```

同时 `0xbf3684` processor 实际进入 78 次。静态字符串和 FDE 分析把第二个调用归到
`src/recents/gesture/gesture_input_home_helper.rs`。因此 accepted-DOWN 边界仍是
`0xbf07b0`；`0xc11a78` 是同一流稍后的重复 pilfer，不是新的返回入口。0.8.14 在
成功发布 token 后冻结完整 DOWN/monitor/generation 身份，只对同一身份的后续调用和
processor 做 fail-closed 抑制；新 DOWN、身份缺失或发布失败保持 Xiaomi 原生路径。

### 11.15 2026-08-15 映射文件事故与无属性恢复

一次开发部署用 `cp` 原位覆盖了仍被 PID 11393 及其子进程映射的 active native
模块文件。新旧 ELF 布局不同，随后派生的 `usap64` 在模块偏移 `0x1e2c` 执行到非法
指令，tombstone 04/05 均为 `SIGILL`；Launcher 因此无法启动，手势也随之消失。
这不是 `0xbf07b0` 接管逻辑的验证结果。

永久约束：不得覆盖或 truncate 一个仍被映射的 ELF。更新必须使用不同路径/不同
inode staging，在精确 owning spawner 停止或替换后才激活；禁止再次 `cp` 到 live
mapped `.so`。

按操作者要求，所有 Android property 控制已从 native、installer 与 `hsctl` 删除，
改为模块目录 `run/` marker。此前遗留的四个 persist 属性经一次明确授权使用
`resetprop -p --delete` 删除，随后只读验证全部为空。恢复流程没有写 `ctl.*` 或
RescueParty 属性：删除 markers、禁用 `miui-home-hyos-zn` ZN module、对 exact root
spawner 发 `SIGTERM` 并让 init 拉起。恢复后的 PID 23968 未注入本模块，且没有新增
tombstone；Launcher 尚未自动恢复，因此下一步必须由操作者重装 exact 4371 一次。

操作者完成重装后，只读核对显示 `versionCode=801024371`、
`versionName=RELEASE-8.01.02.4371-260727-08131546-R`，Launcher PID 703，
Home Activity 已 resumed。实验 module 仍为 disabled、`run/` markers 为空，故该状态是
未注入模块的 Xiaomi 原生手势基线。

### 11.16 0.8.16 激活失败与部署流程固化

0.8.16 将 Zygisk Next module enabled state 改为唯一运行 gate，修正了 native SELinux
域无法读取模块目录 marker 的错误假设。一次受控激活后，新 root `hyos_spawner` 已注入且
没有新 tombstone，但普通 Launcher 没有随 spawner 自动重建；设备停留在 Settings，侧边与
底部手势同时消失。立即禁用该 ZN module 并替换为未注入 spawner 后，Launcher 仍未自动
出现；一次标准 `MAIN` + `HOME` Activity 启动使 `com.miui.home/.launcher.Launcher` 以 warm
状态恢复。新 Launcher 的父进程是未注入 spawner，且没有模块映射。由此确认这次无手势的
直接原因是 Home 进程缺失，不是新的 native tombstone，也不是接管成功。

后续不再允许手工组合安装、文件替换、ZN reload 与 spawner 信号。仓库新增
`experiments/miui-home-hyos-zn/safe-device-test.ps1` 作为唯一主机入口；它验证 exact 4371
和单一 package SHA，使用不同路径/inode staging，核对 native SHA，先禁用 ZN；存在旧
mapping 时再替换 exact root/PPID-1 spawner，确认旧 ELF 已完全解除映射后才原子激活新文件。设备端 `hsctl` 只保留
`status`、`activate --confirm`、`rollback --confirm` 与日志读取；激活会显式启动 Home 并
核对 Launcher parent、ZN injection 和模块 mapping，失败自动回滚。测试判据固定为一次激活、
一次全新侧滑、一次证据采集，并且同一 session 必须连续出现 native accepted-DOWN 发布、
SystemUI 精确匹配/pilfer 与 Shell navigation start；广播 query/reply 或视觉效果不再作为
接管证据。

### 11.17 0.8.18/0.8.19 实机边界与 Android 17 carrier 透传

0.8.18 在 exact 4371 上保持稳定，首次手势只证明启动 query 早于 Launcher Runtime
ready：`send_state=2`、`generation=0`，没有 accepted-DOWN。0.8.19 在 processor 原函数
返回后执行唯一第二次 query；readiness warmup 后得到 `send_state=14`、
`arbiter_ready=1` 和有效 generation，且该 warmup 保持 Xiaomi 原生路径。

随后在 Settings/Wi-Fi 执行正式侧滑时，SystemUI spy 连续看到了新的边缘 DOWN，但 native
计数只有 `down_capture` 增长；`processor_entry`、`pilfer_hook_count`、`accepted_count` 和
`publish_count` 均不变，页面也没有返回。通过标准脚本禁用模块、替换 clean spawner 并启动
Home 后，同一页面的原生侧滑立即回到 `MainSettings`。这证明故障发生在模块启用并收到
arbiter 状态之后、accepted-DOWN 之前。

4371 ELF 的精确静态证据为：

```text
libapp_launcher.so + 0xbd749c..0xbddfec  receiver/Launcher 初始化函数
libapp_launcher.so + 0xbda084           构造 30-byte fsgesture action
libapp_launcher.so + 0xbda0bc           IntentFilter.addAction
libapp_launcher.so + 0xbda130           Broadcast_register_receiver
libhyper_os_broadcast_private.dylib.so + 0xe814
                                        BroadcastReceiver_TO::on_receive
```

私有 TO shim 从 receiver vtable `+0x18` 取 Xiaomi callback 后直接尾跳；0.8.19 的 marked
carrier 分支在该 shim 入口直接 `return`，因此不是“只吃模块 extras”，而是完整跳过了
Xiaomi 的 receiver callback。0.8.20 不增加 receiver、filter 或输入 hook：认证并记录状态后，
把同一个未修改 intent 交回原 callback。新增 `state_marked`/`state_passthrough` BSS 计数，
正式测试前二者必须同步增长。当前 clean rollback 基线正常；0.8.20 只在重新构建并经
`safe-device-test.ps1` 校验后才允许下发。

### 11.18 0.8.20 正式轨迹与 processor accepted-DOWN 修正

0.8.20 的 readiness warmup 成功得到 `send_state=14`、`arbiter_ready=1` 和有效
generation；`state_marked=1`、`state_passthrough=1` 严格同步，且
`processor_entry` 从 0 增至 54，证明 carrier 透传恢复了小米原 receiver 回调和手势区域
状态，没有新增 tombstone。

随后 Settings/Wi-Fi 的一次正式侧滑使 `processor_entry` 从 54 增至 109，MotionEvent
DOWN 捕获也继续增长，但 `pilfer_hook_count=0`、`accepted_count=0`、
`publish_count=0`。SystemUI 同时记录了匹配时间点的 spy-channel DOWN 候选，却始终等待
MiuiHome token。由此推翻 11.14 中“`+0xbf07b0` 必为普通手势 accepted-DOWN”的结论：
那是某些运行状态下出现的后续/旁路 monitor 行为，不是 GestureStub 原始 DOWN owner 的
必要边界。

4371 精确反汇编确认 `GesturesBackTouchProcessor` 位于 `+0xbf3684`，其 ABI 为
`(processor=x0, MotionEvent=x1, state=x2, mode=w3)`；原生函数在 `+0xbf3784` 首先对
`x1` 调用 `input_MotionEvent_getActionMasked()`。结合“redirect/exclusion 流不会进入
processor”的实机证据，0.8.21 把真实 `ACTION_DOWN` 定为 accepted-input 边界：在原生
状态机改变事件前冻结身份并发布；仅发布成功后按同一 event/downTime/device/source 身份
抑制 processor 至 UP/CANCEL。pilfer hook 不再发布 token 或触发 readiness retry，只保留
透明诊断，以及对已经由 processor 成功移交的同一物理流作防重复保护。

### 11.19 首次完整 handoff、Android 17 BackPanel 与 Launcher 重建

0.8.21 的正式 Settings/Wi-Fi 手势首次证明身份链路完整：SystemUI 候选 eventId/
downTime 与 native accepted-DOWN token 精确匹配，在 31px（超过固定 8dp outward
阈值）后由 SystemUI spy monitor 成功 `pilferPointers()`，Shell 返回
`BackNavigationInfo type=2` 并启动跨 Activity navigation。由此确认 0.8.21 的
processor-DOWN 定位正确。

该次释放仍未提交：Android 17 专用 `prepareNativeBackPanel()` 在
`installBackCallback()` 失败，MOVE/UP 随后也无法交给 `NavigationEdgeBackPlugin`，所以
原生 tracker 的 `actualTrigger=false`。当前 MiuiSystemUI 的 JADX/Smali 证明
`mBackCallback` 类型为 `EdgeBackGestureHandler$5`，但 R8 已完全删除其 `<init>`；stock
DEX 使用 `new-instance`、直接调用 `Object.<init>`、再写 synthetic `this$0`。Java 反射
因此返回零个 constructor，旧实现寻找 0/1 参数 constructor 必然失败。修复仅位于
`SystemUiAndroid17Impl`：仅对 owner 名称匹配且 constructor 数为零的精确类使用
`Unsafe.allocateInstance()`，写回 `this$0`，然后继续绑定 stock callback；不实现自定义
trigger/cancel/commit 逻辑，Android 16 不变。

手势后 Launcher 在没有新增 tombstone 的情况下被正常替换。新进程仍从已注入 spawner
fork 且映射 ZN module，但旧的跨进程 cache lease 导致 `bridge_state=4`、全部计数重新为零。
0.8.22 删除该过时 lease：每个 Launcher 进程依靠 process-local atomic state 安装一次，
同时保留 exact process、4371 ELF/Build ID、解析地址、原 GOT 值及代码指纹校验。这样只修复
正常 Launcher 生命周期，不扩大静态 scope，也不写 Android property。

### 11.20 Android 17 Panel 成功与 MiuiHome 输入 ANR

0.8.22 配合 Android 17 专用 BackPanel callback 修复后，实机已经绘制 A17 原生 panel，
accepted-DOWN 与 SystemUI spy 身份匹配，31px 左右完成 pilfer，Shell 多次得到标准
`TYPE_CALLBACK`；其中提交轨迹的 native tracker `actualTrigger=true`，证明 panel、阈值、
释放和 callback 已经贯通。

返回后的桌面退出不是新的 native tombstone。事件缓冲给出两次精确故障：

```text
12:14:21.230 am_anr com.miui.home
  [Gesture Monitor] swipe-up is not responding; waited 5001ms for MOVE
12:14:46.711 am_anr com.miui.home
  [Gesture Monitor] swipe-up is not responding; waited 5000ms for MOVE
```

两次进程均在 ANR 后被系统/用户杀死并正常重建。为避免再把 PID 替换误报成 native
crash，受控采集脚本现在固定保存 bounded crash buffer `crash-logcat.txt` 和筛选后的
`process-events.txt`；验证脚本要求两份证据都存在。

精确反汇编调用点 `+0xbf0918`、`+0xbf0b5c`、`+0xbf179c`、`+0xbf1898` 和
`+0xbf18ec` 在调用 `+0xbf3684` 后均不读取返回寄存器，因此 hook 的 `void` ABI 不是
ANR 原因。真正错误在流身份判断：0.8.22 把后续 MOVE/UP/CANCEL 的
`MotionEvent.getId()` 与 DOWN ID 比较；该 ID 标识单个事件对象而非完整 pointer stream。
结果是 DOWN 被抑制、MOVE 因 ID 改变而重新进入未收到 DOWN 初始化的小米 processor，最终
卡住 `swipe-up` monitor。

0.8.23 保留 eventId 作为跨进程 exact DOWN 认证字段，但 native ownership 的后续连续性
只使用不变的 downTime/device/source，并持续识别到同一流 UP/CANCEL；新 DOWN 仍通过完整
eventId/downTime/device/source/edge 身份替换旧 owner。

0.8.23 实机又给出更深一层约束。首次划动仍是 Xiaomi readiness warmup，随后 AOSP panel
正常绘制。一次 AOSP 取消在 `12:22:42.084` 完成，但其 DOWN 从 `12:22:39.507` 起已经泄漏
outer handler 的 Rust borrow，故 `12:22:44.514` 恰好报告 5 秒
`GestureStubRight` input-dispatch ANR，并在 `12:22:47` 杀死 Launcher；提交发生在新
Launcher 的 `12:22:52`，只是让退出更容易被观察到。

`+0xbf3684` 的 x2 是调用方预先取得的 Rust 状态 borrow，而不是可忽略的普通参数；统一尾部
`+0xbf52f0..+0xbf5360` 负责原子解锁、Arc release 和栈清理。因此即便调用方不读取返回值，
从函数入口 return 仍然必然泄漏 borrow。该入口级 suppression 已废弃。

FDE 把 outer 精确定界为 `+0xbf3684..+0xbf538c`。它只在四处调用内部事件业务分发器
`+0xc0fe28`（`+0xbf3c70`、`+0xbf5050`、`+0xbf5200`、`+0xbf52a4`），每次返回后均继续
outer 的 MotionEvent drop/统一清理；inner 自身 FDE
为 `+0xc0fe28..+0xc11d7c`。0.8.24 因此保留 outer hook 只做 accepted-DOWN 发布和 TLS
ownership 跟踪，但无条件调用原 outer；仅在 exact owned stream 进入 `+0xc0fe28` 时返回，
从而屏蔽旧箭头/注入/直接 OPEN-break 业务，同时保证 outer 的 borrow unlock 永远执行。
inner 先以透明模式安装，outer 后安装；两处均校验 4371 精确 prologue。当前设备已由标准
脚本安全回滚，Launcher 正常且无需重装。

### 11.21 0.8.24 窄边界稳定与 Android 17 WMShell 提交崩溃

0.8.24 的实机计数同时出现 `accepted_count=3`、`publish_count=2`、
`processor_boundary_return=8`，MiuiHome PID 7838 在整个正式测试中保持不变；这证明 inner
business-dispatcher suppression 已经消除旧 outer-entry hook 的 Rust borrow 泄漏和
GestureStub ANR。取消路径也能完成 stock Shell cleanup。

提交时退出的是 SystemUI，而非 MiuiHome。精确栈为：

```text
FATAL EXCEPTION: wmshell.main
Process: com.android.systemui
java.lang.NullPointerException
  at com.android.wm.shell.back.BackAnimationBackground
      .resetStatusBarCustomization(...)
  at com.android.wm.shell.back.CrossActivityBackAnimation
      $onGestureCommitted$1.onAnimationUpdate(...:27)
```

设备 `/system_ext/framework/Miui-WindowManager-Shell.jar` 已只读保存为
`refs/android17/miui-wmshell/Miui-WindowManager-Shell.jar`，SHA-256 为
`B919D0A3686786C2BCDAD476C9E1D0EC59D3CA02CD1E566B8FF72C0FA402F523`。JADX 和 smali
给出确定字节码：Android 17 的 `customizeStatusBarAppearance(int)` 与
`setStatusBarCustomizer(StatusBarCustomizer)` 都直接 `return-void`，但
`resetStatusBarCustomization()` 是 `const/4 p0, 0; throw p0`。也就是说 Xiaomi 已移除
状态栏定制，却保留了 AOSP cross-activity commit 的 reset 调用点，恢复该 animation 后必然
触发 NPE。

修复只由 `SystemUiAndroid17Impl` 解析并验证这组三个精确方法；Android 16 adapter 返回
无目标。运行时用 `systemui_a17_back_background_status_reset` 将损坏的 reset 替换为空返回，
不恢复或强制任何状态栏 appearance。因为 companion customize 方法从不把
`mIsRequestingStatusBarAppearance` 置真，这与 Xiaomi 已剥离功能的正常状态等价，并保留当前
窗口请求的状态栏外观。该 hook 已同时进入冷启动安装、旧 handle replacement、成功 presence
tracking 和 missing-hook backfill；Java 编译通过。native 0.8.24 仍保持安全回滚，等待新
SystemUI APK 安装后再通过唯一的 `safe-device-test.ps1` 重新激活测试。

正式测试先得到一次 readiness warmup：`send_state=14`、`arbiter_ready=1`，但
`publish_count=0`，因此仍由 Xiaomi 处理且取消后两个目标进程都保持稳定。下一次提交完整出现
`publish_count=1`、`processor_boundary_return=5`、SystemUI exact accepted-token match 和
39px pilfer；SystemUI 与 MiuiHome PID 分别保持 10658、19756，原来的
`BackAnimationBackground.resetStatusBarCustomization()` NPE 没有复现。

该次 Shell 返回的是 `BackNavigationInfo=null`，所以没有进入 cross-activity runner，而是命中
已认证的 AOSP null-navigation fallback。它同时暴露出另一处 Android 17 签名差异：旧版
`BackAnimationController.sendBackEvent(int action)` 已变成
`sendBackEvent(int action, int displayId)`，并新增 stock `injectBackKey(int displayId)`，由后者
同步发送唯一 DOWN/UP 对。修复仍隔离在 `SystemUiAndroid17Impl`：duplicate-pair guard 解析
双参数方法，fallback 调用 stock `injectBackKey(displayId)`；Android 16 adapter 继续使用原
单参数 DOWN/UP。displayId 从创建 InputMonitor 时冻结到 driver，不写死默认屏。热重载日志已
确认双参数 guard 安装成功，hook 总数从 30 增为 31，两个目标进程未重启。

### 11.22 redirected 流的负证据与复测边界

Android 17 双参数 `injectBackKey(displayId)` 修复热重载后，Settings、文件管理器、MT
管理器和 AyuGram 的多次物理侧滑都只在 SystemUI spy channel 产生 DOWN candidate，native
计数保持 `accepted_count=1`、`publish_count=0`、`processor_entry=39` 和
`processor_boundary_return=0`。因此这些轨迹没有到达 MiuiHome 的
`GesturesBackTouchProcessor` accepted-input 边界，不能验证新的 null-navigation BACK，也
不能验证 cross-activity commit。

为区分“没有进入 processor”和“processor 进入后发布失败”，受控采集脚本对 exact 0.8.24
ELF SHA-256
`10388972D3FED052285710D7B3DE8B895F3F6BAC71F711FEE9DAB32530599D78`
只读导出额外 BSS 计数。最后一次轨迹为：

```text
pilfer_hook_count=9
pilfer_caller_bf07b4=4
pilfer_caller_c11a7c=5
pilfer_caller_be8e98=0
pilfer_caller_c12e2c=0
pilfer_last_return_offset=0xc11a7c
pilfer_observation_sequence=9
```

这证明 Xiaomi 的 monitor/pilfer 路径在 processor 缺席时仍可能经过 `+0xbf07b4` 和
`+0xc11a7c`。它们不是 accepted-DOWN 的替代发布点：按当前输入所有权约束，redirect、排除区、
disabled 或 non-touchable 流若没有进入 processor，就不得伪造 token、重放或转交。因此不恢复
早期在 `+0xbf07b4` 发布 token 的实验实现；该 hook 继续只作透明诊断，以及对已经由 processor
成功移交的同一物理流作防重复保护。

最后一次用户提交前的前台是 AyuGram 根 Activity，提交后回到 Launcher；它既不是双 Activity
栈，也没有 accepted token，所以只是 Xiaomi 原生 `RETURN_TO_HOME` 负样本。SystemUI PID
10658 与 MiuiHome PID 28938 均保持稳定，没有新的
`BackAnimationBackground.resetStatusBarCustomization()` 崩溃。下一次精确提交复测应使用已
知能够产生 `TYPE_CROSS_ACTIVITY` 的文件管理器 `FileExplorerTabActivity ->
ImagePreviewActivity` 栈，并从物理屏幕边缘起手；其 manifest 明确声明
`android:enableOnBackInvokedCallback=false`，可避免把应用 callback 路径误当成 Shell
cross-activity runner。

### 11.23 Launcher 文本重映射、ZN 旧注册与 0.8.26 实机接管

0.8.25 进一步证明上述 redirected 现象不是文件管理器特有的输入路径。Launcher PID 28938
中，模块仍保存 `business_state=3` 和两个 trampoline，但 APK-backed launcher ELF 的
`+0xbf3684` 与 `+0xc0fe28` 已同时恢复为 4371 原始 prologue；MotionEvent PLT hook 仍然存活，
所以 `down_capture` 继续增长，而 accepted-token boundary 消失。第一次 lazy repair 将状态从
3 claim 到 1 后，重新调用 `inlineHook(+0xc0fe28)` 立即失败，目标字节仍保持原样。这说明
Launcher 子代生命周期不仅还原了目标 text，Zygisk Next 内部还保留着对应 target 的旧 inline
hook 注册；单纯根据代码字节重新 `inlineHook` 不足以恢复。

0.8.26 的修复仍只接受两处 exact 4371 prologue 同时出现。claim 成功后，它通过 Zygisk Next
API 对 inner、outer 两个旧 target 成对调用 `inlineUnhook`，要求两次都成功，再清空旧
trampoline 并按 inner -> outer 顺序安装；单边原始代码、任一 unhook 失败或重装失败均封闭。
它不直接写入已映射 ELF，也不修改 Android prop。新增 `business_repair_stage` 将 detect、
unregister、success、unhook failure、rehook failure 和 one-sided inconsistency 分别记录为
1..6。

0.8.26 安全部署后的文件管理器测试没有再次发生 text remap，因此 repair counter 保持 0；
这表示恢复分支本身在该进程代未被触发，不能把它记作已动态覆盖。readiness 取消手势先得到
`arbiter_ready=1`、generation `45626646158973`、`processor_entry=147`，且按设计
`publish_count=0`。随后正式提交完整进入 SystemUI：

```text
accepted_count=2
publish_count=1
processor_entry=155
processor_boundary_return=8
processor_suppressed=8
business_state=3
business_repair_attempts=0
```

SystemUI 在同一 DOWN identity 上记录 matched accepted token，38px 后 pilfer，Shell 返回
`BackNavigationInfo type=4`；release transaction 读取 native tracker 的
`actualTrigger=true`，以 `direct-callback` 完成返回。这里的实测目标是 `TYPE_CALLBACK`，不是
之前预期的 cross-activity runner，不能用来声称 `TYPE_CROSS_ACTIVITY` 已复验；但它明确证明
MiuiHome accepted-DOWN、SystemUI input ownership、pilfer、BackPanel/Shell progress、提交回调
这一整条 SystemUI-first 接管链已经恢复。hyos_spawner PID 13234、MiuiHome PID 13432 全程
稳定，未出现新的桌面、SystemUI 崩溃或 ANR。

### 11.24 共享 GestureInputMonitor 误认领与底部 Home 回归

0.8.26 长时间测试暴露出同一 native 边界的分类错误：底部 Home 完全失效，侧边 AOSP panel
出现时偶尔仍会漏出少量 Xiaomi arrow。原始输入确认有效底部轨迹从 `(666,2607)` 上划；Launcher
日志又确认下一次 `(566,2607)` DOWN 已被分类为 `gesture_type: Home`、`home_region=true`，但
随后的每个 MOVE 都在 `Started(Drag)` 状态下进入 `unexpected action in Up/Cancel branch`，只做
cancel passthrough，最终不能 pilfer 或提交。

同一 DOWN 还让模块向 SystemUI 发布了 `edge=1` token；SystemUI 因没有匹配的侧边 pending DOWN
而记录 `matchedPendingDown=false`，但 MiuiHome 线程已经把该物理流标为 SystemUI-owned。计数中的
`processor_suppressed=413` 证明共享 dispatcher 被大范围跳过，而
`owned_pilfer_suppressed=0` 排除了 pilfer hook 误拦底部的假设。0.8.26 的 remap repair 同时已在
实机成功运行两次：`attempts=2, successes=2, stage=3`。

4371 反汇编给出确定结构：`+0xbf3684` 是四参数共享 `GestureInputMonitor` outer，不是 side-only
GestureStub；它在 `+0xbf5028` 读取 outer state `+0x140` 的 gesture type，并在四个分支调用
`+0xc0fe28`。inner 的 `x0` 是 outer state `+0x10`，因此入口 `x0+0x130` 正是同一字段；入口只
接受值 1/2，设备日志对应 `1=Home`、`2=Back`。

0.8.27 因此不再从共享 outer 的任意 DOWN 发布 token。outer 只捕获 immutable MotionEvent
identity 并始终执行原函数和统一 borrow cleanup；inner 在 Xiaomi 完成分类后，仅对 exact
type 2 Back DOWN 发布 ownership，并且仅对 exact type 2 的同一物理流返回。type 1 Home 与未知
类型无条件调用 Xiaomi 原逻辑。设备已先通过标准脚本回滚，模块 disabled、无映射，Launcher
PID 4505，`reinstall_required=0`；修正版在重新部署前必须先通过 bottom Home、side cancel 和
side commit 三项分离验证。

### 11.25 4371 gesture type 枚举纠正

0.8.27 的首次底部验证成功保持 `accepted_count=0`、`publish_count=0`、
`processor_suppressed=0`，原生 Home Drag 完成 `fastPullUp -> homeToHome`。随后 readiness
预热得到 `arbiter_ready=1` 和 generation `45626646158973`，但第二次物理侧滑仍只显示 Xiaomi
指示器。采集显示 SystemUI 已建立同一时刻的 spy DOWN candidate；MiuiHome outer/inner 入口分别
增长，而 `accepted_count=0`、`publish_count=0`、`processor_suppressed=0`。其中 inner 从 100
增长到 190，排除了 hook 丢失、广播失败和 pending DOWN 缺失。

重新核对 exact 4371 原始入口：`+0xc0fe4c` 第一条业务指令就是
`ldr w8, [x0, #0x130]`，随后 `sub #1; cmp #2; b.hs`，所以有效枚举严格只有 1/2。真实侧边流
九十次进入 inner 却从未命中旧 type-2 gate，同时 Xiaomi Back 业务正常运行，证明 11.24 的枚举
名称推断写反：`1=Back`、`2=Home`。0.8.28 将唯一 ownership/suppression gate 改为 exact type 1，
并增加只读 `inner_gesture_type_last/type_1/type_2` 计数；偏移、inner 边界、bottom 原生透传和
SystemUI identity matching 规则均不改变。

上述 0.8.28 枚举结论在部署后的第一条分离底部轨迹即被反证，因此不得作为实现依据：用户确认
底部 Home 完整正常，同一采集却得到 `accepted_count=1`、`publish_count=0`、
`inner_gesture_type_last=1`、`inner_gesture_type_1=11`、`inner_gesture_type_2=0`。它之所以未破坏
底部，仅因为新进程的该流正好执行 readiness query，按规则不允许 publish。为避免下一条底部在
ready 状态下被错误接管，0.8.28 已立即通过标准脚本回滚：模块 disabled、无映射、hyos_spawner
PID 2792、Launcher PID 3250、`reinstall_required=0`。

因此确定结论恢复为 `type 1` 属于 Home；但不能再把“inner 未命中 type 2”反推为普通 side Back
就是 type 1。`+0xc0fe28` 是 outer 在多个分支复用的子 dispatcher，侧边流进入它可能只是 Home
取消/共享状态维护，而 Xiaomi Back 指示器与 accepted-input 业务仍位于 outer 的另一分支。下一步
必须定位 side-only 调用点或状态边界，禁止继续用 1/2 枚举猜测 ownership。

### 11.26 outer 返回状态、无效 helper 与 DOWN-time 分类器

0.8.29 将 `g_enable_systemui_ownership` 固定为 0，只增加 outer 原函数返回后的 DOWN 状态计数。
分离实测得到：底部 Home 的 inner 只出现 type 1，outer post-DOWN 也是 type 1；侧边取消虽然让
outer entry 增长 87 次并在 SystemUI 出现同时间 spy candidate，但 inner type 1/2 均不增长，
outer post-DOWN 为 type 0。因此侧边 Back 不经过 `+0xc0fe28` 的有效 1/2 分支。这里的 type 0
可能已经是 outer 的终态清零，不能直接当成 accepted-side 分类值。

0.8.30 又以完全透明方式测试了疑似 side helper `+0xc12e38`。Home 与 side 两条分离轨迹的
`side_dispatcher_count` 都严格保持 0，证明该函数不是这两类当前物理手势的业务入口，已从下一版
hook 集合移除。

exact 4371 反汇编显示 outer 在 DOWN 上调用 `+0xc12504(state+0x10, pointerCount, rawX, rawY)`。
该函数按多个矩形区域选择局部值 0/1/2/3，并在返回前通过 `str w23, [x19,#0x130]` 等路径写回
同一个 gesture-type 字段；所以它比 outer post-DOWN 更接近瞬时分类边界。0.8.31 用它替换无效
helper：原分类器完整返回后立即读取 `processor+0x130`，分别累计 type 0..3。它继续固定
`ownership_enabled=0`，不发布 token、不 pilfer、不抑制 Xiaomi 处理；三处 inline hook 的
prologue 校验、成组 unhook 和 remap repair 仍保持原子一致。

0.8.31 构建库 SHA-256 为
`51C35BCDBD4181236C823987174EE46588EC34935A3D059D063F3E64189B3F52`，安全部署后
hyos_spawner PID 31738、Launcher PID 32004，`business_state=3`、`ownership_enabled=0`、
`classifier_count=0`，没有新 tombstone。下一步只做分离的 bottom Home 与 side cancel，比较
分类器返回时的精确 type 增量；在这项证据完成前不得重新启用 ownership。

### 11.27 GestureStubViewWindow side-only 边界与 SystemUI 接管恢复

0.8.31 分离测试证明 `init_gesture_type(+0xc12504)` 仍不是可用 accepted 边界：bottom Home
出现一次 type 1，side cancel 出现一次 type 0；同一 type 0 也会被普通非手势触摸使用。side
轨迹中 inner type 1/2 均不增长，所以禁止从该枚举继续推断 Back。

exact 4371 符号与全镜像 xref 给出真正独立链路：

```text
hyper_os_ui::window::dyn_window_api::UiWindow_trait::on_window_motion_event
  +0x575308 ->
GestureStubViewWindow::handle_back_gesture (+0xc6e954)
  +0xc6e9a0 ->
GestureInputBackHelper::on_touch_event (+0xc073e0)
```

`handle_back_gesture(self,event)` 从 `self+0xec` 读取固定 edge，再把 `self+0xb8` 的唯一
BackHelper、edge 和原始 MotionEvent 传入 `on_touch_event`。0.8.32 透明探针的单次 side cancel
得到 DOWN 1、MOVE 103、UP 1、edge 1；随后完整 bottom Home 让共享 inner type 1 增长 57 次，
但 side handler 的总数、DOWN/MOVE/UP/CANCEL 全部严格不变。由此实机证明该入口就是 side-only
完整物理流边界，且 bottom 不经过它。

0.8.33 只在该入口启用 ownership：DOWN 现场重建 eventId/downTime/device/source/edge，要求
GestureStub edge 与坐标 edge 完全一致；readiness 未同步的第一条流完整交给 Xiaomi。成功发送
显式 identity-sharing accepted token 后冻结 generation，只有同一物理流跳过
`GestureInputBackHelper::on_touch_event`，并返回既有 UiWindow caller 完成原生事件清理。共享
`GestureInputMonitor::trigger_gesture` 已恢复为无条件调用原函数的透明诊断；replacement 或终止
UP/CANCEL 清除 ownership。静态验证脚本也改为强制新 side-only gate，并拒绝旧
`gesture_type == kGestureTypeBack4371` 所有权实现。

0.8.33 库 SHA-256 为
`82E1DDBA5684D3E46D2EB800E5E5E0331AF7AEE96E8C5241BB6FB77B794F330B`。bottom readiness
预热保持 `stub_back_count=0` 并得到 generation `45626646158973`。随后正式 side cancel：

```text
accepted_count=1
publish_count=1
processor_suppressed=3
processor_boundary_return=3
stub_back_down=1
stub_back_move=1
stub_back_cancel=1
stub_back_edge_last=0
```

MiuiHome 在 SystemUI pilfer 后收到 CANCEL，因此不再接收后续 UP，正好形成 DOWN/MOVE/CANCEL
三次同流抑制。SystemUI 日志确认 accepted token 的 eventId/downTime/edge/generation 全部匹配，
`matchedPendingDown=true`，63px 后 pilfer，Shell 返回 `TYPE_CROSS_ACTIVITY(type=2)`；本次取消
`actualTrigger=false`，AOSP panel 正常取消。hyos_spawner PID 9649、Launcher PID 9877 保持
稳定，没有 Xiaomi 指示器竞争或新崩溃。三目标 text remap 同期触发一次并成功修复，证明新的
side handler 已纳入成组生命周期。

### 11.28 A17 system_server 平台拆分与 prepared-transition 层级修复

首次成功提交 `TYPE_CROSS_ACTIVITY` 后，返回上一页的导航结果正确，但 A16 曾修复的
prepared-transition 层级异常复现。采集中的决定性证据不是 native ownership 失败，而是
system_server 冷启动和每次热重载均打印：

```text
Transition.calculateTransitionInfo five-argument overload not found
```

同一提交已进入 `TRANSIT_PREDICTIVE_BACK` 并保留 composed animation，但没有出现
`Normalized server cross-activity prepare role`。exact A17 `services.jar` 显示实际调用已从 A16
五参数形态改成：

```java
calculateTransitionInfo(type, flags, targets, startT, syncId, transitionStub)
```

此外 A17 已删除 `unifyBackNavigationTransition()`；其
`ScheduleAnimationBuilder.prepareTransitionIfNeeded(...)` 对所有非 `WindowState` target 直接创建
type 13 prepared transition。旧 runtime 因此同时存在两个错误版本假设：normalizer 只解析五参数
方法，且 schedule interceptor 仍查询已经不存在的 A16 flag。前者让 departing role 的
`TO_FRONT -> CHANGE` 和两个 predictive leash 的绝对 layer 重申完全没有执行；后者虽然以 false
继续调用原函数，没有直接阻断 A17 导航，但产生了错误路径描述并掩盖了 A17 始终 prepared 的事实。

system_server 现与 SystemUI 一样拆为独立平台实现：

- `SystemServerAndroid16Impl` 只接受五参数 `calculateTransitionInfo`，保留 A16 的
  `unifyBackNavigationTransition()` 分支和旧 setLaunchBehind 语义。
- `SystemServerAndroid17Impl` 只接受末参数为精确 `TransitionStub` 的六参数实现，不读取 A16 flag，
  始终保留 A17 原生 prepared-transition 调用。
- 公共 `SystemServerHookRuntime` 只保留两个版本共享的 immutable target shape 校验、departing role
  归一化和 start transaction layer 修复；平台按 exact 方法结构选择，不按模糊异常回退。
- `server_freeform_prepare_role_normalization` 继续作为同一语义生命周期 key。旧 handle 只有在
  `replaceHook(...)` 成功后才计入 presence；A17 旧构建中缺失的 normalizer 会在 hot-reload
  missing-hook backfill 中解析并安装到六参数方法。回填前重新从真实 system_server ClassLoader
  选择平台实现。

本地 `:app:compileDebugJavaWithJavac` 已通过。实机验收必须确认启动日志包含
`platform=android17, parameterCount=6`，提交时出现一次精确 shape 的 normalization 日志，并验证
返回后的目标层级、取消路径以及 A16 五参数路径均未被公共 A17 假设污染。

0.9.0 (46) 已通过 `adb install -r` 部署并由 API-102 hot reload 原位恢复。system_server 从旧构建
的 6 个 handle 成功替换并 backfill 为 7 个，日志确认选择 `android17` 且 normalizer 安装到
`parameterCount=6`。随后多条 cross-activity 轨迹均命中 exact A17 native prepared path；取消与
提交分别保持 `actualTrigger=false/true`，提交仍以 Shell `outcome=post-commit` 完成。对应 server
证据稳定为：

```text
Normalized server cross-activity prepare role,
transitionId=1157, changeIndex=0, mode=3->6, changed=true,
leashLayers=1/0, flags=0x8020400
```

左右 edge 的后续 transition 1155、1160、1165、1167 也得到相同 role、flags 与 layer 结果，没有
normalization failure、system_server/SystemUI/MiuiHome 崩溃。用户确认提交返回、取消以及返回后的
视觉层级完全正常，因此 A17 六参数 system_server 回归修复完成闭环。

### 11.29 A17 BackPanel 动态取色与弹出十字接缝

层级修复后，A17 原生 `BackPanelController` 的背景仍显示默认紫色。exact SystemUI 4371 的
`updateConfiguration$3()` 已被 Xiaomi 改成固定 material/blue-grey 组合，没有沿用当前系统动态
调色板。设备 overlay 查询证明 `android` 的 SystemUI dynamic/accent/neutral overlay 以及用户动态
主题 overlay 均处于启用状态；实际 light 配色为 `system_on_secondary_fixed=#ff041f20`、
`system_secondary_fixed_dim=#ffb0cccc`。`SystemUiAndroid17Impl` 因此只在 accepted-DOWN 的原生
panel 准备边界，从 `android` framework color resources 解析当前 night/light 对应的
`system_on_secondary_container/system_secondary_container` 或
`system_on_secondary_fixed/system_secondary_fixed_dim`，并写回现有 arrow/background Paint。
解析失败保持 Xiaomi 原色和原生 panel 可见；A16 实现不进入该路径。实机确认紫色已被当前动态
主题的青色背景与深色箭头正确替换。

取色正确后，用户发现背景只在弹出回弹峰值短暂出现十字裂缝。15 秒、约 55 fps 的实机录屏逐帧
证据排除了重复 MiuiHome/SystemUI 指示器和箭头 Path：裂缝是背景填充从 12/3/6/9 点向圆心延伸的
一像素透明辐条，随 `addRoundRect(RectF, float[8], CW)` 的四段圆角接合点出现；静止和后续拉伸
阶段消失。exact Dagger factory 同时确认 background Paint 由无 flags 的 `new Paint()` 创建，原生
几何、独立弹簧和每角半径本身与 AOSP 绘制结构一致。

单独开启 background Paint antialias 的第一版实机验证没有改变裂缝，证明它不是普通轮廓抗锯齿
缺口，而是 A17 硬件 Path 后端在圆形退化几何上的内部曲线细分接缝。最终修复没有替换
`onDraw()`、没有钳制 AnimatedFloat，也没有改进入态弹簧：只对 A17 的这个小型、visual-only
`BackPanel` View 设置 `LAYER_TYPE_SOFTWARE`，让同一个原生 Path 生成连续的软件覆盖层。release
APK 通过 `adb install -r` 热更新；SystemUI 原 PID 32741 内完成 31 个 hook replacement，重新创建
android17 panel、恢复 headless controller 与唯一 input monitor，arbiter generation 更新为
56261386589211。用户重复弹出回弹测试确认十字裂缝完全消失，颜色、箭头、手势状态和 Shell
导航均保持正常。

### 11.30 A17 cross-task 当前应用占据 entering 位置

`TYPE_CROSS_TASK` 恢复原生 `CrossTaskBackAnimation` 后，远程目标表面看似正确：当前应用 Task
以 `mode=1` 作为 closing，上一个应用 Settings Task 以 `mode=0` 作为 entering，两个 leash、全屏
bounds 和非透明状态也都有效。但拉住手势时，entering 卡片位置显示的仍是当前应用像素。一次
opening Surface 可见性补偿完整 show 了 1 个 Activity 及其 6 层父 Surface，视觉没有任何变化，
据此排除了 opening 层单纯被隐藏。

放宽旧版 `ChangeInfo` flags 过滤后，A17 六参数
`Transition.calculateTransitionInfo(...)` 给出了决定性证据：

```text
closing Task #20096: ChangeInfo flags=0x80,  TransitionInfo mode=3, flags=0x8020000
opening Task #20042: ChangeInfo flags=0x110, TransitionInfo mode=3, flags=0x28000
```

即 Xiaomi 4371 把两个标准全屏 Task 都发布为 `TO_FRONT(3)`。closing Task 已经位于前台，却在
prepared transition 中再次承担 opening role，导致后续 Shell reparent 后其像素出现在 entering
动画位置；故障与已修复的 A17 cross-activity departing-role 异常同源，但 shape 和 flags 不同。

`SystemServerAndroid17Impl` 现只对该精确标准全屏双 Task shape 执行补偿。它验证 native
`BackWindowAnimationAdaptor` 的 open/close 身份、Task 与 animator/leash 归属、predictive animation
type、可见请求、同一 display、相同非空全屏 bounds、精确 flags、空 parent/lastParent、绝对 layer
以及原 start transaction。全部成立后，仅把 closing Change 的 `TO_FRONT` 改为 `CHANGE(6)`，保留
opening Change 为 `TO_FRONT`，并在原 start transaction 中重申两个 native predictive leash 的
既有 `23/22` 层级。没有交换 `RemoteAnimationTarget`，没有改 leash 矩阵、crop、alpha 或原生
`CrossTaskBackAnimation` 几何。

debug APK 经 `adb install -r` 和 API-102 hot reload 原位部署；system_server 8 个 hook 与 SystemUI
32 个 hook 均完成替换。验收 transition 1876 记录：

```text
Normalized Android 17 cross-task prepare role,
closingTaskId=20096, openingTaskId=20042, mode=3->6, leashLayers=23/22
```

同一记录的 `changesAfter` 仅 closing mode 变为 6，opening mode/flags 及双方 bounds、parent 均未
变化。用户实机确认拉住时上一应用回到正确位置，当前应用不再占据 entering 卡片，cross-task
视觉层级恢复正常。
