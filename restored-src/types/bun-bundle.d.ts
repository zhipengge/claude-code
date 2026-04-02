/**
 * Bun Bundle 编译时 feature flag 类型声明
 *
 * 在 Bun 构建过程中，feature() 是编译时常量，用于死代码消除(DCE)。
 * 这里提供类型声明以支持 TypeScript 类型检查，但运行时需要 Bun 编译产物。
 *
 * 已知 feature flags（来自源码分析）：
 * - COORDINATOR_MODE: 多 Agent 协调器模式
 * - KAIROS: 助手 AI 模式
 * - BASH_CLASSIFIER: Bash 命令安全分类器
 * - AGENT_SWARMS: Agent 群集模式
 * - BUDDY: AI 伴侣 UI
 * - VOICE: 语音交互
 */
declare module 'bun:bundle' {
  /**
   * 编译时 feature flag 查询。
   * 在 Bun 构建时被替换为布尔常量，实现死代码消除。
   * 在 TypeScript 类型检查时返回 boolean 类型。
   *
   * ⚠️  警告：此函数在运行时（非 Bun 编译产物）不可用。
   *         始终使用官方编译的 package/cli.js。
   */
  export function feature(name: string): boolean
}
