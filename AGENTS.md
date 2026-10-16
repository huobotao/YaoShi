# 药时项目交付约定

用户于 2026-10-14 明确要求，适用于当前及以后新开的聊天：

- 每项独立修改都要在 GitHub 留对应提交和版本记录。权威远端为 https://github.com/huobotao/YaoShi 。
- 需求完成且验证通过后，立即把新版同步安装到用户的三台 iPhone（17 Pro、Air、14），无需再问安装哪台或是否安装。仅推送源码或模拟器构建不算交付完成。
- 安装前核对设备现有版本、分支及其他工作副本，保留已交付的功能和修正，避免并行任务互相覆盖。构建号递增；保留应用标识、签名组和用户数据，不卸载清空。
- 分别核验构建、安装版本、启动和实际行为；设备离线、锁屏或系统拒绝时明确报告未完成部分，不要求削弱安全设置，不把安装成功等同于数据已经同步或手势已经验收。
- 真机数据只保存在本地备份；仓库、测试、截图和公开说明不得包含真实健康记录或设备标识。
- 供用户阅读的文档使用 PDF，并用系统 Preview 打开；不得在 Codex 内置文件面板打开。

其余开发和测试流程见 CONTRIBUTING.md。

## 并存版本规则（2026-10-14 用户最新要求）

每次用户要求改动，交付一个带清晰版本号、独立 Bundle ID 的新 App，保留已安装旧版供横向比较。不要覆盖或卸载旧版，除非用户明确更改此要求。代码保留独立 Git 分支、提交和来源版本；验证并推送后安装到三台 iPhone。独立版本必须隔离钥匙串同步、共享快照、伴侣凭据及 URL scheme。可以导入只读备份副本，但不得回写原版数据。以上覆盖旧条款中保留同一应用标识的要求。

本恢复分支仅支持 build.sh、build_widget.sh、build_sim.sh 的独立版本。Mac、Watch、TV、Partner 构建脚本仍为原版标识，不得从此分支运行安装；如需这些目标，先单独完成身份与数据隔离。

用户再次强调：从现在开始都不要替换已安装 App。本轮交付 R2（build45）供用户亲自试用；用户验收前，不得标为稳定版本或擅自改名。R2 保留原 2.10.12 功能逻辑，不宣称修复后台持续运行或定位指示。

## 当前交付边界
Air 药时12·R2 为用户验收稳定版，禁止修改、重装、启动、终止或改变设置。此 R4 分支只允许以独立ID新增安装到 Air，旧版全部保留；后台逻辑以 R2 为基准。17 Pro 当前问题优先处理，R4 先在电脑准备。这覆盖上文三台安装要求。

## R8 手表独立候选
本工作树只交付 `build_watch_r8_only.sh` 生成的手表 App，身份为
`com.richardhuo.yaoshi.archive.v21012r8.watchkitapp`，配对现有 17 Pro R8。
禁止运行本工作树的旧 `build_watch.sh`，禁止重新安装、启动或改变 17 Pro R8、
Air R2 及其他现有 iPhone App。手表候选只读显示，不提供表盘组件；
浓度模型暂用已核对的 3.8 小时达峰及 10.5 小时半衰期，并明确标示
手机后续参数、进食状态或记录变化未同步时数值可能不同。

## Air R4 手表独立候选

本工作树当前只交付 `build_watch_air_r4_only.sh`，Watch App 身份为
`com.richardhuo.yaoshi.archive.v21012r4.watchkitapp`，伴侣目标是已安装在配对 iPhone Air 上的
`com.richardhuo.yaoshi.archive.v21012r4`。不运行旧 `build_watch.sh`；不构建、安装、启动、停止或
改变任何 iPhone App，也不覆盖已安装的 R8 Watch App。此候选只读显示，尚未交付表盘组件。

## 健康 R2 手表候选

本分支只通过 `build_watch_health_r2.sh` 生成 `药时手表·健康 R2`（build 53），
Bundle ID 为 `com.richardhuo.yaoshi.watch.standalone.airr4.healthr2`，其 WidgetKit 扩展为
同名前缀 `.widget`。旧版手表 App 与全部 iPhone App 均须保留，不运行此树中任何 iPhone
安装脚本。此版使用独立的 App Group，仅从已核验的只读 Air R4 备份导入记录；不向手机写回。
心率只读取 HealthKit 已有采样，不启动运动会话。真机授权与表盘槽位显示须单独验收，
不得把编译、安装或扩展签名成功称为这些行为已经验证。

## 健康 R3 手表候选

本分支新增 `build_watch_health_r3.sh`，生成独立 `药时手表·健康 R3`（build 54），
Bundle ID 为 `com.richardhuo.yaoshi.watch.standalone.airr4.healthr3`，WidgetKit 扩展同前缀 `.widget`。
只安装至 Apple Watch Ultra 2；保留全部旧版手表及手机 App，不运行任何手机安装脚本。
R3 优先显示浓度及曲线，心率只读取已有 HealthKit 采样，前台监听新增采样；不会主动触发心率测量。
源数据仍为独立导入快照，不能声称已与 iPhone Air 自动同步。

## 健康 R4 手表候选

本分支新增 `build_watch_health_r4.sh`，生成独立 `药时手表·健康 R4`（build 55），
Bundle ID 为 `com.richardhuo.yaoshi.watch.standalone.airr4.healthr4`，WidgetKit 扩展同前缀 `.widget`。
只安装到 Apple Watch Ultra 2，旧版手表和全部手机 App 保留。
手表新增 50 mg 服药记录时仅写独立本地日志，允许撤销与后续修正；它不能自动同步到 iPhone Air，
界面必须明确显示待同步状态，且绝不把待同步记录称为手机已保存。

## 健康 R5 手表候选

本分支新增 `build_watch_health_r5.sh`，生成独立 `药时手表·健康 R5`（build 56），
Bundle ID 为 `com.richardhuo.yaoshi.watch.standalone.airr4.healthr5`，WidgetKit 扩展同前缀 `.widget`。
只安装到 Apple Watch Ultra 2；保留旧版手表与全部手机 App。R5 一按即保存默认 50 mg，
仅在本地日志持久化成功后显示“已记录”；后续可修正或撤销。心率读取显示样本时间，
平均时段和手动检查点仅作用于此独立 Watch App。仍不可宣称服药或心率已同步到 iPhone 药时。

## 健康 R6 手表候选

本分支新增 `build_watch_health_r6.sh`，生成独立 `药时手表·健康 R6`（build 57），
Bundle ID 为 `com.richardhuo.yaoshi.watch.standalone.airr4.healthr6`，WidgetKit 扩展同前缀 `.widget`，
App Group 为 `group.com.richardhuo.yaoshi.watch.healthr6`。只面向 Apple Watch Ultra 2，
保留 R5 和其他已安装版本。抬腕首屏显示 HealthKit 最新已保存心率及采样时间、近期心率折线；
旋转 Digital Crown 在 15 分钟至 24 小时范围缩放时间轴。只读 HealthKit 采样，不启动第二个运动会话；
不宣称能读取传感器原始光学波形或保证每次采样实时可见。空白区间表示没有可读样本。
