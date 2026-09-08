# admin-bff-hertz: 清理重复声明同一输出路径的模板文件

- Issue: #43（作为汇总 Issue 保留，本设计对应其下第一个子任务）
- 范围：仅 `admin-bff-hertz/hertz-template` 目录，其余 3 个模板目录（admin-services-kitex、rbac-kitex、rule-center）作为后续独立 Issue/PR 处理

## 背景

`admin-bff-hertz/hertz-template` 下存在 6 组文件，每组两个 `.yaml` 都声明了完全相同的输出 `path:`：一份是短文件名、注释头为 `# Hertz custom template` 的手工维护版本；另一份是长文件名（由 path 全路径下划线拼接而成）、注释头为 `# ncgo exported template` 的自动导出版本。生成器加载这两份文件时的排序/覆盖行为未定义，属于未清理的历史遗留。

## 根因分析

对全部 6 组做了逐组 body diff（提取 YAML 的 `body` 字段后 `diff -u`），发现一致的模式：

- "导出版" 是某次 `ncgo export templates` 从**已经渲染出的具体项目**反向导出的快照。导出过程把 body 里所有裸露的 Go 花括号转义成了 `{{ "{" }}` / `{{ "}" }}`（渲染结果不变，但明显更难维护，是一次性快照的痕迹）。
- 其中两组（`conf.go`、`Makefile`）导出快照发生在**模板变量已被替换成具体值**之后，把这些具体值錯误地固化进了模板 body，是真实的功能缺陷：如果生成器排序恰好选中这份"导出版"，任何新项目生成出来的配置/构建产物都会被写死成快照当时的值。

## 六组的处置结论

| 路径 | 保留（手工版） | 删除（导出版） | 结论 | 理由 |
|---|---|---|---|---|
| `internal/base/conf/conf.go` | `conf_go.yaml` | `internal_base_conf_conf_go.yaml` | 先合并再删除 | 导出版多出 `JWTConfig`/`GRPCConfig` 类型及字段（真实新功能，需要移植进手工版并保持模板变量写法），同时硬编码了 `Registry.Name: "adminbffservice"`（需要移植时改回 `{{ToLower .ServiceName}}`） |
| `internal/base/data/data.go` | `data_go.yaml` | `internal_base_data_data_go.yaml` | 直接删除 | 导出版丢失了 `{{if .WithDatabase}}...{{end}}` 条件包裹，会导致 `WithDatabase=false` 的项目也生成数据库代码——是功能回退，无价值 |
| `internal/pkg/errcode/errcode.go` | `errcode_go.yaml` | `internal_pkg_errcode_errcode_go.yaml` | 直接删除 | body 内容完全一致（仅转义写法不同），纯冗余 |
| `internal/pkg/middleware/middleware.go` | `middleware_go.yaml` | `internal_pkg_middleware_middleware_go.yaml` | 直接删除 | 仅转义写法不同，无实质内容差异 |
| `internal/pkg/response/response.go` | `response_go.yaml` | `internal_pkg_response_response_go.yaml` | 先合并再删除 | 导出版含更精细的 signature/token 错误码到 HTTP 状态码/消息的映射（真实改进，与 conf.go 的 JWT 改动同源），需移植进手工版 |
| `Makefile` | `makefile_yaml.yaml` | `Makefile.yaml` | 直接删除 | 导出版硬编码了 `APP_NAME = admin-http`，若被选中会导致任何新项目的 Makefile 都写死这个服务名——真实 bug |

## 实施步骤

1. **conf.go 合并**：把 `internal_base_conf_conf_go.yaml` body 中的 `JWTConfig`、`GRPCConfig`、`ClientConfig`、`RetryConfig` 类型定义及 `Config` 结构体里对应字段，移植进 `conf_go.yaml`；`Registry.Name` 保持 `{{ToLower .ServiceName}}` 不还原为硬编码值。合并完成后删除 `internal_base_conf_conf_go.yaml`。
2. **response.go 合并**：把 `internal_pkg_response_response_go.yaml` 中细化的 `CodeSignature*`/`CodeToken*`/`CodeClaimsInvalid`/`CodeSessionInvalid` 错误码定义、`StatusFromCode`/`MsgFromCode` 里对应的 case 分支，移植进 `response_go.yaml`。合并完成后删除 `internal_pkg_response_response_go.yaml`。
3. **直接删除**：`internal_base_data_data_go.yaml`、`internal_pkg_errcode_errcode_go.yaml`、`internal_pkg_middleware_middleware_go.yaml`、`Makefile.yaml`。
4. **新增 CI 检查**：新增脚本（例如 `scripts/check-duplicate-template-paths.sh`），扫描指定模板目录下所有 `.yaml` 文件的 `path:` 字段，同一目录内出现重复即以非零状态退出。本次仅对 `admin-bff-hertz/hertz-template` 生效（写成显式目录列表，而非扫描全仓库），避免其余 3 个尚未清理的模板目录把 CI 标红；其余目录清理完成后在各自的 PR 里把目录加入列表。接入 `.github/workflows/template-build-check.yml`（新增一个 job，或在现有 job 前置一步）。
5. **补齐构建校验矩阵**：把 `admin-bff-hertz` 加入 `template-build-check.yml` 现有 `matrix.template` 列表（当前只有 `rbac-kitex`、`admin-services-kitex`），复用同样的 `ncgo new scratch && go build && go vet` 流程，确保合并后的 conf.go/response.go 模板在真实渲染+编译场景下不出问题。

## 验证计划

- 本地：`ncgo new scratch --module github.com/acme/scratch --kind hertz --dir /tmp/scratch-admin-bff-hertz --template-dir admin-bff-hertz/hertz-template`，随后 `go build ./... && go vet ./...`，并抽查生成的 `conf.go`/`response.go`/`Makefile` 内容确认无硬编码残留、JWT/GRPC 字段和细化错误码均已生效。
- CI：新增/修改后的 `template-build-check.yml` 跑通（含新加入的 admin-bff-hertz matrix 项与新增的重复 path 检查 job）。

## 后续（不在本次范围内）

- Issue #43 保留为汇总 Issue，admin-services-kitex（18组）、rbac-kitex（8组）、rule-center（18组）三个目录分别拆成独立 Issue，复用本设计里验证出的判定思路（导出版 vs 手工版、转义/硬编码信号、逐组 diff 判定是否需要合并字段）。
- 重复 path 检查脚本随每个后续 Issue 清理完成后，把对应目录加入检查列表，最终覆盖全部 4 个模板目录。
