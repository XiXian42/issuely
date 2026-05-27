# Issuely

> Issue-driven Agentic Development —— 用 issue 作为最小可交付单元，
> 让 planner / dev / review 多 agent 接力，把一个想法推进到可交付项目。

## 安装

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/XiXian42/issuely/main/install.sh | bash
```

安装过程会：

1. 安装 `issuely` 命令到 `~/.local/bin/issuely`
2. 引导你选择 planner / dev / review 使用的 agent、模型和 thinking / effort
3. 把全局默认配置写入 `~/.issuely/config.json`

前提：系统里至少已经安装一个支持的 agent。

## 支持的 Agent

| Agent | 模型参数 | thinking / effort 参数 |
|---|---|---|
| `pi` | `--model` | `--thinking` |
| `omp` | `--model` | `--thinking` |
| `claude` | `--model` | `--effort` |
| `codex` | `--model` | `-c model_reasoning_effort=...` |

## 使用

在你想创建项目的目录执行：

```bash
mkdir my-project
cd my-project
issuely prd
issuely issue
issuely dev
```

常用命令：

```bash
issuely prd           # 收集 / 生成 PRD
issuely issue         # 生成 / 重写 issue 包
issuely issue refine  # 开发前 refine 复杂 issue
issuely dev           # 启动 dev/review 流水线
issuely config        # 修改 ~/.issuely/config.json（交互）
issuely status        # 查看当前目录的有效配置与可用 agent
issuely install-hooks # 为当前项目安装 git hooks
```

> `issuely` 默认把“当前目录”当作项目根，请在项目根运行。

## 配置层级

Issuely 现在有两层配置：

1. **全局配置**：`~/.issuely/config.json`
   - 放默认 agent / model / thinking / agent-specific runtime 选项
2. **项目配置**：`./config.json`
   - 放当前项目的 `workspace`、`projectName`、`language`，以及需要覆盖的 role 配置

优先级：

```text
env overrides > project config.json > ~/.issuely/config.json > built-in defaults
```

## 全局配置示例

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
      "thinking": "high"
    }
  },
  "agents": {
    "pi": {
      "tools": "",
      "trace": 1
    },
    "omp": {
      "tools": ""
    },
    "claude": {
      "permissionMode": "dontAsk"
    },
    "codex": {
      "sandbox": "workspace-write",
      "approval": "never"
    }
  }
}
```

## 项目配置示例

```json
{
  "projectName": "my-project",
  "workspace": "workspace",
  "language": "Rust",
  "roles": {
    "review": {
      "model": "claude-sonnet-4-6",
      "thinking": "xhigh"
    }
  }
}
```

## 目录约定

```text
./config.json                    项目配置（项目级覆盖）
./workspace/                     用户产物
  docs/                          PRD / spec / coding-style / tracking docs
  issues/                        有序任务包
  src/, tests/, ...              项目代码
  status.md                      进度状态机（由工具维护）
  memo.md, memo/                 项目记忆与经验文档
  logs/                          运行日志与验收报告
```

框架代码来自安装目录；项目里不再要求放置 `start.sh` 或 `.issuely` 软链。

## 兼容模式

如果你已经在旧项目里放了：

- `./start.sh`
- `./.issuely`

它们仍可继续工作。`./start.sh` 仍是兼容入口；新推荐入口是 `issuely`。

## 开发与测试

框架仓库自测：

```bash
.issuely/tests/e2e.sh
```

覆盖内容包括：

- config 加载与路径解析
- 全局配置 + 项目配置合并
- `.issuely` 符号链接与全局安装路径
- run_while 调度 + dev/review 串行推进
- `issuely` 包装入口
