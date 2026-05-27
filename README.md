# Issuely

> 用极简的方式，推进一个本来要花数十小时才能拆清、排期、开发、审查、验收的复杂工程任务。

Issuely 把一件复杂工作压成一条可持续推进的流水线：

1. 把模糊想法聊成 PRD
2. 自动拆成有依赖顺序的 issue 包
3. 可选地 refine 高风险 / 高复杂度 issue
4. 由 planner / dev / review 多 agent 按 issue 接力推进

它适合：

- 从 0 到 1 的新项目
- 大型重构
- 跨语言 port / migration
- 一条功能链路涉及多人天工作量的复杂任务

## 安装

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/XiXian42/issuely/main/install.sh | bash
```

安装过程会：

1. 安装 `issuely` 命令
2. 检测你本机已有的 agent
3. 让你选择一个默认 agent（用于 planner / dev / review）
4. 再为 dev / review 选择模型和 thinking / effort；planner 默认使用该 agent 的内置模型，thinking 建议为 `high`
5. 把默认配置写入 `~/.issuely/config.json`

前提：系统里至少已经安装一个支持的 agent。

## 极简终端 Demo

```console
$ mkdir html-to-pptx-rs
$ cd html-to-pptx-rs

$ issuely prd
# 告诉它：
# “我要把一个 JS 的 HTML→PPTX 工具完整 port 到 Rust，保留 CLI、HTTP 服务和测试迁移。”

$ issuely issue

# 可选：开发前先细化复杂 issue；简单项目可以跳过
$ issuely issue refine

$ issuely dev
```

最少只需要记住 3 个必需命令：

```console
$ issuely prd
$ issuely issue
$ issuely dev
```

如果 issue 很大、依赖很多、验收条件不够清楚，再加一步可选 refine：

```console
$ issuely issue refine
```

## 运行后会得到什么

```text
./config.json                 项目配置
./workspace/
  docs/prd.md                 需求文档
  docs/spec-project.md        工程规格
  docs/coding-style.md        开发约束
  issues/                     有序任务包
  status.md                   进度状态机
  memo.md                     项目记忆
  logs/                       运行日志与验收报告
```

也就是说：你不是得到“一次回答”，而是得到一套可继续推进的项目工作区。

## 常用命令

```bash
issuely prd           # 收集 / 生成 PRD
issuely issue         # 生成 / 重写 issue 包
issuely issue refine  # 可选：开发前 refine 复杂 issue
issuely dev           # 启动 dev/review 流水线
issuely config        # 修改 ~/.issuely/config.json（交互）
issuely status        # 查看当前目录的有效配置与可用 agent
issuely install-hooks # 为当前项目安装 git hooks
```

## 配置

Issuely 有两层配置：

1. **全局默认配置**：`~/.issuely/config.json`
2. **项目覆盖配置**：`./config.json`

优先级：

```text
env overrides > ./config.json > ~/.issuely/config.json > built-in defaults
```

默认情况下，Issuely 只注入 role、model、thinking / effort，不主动指定工具白名单、权限模式、sandbox 或 approval 策略；这些保持各 agent 自己的 CLI 默认行为。只有在 `agents` 配置里显式填写时，才会额外传递对应参数。

### 全局配置示例

```json
{
  "version": 1,
  "roles": {
    "planner": {
      "agent": "pi",
      "model": null,
      "thinking": null
    },
    "dev": {
      "agent": "pi",
      "model": "openai-codex/gpt-5.5",
      "thinking": "high"
    },
    "review": {
      "agent": "claude",
      "model": "sonnet",
      "thinking": "low"
    }
  }
}
```

### 项目配置示例

```json
{
  "projectName": "my-project",
  "workspace": "workspace",
  "language": "Rust",
  "roles": {
    "dev": {
      "model": "gpt-5.5",
      "thinking": "high"
    },
    "review": {
      "model": "claude-sonnet-4-6",
      "thinking": "low"
    }
  }
}
```

## 支持的 Agent

| Agent | 模型参数 | thinking / effort 参数 |
|---|---|---|
| `pi` | `--model` | `--thinking` |
| `omp` | `--model` | `--thinking` |
| `claude` | `--model` | `--effort` |
| `codex` | `--model` | `-c model_reasoning_effort=...` |

## 框架自测

```bash
.issuely/tests/e2e.sh
```

覆盖：

- 全局配置 + 项目配置合并
- 多 role 配置注入
- `issuely` 入口
- run_while 调度
- dev / review 串行推进
