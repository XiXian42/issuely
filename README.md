# Issuely

> Issue-driven Agentic Development —— 用 issue 作为最小可交付单元，
> dev/review 双 agent 串行接力，把一个想法跑成一个可交付项目。

## 用法

```bash
./start.sh           # 交互模式：收集需求 → 规划 → 自动开发与审查
./start.sh -c        # 续跑模式：跳过规划，直接重启 run_while
./start.sh -h        # 帮助
```

第一次跑会问你 4 个问题（项目名、技术栈、规划深度 A/B、需求描述），然后 Planner agent
把需求拆成 `workspace/docs/` 与 `workspace/issues/`，dev/review 双 agent 接力直到
`workspace/dev.done` 与 `workspace/review.done` 双立。

## 目录

```
./start.sh                       唯一用户入口
./config.json                    项目配置（单一事实源；首次运行会生成）
./config.example.json            配置模板
./workspace/                     用户产物（gitignore，每次跑会重建）
  docs/                          系统设计与规范（Planner 生成）
  issues/                        有序任务包
  src/, tests/, …                项目代码
  status.md                      进度状态机（请勿手改）
  memo.md, memo/                 项目记忆与经验文档
./.issuely/                      框架代码（黑盒，可符号链接到全局位置）
  bin/                           run_dev / run_review / run_while / status_manager
  core_prompts/                  dev / review / planner 的 prompt 模板
  lib/config.cjs                 配置加载器（single source of truth）
  tests/e2e.sh                   端到端集成测试
  logs/                          运行日志（gitignore）
```

## 全局共享 `.issuely`

`.issuely` 可以是项目内目录，也可以是符号链接指向全局安装路径：

```bash
ln -s ~/issuely-framework ~/proj-A/.issuely
ln -s ~/issuely-framework ~/proj-B/.issuely
```

或者在 start.sh 调用前显式 export：

```bash
ISSUELY_META_DIR=~/issuely-framework ./start.sh
```

## 配置 (`config.json`)

| 字段 | 说明 | 默认 |
|---|---|---|
| `projectName` | 项目名（人类可读） | `my-project` |
| `workspace` | 工作区目录（相对项目根） | `workspace` |
| `language` | 技术栈/语言（注入到 prompt） | `unspecified` |
| `originalRequirement` | 原始需求描述 | `""` |
| `models.dev` | dev agent 模型 | `openai-codex/gpt-5.5` |
| `models.review` | review agent 模型 | `openrouter/anthropic/claude-sonnet-4.6` |
| `models.planner` | planner 模型（null = 用 pi 默认） | `null` |
| `tools` | 传给 pi 的 `--tools`（空 = 用 pi 默认） | `""` |
| `piTrace` | 1=过滤 JSON 流；0=直出 stdout | `1` |

## 测试

```bash
.issuely/tests/e2e.sh
```

用 fake pi（无真实 LLM 调用）覆盖：config 加载、符号链接、PI_TOOLS 切换、
完整 run_while 流水线、续跑模式、空项目错误处理。

## 方法论

参见 `issue-driven-agentic-development.md`（如已纳入仓库），核心约束：
每轮 agent 只做一个 issue，状态机由工具维护，dev/review 严格分离，
全部完成才能 touch 顶层 `.done` 标志。
