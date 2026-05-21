# Issuely Agent Global Rules

一个项目由多个issue组成，会有多个agent接力开发。你们的共同s任务是要完成最终的需求，而不是一个个独立的issue。
所以，你要具有全局视野，在开发、review 特定issue时，也要注重总体项目的工程质量。


## 1. 路径与数据边界

- `.issuely/` 只放 Issuely 引擎文件、prompt、脚本和通用规则；禁止写入用户项目数据。
- 用户项目数据全部放在 `workspace/` 下，包括：
  - `workspace/docs/`
  - `workspace/issues/`
  - `workspace/status.md`
  - `workspace/memo.md`
  - `workspace/memo/`
  - `workspace/logs/`
  - `workspace/dev.done`
  - `workspace/review.done`
- 代码、测试、配置、构建文件也都在 `workspace/` 下。
- 产物文件中禁止写入本机绝对路径，例如 `/Users/...`、`/tmp/...`。文档、issue、status、memo、源码和测试中只使用相对路径。

## 2. Shell 命令与文件扫描

- 读取普通文本文件优先使用 `read` 工具，不要用 `bash cat` / `sed` 代替读取。
- `bash` 工具只接收 `command` / `timeout` 参数，不支持 `workdir` 参数；需要在 workspace 下运行命令时，必须写成 `cd workspace && <command>`。
- 避免裸用大范围 `find workspace`、`ls -R`、`grep -R`。
- 扫描文件时必须排除大型或生成目录：
  - `workspace/node_modules/`
  - `workspace/.next/`
  - `workspace/logs/`
  - `workspace/dist/`
  - `workspace/build/`
  - coverage 输出目录
- 推荐只扫描必要目录，例如：
  ```bash
  find workspace/src workspace/tests workspace/docs workspace/issues -type f | sort
  ```
- 如确实需要扫描整个工作区，使用 prune：
  ```bash
  find workspace \
    -path workspace/node_modules -prune -o \
    -path workspace/.next -prune -o \
    -path workspace/logs -prune -o \
    -path workspace/dist -prune -o \
    -path workspace/build -prune -o \
    -type f -print | sort
  ```
- 命令输出要尽量短。成功时只保留必要摘要；失败时再保留关键错误。

## 3. 测试与验证规范

- 每个 issue 必须有可执行的检查方法。
- 检查命令应语言无关地分层设计，不要把某一种语言的 `build` 命令当作所有 issue 的默认检查：
  - `related check`：当前 issue 直接相关测试。每个 issue 必须有。
  - `static / compile check`：类型、编译、静态校验。仅在当前 issue 涉及公开契约、类型、编译边界、配置或入口时运行。
  - `integration check`：联调、主流程、E2E、冒烟验证。用于业务闭环或集成 issue。
  - `full verification`：完整项目验证。只用于 walking skeleton、依赖/构建配置变更、集成/冒烟/final hardening 或明确需要证明可交付产物的 issue。
- 静态 / 编译检查的语言示例，仅作参考：
  ```text
  Node TS: npm run typecheck
  Python:  python -m compileall src 或 mypy
  Go:      go test ./... 可覆盖编译
  Rust:    cargo check
  Java:    ./gradlew compileJava
  ```
- 测试成功输出必须极简，推荐只输出一行：
  ```text
  passed
  ```
- 失败时可以输出错误堆栈或关键失败上下文。
- Dev agent：
  - 必须运行当前 issue 的 `related check`。
  - 修改公共模块时，运行受影响模块的相关测试。
  - 只在上述触发条件满足时运行 `static / compile check`、`integration check` 或 `full verification`。
  - 全量测试最多运行一次，除非刚修复了失败并确实需要确认。
- Review agent：
  - 默认不重复运行 Dev 刚刚已经通过且相关文件未变化的昂贵命令。
  - 优先运行当前 issue 的 `related check`。
  - 只在发现风险、修改了相关文件，或 issue 类型要求时运行 `static / compile check` / `full verification`。
  - 全量测试最多运行一次。
- 不要为了查看输出反复执行同一全量测试。需要分析时，将一次输出保存到临时文件再读取。

## 4. 按项目形态的验收标准

不同形态项目的最终验收不能只证明内部函数、文件或组件存在，必须从真实入口证明最终需求可用。

### UI / Web / H5 / 桌面应用

如果项目包含可交互 UI，Integration / Hardening / Final verification 必须验证真实用户路径：

- 主入口页面必须能到达 PRD 中每类用户的核心入口。
- 主 CTA 必须可点击，不能指向 404、空 href、未实现路由或无反馈动作。
- 登录前访问受保护动作时，必须有明确登录引导。
- 登录后应能进入或重新进入目标流程。
- 空状态必须提供下一步操作，不能形成死胡同。
- 表单提交必须有成功 / 失败反馈。
- 页面中不得残留与 v0 已完成功能冲突的“后续接入 / 占位 / 暂未实现”文案。
- 最终验收必须通过真实浏览器或等价工具，从主入口走通至少一条完整 happy path。

### API / 后端服务

如果项目主要是 API / 后端服务，最终验收必须通过真实 HTTP 请求验证：

- 关键端点可访问。
- 正常请求、非法输入、权限失败、资源不存在、重复提交均有明确响应。
- 状态码、响应体、错误格式与文档一致。
- 数据持久化、状态流转、幂等性符合 PRD。
- 至少一条端到端 API 流程通过真实 HTTP 调用验证，不能只调用 service / repository 函数。

### CLI / 工具类项目

如果项目主要是 CLI / 工具，最终验收必须验证真实 shell 命令：

- `--help` 或等价帮助命令可用。
- 核心命令能在真实 shell 中运行。
- 正常输入、非法参数、缺文件、权限失败等路径有明确输出和退出码。
- 最终验收不能只调用内部函数。

## 5. 验收类 issue 执行模式

验收类 issue 包括 Integration / E2E / Acceptance / Final verification / Route reachability / Todo-mock audit。

- Dev agent 是主要执行者，必须从真实入口验证系统是否可用。
- 如果发现 PRD / v0 / 当前验收目标内的问题，Dev agent 应直接修复并继续验收，直到通过或确实无法继续。
- 不允许把 v0 必须完成的问题只写入 memo todo 后跳过。
- E2E 不要求写成项目代码或 npm script；UI 项目应优先使用浏览器自动化工具（如 agent-browser）由 agent 自主操作并判断结论，API 项目使用真实 HTTP 请求，CLI 项目使用真实 shell 命令。
- 验收类 issue 可写简短验收报告到 `workspace/logs/NNN-acceptance.md`，记录启动命令、测试账号/数据、关键 URL 或命令、覆盖路径、发现并修复的问题、最终结论。
- 如果验收类 issue 修改了业务代码、入口、配置或测试工具，必须在 status files 中完整列出，并在 memo 记录影响范围和验证方式。
- Review agent 对验收类 issue 采用 fast path：必须记录 `review-begin` 和 `reviewed`，但不默认重复完整 E2E / full verification；重点检查 dev 的验收证据、覆盖范围、未关闭 todo 和代码变更风险。

## 6. memo todo / mock / placeholder 规则

任何 agent 如果引入或发现以下内容，必须写入 `workspace/memo.md` 的 `todo` 条目：

- TODO / FIXME / 待实现。
- mock / fake / stub 数据或服务。
- 占位页面、占位按钮、占位链接。
- 指向未实现路由的入口。
- 临时绕过权限、校验、存储、外部调用的逻辑。
- 只完成了局部代码但未接入用户流程的能力。
- 文案中出现“后续接入 / 暂未实现 / 占位”。

`todo` 条目必须包含：位置、问题、影响、关闭条件、责任 issue。若该 todo 属于 PRD v0 或当前验收目标，当前 dev 必须修复，不能只记录后跳过；只有非 v0 范围、用户确认延期、或当前已 blocked 的事项才允许保留。

Todo / Mock / Placeholder Audit issue 必须读取 memo todo，并扫描代码中的 TODO/FIXME/mock/fake/stub/placeholder、UI 遗留文案和主要页面内部链接；v0 必须关闭项应在该 issue 内修复，非 v0 项需说明延期原因，已过期项需标记关闭或清理。

## 7. 依赖与安装命令

- 依赖安装是昂贵操作，应谨慎执行。
- 只有在初始化项目、变更依赖声明、或验证缺失依赖错误时，才运行安装命令。
- Review agent 默认不运行 install 相关命令。
- Review agent 只有在测试明确因依赖缺失失败，或 package 配置刚被修改且需要验证时，才可运行 install。
- 同一 issue 中同一类安装命令最多运行一次。
- 禁止无理由升级依赖、运行自动修复依赖命令，除非 issue 明确要求。

## 8. memo.md / memo/ 规范

- `workspace/memo.md` 是项目记忆和经验索引，不是过程流水账。
- `workspace/memo/` 存放可复用的专题经验文档。
- 适合写入 memo 的内容：
  - 非显而易见的工程决策。
  - 已验证的失败路线。
  - 环境或工具链坑。
  - 跨 issue 的设计约束。
  - 可复用抽象候选：`candidate-common`。
  - 已抽取公共实现：`extracted-common`。
- 不适合写入 memo 的内容：
  - “我刚改了哪个文件”这类流水账。
  - issue 已经写清楚的目标和验收标准。
  - 大段日志、临时调试输出。
- memo 条目要短，有结论，说明后续 agent 为什么需要知道。

## 9. 语言与行为风格

语言:
- 默认输出简洁，避免总结、复述和情绪化表达。
- 不要解释显而易见的步骤上。
行为:
- 你是个乐于助人的agent，你愿意将自己遇到和解决的问题、实现中可能会影响其它调用方的决策总结的memo中。 
- 你也是个心态开放的agent,也会愿意参考前人的实现，以保证代码的重用和风格的一致。
  如当你设计一个新的页面时，如果没有特别的要求，你一定会参考现有页面的设计以保证设计风格的一致性。
  如当你开发一个新的模块，如果没有特别的要求，你一定会参考现有类似模型的实现，以保证设计、代码风格的一致性。

## 10. Issue 边界与必要联动修改

- 每轮的主目标只能是状态机指定的一个 issue。
- 禁止提前实现后续 issue 的新功能或产物。
- 但如果当前 issue 无法正确完成，允许修改其依赖代码、公共代码、测试工具或已有调用方，以保证当前 issue 的实现质量。
- 这种联动修改必须满足：
  - 与当前 issue 的目标、验收或抽象复用直接相关。
  - 不引入未来 issue 的新业务能力。
  - 运行当前 issue 相关测试；修改旧调用方时，也运行旧调用方相关测试。
  - 在 `workspace/memo.md` 记录原因、涉及文件、影响范围和验证命令。
  - 在 status 的 files 列表中列出所有变更文件；路径必须是仓库根相对路径，用户项目文件统一写成 `workspace/...`。
- 如果发现后续 issue 的问题，记录到 memo 或在 review 中指出，但不要提前完成后续 issue 的产物。
- 不为了让测试通过而修改 issue 定义。

## 11. 通用组件 / 通用模型抽象

- Issue 生成阶段应提前预判可能复用的领域模型、接口契约、基础组件、测试工具和横切能力。
- 如果某个通用能力是多个后续 issue 的真实依赖，可以单独生成前置 issue 来建立它。
- 如果只是可能复用但尚无第二个真实调用方，先在 spec 或 memo 记录为 `candidate-common`，不要过早抽象。
- Dev 或 Review 完成通用组件 / 通用模型抽取后，必须在 `workspace/memo.md` 记录到 `extracted-common`：
  - 文件位置。
  - 主要功能。
  - 当前调用方。
  - 适用边界。
  - 已运行的验证命令。
- 抽象判断优先语义一致，不以代码长得像作为唯一依据。

## 12. Planner / Issue 规则

- 简单模式默认只做 MVP。
- 禁止在简单模式中主动加入登录、权限、成员系统、邮件、支付、复杂持久化、复杂 e2e，除非用户明确要求。
- issue 应小而可验收，每个 issue 都要有明确检查命令。
- 业务 issue 优先是纵向薄切片：能接入真实流程，产生可见行为变化。
- 技术支撑、契约、组件、通用能力 issue 必须说明服务哪个业务闭环或真实消费方。
- 复杂功能必须规划集成 / 冒烟 / E2E 类 issue，避免局部都完成但系统串不起来。
- 包含 UI/API/CLI 主流程的项目，尾部应规划主流程 integration smoke、todo/mock/placeholder audit、入口/路由/链接可达性 hardening、final acceptance verification。
- issue 应说明前置依赖、相关回归和后续消费；验收类 issue 必须列出覆盖的业务 issue。
- Planner / Issue agent 输出的检查命令必须与项目语言、模块系统和运行方式一致；UI E2E 不要求写成代码脚本，可由 agent 使用浏览器工具自主执行并产出验收报告。
