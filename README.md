# Protocol 75 (v0.1.1)

Protocol 75 是基于 Aptos Move 构建的去中心化自律激励协议。它通过“资金连坐”与“信用独立”的双轨制博弈模型，解决 Web3 用户的行为激励问题。

## 核心架构 (Core Architecture)

项目采用 **Manager-Storage** 分层架构模式，包含以下核心模块：

- **challenge_manager**: 业务核心，负责协调挑战创建、资金锁仓、每日打卡与结算逻辑。
- **bio_credit**: 用户身份层 (Storage)，管理 BioSoul (SBT)、个人连胜记录与勋章挂载。
- **asset_manager**: 资金托管层，负责与 DeFi 协议交互、资金锁仓与清算分发。
- **task_market**: 策略层，定义任务规格 (TaskSpec) 与难度计算算法。
- **badge_factory**: 资产层，负责铸造系统成就勋章与商业品牌勋章。

## 开发环境 (Development)

- **Language**: Move 2.0+
- **Network**: Aptos Testnet
- **Framework**: Aptos Framework (Testnet Release)

## 目录结构

```text
protocol_75/
├── Move.toml          # 依赖与地址配置
├── sources/           # 核心合约代码
└── tests/             # 集成测试脚本
```
