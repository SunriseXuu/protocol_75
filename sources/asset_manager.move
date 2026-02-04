/// # 资产托管模块 (Asset Manager)
///
/// ## 功能描述
/// 本模块充当协议的“去中心化银行”，负责底层资金的托管与流转。
/// 它实现了“非托管”架构，即资金凭证 (YieldPosition) 存储在用户自己的账户资源下，而非中心化合约中。
///
/// 核心功能包括：
/// 1. **资金托管**：处理用户参与挑战时的资金质押、追加与合并。
/// 2. **风控执行**：响应 `challenge_manager` 的指令，执行资金冻结 (Freeze) 与解冻。
/// 3. **结算清算**：提供底层接口，允许上层模块提取资金以进行退款或罚没分账。
/// 4. **逃生舱**：提供基于时间锁的强制提款机制，防止协议逻辑死锁或管理员作恶。
/// 5. **保证金管理**：托管举报者的质押金，支持退还或罚没。
///
/// ## 设计原则
/// - **安全性**：资产分散存储，避免单点资金池被黑客攻破的风险。
/// - **被动性**：本模块不包含业务判断逻辑（如谁作弊了），仅被动执行 Friend 模块的指令。
/// - **状态机**：严格管理资金状态流转 (Active -> Frozen -> Settled/Destroyed)。
///
/// ## 模块依赖
/// - 依赖 `aptos_framework::coin` 处理代币资产。
/// - 仅允许 `challenge_manager` (Friend) 调用敏感的风控与结算操作。
module protocol_75::asset_manager {
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin; // TODO: 生产环境替换为稳定币
    use aptos_framework::timestamp;

    // 友元声明 (Friend Declarations) -----------------------------------

    /// 只允许 challenge_manager 调用冻结、结算、罚没等敏感接口
    friend protocol_75::challenge_manager;

    // 错误码 (Error Codes) --------------------------------------------

    /// 错误：用户未质押或资源不存在
    const E_NO_POSITION: u64 = 1;
    /// 错误：锁仓未到期 (无法使用逃生舱)
    const E_LOCK_NOT_EXPIRED: u64 = 2;
    /// 错误：资金状态异常 (例如试图操作已冻结的资金)
    const E_POSITION_FROZEN: u64 = 3;
    /// 错误：资金状态无效 (例如试图结算非活跃资金)
    const E_INVALID_STATUS: u64 = 4;
    /// 错误：无保证金记录
    const E_NO_BOND: u64 = 5;

    // 常量 (Constants) -----------------------------------------------

    /// 逃生舱等待期 (缓冲期)
    /// 生产环境建议设为 7 天 (604800秒)，测试环境设为 100秒
    const EMERGENCY_LOCK_DURATION: u64 = 100; // TODO: 生产环境设为 604800

    /// 状态：活跃中 (正常质押，可追加，可被冻结)
    const STATUS_ACTIVE: u8 = 1;
    /// 状态：冻结中 (被举报，不可提取，不可追加，等待裁决)
    const STATUS_FROZEN: u8 = 2;

    /// 协议金库地址 (用于接收罚没款或恶意举报没收金)
    const TREASURY_ADDR: address = @protocol_75;

    // 数据结构 (Data Structures) ---------------------------------------

    /// 资产仓位 (Yield Position)
    /// 存储用户质押在协议中的资金及其状态。
    struct YieldPosition has key {
        /// 质押的代币资产 (当前锁定为 AptosCoin)
        principal: Coin<AptosCoin>,
        /// 锁仓截止时间 (用于逃生舱逻辑判断)
        lock_until: u64,
        /// 绑定的小队哈希 (用于上层业务校验)
        team_hash: vector<u8>,
        /// 当前状态 (Active/Frozen)
        status: u8
    }

    /// 举报保证金 (Report Bond)
    /// 当用户发起举报时，临时托管其保证金。
    struct ReportBond has key {
        /// 保证金代币
        coins: Coin<AptosCoin>,
        /// 保证金额度
        amount: u64,
        /// 举报者地址 (冗余存储，便于校验)
        reporter: address
    }

    // 用户交互接口 (Public Entries) --------------------------------------

    /// 用户质押资金 (Deposit & Stake)
    ///
    /// 如果用户已有仓位，支持追加质押；否则创建新仓位。
    ///
    /// @param user: 用户交易签名
    /// @param amount: 质押金额
    /// @param team_hash: 关联的小队哈希
    /// @param lock_duration: 预计锁仓时长 (秒)
    public entry fun deposit_and_stake(
        user: &signer,
        amount: u64,
        team_hash: vector<u8>,
        lock_duration: u64
    ) acquires YieldPosition {
        let user_addr = signer::address_of(user);

        // 1. 从用户钱包提取代币
        let payment = coin::withdraw<AptosCoin>(user, amount);

        // 2. 检查是否存在现有仓位
        if (exists<YieldPosition>(user_addr)) {
            // 借用用户仓位的可变引用
            let position = borrow_global_mut<YieldPosition>(user_addr);

            // [核心风控] 如果资金被冻结，禁止追加质押 (防止混淆视听或重置状态)
            assert!(position.status == STATUS_ACTIVE, E_POSITION_FROZEN);

            // 合并资金
            coin::merge(&mut position.principal, payment);

            // 更新小队哈希
            position.team_hash = team_hash;

            // 延长锁仓时间：取 (当前+时长) 与 (原有锁仓时间) 的较大值
            let new_lock = timestamp::now_seconds() + lock_duration;
            if (new_lock > position.lock_until) {
                position.lock_until = new_lock;
            };
        }
        // 3. 否则创建新仓位
        else {
            let position = YieldPosition {
                principal: payment,
                lock_until: timestamp::now_seconds() + lock_duration,
                team_hash,
                status: STATUS_ACTIVE // 默认为活跃状态
            };

            move_to(user, position);
        };
    }

    /// 逃生舱强制提款 (Emergency Withdraw)
    ///
    /// 当协议长时间未响应（超过 `lock_until + EMERGENCY_LOCK_DURATION`），
    /// 用户可无视任何状态（包括 Frozen），强制取回资金。
    /// 这是防止 Rug Pull 或治理攻击的最后一道防线。
    ///
    /// @param user: 用户交易签名
    public entry fun emergency_withdraw(user: &signer) acquires YieldPosition {
        // 获取并校验用户
        let user_addr = signer::address_of(user);
        assert!(exists<YieldPosition>(user_addr), E_NO_POSITION);

        let position = borrow_global<YieldPosition>(user_addr);

        // [核心校验] 检查时间锁是否过期
        assert!(
            timestamp::now_seconds() > position.lock_until + EMERGENCY_LOCK_DURATION,
            E_LOCK_NOT_EXPIRED
        );

        // 执行销毁与提款 (无视 status，因为时间锁是最高优先级)
        let YieldPosition { principal, lock_until: _, team_hash: _, status: _ } =
            move_from<YieldPosition>(user_addr);

        // 如果用户还没注册 CoinStore，自动注册以免转账失败
        if (!coin::is_account_registered<AptosCoin>(user_addr)) {
            coin::register<AptosCoin>(user);
        };
        coin::deposit(user_addr, principal);
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 冻结用户资产
    ///
    /// 场景：当用户被举报作弊时调用。冻结后用户无法追加质押或正常结算。
    ///
    /// @param user_addr: 目标用户地址
    public(friend) fun freeze_position(user_addr: address) acquires YieldPosition {
        // 允许对不存在仓位的用户调用(虽然无意义)，防止上层逻辑崩溃，但如果有仓位则必须存在
        if (exists<YieldPosition>(user_addr)) {
            let position = borrow_global_mut<YieldPosition>(user_addr);

            // 只有 Active 状态才能被冻结
            if (position.status == STATUS_ACTIVE) {
                position.status = STATUS_FROZEN;
            };
        };
    }

    /// 解冻用户资产
    ///
    /// 场景：举报被判定无效（无罪释放），恢复用户资金活性。
    ///
    /// @param user_addr: 目标用户地址
    public(friend) fun unfreeze_position(user_addr: address) acquires YieldPosition {
        if (exists<YieldPosition>(user_addr)) {
            let position = borrow_global_mut<YieldPosition>(user_addr);
            if (position.status == STATUS_FROZEN) {
                position.status = STATUS_ACTIVE;
            };
        };
    }

    /// 提取资金对象 (Extract Funds)
    ///
    /// 这是一个底层的取款接口。它将用户的 YieldPosition 彻底销毁，
    /// 并将内部的所有本金以 `Coin` 对象形式返回给调用者。
    /// *注意*：调用者 (`challenge_manager`) 负责决定这笔钱是退给用户、还是分给举报者。
    ///
    /// @param user_addr: 目标用户地址
    /// @return Coin<AptosCoin>: 提取出的全部本金
    public(friend) fun extract_funds(user_addr: address): Coin<AptosCoin> acquires YieldPosition {
        assert!(exists<YieldPosition>(user_addr), E_NO_POSITION);

        // 1. 彻底移出资源 (Move From)
        let YieldPosition { principal, lock_until: _, team_hash: _, status: _ } =
            move_from<YieldPosition>(user_addr);

        // 2. 返回代币对象
        principal
    }

    /// 收取举报保证金
    ///
    /// 场景：用户发起举报时，需缴纳投名状。
    ///
    /// @param reporter: 举报者签名
    /// @param amount: 保证金金额
    public(friend) fun collect_report_bond(
        reporter: &signer, amount: u64
    ) acquires ReportBond {
        let coins = coin::withdraw<AptosCoin>(reporter, amount);
        let reporter_addr = signer::address_of(reporter);

        // 如果已有保证金记录，则追加 (支持多重举报场景)
        if (exists<ReportBond>(reporter_addr)) {
            let bond = borrow_global_mut<ReportBond>(reporter_addr);
            coin::merge(&mut bond.coins, coins);
            bond.amount += amount;
        } else {
            move_to(
                reporter,
                ReportBond { coins, amount, reporter: reporter_addr }
            );
        };
    }

    /// 释放或罚没保证金
    ///
    /// 场景：举报裁决完成后，根据结果处理保证金。
    ///
    /// @param reporter_addr: 举报者地址
    /// @param amount: 需要释放/罚没的金额
    /// @param is_return: true=退还给举报者 (举报成功), false=罚没到国库 (恶意举报)
    public(friend) fun release_report_bond(
        reporter_addr: address, amount: u64, is_return: bool
    ) acquires ReportBond {
        assert!(exists<ReportBond>(reporter_addr), E_NO_BOND);
        let bond = borrow_global_mut<ReportBond>(reporter_addr);

        // 从总保证金中提取指定金额
        let release_coins = coin::extract(&mut bond.coins, amount);
        bond.amount -= amount;

        if (is_return) {
            // 退还
            coin::deposit(reporter_addr, release_coins);
        } else {
            // 罚没 (转入协议金库)
            coin::deposit(TREASURY_ADDR, release_coins);
        };

        // 如果剩余保证金为0，销毁资源以释放存储空间
        if (coin::value(&bond.coins) == 0) {
            let ReportBond { coins, amount: _, reporter: _ } =
                move_from<ReportBond>(reporter_addr);
            coin::destroy_zero(coins);
        };
    }

    // 视图方法 (View Methods) ------------------------------------------

    #[view]
    /// 获取用户仓位详情
    ///
    /// @param user: 用户地址
    /// @return (principal, lock_until, status)
    public fun get_position_info(user: address): (u64, u64, u8) acquires YieldPosition {
        if (!exists<YieldPosition>(user)) {
            return (0, 0, 0)
        };
        let pos = borrow_global<YieldPosition>(user);
        (coin::value(&pos.principal), pos.lock_until, pos.status)
    }
}

