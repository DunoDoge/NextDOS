# AGC 隐私合规托管与许可义务

覆盖范围：上架审核要求的 AGC 标准化隐私声明托管与首次启动弹窗门控（禁止自绘弹窗）、GPL-2.0-or-later 传染性与随附源码义务（ND-006、ND-012）。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-006] 隐私弹窗：AGC 标准化托管，禁止自绘
- **类别**: constraint
- **状态**: merged
- **来源**: zcode/plans/plan-sess_534a1bd8-7162-4ee8-880d-eead486c5f63.md（隐私弹窗方案）; AGENTS.md（Privacy consent gotcha）
- **日期**: 2026-09-18
- **关联**: [[DormHub]]（同用 AGC 托管隐私体系，DH-012）
- **内容**: 接入 AGC 标准化隐私声明托管服务后，首次打开展示**系统标准化弹窗**，自绘弹窗将被发布审核驳回。实现：module.json5 metadata 预置 `appgallery_privacy_hosted=1` + `appgallery_privacy_link_privacy_statement=<托管链接>`（上架后 AGC 托管配置接管，此配置供 hdc 本地 debug 包生效；需 debug 构建 + 应用市场可用 + 联网）；`Index.initPrivacy` 用 `privacyManager`（@kit.AppGalleryKit，5.0.0(12)+）门控引擎 boot：`getAppPrivacyResult()` 判 `PRIVACY_AGREEMENT(1) && FULL_MODE_AGREED(1)`（DISAGREED(0)/REQUIRE_RESIGNING_VERSION_UPDATE(2) 均视为未签署）→ 已签署直接 boot；未签署 `requestAppPrivacyConsent(ctx)` 拉系统弹框 → 同意 boot；拒绝 toast + 1.6s 后 `terminateSelf`（不强制授权，下次再弹）。模拟器/无服务环境 catch（1006700003）记日志放行 boot 保开发可用。不新增 preferences 持久化（签署状态系统/应用市场托管，协议换版按 versionCode 重弹）。审核要求主界面 4 次点击内可达隐私政策：设置「关于」卡「隐私政策」行 openLink。

### [ND-012] GPL 合规义务
- **类别**: security
- **状态**: active
- **来源**: zcode/plans/plan-sess_cfcf9be4（阶段 2 合规说明）; AGENTS.md（Licensing）; third_party/NOTICE.md; 仓库根 LICENSE
- **日期**: 2026-09-18
- **内容**: dosbox-staging 为 GPL-2.0-or-later，链接进应用使整体作品受 GPL v2(或更高)约束，**分发须随附合成作品的相应源码**（GPL 传染性）。repo 根 LICENSE 载 GPL-2.0 全文、README 声明许可、应用内 LicenseSheet 展示，三者须与 third_party/NOTICE.md 保持同步（第三方组件变更时）。vdisk/8086tiny 时代无此义务，迁移后新增——分发渠道（含上架）前必须确认源码随附方案。
