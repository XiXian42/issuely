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

## 4. 依赖与安装命令

- 依赖安装是昂贵操作，应谨慎执行。
- 只有在初始化项目、变更依赖声明、或验证缺失依赖错误时，才运行安装命令。
- Review agent 默认不运行 install 相关命令。
- Review agent 只有在测试明确因依赖缺失失败，或 package 配置刚被修改且需要验证时，才可运行 install。
- 同一 issue 中同一类安装命令最多运行一次。
- 禁止无理由升级依赖、运行自动修复依赖命令，除非 issue 明确要求。

## 5. memo.md / memo/ 规范

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

## 6. 语言与行为风格

语言:
- 默认输出简洁，避免总结、复述和情绪化表达。
- 不要解释显而易见的步骤上。
行为:
- 你是个乐于助人的agent，你愿意将自己遇到和解决的问题、实现中可能会影响其它调用方的决策总结的memo中。 
- 你也是个心态开放的agent,也会愿意参考前人的实现，以保证代码的重用和风格的一致。
  如当你设计一个新的页面时，如果没有特别的要求，你一定会参考现有页面的设计以保证设计风格的一致性。
  如当你开发一个新的模块，如果没有特别的要求，你一定会参考现有类似模型的实现，以保证设计、代码风格的一致性。

## 7. Issue 边界与必要联动修改

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

## 8. 通用组件 / 通用模型抽象

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

## 9. Planner / Issue 规则

- 简单模式默认只做 MVP。
- 禁止在简单模式中主动加入登录、权限、成员系统、邮件、支付、复杂持久化、复杂 e2e，除非用户明确要求。
- issue 应小而可验收，每个 issue 都要有明确检查命令。
- 业务 issue 优先是纵向薄切片：能接入真实流程，产生可见行为变化。
- 技术支撑、契约、组件、通用能力 issue 必须说明服务哪个业务闭环或真实消费方。
- 复杂功能必须规划集成 / 冒烟 / E2E 类 issue，避免局部都完成但系统串不起来。
- Planner / Issue agent 输出的检查命令必须与项目语言、模块系统和运行方式一致。
