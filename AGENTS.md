- 使用中文回答；注释、面向用户的文案、文档和提交信息使用英文；
- 每个提交都加上类型前缀，例如 `feat:`、`fix:`、`refactor:`、`test:` 或 `docs:`；
- 保持代码可读、职责清晰；为未来扩展设计稳定的边界；
- 完成代码修改后，运行相关检查并立即提交；
- 遇到同一个文件多人并发修改时，尽量保留别人的修改并说明；

## Review Standard

Before submitting or merging a change, review the implementation from all of the following angles:

- **Business intrusiveness**: confirm that the change does not alter existing business behavior, data ownership, or user expectations beyond the stated scope. Call out migrations, compatibility risks, and irreversible effects.
- **Interaction impact**: verify loading, error, empty, retry, keyboard, accessibility, and responsive states. Check that existing flows remain predictable and that new prompts or defaults do not interrupt normal work.
- **Performance impact**: consider startup time, steady-state latency, throughput, memory, CPU, I/O, network traffic, and battery usage. Measure or document the reason when a change adds work to a hot path.
- **Out-of-the-box usability**: ensure a fresh checkout can build, run, and recover with the documented prerequisites and defaults. Avoid hidden credentials, machine-specific paths, manual cleanup, or undocumented setup steps.
- **Functional coupling**: keep boundaries explicit and dependencies minimal. Check whether the change creates unnecessary coupling between domain logic, UI, storage, transport, or platform code, and preserve a straightforward path for future replacement.

Record any material risk and its mitigation in the change description before requesting review. Do not mark a change ready while any of these dimensions remains unexamined.

## Contribution Identity

Only identifiable individual developers may submit contributions. Do not accept commits or pull requests authored by organizations, bots, shared accounts, or other non-personal identities. Company-domain email addresses are not accepted as contributor identities; ask the contributor to re-submit with a personal, verifiable identity before merging.
