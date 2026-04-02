# Claude Code 架构文档

> 版本：2.1.88  
> 还原自：`@anthropic-ai/claude-code` npm 包 source map  
> 仅供研究，版权归 Anthropic 所有

---

## 一、整体架构

Claude Code 是一个基于终端的 AI Agent 框架，使用 **Bun** 作为运行时，**React/Ink** 构建 TUI 界面，**Anthropic SDK** 驱动 LLM 推理。

```mermaid
graph TD
    A["main.tsx (CLI 入口, 4683行)"]
    A --> B["Commander.js CLI 路由<br/>/api /chat /commit /doctor /mcp ..."]
    B --> C["launchRepl()<br/>交互式 TUI 模式"]
    B --> D["各 Command 处理器<br/>(40+ 个命令)"]
    C --> E["Task.ts (任务管理器)<br/>local_bash | local_agent | remote_agent<br/>in_process_teammate | local_workflow | dream"]
    E --> F["QueryEngine.ts (推理引擎)<br/>query() → Anthropic API → 消息流处理"]
    F --> G["Tool.ts (工具抽象层)<br/>buildTool() → ToolDef → 权限检查 → 执行"]
    G --> H["tools/ (40+ 个工具)"]

    subgraph tools ["工具集"]
        H1["BashTool / PowerShellTool"]
        H2["FileReadTool / FileEditTool / FileWriteTool"]
        H3["GlobTool / GrepTool"]
        H4["AgentTool / SkillTool"]
        H5["MCPTool / REPLTool / ..."]
    end

    H --> H1
    H --> H2
    H --> H3
    H --> H4
    H --> H5
```

---

## 二、核心模块详解

### 2.1 入口层（`main.tsx` — 4683 行）

**职责**：解析 CLI 参数、初始化所有子系统、路由到对应模式。

**启动优化链**（并行化关键路径，节省 ~65ms）：

```mermaid
sequenceDiagram
    participant M as main.tsx
    participant P as startupProfiler
    participant MDM as startMdmRawRead
    participant KC as startKeychainPrefetch
    participant I as init()

    M->>P: profileCheckpoint('main_tsx_entry')
    par 并行启动
        M->>MDM: startMdmRawRead() [~65ms 并行]
    and
        M->>KC: startKeychainPrefetch() [macOS Keychain]
    end
    Note over MDM,KC: 与后续 135ms import 评估并行运行
    M->>I: preAction → ensureMdmSettingsLoaded()<br/>ensureKeychainPrefetchCompleted()
    I-->>M: 初始化完成（两个预取几乎免费）
```

**功能模式路由**：
- `--print` / `-p`：无交互打印模式
- `--repl`：交互式 REPL
- `COORDINATOR_MODE`（feature flag）：多 Agent 协调器模式
- `KAIROS`（feature flag）：助手 AI 模式

---

### 2.2 查询引擎（`QueryEngine.ts`）

**职责**：管理与 Claude API 的消息往返，处理工具调用循环。

```mermaid
sequenceDiagram
    participant U as 用户输入
    participant QE as QueryEngine
    participant API as Anthropic API
    participant P as 权限系统
    participant T as 工具执行器

    U->>QE: 用户消息
    QE->>QE: processUserInput() 预处理/附件
    QE->>QE: fetchSystemPromptParts() 构建系统提示
    QE->>API: 流式 API 调用
    API-->>QE: 文本 / 工具调用块
    loop 工具调用循环
        QE->>P: bashToolHasPermission() 权限检查
        P-->>QE: allow / deny / ask
        QE->>T: 执行工具
        T-->>QE: 工具结果
        QE->>API: 带工具结果的新轮次
        API-->>QE: 下一步响应
    end
    QE-->>U: 最终输出 + React/Ink 渲染
```

---

### 2.3 任务系统（`Task.ts` + `tasks/`）

| TaskType | 前缀 | 说明 |
|----------|------|------|
| `local_bash` | `b` | 本地 Shell 命令执行 |
| `local_agent` | `a` | 本地子 Agent |
| `remote_agent` | `r` | 远程 Agent（通过 API） |
| `in_process_teammate` | `t` | 进程内队友 Agent |
| `local_workflow` | `w` | 本地工作流 |
| `monitor_mcp` | `m` | MCP 监控任务 |
| `dream` | `d` | 自主探索模式 |

**任务 ID 格式**：`{前缀}{8位随机字符(base36)}`，例如 `b-x7k9m2p1`  
**熵**：36⁸ ≈ 2.8 万亿组合，可抵抗暴力符号链接攻击。

**任务状态机**：

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> running : spawn
    running --> completed : 执行成功
    running --> failed : 执行失败
    running --> killed : 主动终止
    completed --> [*]
    failed --> [*]
    killed --> [*]
    note right of running : isTerminalTaskStatus()<br/>guards inject / evict / cleanup
```

---

### 2.4 工具系统（`Tool.ts` + `tools/`）

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

**40+ 工具分类**：

| 分类 | 工具 |
|------|------|
| 文件操作 | `FileReadTool` `FileEditTool` `FileWriteTool` `GlobTool` `GrepTool` |
| Shell 执行 | `BashTool` `PowerShellTool` `REPLTool` |
| Agent 协作 | `AgentTool` `SkillTool` `TodoWriteTool` |
| MCP 集成 | `MCPTool` `ListMcpResourcesTool` `ReadMcpResourceTool` `McpAuthTool` |
| 任务管理 | `TaskCreateTool` `TaskGetTool` `TaskListTool` `TaskUpdateTool` `TaskStopTool` `TaskOutputTool` |
| 笔记本 | `NotebookEditTool` |
| 规划/模式 | `EnterPlanModeTool` `ExitPlanModeTool` `EnterWorktreeTool` `ExitWorktreeTool` |
| 团队协作 | `TeamCreateTool` `TeamDeleteTool` `SendMessageTool` |
| 其他 | `AskUserQuestionTool` `BriefTool` `ConfigTool` `LSPTool` `SleepTool` `SyntheticOutputTool` `ToolSearchTool` `ScheduleCronTool` `RemoteTriggerTool` |

---

### 2.5 权限系统（`utils/permissions/`）

```mermaid
flowchart TD
    A([用户请求执行命令]) --> B{PermissionMode?}
    B -->|bypassPermissions| Z([✅ 直接执行])
    B -->|acceptEdits| C
    B -->|default| C

    C[工具级 needsPermissions 检查] --> D{结果?}
    D -->|allow| Z
    D -->|deny| X([❌ 拒绝])
    D -->|ask| E

    E["BashTool 多层安全检查"] --> E1{沙箱检查<br/>shouldUseSandbox}
    E1 -->|需沙箱| E2[在沙箱中执行]
    E1 -->|不需要| E3{路径验证<br/>checkPathConstraints}
    E3 -->|危险路径| X
    E3 -->|通过| E4{AST 安全分析<br/>parseForSecurity}
    E4 -->|不安全| E5{DenialTracking}
    E4 -->|安全| Z
    E5 -->|连续拒绝≥3 或总拒绝≥20| F([🙋 强制询问用户])
    E5 -->|未达阈值| X

    F -->|用户允许| Z
    F -->|用户拒绝| X
```

**PermissionRule 类型**：
- `prefix`：前缀匹配（如 `git:*`）
- `exact`：精确命令匹配
- `wildcard`：通配符匹配（如 `npm run *`）

---

### 2.6 MCP 集成（`services/mcp/`）

Claude Code 同时作为 **MCP 客户端**（调用外部工具）和 **MCP 服务端**（暴露工具给 IDE）。

```mermaid
graph LR
    subgraph claude ["Claude Code 进程"]
        CC["MCP Client<br/>getMcpToolsCommandsAndResources()"]
        CS["MCP Server<br/>vscodeSdkMcp.ts"]
    end

    subgraph ext ["外部 MCP 服务器"]
        S1["stdio 服务器<br/>(最常用)"]
        S2["SSE 服务器"]
        S3["HTTP Streamable"]
        S4["WebSocket"]
    end

    subgraph ide ["IDE 插件"]
        VSC["VSCode Extension"]
    end

    CC -->|stdio/sse/http/ws| S1
    CC -->|sse| S2
    CC -->|http| S3
    CC -->|ws| S4
    VSC -->|sdk transport| CS
```

**连接范围**：`local` | `user` | `project` | `dynamic` | `enterprise` | `claudeai` | `managed`

---

### 2.7 多 Agent 系统（`coordinator/` + `utils/swarm/`）

```mermaid
graph TD
    CO["CoordinatorMode<br/>coordinatorMode.ts"]
    CO --> A1["SubAgent 1<br/>in_process_teammate"]
    CO --> A2["SubAgent 2<br/>in_process_teammate"]
    CO --> A3["SubAgent N<br/>remote_agent"]

    A1 <-->|TeamCreateTool<br/>SendMessageTool| A2
    A1 <-->|TeammatePromptAddendum| A3

    subgraph each ["每个 Agent 独立持有"]
        MH["消息历史"]
        FC["文件状态缓存"]
        AC["AbortController"]
    end

    A1 --> each
```

---

### 2.8 认证系统（`utils/auth.ts` + `utils/secureStorage/`）

```mermaid
flowchart TD
    S([认证请求]) --> C1{isManagedOAuthContext?}
    C1 -->|是 CCR/Claude Desktop| T1["CLAUDE_CODE_OAUTH_TOKEN<br/>环境变量"]
    C1 -->|否| C2{CLAUDE_CODE_OAUTH_TOKEN<br/>环境变量?}
    C2 -->|存在| T1
    C2 -->|不存在| C3{OAuth Token<br/>Keychain/Secret Service?}
    C3 -->|存在且未过期| T2["OAuth 令牌<br/>(macOS Keychain 并行预取)"]
    C3 -->|过期| T3["refreshOAuthToken()"]
    T3 --> T2
    C3 -->|不存在| C4{ANTHROPIC_API_KEY<br/>环境变量?}
    C4 -->|存在| T4["API Key (env)"]
    C4 -->|不存在| C5{settings.json<br/>apiKeyHelper?}
    C5 -->|存在| T5["apiKeyHelper 脚本<br/>(TTL 5分钟缓存)"]
    C5 -->|不存在| ERR([❌ 认证失败])

    subgraph platform ["平台差异"]
        P1["macOS: Keychain<br/>(并行预取节省65ms)"]
        P2["Linux: Secret Service API"]
        P3["Windows: DPAPI/Credential Manager"]
    end
```

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
| 运行时 | **Bun**（需要 Bun 编译，使用 `bun:bundle` feature flags） |
| UI 框架 | **React + Ink**（TUI 渲染） |
| CLI 框架 | **Commander.js**（`@commander-js/extra-typings`） |
| LLM SDK | **@anthropic-ai/sdk** |
| MCP SDK | **@modelcontextprotocol/sdk** |
| Shell 解析 | **tree-sitter**（AST 安全分析） |
| 类型验证 | **Zod v4** |
| 功能开关 | **GrowthBook** + `bun:bundle feature()` |
| 认证 | macOS Keychain / Linux Secret Service / OAuth |
| 图像处理 | **sharp**（可选依赖） |

---

## 五、完整数据流

```mermaid
flowchart TD
    U([用户]) -->|CLI 参数| A["main.tsx\nCommander.js 解析"]
    A -->|preAction| B["init() 初始化\n• 加载 ~/.claude/settings.json\n• 认证检查\n• MCP 连接建立\n• 插件/技能加载\n• GrowthBook 初始化"]
    B --> C{模式判断}
    C -->|交互模式| D["launchRepl()\nReact/Ink TUI"]
    C -->|--print 模式| E["非交互输出"]
    C -->|子命令| F["Command 处理器"]
    D --> G["QueryEngine.query()"]
    E --> G
    G --> H["Anthropic API\n流式调用"]
    H -->|文本块| I["React/Ink 渲染"]
    H -->|工具调用块| J["权限检查"]
    J -->|通过| K["工具执行\nbashTool/fileEdit/..."]
    J -->|拒绝| L["拒绝响应\n返回 API"]
    K --> M["工具结果\n回填消息历史"]
    M --> H
    I --> N[(会话存储\nflushSessionStorage)]
    I --> O[(遥测上报\nlogEvent)]
```
