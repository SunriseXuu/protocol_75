/// # 资产托管模块 (Asset Manager)
///
/// ## 功能描述
/// 本模块充当协议的“去中心化银行”，负责底层资金的托管与流转。
/// 它实现了“非托管”架构，即资金凭证 (YieldPosition) 存储在用户自己的账户资源下，而不是合约中。
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
/// - **被动性**：本模块不关心业务判断逻辑（如谁作弊了），仅被动执行 Friend 模块的指令。
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

    /// 错误：无效的锁仓时间 (不能小于当前时间)
    const E_INVALID_LOCK_TIME: u64 = 1;
    /// 错误：用户未质押或资源不存在
    const E_NO_POSITION: u64 = 2;
    /// 错误：锁仓未到期 (无法使用逃生舱)
    const E_LOCK_NOT_EXPIRED: u64 = 3;
    /// 错误：资金状态异常 (例如试图操作已冻结的资金)
    const E_POSITION_FROZEN: u64 = 4;
    /// 错误：资金状态无效 (例如试图结算非活跃资金)
    const E_INVALID_STATUS: u64 = 5;
    /// 错误：无保证金记录
    const E_NO_BOND: u64 = 6;

    // 常量 (Constants) -----------------------------------------------

    /// 逃生舱等待期 (缓冲期)
    /// 生产环境建议设为 7 天 (604800秒)，测试环境设为 100秒
    const EMERGENCY_LOCK_DURATION: u64 = 100; // TODO: 生产环境设为 604800

    /// 仓位状态：活跃中 (正常质押，可追加，可被冻结)
    const POSITION_STATUS_ACTIVE: u8 = 1;
    /// 仓位状态：冻结中 (被举报，不可提取，不可追加，等待裁决)
    const POSITION_STATUS_FROZEN: u8 = 2;
    /// 仓位状态：已结算 (已提取，不可操作)
    const POSITION_STATUS_SETTLED: u8 = 3;

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
        /// 绑定的挑战哈希 (用于上层业务校验)
        challenge_hash: vector<u8>,
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

        // 检查时间锁是否过期
        assert!(
            timestamp::now_seconds() > position.lock_until + EMERGENCY_LOCK_DURATION,
            E_LOCK_NOT_EXPIRED
        );

        // 执行销毁与提款 (无视 status，因为时间锁是最高优先级)
        let YieldPosition { principal, lock_until: _, challenge_hash: _, status: _ } =
            move_from<YieldPosition>(user_addr);

        // 如果用户还没注册 CoinStore，自动注册以免转账失败
        if (!coin::is_account_registered<AptosCoin>(user_addr)) {
            coin::register<AptosCoin>(user);
        };
        coin::deposit(user_addr, principal);
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 存入并质押 (Deposit & Stake)
    ///
    /// 用户只能通过友元模块间接调用，确保 `lock_until` 是由友元校验过的。
    /// 调用前须确保如果用户处于“换局”状态，其上一轮挑战必须已完成结算。
    ///
    /// 本方法支持两种核心业务场景的自动路由：
    /// 1. **追加质押 (Top-up)**:
    ///    - 场景：用户在当前挑战中觉得本金太少，想增加投入。
    ///    - 逻辑：合并资金，**严禁修改锁仓时间**（防止恶意缩短或非必要的延长）。
    /// 2. **资金复用 (Rollover)**:
    ///    - 场景：上一轮挑战结算后，用户未提款，直接用余额开启下一轮。
    ///    - 逻辑：合并资金（若有新增），**更新锁仓时间**（取最大值以覆盖风险）。
    ///
    /// @param user: 用户交易签名
    /// @param amount: 质押金额
    /// @param challenge_hash: 关联的挑战哈希
    /// @param lock_until: 锁仓截止的绝对时间戳
    public(friend) fun deposit_and_stake(
        user: &signer,
        amount: u64,
        challenge_hash: vector<u8>,
        lock_until: u64
    ) acquires YieldPosition {
        let user_addr = signer::address_of(user);

        // 校验防止传入过去的时间
        assert!(lock_until > timestamp::now_seconds(), E_INVALID_LOCK_TIME);

        // 从用户钱包提取代币
        let payment =
            // 追加质押场景，提取代币
            if (amount > 0) {
                coin::withdraw<AptosCoin>(user, amount)
            }
            // 资金复用场景，直接返回零代币
            else {
                coin::zero<AptosCoin>()
            };

        // 检查是否存在现有仓位
        if (exists<YieldPosition>(user_addr)) {
            let position = borrow_global_mut<YieldPosition>(user_addr);

            // 如果资金被冻结，禁止追加质押 (防止混淆视听或重置状态)
            assert!(position.status == POSITION_STATUS_ACTIVE, E_POSITION_FROZEN);

            // 合并资金
            coin::merge(&mut position.principal, payment);

            // 场景1：同挑战追加资金 (Top-up)
            // 如果用户还在同一个挑战里追加资金，那么锁仓时间必须与之前保持一致。
            // 1. 禁止缩短：防止提前取款（提前逃跑）。
            // 2. 禁止延长：防止恶意延期，导致无法结算。
            if (position.challenge_hash == challenge_hash) {
                assert!(lock_until == position.lock_until, E_INVALID_LOCK_TIME);
            }
            // 场景2：切换到新挑战 (Rollover)，则允许更新时间。
            // 1. 如果上一个挑战已被结算，则可以直接更新时间，
            // 2. 如果上一个挑战未被结算，友元模块在调用此函数前，会先结算上一个挑战
            else {
                // 更新挑战哈希
                position.challenge_hash = challenge_hash;

                // 锁仓时间只能延长，禁止缩短 (Max Logic)。
                // 如果用户上一轮挑战的锁仓期还未结束（例如下个月才到期），
                // 不允许通过参与一个更短周期的新挑战（例如明天结束）来变相“提前解锁”原有资金。
                // 因此，新的锁仓时间必须取 max(原有锁仓, 新挑战锁仓)。
                if (lock_until > position.lock_until) {
                    position.lock_until = lock_until;
                };
            };
        }
        // 否则创建新仓位
        else {
            let position = YieldPosition {
                principal: payment,
                lock_until,
                challenge_hash,
                status: POSITION_STATUS_ACTIVE // 默认为活跃状态
            };

            move_to(user, position);
        };
    }

    /// 冻结用户资产 (Freeze Position)
    ///
    /// 场景：当用户被举报作弊时调用。冻结后用户无法追加质押或正常结算。
    ///
    /// @param user_addr: 目标用户地址
    public(friend) fun freeze_position(user_addr: address) acquires YieldPosition {
        assert!(exists<YieldPosition>(user_addr), E_NO_POSITION);

        let position = borrow_global_mut<YieldPosition>(user_addr);

        // 只有活跃状态才能被冻结
        if (position.status == POSITION_STATUS_ACTIVE) {
            position.status = POSITION_STATUS_FROZEN;
        };
    }

    /// 解冻用户资产 (Unfreeze Position)
    ///
    /// 场景：举报被判定无效（无罪释放），恢复用户资金活性。
    ///
    /// @param user_addr: 目标用户地址
    public(friend) fun unfreeze_position(user_addr: address) acquires YieldPosition {
        assert!(exists<YieldPosition>(user_addr), E_NO_POSITION);

        let position = borrow_global_mut<YieldPosition>(user_addr);

        // 只有冻结状态才能被解冻
        if (position.status == POSITION_STATUS_FROZEN) {
            position.status = POSITION_STATUS_ACTIVE;
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

        // 彻底移出资源 (Move From)
        let YieldPosition { principal, lock_until: _, challenge_hash: _, status: _ } =
            move_from<YieldPosition>(user_addr);

        // 返回代币对象
        principal
    }

    /// 收取举报保证金 (Collect Report Bond)
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
        }
        // 如果没有，则创建新记录
        else {
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
    public(friend) fun release_or_seize_report_bond(
        reporter_addr: address, amount: u64, is_return: bool
    ) acquires ReportBond {
        assert!(exists<ReportBond>(reporter_addr), E_NO_BOND);

        let bond = borrow_global_mut<ReportBond>(reporter_addr);

        // 从总保证金中提取指定金额
        let release_coins = coin::extract(&mut bond.coins, amount);
        bond.amount -= amount;

        // 退还
        if (is_return) {
            coin::deposit(reporter_addr, release_coins);
        }
        // 罚没 (转入协议金库)
        else {
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
    /// 获取用户仓位详情 (Get Position Info)
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

