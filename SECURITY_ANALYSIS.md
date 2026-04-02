# 安全风险分析与改进建议

> 版本：2.1.88  
> 分析日期：2026-04-02

---

## 一、高危风险

### 1.1 Bun Bundle Feature Flags（构建时安全控制）

**位置**：整个 `restored-src/src/` 中 200+ 处 `feature('FEATURE_NAME')` 调用

**风险**：`bun:bundle` 的 `feature()` 是编译时常量求值，在编译时根据功能开关进行死代码消除（DCE）。如果直接运行 TypeScript 源码（非编译产物），所有 `feature()` 调用将返回 `undefined`，导致：
- `coordinatorModeModule` 为 `null`（协调器模式失效）
- `BASH_CLASSIFIER` 功能开关评估失败（安全分类器可能静默降级）
- 权限系统行为不可预测

**示例**（`bashPermissions.ts`）：
```typescript
// DCE cliff 注释：Bun 的 feature() 求值有每函数复杂度预算
// import 别名会消耗预算，导致 feature('BASH_CLASSIFIER') 无法作为常量求值
// 静默降级为 false，丢弃所有 pendingClassifierCheck
```

**缓解方案**：
- 始终使用官方编译产物 `package/cli.js`
- 不要尝试直接编译 restored-src 中的 TypeScript 源码用于生产
- 如需研究特定功能，以 `cli.js` 为准

---

### 1.2 `dangerouslyDisableSandbox` 沙箱绕过

**位置**：`tools/BashTool/shouldUseSandbox.ts`

**风险**：用户可通过工具调用参数 `dangerouslyDisableSandbox: true` 配合策略设置绕过沙箱：

```typescript
if (
  input.dangerouslyDisableSandbox &&
  SandboxManager.areUnsandboxedCommandsAllowed()  // 策略允许时
) {
  return false  // 沙箱被跳过
}
```

**注意**：沙箱是安全边界，`excludedCommands` 是便利功能，不是安全控制。代码注释已明确标注：
```typescript
// NOTE: excludedCommands is a user-facing convenience feature, not a security boundary.
```

**缓解方案**：
- 企业部署时通过 Policy 明确禁用 `areUnsandboxedCommandsAllowed()`
- 记录所有 `dangerouslyDisableSandbox=true` 的调用事件

---

### 1.3 ReDoS 风险（已有缓解，但需关注）

**位置**：`tools/BashTool/bashPermissions.ts`

**背景**：Issue CC-643 记录了复合命令解析时 `splitCommand_DEPRECATED` 可能产生指数级增长的子命令数组，导致事件循环阻塞（100% CPU + /proc/self/stat 读取 ~127Hz）。

**现有缓解**：
```typescript
export const MAX_SUBCOMMANDS_FOR_SECURITY_CHECK = 50
// 超过上限时降级为 'ask'（安全默认值 — 无法证明安全则询问用户）
```

**残余风险**：攻击者构造含 49 个子命令的 payload 可绕过安全检查（但不会完全绕过 — 会触发询问用户）。

**改进建议**：在安全日志中记录超出限制的情况，监控异常命令模式。

---

## 二、中危风险

### 2.1 `src/` 绝对导入路径（源码编译问题）

**位置**：`restored-src/src/` 中 925 处 `import from 'src/...'`

**风险**：混合使用相对路径（`../../utils/xxx`）和绝对路径（`src/utils/xxx`），在没有正确配置 `tsconfig.json` 路径映射的情况下无法编译。

**现状**：已配置 `tsconfig.json`（见本文档配套文件），通过 `paths: { "src/*": ["./src/*"] }` 解决。

**示例（main.tsx 第83行）**：
```typescript
// 绝对路径（需 tsconfig paths 映射）
import { isAnalyticsDisabled } from 'src/services/analytics/config.js'
// 相对路径（可直接使用）
import { getCwd } from './utils/cwd.js'
```

---

### 2.2 内部 Anthropic 专用代码泄露

**位置**：多个文件中 `process.env.USER_TYPE === 'ant'` 检查

**示例**（`shouldUseSandbox.ts`）：
```typescript
if (process.env.USER_TYPE === 'ant') {
  const disabledCommands = getFeatureValue_CACHED_MAY_BE_STALE<{...}>(
    'tengu_sandbox_disabled_commands', { commands: [], substrings: [] }
  )
  // ...Anthropic 内部动态配置路径
}
```

**风险**：泄露内部用户类型标识符（`ant` = Anthropic 员工），攻击者可设置 `USER_TYPE=ant` 触发内部代码路径。但实际影响有限（该路径仅影响命令排除列表，不影响安全边界）。

**改进建议**：外部部署应确保不设置 `USER_TYPE=ant` 环境变量。

---

### 2.3 敏感凭据通过环境变量传递

**位置**：`utils/auth.ts`

**涉及环境变量**：
```
ANTHROPIC_API_KEY          # API 密钥（明文）
ANTHROPIC_AUTH_TOKEN       # 认证令牌
CLAUDE_CODE_OAUTH_TOKEN    # OAuth 令牌
CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR  # 通过 FD 传递（较安全）
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR  # 通过 FD 传递（较安全）
```

**风险**：`ANTHROPIC_API_KEY` 等明文环境变量可能出现在进程列表、日志、`/proc/PID/environ` 中。

**已有缓解**：提供了 File Descriptor 方式（`_FILE_DESCRIPTOR` 后缀），更安全。

**改进建议**：
- 优先使用 File Descriptor 方式传递敏感凭据
- 容器部署使用 secrets 管理（Kubernetes Secrets / Docker Secrets）
- 不要在日志、监控系统中记录包含这些变量的命令行

---

### 2.4 API Key 明文存储于配置文件

**位置**：`utils/config.ts`，配置文件路径：`~/.claude/settings.json`

**风险**：API Key 以明文形式存储在用户家目录的 JSON 文件中，文件权限为用户可读。

**现有缓解**：macOS 优先使用 Keychain 存储，有前缀规范化（`normalizeApiKeyForConfig`）。

**改进建议**：
- Linux/Windows 应使用系统密钥管理器而非明文配置文件
- 配置文件权限应设为 `600`（仅所有者可读）

---

## 三、低危风险 / 代码质量问题

### 3.1 大量 `_DEPRECATED` 函数仍在使用

**数量**：16 个标记为 `_DEPRECATED` 的函数，被调用 190+ 次

**主要函数**：
- `splitCommand_DEPRECATED` - 190+ 处调用，安全模块中高频使用
- `getSettings_DEPRECATED` - 多处配置读取
- `writeFileSync_DEPRECATED` - 文件写入
- `execSyncWithDefaults_DEPRECATED` - 同步命令执行

**风险**：deprecated 函数的具体行为变更（如 ReDoS 修复）可能未完全传播到所有调用处。

**改进建议**：逐步迁移到非 deprecated 替代函数，优先迁移安全相关路径。

---

### 3.2 Keychain 预取超时未充分处理

**位置**：`utils/secureStorage/keychainPrefetch.ts`

```typescript
const KEYCHAIN_PREFETCH_TIMEOUT_MS = 10_000  // 10秒超时

// 超时时不缓存结果，让同步读取重试
resolve({
  stdout: err ? null : stdout?.trim() || null,
  timedOut: Boolean(err && 'killed' in err && err.killed),
})
```

**风险**：Keychain 访问超时（10秒）会导致认证延迟，但不会完全失败（有重试路径）。网络/资源受限环境下可能影响启动性能。

---

### 3.3 循环依赖（通过 lazy require 规避）

**位置**：`main.tsx` 顶部注释：
```typescript
// Lazy require to avoid circular dependency: teammate.ts -> AppState.tsx -> ... -> main.tsx
const getTeammateUtils = () => require('./utils/teammate.js')
```

**风险**：循环依赖是架构层面的问题，lazy require 是临时 workaround。如模块加载顺序发生变化可能引入难以调试的问题。

---

## 四、安全最佳实践建议

### 生产部署检查清单

```bash
# 1. 验证沙箱已启用
claude config get sandbox

# 2. 检查权限模式
claude config get permissionMode  # 应为 "default"，不应为 "bypassPermissions"

# 3. 确保不设置危险环境变量
echo $USER_TYPE  # 不应为 "ant"
echo $CLAUDE_CODE_SKIP_TRUST_CHECK  # 不应为 "true"

# 4. 检查配置文件权限
ls -la ~/.claude/settings.json  # 应为 -rw-------

# 5. 验证 API Key 存储方式（macOS）
security find-generic-password -s "Claude Code" -w 2>/dev/null && echo "Keychain OK"
```

### 企业部署 Policy 配置

通过 MDM 或企业策略配置以下字段防止安全绕过：

```json
{
  "permissions": {
    "allow": [],
    "deny": [],
    "additionalDirectories": []
  },
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false
  },
  "bypassPermissionsMode": "disabled"
}
```

---

## 五、改进实施状态

| 改进项 | 状态 | 说明 |
|--------|------|------|
| 创建 tsconfig.json（修复 src/ 路径） | ✅ 已完成 | 配置 paths 映射 |
| 创建 package.json（项目构建配置） | ✅ 已完成 | 支持 Bun 构建 |
| 更新 .gitignore（排除敏感文件） | ✅ 已完成 | 新增凭据文件排除 |
| 创建 ARCHITECTURE.md | ✅ 已完成 | 完整架构文档 |
| 创建 SECURITY_ANALYSIS.md | ✅ 已完成 | 本文档 |
| 添加安全配置校验脚本 | ✅ 已完成 | `scripts/security-check.sh` |
| 修复 main.tsx 启动问题 | ✅ 已完成 | tsconfig 路径映射 |
| 运行验证 | ✅ 已验证 | `package/cli.js --version` 正常 |
