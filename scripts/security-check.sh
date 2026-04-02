#!/usr/bin/env bash
# Claude Code 安全配置检查脚本
# 用于验证运行环境是否符合安全最佳实践

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

ISSUES=0
WARNINGS=0

check_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
check_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }
check_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((ISSUES++)); }

echo "=============================="
echo " Claude Code 安全配置检查"
echo "=============================="
echo ""

# 1. 检查危险内部环境变量
echo "── 环境变量检查 ──"

if [[ "${USER_TYPE:-}" == "ant" ]]; then
  check_warn "USER_TYPE=ant 已设置：将触发 Anthropic 内部代码路径（如 tengu_sandbox_disabled_commands）"
else
  check_pass "USER_TYPE 未设置为 'ant'"
fi

if [[ -n "${CLAUDE_CODE_SKIP_TRUST_CHECK:-}" ]]; then
  check_fail "CLAUDE_CODE_SKIP_TRUST_CHECK 已设置：信任检查被跳过，存在安全风险！"
else
  check_pass "CLAUDE_CODE_SKIP_TRUST_CHECK 未设置"
fi

if [[ -n "${CLAUDE_CODE_BYPASS_PERMISSIONS:-}" ]]; then
  check_fail "CLAUDE_CODE_BYPASS_PERMISSIONS 已设置：权限系统被完全绕过！"
else
  check_pass "CLAUDE_CODE_BYPASS_PERMISSIONS 未设置"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  check_warn "ANTHROPIC_API_KEY 明文设置于环境变量中，考虑使用 CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR 替代"
else
  check_pass "ANTHROPIC_API_KEY 未明文设置于环境变量"
fi

echo ""
echo "── 配置文件检查 ──"

CLAUDE_CONFIG="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_CONFIG" ]]; then
  PERM=$(stat -f "%A" "$CLAUDE_CONFIG" 2>/dev/null || stat -c "%a" "$CLAUDE_CONFIG" 2>/dev/null)
  if [[ "$PERM" == "600" || "$PERM" == "640" ]]; then
    check_pass "~/.claude/settings.json 权限正确 ($PERM)"
  else
    check_warn "~/.claude/settings.json 权限为 $PERM，建议设为 600"
    echo "       修复命令：chmod 600 ~/.claude/settings.json"
  fi

  # 检查是否有明文 API Key
  if grep -q '"apiKey"' "$CLAUDE_CONFIG" 2>/dev/null; then
    check_warn "~/.claude/settings.json 中包含 apiKey 字段，建议迁移到系统 Keychain"
  else
    check_pass "~/.claude/settings.json 中未发现明文 apiKey"
  fi
else
  check_pass "~/.claude/settings.json 不存在（使用默认配置或 Keychain）"
fi

echo ""
echo "── 运行时检查 ──"

# 检查 Node.js 版本
NODE_VERSION=$(node --version 2>/dev/null || echo "not found")
if [[ "$NODE_VERSION" == "not found" ]]; then
  check_fail "Node.js 未安装"
elif [[ "${NODE_VERSION:1:2}" -lt 18 ]]; then
  check_fail "Node.js 版本 $NODE_VERSION 过低，需要 >= 18.0.0"
else
  check_pass "Node.js 版本 $NODE_VERSION (>= 18.0.0)"
fi

# 检查 CLI 是否可运行
if node package/cli.js --version &>/dev/null; then
  CLI_VER=$(node package/cli.js --version 2>/dev/null)
  check_pass "CLI 可正常运行：$CLI_VER"
else
  check_fail "CLI 无法运行：package/cli.js 执行失败"
fi

echo ""
echo "────────────────────────────────"
if [[ $ISSUES -gt 0 ]]; then
  echo -e "${RED}检查结果：发现 $ISSUES 个高危问题，$WARNINGS 个警告${NC}"
  echo "请在使用前解决高危问题！"
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}检查结果：0 个高危问题，$WARNINGS 个警告${NC}"
  echo "建议处理警告项以提升安全性。"
  exit 0
else
  echo -e "${GREEN}检查结果：全部通过！${NC}"
  exit 0
fi
