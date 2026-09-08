# kitex 模板：清理重复声明同一输出路径的模板文件（admin-services-kitex / rbac-kitex / rule-center）

- Issue: #43（汇总 Issue，本设计对应其下第 2/3/4 个子任务；第 1 个子任务 admin-bff-hertz 已在 #52 完成，见 `2026-09-08-admin-bff-hertz-duplicate-templates-design.md`）
- 范围：`admin-services-kitex/kitex-template`（18 组）、`rbac-kitex/kitex-template`（8 组）、`rule-center/kitex-template`（18 组），共 44 组重复 `path:` 声明
- 处置方式：按目录拆成 3 个独立 Sub-Issue / PR，与 #52 建立的先例一致

## 背景

用已有脚本 `scripts/check-duplicate-template-paths.sh` 对三个目录扫描，确认存在 44 组重复，数量与 Issue #43 原始描述一致（18 + 8 + 18）。`admin-bff-hertz` 已在 #52 清理完毕，不在本次范围内。

## 判定方法论（延续 #52 的做法）

对每一组重复 `path:`，逐组比对两份文件的 `body` 内容（而非只看文件名/注释头），确认：

1. 是否存在**真实的功能差异**（新增字段、条件包裹 `{{if}}`、错误码映射等）而非只是转义写法（`{{ "{" }}` vs 裸 `{`）或缩进风格的不同；
2. 是否存在**硬编码残留**——即导出版本把模板变量（如 `{{ToLower .ServiceName}}`、`{{.Module}}`）替换成了导出时那个具体项目的字面值，这是真实 bug，被选中会导致新项目生成出写死的错误内容；
3 是否存在**过时/复制粘贴痕迹**（如注释头写着别的服务名、缺失后来新增的依赖注入）。

抽样结果印证了以下几类模式（三个目录不完全一致，需逐组核实，不能全部套用同一条）：

| 模式 | 特征 | 默认结论 |
|---|---|---|
| A. 导出版 vs 手工版（`# ncgo exported template` vs `# Kitex custom template`），约 25 组 | 逻辑等价，仅转义/缩进不同；个别手工版有硬编码残留（如 rbac-kitex 的 `server.yaml` 写死 `"rbac"` 而导出版正确使用 `{{ToLower .ServiceName}}`；admin-services-kitex 的 `server.yaml` 注释头写着"Edited for rbac-kitex"且缺 rulecenter 相关依赖注入） | 优先保留导出版，除非手工版有导出版没有的真实新增内容（此时需合并，参考 #52 的 conf.go/response.go 处置方式） |
| B. 导出版 vs "shared/preset" 手工版（`# Shared rate-limit ...`、`# Kitex rule-center preset ...`），约 16 组 | 这些是 ratelimit-hertz / rule-center 相关能力被移植到 kitex 服务时手工引入的，命名不遵循 `# Kitex custom template` 惯例但本质相同 | 同 A，逐组 diff 后判定，不能仅凭注释头字样跳过审查 |
| C. 两份都是导出版（`internal/base/server/server.go`，3 组：admin-services-kitex、rbac-kitex、rule-center 各一） | 说明历史上被导出过不止一次；rule-center 的一份实际是"preset"（`ratelimit_server.yaml`，注释头虽非 exported 但内容是刻意为 rule-center 自身包结构定制的 server 装配），需要对照该服务当前真实源码结构核实哪份才是正确的 | 不能默认"两个都导出就随便留一个"，必须结合该服务实际 handler/repo/usecase 包路径确认 |

## 各子任务范围与处置流程

三个目录各建一个 Sub-Issue，处置流程一致：

1. 用 `scripts/check-duplicate-template-paths.sh <dir>` 拉出该目录全部重复组列表；
2. 对每组按上表方法论 diff 判定，保留一份、删除另一份（如手工版有导出版没有的真实内容，先合并再删）；
3. 目录内清理完成后重跑检查脚本确认归零；
4. 用 `ncgo new scratch --module github.com/acme/scratch --kind kitex --db none --dir /tmp/scratch-<dir> --template-dir <dir>`（参考 `template-build-check.yml` 现有 `build-check` job 的 matrix 写法）渲染 + `go build ./... && go vet ./...` 验证生成产物可编译；
5. 把该目录加入 `.github/workflows/template-build-check.yml` 的 `duplicate-path-check` job 检查列表（该 job 当前只检查 `admin-bff-hertz/hertz-template`，脚本本身已支持多目录参数，一行改动）。

三个目录全部清理完成后，`duplicate-path-check` 覆盖全部 4 个模板目录，Issue #43 可关闭。

## 验证计划

- 本地：每个子任务清理完成后跑 `scripts/check-duplicate-template-paths.sh <dir>`（应无输出、exit 0）+ `ncgo new scratch ...` 渲染编译验证
- CI：`template-build-check.yml` 的 `duplicate-path-check` 与 `build-check` 两个 job 均需通过

## 后续

- 三个 Sub-Issue 建议顺序：rbac-kitex（8 组，最小）→ admin-services-kitex（18 组）→ rule-center（18 组，含 preset 特殊情况，放最后处理便于复用前两个子任务积累的判定经验）
