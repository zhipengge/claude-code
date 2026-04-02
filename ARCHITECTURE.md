# Claude Code 架构文档

> 版本：2.1.88  
> 还原自：`@anthropic-ai/claude-code` npm 包 source map  
> 仅供研究，版权归 Anthropic 所有

---

## 一、整体架构

Claude Code 是一个基于终端的 AI Agent 框架，使用 **Bun** 作为运行时，**React/Ink** 构建 TUI 界面，**Anthropic SDK** 驱动 LLM 推理。

```
┌─────────────────────────────────────────────────────────────────┐
│                          main.tsx (CLI 入口)                      │
│   启动优化: startupProfiler → startMdmRawRead → startKeychainPrefetch  │
└───────────────────────────────┬─────────────────────────────────┘
                                │
         ┌──────────────────────▼──────────────────────┐
         │           Commander.js CLI 路由               │
         │  /api  /chat  /commit  /doctor  /mcp  ...    │
         └──────────────┬────────────────────┬──────────┘
                        │                    │
          ┌─────────────▼──────┐   ┌────────▼──────────┐
          │   launchRepl()     │   │ 各 Command 处理器  │
          │  交互式 TUI 模式    │   │  (40+ 个命令)      │
          └─────────────┬──────┘   └───────────────────┘
                        │
          ┌─────────────▼──────────────────────────────┐
          │              Task.ts (任务管理器)             │
          │  TaskType: local_bash | local_agent |        │
          │  remote_agent | in_process_teammate |        │
          │  local_workflow | monitor_mcp | dream        │
          └─────────────┬──────────────────────────────┘
                        │
          ┌─────────────▼──────────────────────────────┐
          │           QueryEngine.ts (推理引擎)           │
          │   query() → Anthropic API → 消息流处理        │
          └─────────────┬──────────────────────────────┘
                        │
          ┌─────────────▼──────────────────────────────┐
          │              Tool.ts (工具抽象层)             │
          │   buildTool() → ToolDef → 权限检查 → 执行     │
          └─────────────┬──────────────────────────────┘
                        │
        ┌───────────────┴─────────────────┐
        │           tools/ (40+ 个工具)    │
        ├──────────────────────────────────┤
        │ BashTool     FileReadTool        │
        │ FileEditTool FileWriteTool       │
        │ GlobTool     GrepTool            │
        │ AgentTool    MCPTool             │
        │ SkillTool    TodoWriteTool       │
        │ REPLTool     NotebookEditTool    │
        │ ...          (共 40+ 个)          │
        └──────────────────────────────────┘
```

---

## 二、核心模块详解

### 2.1 入口层 (`main.tsx` - 4683 行)

**职责**：解析 CLI 参数、初始化所有子系统、路由到对应模式。

**启动优化链**（并行化关键路径）：
```
main.tsx 顶部
  ├── profileCheckpoint('main_tsx_entry')   // 性能打点
  ├── startMdmRawRead()                     // 并行启动 MDM 读取 (~65ms 并行)
  └── startKeychainPrefetch()               // 并行启动 macOS Keychain 读取
```

**功能模式路由**：
- `--print` / `-p`：无交互打印模式
- `--repl`：交互式 REPL
- `COORDINATOR_MODE`（feature flag）：多 Agent 协调器模式
- `KAIROS`（feature flag）：助手 AI 模式

### 2.2 查询引擎 (`QueryEngine.ts`)

**职责**：管理与 Claude API 的消息往返，处理工具调用。

**消息流**：
```
用户输入
  → processUserInput()        // 预处理、附件处理
  → fetchSystemPromptParts()  // 构建系统提示
  → Anthropic API 流式调用
  → 工具调用解析
  → bashToolHasPermission()   // 权限检查
  → 工具执行
  → 结果回填消息历史
  → 下一轮推理
```

### 2.3 任务系统 (`Task.ts` + `tasks/`)

| TaskType | 说明 |
|----------|------|
| `local_bash` | 本地 Shell 命令执行 |
| `local_agent` | 本地子 Agent |
| `remote_agent` | 远程 Agent（通过 API） |
| `in_process_teammate` | 进程内队友 Agent |
| `local_workflow` | 本地工作流 |
| `monitor_mcp` | MCP 监控任务 |
| `dream` | 自主探索模式 |

**任务 ID 格式**：`{前缀}{8位随机字符(base36)}`，例如 `b-x7k9m2p1`

### 2.4 工具系统 (`Tool.ts` + `tools/`)

**工具定义结构**：
```typescript
type ToolDef<Input> = {
  name: string
  description: string
  inputSchema: z.ZodSchema<Input>
  userFacingName?: string
  isEnabled?: () => boolean
  isReadOnly?: () => boolean
  needsPermissions?: (input: Input, ctx: ToolPermissionContext) => PermissionResult
  call: (input: Input, ctx: ToolUseContext) => AsyncGenerator<ToolProgress, ToolResult>
}
```

**40+ 工具列表**：
```
文件操作:    FileReadTool, FileEditTool, FileWriteTool, GlobTool, GrepTool
Shell:       BashTool, PowerShellTool, REPLTool
Agent:       AgentTool, SkillTool, TodoWriteTool
MCP:         MCPTool, ListMcpResourcesTool, ReadMcpResourceTool, McpAuthTool
任务管理:    TaskCreateTool, TaskGetTool, TaskListTool, TaskUpdateTool, TaskStopTool, TaskOutputTool
笔记本:      NotebookEditTool
其他:        AskUserQuestionTool, BriefTool, ConfigTool, LSPTool, SleepTool
             SyntheticOutputTool, ToolSearchTool, WebSearchTool (通过MCP)
             ScheduleCronTool, SendMessageTool, RemoteTriggerTool
             EnterPlanModeTool, ExitPlanModeTool, EnterWorktreeTool, ExitWorktreeTool
             TeamCreateTool, TeamDeleteTool
```

### 2.5 权限系统 (`utils/permissions/`)

**多层权限控制**：
```
用户请求执行命令
  ↓
1. PermissionMode 检查 (bypassPermissions / acceptEdits / default)
  ↓
2. 工具级 needsPermissions() 检查
  ↓
3. BashTool: bashToolHasPermission()
   ├── 沙箱检查: shouldUseSandbox()
   ├── 路径验证: checkPathConstraints()
   ├── 命令分类器: bashClassifier (AI辅助分类)
   ├── AST 安全分析: parseForSecurity() (tree-sitter)
   └── 危险路径检查: isDangerousRemovalPath()
  ↓
4. DenialTracking: 连续拒绝 ≥3 或总拒绝 ≥20 → 强制询问用户
  ↓
5. 用户确认 / 自动允许 / 拒绝
```

**PermissionRule 类型**：
- `prefix`: 前缀匹配（如 `git:*`）
- `exact`: 精确命令匹配
- `wildcard`: 通配符匹配

### 2.6 MCP 集成 (`services/mcp/`)

Claude Code 同时作为 MCP 客户端（调用外部工具）和 MCP 服务端（暴露工具给 IDE）。

**支持的 MCP 传输类型**：
- `stdio`：标准 I/O（最常用）
- `sse`：Server-Sent Events
- `http`：HTTP Streamable
- `ws`：WebSocket
- `sdk`：SDK 内嵌（如 VSCode 插件）

**连接范围**：`local | user | project | dynamic | enterprise | claudeai | managed`

### 2.7 多 Agent 系统 (`coordinator/` + `utils/swarm/`)

```
CoordinatorMode
  └── 多个 SubAgent (in_process_teammate / remote_agent)
        ├── 每个 Agent 独立消息历史
        ├── 通过 TeamCreateTool/SendMessageTool 通信
        └── 通过 TeammatePromptAddendum 注入上下文
```

### 2.8 认证系统 (`utils/auth.ts` + `utils/secureStorage/`)

**认证方式优先级**（从高到低）：
1. `CLAUDE_CODE_OAUTH_TOKEN` 环境变量（托管 OAuth 上下文）
2. OAuth 令牌（macOS Keychain / Linux Secret Service）
3. `ANTHROPIC_API_KEY` 环境变量
4. `~/.claude/settings.json` 中的 API Key
5. `apiKeyHelper` 脚本（自定义 key 提供器）

**平台差异**：
- macOS：使用 Keychain（并行预取，减少启动延迟）
- Linux：使用 Secret Service API
- Windows：使用 DPAPI / Credential Manager

---

## 三、目录结构

```
restored-src/src/
├── main.tsx              # CLI 入口 (4683行)
├── Tool.ts               # 工具抽象类型 (792行)
├── Task.ts               # 任务类型与生命周期
├── QueryEngine.ts        # 推理引擎
├── query.ts              # API 查询封装
├── tools.ts              # 工具注册
├── commands.ts           # 命令注册
├── tools/                # 40+ 工具实现
│   ├── BashTool/         # Shell 执行（含安全模块）
│   ├── FileEditTool/     # 文件编辑
│   ├── AgentTool/        # 子 Agent
│   └── ...
├── commands/             # 40+ CLI 命令
├── services/             # 服务层
│   ├── analytics/        # 遥测 (GrowthBook)
│   ├── api/              # Anthropic API 封装
│   ├── mcp/              # MCP 客户端/服务端
│   ├── oauth/            # OAuth 流程
│   └── ...
├── utils/                # 工具函数 (100+ 文件)
│   ├── permissions/      # 权限系统
│   ├── secureStorage/    # 安全存储
│   ├── bash/             # Bash AST 解析
│   ├── settings/         # 配置管理
│   └── ...
├── state/                # React Context 状态管理
├── coordinator/          # 多 Agent 协调器
├── assistant/            # KAIROS 助手模式
├── plugins/              # 插件系统
├── skills/               # 技能系统
├── memdir/               # Memory 目录管理
└── bootstrap/            # 启动状态
```

---

## 四、关键技术栈

| 层级 | 技术 |
|------|------|
| 运行时 | **Bun** (需要 Bun 编译，使用 `bun:bundle` feature flags) |
| UI 框架 | **React + Ink** (TUI 渲染) |
| CLI 框架 | **Commander.js** (`@commander-js/extra-typings`) |
| LLM SDK | **@anthropic-ai/sdk** |
| MCP SDK | **@modelcontextprotocol/sdk** |
| Shell 解析 | **tree-sitter** (AST 安全分析) |
| 类型验证 | **Zod v4** |
| 功能开关 | **GrowthBook** + `bun:bundle feature()` |
| 认证 | macOS Keychain / Linux Secret Service / OAuth |
| 图像处理 | **sharp** (可选依赖) |

---

## 五、数据流图

```
用户 → CLI 参数
         ↓
    Commander.js 解析
         ↓
    init() 初始化
    ├── 加载配置 (~/.claude/settings.json)
    ├── 认证检查
    ├── MCP 连接建立
    ├── 插件/技能加载
    └── GrowthBook 初始化
         ↓
    REPL / 命令执行
         ↓
    QueryEngine.query()
    ├── 构建系统提示
    ├── Anthropic API 流式调用
    └── 工具调用循环
         ├── 权限检查
         ├── 执行工具
         └── 返回结果
         ↓
    React/Ink 渲染输出
         ↓
    会话存储 / 遥测上报
```
