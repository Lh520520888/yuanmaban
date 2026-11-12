# MCM 容器通道 · 原理与实现规格（定案）

> 2026-11-08 · 从目标包 `libuiopsersvc` 二进制取证 + Apple libcontainer 公开 API 交叉验证
> 适用：源码版 `src/Container/OWContainerPass` 重写依据

---

## 0. 一句话结论

**MCM 通道的本质不是「调私有 ObjC 类拿路径」，而是「向 containermanagerd 申请一个 sandbox extension token，消费它，之后普通文件 IO 就能读目标容器」。**

没有 token 这一步，枚举出路径也读不到任何字节（`EPERM`）。

---

## 1. 从目标包取证到的真实符号

在 `Payload/OPEN.app/Frameworks/libuiopsersvc.framework/libuiopsersvc`（903,616 B）中提取到的证据：

### 1.1 libcontainer C API（实打实的函数名）

```
container_query_create
container_query_free
container_query_set_class
container_query_set_identifiers
container_query_set_group_identifiers
container_query_operation_set_flags
container_query_operation_set_part
container_query_operation_set_part_domain
container_query_iterate_results_sync
container_query_get_next_result        ← 真正的迭代接口（取完返回 NULL）
container_query_get_single_result      ← 仅用于「恰好一个结果」的查询
container_query_get_last_error
container_object_copy
container_object_free
container_object_get_identifier
container_object_get_path
container_object_sandbox_extension_activate
container_copy_sandbox_token
container_error_get_message
container_error_get_posix_errno
```

### 1.2 sandbox extension API

```
sandbox_extension_consume
sandbox_extension_issue_file
sandbox_extension_issue_file_to_self
sandbox_extension_issue_mach
sandbox_extension_free
```

导入符号表确认（`libuiopsersvc` 直接导入）：
```
_sandbox_extension_consume       type=1 (import)
_sandbox_extension_issue_mach    type=1 (import)
```

### 1.3 身份检查（硬性）

```
'[MCMFilza] disabled: signed code identifier %@ must be %@ (bundle=%@)'
'ned code identifier is not the required MCM caller identity'
'com.apple.mobile.MobileHouseArrest'
```

**签名身份必须是 `com.apple.mobile.MobileHouseArrest`**，否则 MCM 直接被禁用。

### 1.4 容器类别（目标包实际使用的 class 编号）

```
class 2   application-data            App 的 Data 容器（Documents/Library/tmp）
class 4   extension-data              App Extension
class 6   VPN-data                    VPN 插件
class 7   app-group                   App Group 共享容器（备忘录在此）
class 10  service-data
class 12  system-data
class 13  scoped part-domain / system-group
class 15  protected-data
```

日志佐证：
```
'MHA-MCM class 2 application-data lookup and sandbox extension'
'MHA-MCM class 4 extension-data lookup and sandbox extension'
'MHA-MCM class 6 VPN-data lookup and sandbox extension'
'MHA-MCM class 7 app-group lookup and sandbox extension'
'MHA-MCM class 10 service-data lookup and sandbox extension'
'MHA-MCM class 12 system-data lookup and sandbox extension'
'MHA-MCM class 13 scoped part-domain lookup and sandbox extension'
'MHA-MCM class 13 system-group lookup and sandbox extension'
'MHA-MCM class 15 protected-data lookup and sandbox extension'
```

### 1.5 lease 管理

```
'=MCMLease'  'BMCMLease'  'MCMLease'
'_OBJC_CLASS_$_MCMLease'
'[MCMFilza] ready root=%@ active_leases=%lu entries=%@ list_error=%@'
'[MCMFilza] lease ok class=%llu id=%@ flags=%llx activated=%d token=%d'
'[MCMFilza] activation failed class=%llu id=%@ detail=%@'
'[MCMFilza] scoped activation failed class=%llu id=%@ part=%llu domain=%@ detail=%@'
'MCM object contained no sandbox token'
'MCM returned no absolute container path'
```

### 1.6 LaunchServices UUID → bundleId 映射

```
'[MCMFilza] LaunchServices store path=%@ bytes=%lu candidates=%lu'
'[MCMFilza] LaunchServices store total candidates=%lu'
'[MCMFilza] LaunchServices store unavailable detail=%@'
'[MCMFilza] LaunchServices store candidate limit reached'
```

### 1.7 虚拟根（symlink 批量访问）

```
'_MCMFilzaVirtualRoot'
'_MCMFilzaDataContainerPath'
'_MCMFilzaArchivePath'
'[MCMFilza] direct symlink failed id=%@ target=%@ errno=%d'
'[MCMFilza] scoped path ready name=%@ target=%@'
```

---

## 2. 授权链原理

### 2.1 为什么普通 App 调不通

`containermanagerd` 对每个请求做**双层检查**：

```
第一层：客户端身份
  signed code identifier (entitlement application-identifier + bundle id)
  必须命中白名单

第二层：sandbox extension
  即使身份通过，容器目录的 sandbox profile 也不允许你的进程访问
  必须由 containermanagerd 签发 extension token，你 consume 后才获得访问权
```

普通 App 两层都过不去。第一层靠 **bundle id 伪装成 MHA**，第二层靠 **token**。

### 2.2 完整调用链

```
1. dlopen("/usr/lib/system/libsystem_container.dylib", RTLD_NOW)
   或直接链接（它在 dyld shared cache 里，路径固定）

2. query = container_query_create()

3. container_query_set_class(query, 2)              // application-data
   container_query_set_identifiers(query, cfArray)   // 可指定 bundle id 列表
   // 或 container_query_set_group_identifiers(query, cfArray)  // app group

4. container_query_iterate_results_sync(query, &err)   // 只是初始化结果集
   → 再循环 container_query_get_next_result(query)，直到返回 NULL
   ※ 不要用 container_query_get_single_result 做迭代：它只返回「那一个」结果，
     反复调用会一直返回同一对象（旧实现即因此存在死循环风险）

5. 对每个 result（container_object_t）：
   path  = container_object_get_path(obj)
   ident = container_object_get_identifier(obj)

6. ★ token = container_copy_sandbox_token(obj)
   if (!token) → "MCM object contained no sandbox token" → 失败

7. ★ handle = sandbox_extension_consume(token)
   if (handle < 0) → 读文件会 EPERM

8. 现在可以用 NSFileManager 读 path 下的任何文件

9. 用完：sandbox_extension_release(handle)  // 或让它随进程结束
        container_object_free(obj)
        container_query_free(query)
```

### 2.3 关键点：token 有生命周期

- `sandbox_extension_consume` 返回一个 `handle`（int64）
- **同一个进程同时持有的 handle 数量有限**（目标包日志里 `active_leases=3` 说明它同时最多挂 3 个）
- 用完必须 `release`，否则后续申请会失败
- 这就是为什么目标包要自己实现 `MCMLease` 类来管理

### 2.4 app-group 是第二个入口

备忘录、微信/QQ 共享数据在 App Group 容器里：

```
container_query_set_class(query, 7)
container_query_set_group_identifiers(query, @[@"group.com.apple.notes", ...])
```

目标包日志：`'(keychain) notes source filza-mcm-group: '`

---

## 3. 与源码版现状的差距

| 项 | 目标包 | 源码版现有 `OWContainerPass.m` |
|---|---|---|
| API | `container_query_*` C API | `MCMContainerManager` ObjC |
| 沙箱 token | `container_copy_sandbox_token` + `sandbox_extension_consume` | **完全没有** |
| 身份校验 | 显式比对 signed identifier | 无 |
| 容器类别 | 2/4/6/7/10/12/13/15 | 只试 2 和 7 |
| lease 管理 | 自实现 `MCMLease` | 无 |
| UUID→bundleId | LaunchServices store | 靠 `identifier` 属性 |
| 虚拟根 | symlink 批量 | 无 |

**结论：现有实现是结构性错误，必须重写。**

---

## 4. 重写方案

### 4.1 文件结构

```
src/Container/
  OWContainerPass.h/.m     保留接口，内部重写
  OWMCM.h/.m               新增：libcontainer C API 封装 + dlsym 绑定
  OWMCMLease.h/.m          新增：token 生命周期管理
  OWLaunchServices.h/.m    新增：UUID → bundleId 映射
```

### 4.2 OWMCM 设计

```objc
// 所有 API 用 dlsym 解析，缺失时不崩、返回明确错误码
typedef void *        (*ow_query_create_t)(void);
typedef void          (*ow_query_free_t)(void *);
typedef void          (*ow_query_set_class_t)(void *, uint64_t);
typedef void          (*ow_query_set_identifiers_t)(void *, CFArrayRef);
typedef void          (*ow_query_set_group_identifiers_t)(void *, CFArrayRef);
typedef void          (*ow_query_operation_set_flags_t)(void *, uint64_t);
typedef bool          (*ow_query_iterate_sync_t)(void *, void **);
typedef void *        (*ow_query_get_single_result_t)(void *);
typedef void *        (*ow_query_get_last_error_t)(void *);
typedef void *        (*ow_object_copy_t)(void *);
typedef void          (*ow_object_free_t)(void *);
typedef const char *  (*ow_object_get_path_t)(void *, void **);
typedef const char *  (*ow_object_get_identifier_t)(void *, void **);
typedef bool          (*ow_object_sbx_activate_t)(void *);
typedef char *        (*ow_copy_sandbox_token_t)(void *);
typedef const char *  (*ow_error_get_message_t)(void *);
typedef int           (*ow_error_get_errno_t)(void *);
```

### 4.3 错误码

| 码 | 含义 |
|---|---|
| -10 | libsystem_container.dylib 加载失败 |
| -11 | 必需符号缺失（列出名字） |
| -12 | 身份不是 MHA（日志打印实际 identifier） |
| -13 | query 创建失败 |
| -14 | 枚举/查询失败（带 posix errno） |
| -15 | 容器无 sandbox token |
| -16 | token consume 失败 |
| -17 | 路径非绝对 |

### 4.4 采样策略

```
pass1: 枚举 app-data(class 2) 全部 → 按 bundleId 命中 targets
pass2: 定向 container_query_set_identifiers(未命中的 bundleId)
pass3: app-group(class 7) 枚举 → 备忘录等
```

每个容器最多同时持有 3 个 token（对应用户观察到的 `active_leases=3`），
超过就释放最旧的。

---

## 5. 通道 A（内核）在 IPA 场景下的约束

### 5.1 主二进制 entitlements（实测）

```
application-identifier          : A9HAF6NT6S.com.cd-rail.zhct
keychain-access-groups          : ['A9HAF6NT6S.*', 'com.apple.token']
get-task-allow                  : false
（无 platform-application，无 com.apple.private.*）
```

**没有特权 → 内核利用是必需品，不是优化。**

### 5.2 内核链的五个阶段

```
1. 取 kernelcache     libgrabkernel2 grab_images / 内嵌 / 本地缓存
2. patchfind 偏移      XPF xpf_start_with_kernel_path + xpf_construct_offset_dictionary
3. exploit            kfd / weightBufs / multicast_bytecopy 等，按 priority 降级
4. KRW 原语            gPrimitives (libjailbreak) 或 kreadbuf/kwritebuf
5. 提权               复制 launchd ucred + 清 cr_label → root + 无沙箱
```

### 5.3 版本天花板（实测于目标包）

| exploit | CVE | 上限 |
|---|---|---|
| weightBufs | CVE-2024-27804 | iOS 17.4.1 |
| multicast_bytecopy | CVE-2023-32434 | iOS 16.5.1 |
| kfd (smith/landa/physpuppet) | CVE-2023-41974 等 | iOS 16.6 |

18.7+ / 26.x：通道 A 基本无望，只能靠通道 B。

### 5.4 源码版 kernel chain 的已知缺陷

| 缺陷 | 影响 |
|---|---|
| `deps/build/ios` 为空 | 无 libxpf.a / libgrabkernel2.a，`dlsym` 全失败 |
| exploit framework 未入包 | 无候选，内核通道永远不启动 |
| `ds_get_rw_socket_pcb` 返回 0 | `procbysock` 失效，部分版本 `ourproc()` 失败 |

---

## 6. 验证方法（不需要内核）

通道 B 可以**完全脱离内核独立验证**：

```
1. 装包（bundle id = com.apple.mobile.MobileHouseArrest）
2. 启动，看日志：
   OWMCM: libsystem_container 加载 OK
   OWMCM: 绑定 18/18 符号
   OWMCM: 身份 = com.apple.mobile.MobileHouseArrest ✓
   OWMCM: class 2 枚举 N 个容器
   OWMCM: lease ok id=com.tencent.xin path=/private/var/.../Application/... token=1
3. 若 N=0 → 身份或 class 不对
4. 若 token=0 → 授权层拒绝（EPERM 根因）
5. 若 token=1 且能列出 .sqlite → 通道 B 打通
```

**这是最低成本的第一步验证，不需要内核、不需要真机越狱。**

---

## 7. 落地顺序

```
Step 1  OWMCM.{h,m}          libcontainer C API 绑定（~350 行）
Step 2  OWMCMLease.{h,m}     token 生命周期（~120 行）
Step 3  OWLaunchServices.{h,m}  UUID→bundleId（~150 行）
Step 4  重写 OWContainerPass.m  （~450 行）
Step 5  lint + 静态检查
Step 6  macOS 编译（用户侧）
```

前 5 步我在 Windows 上可以全部完成并做静态自检，第 6 步需要 macOS。
