# 09 · MCM 通道 B 实战用法

> 回答一个问题：这条链**具体怎么用**、每一步失败长什么样、失败了看哪里。
> 不讲源码封装，只讲动作、判据、命令。

---

## 0. 一句话

用法的全部内容就一件：**让 containermanagerd 相信你是苹果的 MobileHouseArrest 客户端，然后按它的档位领取每个容器的 sandbox extension token。**

拿到 token 之后，读文件没有任何技巧——`NSFileManager` 就能读。

所以整条链只有两个动作有技术含量：
1. 把身份造对（签名层）
2. 把 token 领到手（授权层）

其余都是收尾。

---

## 1. 动作一：造身份

### 1.1 三个字段必须同时对上

| 位置 | 值 | 现状 |
|---|---|---|
| `Info.plist` → `CFBundleIdentifier` | `com.apple.mobile.MobileHouseArrest` | 已设 |
| `entitlements.plist` → `application-identifier` | `<TEAMID>.com.apple.mobile.MobileHouseArrest` | 已设（`$(AppIdentifierPrefix)` 由签名时注入） |
| `entitlements.plist` → `keychain-access-groups` | 同上 | 已设 |

containermanagerd 比的是**签名里的 code identifier**，不是运行时 `NSBundle.bundleIdentifier`。
所以光改 Info.plist 没用，entitlements 里那一行才是真正被读的。

### 1.2 真正的卡点：App ID 怎么过审

`com.apple.mobile.MobileHouseArrest` 这个 App ID 属于苹果，开发者后台注册会直接失败（"not available"）。

唯一能绕过的组合：

```
企业证书（In-House）+ 通配符 App ID（TEAMID.*）的 provisioning profile
```

通配符 profile 的 `application-identifier` 是 `TEAMID.*`，能匹配任何 bundle id，所以
`TEAMID.com.apple.mobile.MobileHouseArrest` 合法。

通配符的代价——不能带这些 entitlement：

- App Groups（要具体 App ID）
- Push
- Associated Domains

**MCM 不需要这三样，所以这个代价是零。** 但 §1.4 的 app-group 采集（class 7）也需要
App Group 容器访问权——注意区分：**访问别人的 group 容器**靠 MCM token，**自己声明 group** 才需要 App Groups entitlement。前者不需要。

### 1.3 签名顺序（必须严格）

```
1. Frameworks/ 下 9 个 exploit framework + libxpf.dylib
2. 根目录 libjailbreak.dylib、libchoma.dylib
3. 主程序 OPENsrc（最后）
```

用 zsign 强推 entitlements，不要指望工具自动推断：

```bash
zsign -k inhouse.p12 -p <密码> -m wildcard.mobileprovision \
      -e entitlements.plist -o OPENsrc-signed.ipa OPENsrc.ipa
```

签完必须回读校验三件事，缺一不可：

```bash
# 1. 主程序 entitlements 里 application-identifier 是不是 MHA
codesign -d --entitlements :- Payload/OPENsrc.app/OPENsrc

# 2. bundle id 是不是 MHA
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Payload/OPENsrc.app/Info.plist

# 3. 每个 framework 的签名链是否完整（漏签一个 = 启动闪退）
codesign -vvv --deep --strict Payload/OPENsrc.app
```

### 1.4 这一步唯一的未知

**iOS 的安装链会不会拒绝 `com.apple.` 前缀的第三方 bundle id。**

没有公开的硬性规则禁止，但 InstallCoordination / CoreTrust 对苹果命名空间可能有特殊处理。
这是整条链**唯一没有实测过**的环节，且失败表现和其他环节完全不同：

| 现象 | 说明 | 结论 |
|---|---|---|
| 装不上 / 安装器报错 | 安装层就拒了 | 身份这条路走不通，要么换真实 MHA 的 identifier 结构，要么放弃 |
| 装上但点开即闪退 | AMFI 在 `execve` 拒了签名 | 签名不自洽（见 §1.5） |
| 能启动，B2 FAIL | 身份没被 containermanagerd 认 | 签名 OK，但 code identifier 比对没过 |
| 能启动，B2 OK，B4 token=0 | **身份认了，档位不够** | 苹果收窄了授权，见 §3.3 |

**这四种现象必须分开对待，混在一起就会得出"通道 B 不行"的错误结论。**

### 1.5 闪退的常见原因是签名不自洽，不是身份

沿用 `hc888-签名规范-定案.md` 的结论：`_CodeSignature` 条目为 0 且内嵌 CodeDirectory 失配
→ 必然闪退。源码版是 CI 出 ad-hoc 包再重签，重签工具会重算 CD，所以这条通常不会踩。
但如果手工改过 Info.plist 又没重签，一定踩。

---

## 2. 动作二：领 token

### 2.1 领的顺序（这个顺序不能反）

```
枚举容器（拿 UUID + path）
  → 对每个容器 copy sandbox token
    → consume
      → 立刻读文件
        → release
```

关键：**token 不是枚举时自动给的，是逐个申请的。** 申请被拒的那一瞬间就是全部失败点。

### 2.2 自检六项 = 这条链的仪表盘

跑一次自检，按这个顺序读结果，第一项 FAIL 就是根因所在，后面的不用看：

| 项 | 通过含义 | FAIL 的根因 |
|---|---|---|
| B0 库加载 | `libsystem_container.dylib` 可用 | 系统版本改了库路径（罕见） |
| B1 符号 | 18 个 API 全部解析到 | 苹果删/改了接口（版本天花板） |
| **B2 身份** | code identifier = MHA | 签名层没生效，回 §1 |
| B3 枚举 | class 2 拿到 N>0 个容器 | N=0 → 身份过了但查询被拒；或设备真没装 App |
| **B4 token** | 至少一个容器给 token | **授权档位不够 —— 18.7/26 的核心症状** |
| B5 真读 | 能列出并读到文件内容 | token 拿到了但路径不对，或 Data Protection 挡了 |
| B6 LS 映射 | UUID 能反查到 bundleId | 只影响"知道拿的是谁"，不影响拿到数据 |

**判读铁律：B3 > 0 但 B4 全 0，就是授权被收窄，不要再怀疑签名。**
反过来 B3 = 0，才是身份或查询参数的问题。

### 2.3 lease 池：3 是上限，不是配额

现场 `active_leases=3` 说明 containermanagerd 对单客户端同时持有的 extension 有硬上限。

**正确用法是一次只持 1 个**：

```
取容器A → 领token → 读完A → release → 取容器B → 领token → 读完B → release
```

错误用法（也是最常见的实现错误）：先枚举 500 个容器，全部领 token 再统一读。
结果就是前 3 个成功、后面全部 `EPERM`，看起来像"只有 3 个容器能读"。

这个上限是苹果的反制设计，目的是让攻击者没法一次性把全设备容器端走。
**它不能提高，只能顺着它做流水线。**

---

## 3. 失败定位：抓 containermanagerd 的拒绝理由

### 3.1 Windows 上就能抓（不需要 Mac）

工作区已有 `pymobiledevice3`：

```bash
pip install pymobiledevice3

# 确认设备连上
python -m pymobiledevice3 lockdown info

# 只盯 containermanagerd（走 os_trace，不是旧 syslog）
python -m pymobiledevice3 syslog live --process-name containermanagerd
```

Mac 上等价：

```bash
log stream --device --predicate 'process == "containermanagerd"' --level debug
```

抓的时候在设备上触发一次扫描，然后只看这几类关键字。

### 3.2 拒绝理由 → 对策对照表

| 日志关键字 | 真实含义 | 对策 |
|---|---|---|
| `denied ... entitlement` | 缺某个 `com.apple.private.container-manager.*` | 补 entitlement 重签，逐个试 |
| `denied ... code signing identifier` | 身份不认 | 查 profile 的 App ID 与 bundle id 是否真的一致 |
| `too many leases` / `lease limit` | lease 池满 | 改成用完即放（§2.3） |
| `no such container` | 目标没装 / 从没启动 | 不是通道问题 |
| `sandbox extension ... invalid` | token 过期或被撤 | 缩短"领到→读"的间隔 |
| 什么都没有，直接 EPERM | 很可能在 seatbelt 层就被拦，没走到 MCM | 说明连 token 都没拿到，回头看 B4 |

**这一条日志是整个项目当前最值钱的信息**——它能一次性区分"身份问题"和"档位问题"，
而这两者的修法完全不同，靠猜就是赌。

### 3.3 18.7.x / 26.x 的 EPERM 到底可能是哪种

三种可能，按概率排序：

1. **MHA 档位被收窄**——不再 class 通吃，只给"自己 lease 的容器"或要求额外 entitlement。
   症状：B3 > 0，B4 = 0。对策：补 `com.apple.private.container-manager.*` 逐个试。
2. **身份校验升级为绑定 team**——要求 code identifier 的 team 是苹果。
   症状：B2 FAIL 或 B3 = 0。对策：这条路基本封死，只能等新的身份载体。
3. **lease 机制改造**——新增"申请者必须是容器属主"的校验。
   症状：B3 > 0，B4 部分成功（只拿到自己容器的）。

**先抓日志再动手，不要同时改三样。**

---

## 4. 三个"跑通但零数据"的坑

这三个坑的共同点：日志全绿、自检全过、上传成功、内容是空的。

### 4.1 BFU / 锁屏

`NSFileProtectionComplete` 类文件在首次解锁前是密文，读出来是空或报错。

**必须先判 `protectedDataAvailable`，为 NO 就等 `UIApplicationProtectedDataDidBecomeAvailable`。**
不等直接扫 = 把"文件被加密"误判成"设备上没装钱包"，然后写 done，永久零数据。

### 4.2 容器是空壳

目标 App 从没启动过 = 容器存在但没数据。
OKX 那两台"35 张表全 0 行"就是这种，**不是解密失败**。

判据：容器 `metadata.plist` 的创建时间 / `Library/` 下有没有业务目录。

### 4.3 oversized skip 误伤

按体积门限跳大文件时，关键小文件（keystore、keychain 类、`main.sqlite3` 的 -wal）
绝不能进 skip 名单。wal 文件常常比主库还关键。

---

## 5. 完整操作顺序（从 CI 产物到有数据）

```
[1] CI 出包 → OPENsrc-ipa（ad-hoc，不能直接装）
[2] 企业签 + 通配符 profile + MHA entitlements（§1.3）
[3] 回读校验三件事（§1.3 末尾）
[4] 装机。先看能不能启动：
      装不上    → 身份路线判定失败（§1.4 第一行）
      闪退      → 签名不自洽（§1.5）
[5] 打开 OWSelfTestOnLaunch，读 Documents/ow_debug.log
      按 B0→B6 顺序找第一个 FAIL
[6] 若是 B3/B4 问题 → 开 containermanagerd 日志抓拒绝理由（§3.1）
[7] 按 §3.2 对照表定向修，一次只改一样
[8] B4 token=1 且能列出 .sqlite → 通道 B 打通
[9] 再谈数据质量（§4 三个坑）
```

---

## 6. 这套用法的边界（必须记住）

**能拿到**：任何已安装 App 的容器内**全部文件字节**，包括加密的数据库本体。

**拿不到**：
- 明文（要 class keys，那是通道 A 的产出，或服务端离线解）
- 系统库（短信/通讯录，要 root）
- BFU 状态下的 Complete 保护文件

**不会失效**：不依赖任何内存破坏，PAC/PPL/KASLR 与它无关。苹果只能靠收窄档位反制，
不能"修好"它——因为它不是 bug，是 MHA 的合法能力被冒用。
