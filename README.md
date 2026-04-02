# claude-code-sourcemap

[![linux.do](https://img.shields.io/badge/linux.do-huo0-blue?logo=linux&logoColor=white)](https://linux.do)

> [!WARNING]
> 本仓库为**非官方**整理版，基于公开 npm 发布包与 source map 分析还原，**仅供研究使用**。  
> **不代表**官方原始内部开发仓库结构。源码版权归 [Anthropic](https://www.anthropic.com) 所有。

---

## 概述

通过 `@anthropic-ai/claude-code` npm 包（版本 `2.1.88`）内附带的 source map（`cli.js.map`）还原的 TypeScript 源码。

| 项目 | 信息 |
|------|------|
| npm 包 | [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code) |
| 还原版本 | `2.1.88` |
| 还原文件数 | **4756 个**（含 1884 个 `.ts`/`.tsx` 源文件） |
| 还原方式 | 提取 `cli.js.map` 中的 `sourcesContent` 字段 |

---

## 快速开始

```bash
# 验证版本
node package/cli.js --version

# 查看帮助
node package/cli.js --help

# 或通过 npm scripts
npm start
```

---

## 文档

详细文档请见 [`docs/`](./docs/) 目录：

- [📐 架构文档](./docs/architecture.md) — 整体架构、模块详解、Mermaid 流程图
- [🔒 安全分析](./docs/security.md) — 风险矩阵、漏洞分析、缓解建议

---

## 目录结构

```
.
├── docs/                   # 文档目录
│   ├── README.md           # 文档索引
│   ├── architecture.md     # 架构分析（含 Mermaid 流程图）
│   └── security.md         # 安全风险分析
├── package/                # 可运行的编译产物
│   ├── cli.js              # 主入口（Node.js 可直接运行）
│   └── package.json        # 包元信息
├── restored-src/           # 还原的 TypeScript 源码
│   ├── src/                # 1884 个 .ts/.tsx 源文件
│   ├── tsconfig.json       # TypeScript 配置
│   └── types/              # 补充类型声明
│       └── bun-bundle.d.ts # Bun bundle feature flag 类型
├── scripts/
│   └── security-check.sh   # 运行时安全配置检查
├── extract-sources.js      # Source map 提取脚本
└── package.json            # 项目构建配置
```

---

## 声明

- 源码版权归 [Anthropic](https://www.anthropic.com) 所有
- 本仓库仅用于技术研究与学习，请勿用于商业用途
- 如有侵权，请联系删除
