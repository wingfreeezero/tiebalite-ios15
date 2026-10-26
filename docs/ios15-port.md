# iOS 15 移植说明（TiebaLite-IOS）

本分支把上游「最低 iOS 17」的原生客户端降到 **iOS 15.0**，同时**彻底关闭 iOS 26 的液态玻璃**。
改动集中在「系统件在 15 上没有」的地方，其余业务代码一行未动。

## 1. 构建配置

| 文件 | 改动 |
|---|---|
| `.bazelrc` | `build --ios_minimum_os=17.0` → `15.0` |
| `BUILD.bazel` | `minimum_os_version = "17.0"` → `"15.0"`；删掉 `extensions = ["//Extensions/TiebaLiveActivity:extension"]` |
| `TiebaLite/Info.plist` | `LSMinimumSystemVersion` `17.0` → `15.0` |

## 2. 新增兼容层

`Sources/TiebaNative/Compat/TiebaIOS15Compat.swift`

* **`TiebaContentUnavailableConfiguration` / `TiebaContentUnavailableView`** —— iOS 17 `UIContentUnavailableView`
  的替身。字段名与系统一致（`image` / `text` / `secondaryText` / `button` / `imageProperties` /
  `textProperties` / `secondaryTextProperties` / `buttonProperties`），所以 20 个调用点只把类型名
  从 `UIContentUnavailable*` 换成 `TiebaContentUnavailable*`，语义与用法不变。
* **`TiebaGlass.isEnabled = false`** —— 液态玻璃总开关（见第 4 节）。

## 3. 逐项处理

| 系统件 | 起于 | 处理 |
|---|---|---|
| `UIContentUnavailableView/Configuration` | iOS 17 | 换成本仓实现（类型名重命名，20 个文件） |
| `registerForTraitChanges` | iOS 17 | 13 处调用包进 `if #available(iOS 17.0, *)`；trait 令牌属性类型 `UITraitChangeRegistration?` → `AnyObject?`。iOS 15 上不做实时 trait 刷新 |
| `UIEditMenuInteraction` | iOS 16 | 装配/弹出/收起全部 `#available(iOS 16.0, *)`；delegate 扩展加 `@available(iOS 16.0, *)` |
| `UITextViewDelegate.textView(_:primaryActionFor:defaultAction:)`（`UITextItem`） | iOS 17 | 方法加 `@available(iOS 17.0, *)` |
| `textView(_:editMenuForTextIn:suggestedActions:)` | iOS 16 | 方法加 `@available(iOS 16.0, *)` |
| `UISheetPresentationController.Detent.custom(identifier:resolver:)` | iOS 16 | 15 上退化为 `.medium()` / `.large()` 两档 |
| `Task.sleep(for:)` | iOS 16 | 改成 `Task.sleep(nanoseconds:)`（2 处） |
| `UIFont.Width` / `UIFontDescriptor.TraitKey.width` | iOS 16 | 15 上忽略自定义字宽（退回系统默认宽度） |
| `UIWindowScene.effectiveGeometry` | iOS 16 | 15 上读 `scene.interfaceOrientation` |
| ActivityKit / Live Activity | iOS 16.1 | 整条链路改空实现 + 移除扩展目标（见第 5 节） |

## 4. 移除液态玻璃

上游把「玻璃」收在一个入口 `TiebaGlassContainerView.makeEffect(...)`，另有若干
`UIButton.Configuration.glass()/.prominentGlass()` 分支，全部包在 `#available(iOS 26.0, *)` 里。

移植版给这些分支再加一个与条件：

```swift
if #available(iOS 26.0, *), TiebaGlass.isEnabled {   // isEnabled == false
  // 液态玻璃
} else {
  // iOS 17/18 的经典材质：UIBlurEffect(.systemUltraThinMaterial) / .gray() / .filled()
}
```

覆盖 9 个文件 15 处（顶栏、底栏、导航条、相册顶栏、表单胶囊、空态按钮、更新弹窗卡片等）。
结果是：**iOS 26 上也只走经典材质**，iOS 15 本来就没有这层效果。

另外 `TiebaLite/Info.plist` 里加了 `UIDesignRequiresCompatibility = true`：这是 Apple 官方给
「用 iOS 26 SDK 编译但想保持旧设计」的 App 的开关，管的是系统自绘的部分（导航栏 / 底栏 / 弹窗 /
菜单材质）。有了它 + 上面的总开关，**系统件与自绘件都不会出液态玻璃**。

## 5. Live Activity 为什么整个拿掉

`import ActivityKit` 会在主二进制的 `LC_LOAD_DYLIB` 里写死
`/System/Library/Frameworks/ActivityKit.framework/ActivityKit`。iOS 15 的 dyld 找不到这个框架会直接
`Library not loaded` 闪退（`@available` 只影响符号弱引用，不影响 dylib 的加载方式）。
要让 15 能启动，只能：整包弱链接（`-weak_framework`，Bazel 下与 autolink 的 `-framework` 冲突，不可靠），
或者不引入这个框架。移植版选后者：

* `Sources/TiebaNative/Core/LiveActivity/TiebaLiveActivity.swift` → 空实现（`areActivitiesEnabled()` 恒 `false`）；
* `Sources/TiebaNative/Core/LiveActivity/LiveActivityKitAttributes.swift` → 去掉 `ActivityAttributes` 一致性，
  字段/`init(raw:)` 原样保留，调用点不用改；
* `BUILD.bazel` 不再内嵌 `//Extensions/TiebaLiveActivity:extension`。

副作用：一键签到的「灵动岛/锁屏」进度不再出现（iOS 15 本来也没有），签到完成的前台本地通知仍走
`TiebaNotificationCenter`。

## 6. iOS 15 上的功能差异（均为优雅降级，不是崩溃）

1. 系统深浅色 / 字号切换不会**实时**重绘页面，重开 App 生效（15 上没有注册 `registerForTraitChanges`）。
2. 正文长按选词仍有选择高亮与拖拽手柄，但**不弹编辑菜单**（复制/查询/分享）——`UIEditMenuInteraction` 是 16 起；
   行尾「更多操作」（…）按钮里的「复制内容/分享/复制链接」不受影响。
3. 帖子正文里点链接不再弹「显示文字与真实地址不一致」的确认框（该 delegate 回调是 17 起）。
4. 半屏表单用 `.medium()` / `.large()` 两档，不再有 0.3/0.55/0.9 这类自定义比例。
5. 窄体/宽体字宽（`.condensed` / `.expanded`）在 15 上按标准宽度渲染。
6. 无 Live Activity。
7. 无任何液态玻璃（任何系统版本）。

## 7. 出 IPA 的两条路

编译这一步必须有 **macOS + Xcode 26**（源码里 iOS 26 的液态玻璃分支要 26 SDK 才编得过，部署底线又是 15.0，
只有这一个组合同时满足）。除此之外不需要任何 Apple 账号 / 证书 / secret。

### A. 有 mac：一条命令

```bash
bash scripts/build-ipa.sh            # Release（默认）
bash scripts/build-ipa.sh debug      # Debug
# 产物：dist/TiebaLite-2.2.0-iOS15.ipa
```

脚本按 6 步走，任何一步不对就停：

| 步 | 做什么 | 挂了意味着 |
|---|---|---|
| 0 | `uname`/`xcodebuild`/SDK 版本、缺 bazelisk 就 `brew install` | 不是 mac 或没装 Xcode 26 |
| 1 | 配置层部署底线自检（`.bazelrc` / `BUILD.bazel` / `Info.plist` 三处都得是 15.0，且没有内嵌 appex） | 移植被改回 17 |
| 2 | 写 `.bazelrc.user`（磁盘/仓库缓存），二次构建十几秒 | — |
| 3 | 现场生成 `Signing/*.mobileprovision` 占位件（ad-hoc 身份下 rules_apple 不拿它签名） | openssl 不可用 |
| 4 | `bazel build //:AppStripped --config=ci --config=release` | 还有 availability 编译错误（见第 9 节工具） |
| 5 | unzip + 重打包 IPA | — |
| 6 | 产物层三道硬门槛（见第 8 节） | 出一个「看着像 15、其实装不上」的包 |

### B. 没有 mac：GitHub Actions（零 secret）

1. 把这个目录推到你的仓库（fork `toamdou/TiebaLite-IOS`，或新建空仓后 `git push`）；
   *首次 push 进去的 workflow 需要在仓库 **Actions** 页手动点一次启用。*
2. 仓库页 → **Actions** → **Build iOS 15 Unsigned IPA** → **Run workflow**
   （`configuration` 选 Release；`tag_name` 留空则只出 Artifact、不发 Release）；
3. 跑完在该次运行页底部下载 Artifact **`ipa-ios15`**，里面是
   `TiebaLite-2.2.0-iOS15-<commit>.ipa`（若填了 tag 则是 `TiebaLite-<tag>.ipa`）。

工作流与本地脚本跑的是同一套自检，CI 里额外多打一份 `$GITHUB_STEP_SUMMARY`。

### C. Windows / Linux 上能做的部分

能改代码、能跑静态自查（第 9 节）、能打包源码；`xcodebuild` / Apple 的 arm64 链接器只在 mac 上，
所以 IPA 只能在 A 或 B 出。

## 8. 产物自检（脚本与 CI 共用同一套判据）

| 检查 | 判据 | 为什么必须查 |
|---|---|---|
| `Info.plist` | `MinimumOSVersion == 15.0` 且 `LSMinimumSystemVersion == 15.0` | 安装器按这个字段拦；写错就是「装不上」 |
| Mach-O | `LC_BUILD_VERSION → minos 15.0`（`xcrun vtool -show-build`） | 只有 plist 降到 15、二进制还是 17 的包，在老机器上是启动即崩 |
| 依赖框架 | `otool -L` 里**不许有** `ActivityKit.framework` | dyld 找不到框架会直接 `Library not loaded`，`@available` 保不住 dylib 加载 |
| 内嵌扩展 | 不许有 `PlugIns/*.appex` | appex 的 `MinimumOSVersion` 比 app 高时整包装不上 |

## 9. 静态校验记录（2026-10-26）

没有 Xcode 的情况下能验的都验了，工具留在 `scripts/verify-port.py`（跨平台，`--self-test` 可自证）：

```bash
python3 scripts/verify-port.py            # 未兜住的可用性命中 → 退出码 1
python3 scripts/verify-port.py --all      # 连已兜住的命中一起列
python3 scripts/verify-port.py --self-test
```

| 项 | 结果 |
|---|---|
| 改动面 | 相对上游 v2.2.0：**改 44 个文件、新增 2 个**（`Compat/TiebaIOS15Compat.swift`、本文档），diff ≈ 1.3k 行 |
| 可用性扫描 | 63 处「≥ iOS 16/17/18/26 的系统件」命中，**全部**被 `#available` / `@available` 兜住，未兜住 **0** |
| 语法 | tree-sitter 解析 768 个 `.swift`：报错 8 个，与上游基线**完全一致**（tree-sitter 自身的语法缺口，非真错）⇒ 改动没引入新的语法问题 |
| 配置层 | `.bazelrc --ios_minimum_os` / `BUILD.bazel minimum_os_version` / `Info.plist LSMinimumSystemVersion` 三处都是 15.0；`extensions = [...]` 已摘除 |
| protoc 可见性 | 267 个 `*.pb.swift` 全部含 `public` 声明（CI 的拆分前置条件满足） |
| 真编译 | **已通过**：Actions run `40322555788`（macos-26 / Xcode 26.5 / Bazel 9.2.0），commit `c77a1e5`；产物 arm64 `minos 15.0.0 sdk 26.5.0`、无 ActivityKit、无 appex |
| 真机运行 | 未做（手上没有 iOS 15 设备），启动验收请在你机器上完成 |

## 10. 已知风险（务必先读）

* **已真实编译通过（2026-10-26）**：GitHub Actions `macos-26` + Xcode 26.5 上跑通了
  `bazel build //:AppStripped --config=ci --config=release`（run `40322555788`，commit `c77a1e5`），
  产物 `TiebaLite-2.2.0-iOS15.ipa`：arm64、`LC_BUILD_VERSION minos=15.0.0 / sdk=26.5.0`、
  `MinimumOSVersion=15.0`、56 条 `LC_LOAD_DYLIB` 里没有 ActivityKit、无 `PlugIns/`、无内嵌 `Frameworks/`。
  第一次真编暴露并修掉了 4 处只有编译器能发现的可用性问题（静态扫描覆盖不到的类型级用法）：
  `UNUserNotificationCenter.setBadgeCount` ×2（iOS 16）、
  `NSCollectionLayoutGroup.horizontal(layoutSize:repeatingSubitem:count:)`（iOS 16）、
  以及兼容层里误用了非公开的 `UIAction.handler`（改成 `UIButton.addAction(_:for:)` + 按 `identifier` 摘除）。
* **未经真机运行验证**：没有 iOS 15 设备在手，启动/崩溃只能由你在机器上验收。
* **iOS 15.0 ~ 15.3 的并发运行时偏旧**：Swift 6 编译器生成的代码依赖系统自带的 `libswift_Concurrency`；
  15.0~15.3 那一版较旧，若启动即崩，优先在 **15.4+** 上验证。
* 只保证 iPhone/iPad 的 **arm64 真机**构建（上游 CI 口径），模拟器未验证。
* 产物的代码签名是「空签名」（`LC_CODE_SIGNATURE datasize=0`，`//:AppStripped` 剥符号时一并剥掉）：
  TrollStore 导入时会自己 ldid 签名，SideStore / AltStore / Sideloadly 也是重签后再装，均不受影响。
* 与上游 iOS 17 版的差别请对照第 6 节：Live Activity 整条链路空实现、任何系统版本都没有液态玻璃、
  少数 iOS 16/17 才有的交互（编辑菜单、自定义 detent、实时 trait 刷新、字宽）在该系统版本以下优雅降级。
