# Claude Desktop Patch — Research Notes

版本：Claude Desktop 1.6608.0.0 (Windows)  
分析日期：2026-05-08

---

## 目录

1. [文件结构](#文件结构)
2. [前端模型名相关逻辑](#前端模型名相关逻辑)
3. [主进程模型名校验逻辑](#主进程模型名校验逻辑)
4. [Electron asar 完整性校验](#electron-asar-完整性校验)
5. [Patch 方案](#patch-方案)
6. [已知限制](#已知限制)

---

## 文件结构

```
Claude_1.6608.0.0_x64__pzs8sxrjxfjjc\app\
├── claude.exe                        # Electron 主进程，含 fuse wire
└── resources\
    ├── app.asar                      # 主应用包（Electron asar 格式）
    │   └── .vite\build\
    │       └── index.js              # 主进程 JS，含模型名校验逻辑
    └── ion-dist\assets\v1\
        ├── index-BHrKNf9Q.js         # 前端渲染进程，含模型匹配函数
        └── c11959232-CDgj4W3e.js     # 前端组件，调用模型匹配函数
```

---

## 前端模型名相关逻辑

位置：`ion-dist/assets/v1/index-BHrKNf9Q.js`（第23行，压缩代码）

### `Fee(modelId)` — 模型名解析

将模型 ID 解析为结构体，用于 UI 显示。

```js
function Fee(modelId) {
    const ctx = /\[1m\]/i.test(modelId) ? "1M" : undefined;

    // 官方模型：claude-{family}-{major}[-{minor}][-date][-fast]
    const m = modelId.match(/^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?!\d)(?:-\d{8})?(-fast)?/);
    if (m) {
        const [, family, major, minor, fast] = m;
        return { base: `${capitalize(family)} ${minor ? `${major}.${minor}` : major}`,
                 suffix: fast ? "Fast" : undefined, ctx, internal: false };
    }

    // 内部模型：{name}-v{version}[-{variant}]（名称超3字符则打码）
    const n = modelId.match(/^([a-z]+)-v(\d+)(?:-([a-z]+))?/);
    if (n) {
        const [, name, ver, variant] = n;
        return { base: `${zee(name)} ${ver}`, suffix: ..., ctx, internal: true };
    }

    return null;
}
```

### `Bee(modelId)` — 规范化（去日期/suffix）

```js
function Bee(modelId) {
    return modelId.replace(/\[[^\]]+\]$/, "").replace(/-20\d{6}$/, "");
}
```

### `Vee(modelId, availableModels[])` — 模型名匹配（核心）

将配置中的模型名映射到可用模型列表，按优先级依次尝试：

1. 精确匹配
2. 忽略日期 suffix 匹配
3. 前缀/family 别名匹配（opus/sonnet/haiku）
4. **`"claude" === parts[0]` → 直接返回 null**（claude-* 格式不做进一步模糊匹配）
5. 非 claude 模型继续做 token 级模糊匹配

```js
// 关键行：
const parts = lower.split(/[-[\]]+/).filter(Boolean);
if ("claude" === parts[0]) return null;
```

**含义：** `claude-xxx` 格式的模型名如果在可用列表里找不到，不允许猜测，直接失败。非 claude 模型则可以继续模糊匹配。

### `Hee(modelId)` — 生成显示名称

```js
function Hee(modelId) {
    const parsed = Fee(modelId);
    return parsed ? [parsed.base, parsed.suffix, parsed.ctx].filter(Boolean).join(" ") : modelId;
}
```

### 导出/导入别名对照

| 函数 | index.js 导出名 | c11959232 import 别名 |
|------|----------------|----------------------|
| `Fee` | — (内部) | — |
| `Bee` | `Ea` | `tt` |
| `Vee` | `E9` | `et` |
| `Hee` | `Eb` | `st` |

### 调用位置（c11959232-CDgj4W3e.js）

```js
// 把 config 文件里的 model 值匹配到可用模型列表
const L = useMemo(() => z ? et(z, M.map(e => e.model)) : null, [z, M]);
//                          ↑ Vee(configModel, availableModelIds)

// 当前模型不在列表里时生成 fallback 显示名
const G = V ? null : st(W);   // Hee(modelId)

// sticky 偏好比较时忽略日期
tt(S) !== tt(O)               // Bee(S) !== Bee(O)
```

---

## 主进程模型名校验逻辑

位置：`app.asar` → `.vite/build/index.js`

### 调用链

```
oHe(enterpriseConfig)
  └─ LZt.safeParse(n)          # zod schema 校验（字段格式）
  └─ FZt(config)               # 认证字段校验（apiKey/sso 等）
  └─ _Zt(provider, models[])   # 模型名 Anthropic 校验
       └─ ULA(provider, name)  # 按 provider 分发
            ├─ bLA(name)       # gateway / foundry 通用检查
            ├─ XWt(name)       # vertex 专用检查
            └─ zWt(name)       # bedrock 专用检查
```

### `_Zt` — 模型名校验入口

```js
const LLA = process.env.NODE_ENV !== "production" || false;
// 生产包中 NODE_ENV="production"，所以 LLA = false

function _Zt(provider, models) {
    if (!LLA || !models?.length) return null;  // LLA=false → 永远跳过
    for (const model of models) {
        const result = ULA(provider, model.name);
        if (!result.ok)
            return `inferenceModels: configured model "${model.name}" is not an Anthropic model. ...`;
    }
    return null;
}
```

> **注意：** `LLA = false` 导致 `_Zt` 在生产包中永远返回 null，不执行校验。
> 实际触发报错的是 `_Zt` 被调用前的某个路径，或服务端返回的错误。
> 经验证，错误字符串只在本地 `index.js` 中出现一次，说明是本地抛出的。
> 推测：`LLA` 在某些条件下为 `true`，或存在其他调用路径。

### `bLA(name)` — 通用 Anthropic 关键词检查（**Patch 目标**）

```js
const bxe = /^(sonnet|opus|haiku)(-[\d.]+)?$/;
const ZWt = ["claude", "sonnet", "opus", "haiku", "anthropic"];

function bLA(name) {
    const lower = name.toLowerCase();
    return bxe.test(lower) ||                    // 短别名：sonnet/opus/haiku
           ZWt.some(k => lower.includes(k));     // 包含任意关键词
}
```

**通过条件（任意一个）：**
- 名称是 `sonnet`、`opus`、`haiku`（可带版本号）
- 名称包含 `claude`、`sonnet`、`opus`、`haiku`、`anthropic`

**`GLM-5.1` 失败原因：** 不满足任何条件。

### 各 Provider 校验规则

| Provider | 函数 | 通过条件 |
|----------|------|---------|
| gateway  | `e9t` | `bLA(name)` = true |
| foundry  | `A9t` | `bLA(name)` = true |
| vertex   | `XWt` | `name.toLowerCase().startsWith("claude-")` |
| bedrock  | `zWt` | 含 `anthropic.`、ARN 格式、inference profile、provisioned model |

---

## Electron asar 完整性校验

### 问题

修改 `app.asar` 后启动报错：

```
FATAL: Integrity check failed for asar archive
(原始哈希 vs 新哈希)
```

原始哈希 `2c7130aa...` 硬编码在 `claude.exe` 中。

### 原理

Electron 通过 **fuse wire** 控制运行时特性开关。fuse wire 是嵌入在 exe 中的一段固定格式字节序列：

```
sentinel: "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"  (32 bytes)
wire:     [version][cookie][fuse0][fuse1]...[fuseN][0x00]
```

每个 fuse 字节：`0x31` = ON，`0x30` = OFF

### Claude Desktop fuse wire（实测）

```
offset  fuse                                    value
[0]     version                                 0x01
[1]     cookie                                  0x09
[2]     RunAsNode                               OFF (0x30)
[3]     EnableCookieEncryption                  ON  (0x31)
[4]     EnableNodeOptionsEnvironmentVariable    OFF (0x30)
[5]     EnableNodeCliInspectArguments           OFF (0x30)
[6]     EnableEmbeddedAsarIntegrityValidation   ON  (0x31)  ← patch 目标
[7]     OnlyLoadAppFromAsar                     ON  (0x31)
[8]     LoadBrowserProcessSpecificV8Snapshot    OFF (0x30)
[9]     GrantFileProtocolExtraPrivileges        ON  (0x31)
[10]    (reserved)                              ON  (0x31)
```

sentinel 在 `claude.exe` 中的偏移：`185760848`  
fuse[6] 的绝对偏移：`185760886`

### 修复方案

将 fuse[6]（`EnableEmbeddedAsarIntegrityValidation`）从 `0x31` 改为 `0x30`，禁用完整性校验。

---

## Patch 方案

### 两步操作

**Step 1：patch `claude.exe`（禁用 asar 完整性校验）**

定位 fuse sentinel → 找到 wire offset 6 → 将 `0x31` 改为 `0x30`。

**Step 2：patch `app.asar` 内的 `index.js`（绕过模型名校验）**

将 `bLA()` 函数替换为永远返回 `true` 的 stub：

```js
// 原始
function bLA(e){const A=e.toLowerCase();return bxe.test(A)||ZWt.some(t=>A.includes(t))}

// patch 后
function bLA(e){return true/*patched*/}
```

### 脚本

见 `patch-claude.ps1`，需以管理员身份运行。

---

## 已知限制

1. **版本绑定：** patch 目标字符串是精确匹配，Claude Desktop 更新后需重新验证。脚本在找不到目标时会报错提示。

2. **fuse wire 偏移：** sentinel 搜索是动态的（全文扫描），不依赖硬编码偏移，版本更新后仍有效。但 fuse 布局如果变化（Electron 升级）需重新确认 wire offset。

3. **服务端校验：** 本 patch 只绕过客户端本地校验。如果 Anthropic 服务端也有同等校验，非 Anthropic 模型名仍可能被拒绝（取决于具体 gateway 配置）。

4. **WindowsApps ACL：** 需要 `takeown` + `icacls` 拿到写权限，操作完成后权限不会自动还原。
