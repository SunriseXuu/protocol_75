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
    use protocol_75::test_usd::TestUSD;
    use aptos_framework::timestamp;

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
        principal: Coin<TestUSD>,
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
        coins: Coin<TestUSD>,
        /// 保证金额度
        amount: u64,
        /// 举报者地址 (冗余存储，便于校验)
        reporter: address
    }

    // 公开接口 (Public Entries) ----------------------------------------

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
        if (!coin::is_account_registered<TestUSD>(user_addr)) {
            coin::register<TestUSD>(user);
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
                coin::withdraw<TestUSD>(user, amount)
            }
            // 资金复用场景，直接返回零代币
            else {
                coin::zero<TestUSD>()
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
    /// @return Coin<TestUSD>: 提取出的全部本金
    public(friend) fun extract_funds(user_addr: address): Coin<TestUSD> acquires YieldPosition {
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
        let coins = coin::withdraw<TestUSD>(reporter, amount);
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

    // 单元测试 (Unit Tests) --------------------------------------------

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    /// 辅助函数：初始化环境并领取 TestUSD
    /// 返回：(Minted Coins)
    fun setup_test(
        admin: &signer,
        user: &signer,
        framework: &signer,
        time: u64
    ): Coin<TestUSD> {
        let admin_addr = signer::address_of(admin);
        let user_addr = signer::address_of(user);

        // 1. 初始化 Aptos 框架 (时间戳等)
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(time);

        // 2. 创建账户
        if (!account::exists_at(admin_addr)) {
            account::create_account_for_test(admin_addr);
        };
        if (!account::exists_at(user_addr)) {
            account::create_account_for_test(user_addr);
        };

        // 3. 初始化 Coin 和 AssetManager
        protocol_75::test_usd::init_for_test(admin);

        // 注册用户并铸造代币以便测试用于 deposit
        coin::register<TestUSD>(user);
        let coins = protocol_75::test_usd::mint_for_test(admin, 1000000);

        coins
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试核心流程：质押 -> 补仓 -> 跨队复用 -> 提款
    fun test_lifecycle_happy_path(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        let user_addr = signer::address_of(user);

        // 给用户发 1000 块钱
        coin::deposit(user_addr, coins);

        // 1.首次质押 (Deposit)
        // 锁定 100 块，挑战 A (Hash=x01), 锁定到 2000秒 (duration=1000)
        deposit_and_stake(user, 100, vector[1], 2000);

        let (principal, lock_until, status) = get_position_info(user_addr);
        assert!(principal == 100, 1);
        assert!(lock_until == 2000, 2);
        assert!(status == POSITION_STATUS_ACTIVE, 3);

        // 2. 同小队补仓 (Top-up)
        // 必须使用相同的时间戳 2000
        deposit_and_stake(user, 50, vector[1], 2000);

        let (p2, l2, _) = get_position_info(user_addr);
        assert!(p2 == 150, 4); // 余额增加
        assert!(l2 == 2000, 5); // 时间不变

        // 3. 跨小队复用 (Rollover)
        // 用户想加入挑战 B (Hash=x02), 该挑战要求锁仓到 3000秒
        // 这里不充钱 (amount=0)，纯复用
        deposit_and_stake(user, 0, vector[2], 3000);

        let (p3, l3, _) = get_position_info(user_addr);
        assert!(p3 == 150, 6); // 余额不变
        assert!(l3 == 3000, 7); // 时间延长到 3000

        // 4. 彻底结算提款 (Extract)
        let extracted = extract_funds(user_addr);
        assert!(coin::value(&extracted) == 150, 8);

        // 销毁提取出来的代币，防止资源泄漏
        protocol_75::test_usd::burn_for_test(extracted);

        // 确认资源已清除
        assert!(!exists<YieldPosition>(user_addr), 9);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = E_INVALID_LOCK_TIME)]
    /// 测试安全性：禁止在同小队补仓时修改时间
    fun test_topup_lock_restriction(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);

        // 销毁 Caps (因为后面会 abort，如果不提前处理可能会有问题，但在 expected_failure 中通常无需清理)
        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        // 初始：Lock=2000
        deposit_and_stake(user, 100, vector[1], 2000);

        // 尝试缩短时间 -> 失败
        deposit_and_stake(user, 50, vector[1], 1500);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = E_INVALID_LOCK_TIME)]
    /// 测试安全性：禁止在同小队补仓时修改时间 (延长也不行)
    fun test_topup_lock_restriction_extend(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        deposit_and_stake(user, 100, vector[1], 2000);

        // 尝试延长时间 -> 失败 (同小队必须严格一致)
        deposit_and_stake(user, 50, vector[1], 2500);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试安全性：跨小队 Rollover 时的 Max 逻辑
    fun test_rollover_max_logic(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        // 初始：Lock=5000 (很久以后)
        deposit_and_stake(user, 100, vector[1], 5000);

        // 试图加入一个短周期挑战 (Lock=3000)，变相提前解锁
        // 系统应该强制保持 5000
        deposit_and_stake(user, 0, vector[2], 3000);

        let (_, lock_until, _) = get_position_info(signer::address_of(user));
        // 应该还是 5000，而不是 3000
        assert!(lock_until == 5000, 1);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试风控：冻结与解冻
    fun test_freeze_logic(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);
        let user_addr = signer::address_of(user);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        deposit_and_stake(user, 100, vector[1], 2000);

        // 冻结
        freeze_position(user_addr);
        let (_, _, status) = get_position_info(user_addr);
        assert!(status == POSITION_STATUS_FROZEN, 1);

        // 解冻
        unfreeze_position(user_addr);
        let (_, _, status_2) = get_position_info(user_addr);
        assert!(status_2 == POSITION_STATUS_ACTIVE, 2);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = E_POSITION_FROZEN)]
    /// 测试风控：冻结状态下禁止追加资金
    fun test_freeze_prevents_topup(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        deposit_and_stake(user, 100, vector[1], 2000);
        freeze_position(signer::address_of(user));

        // 尝试追加 -> 预期失败
        deposit_and_stake(user, 50, vector[1], 2000);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试逃生舱：时间锁过期后的强制提款
    fun test_emergency_withdraw(
        admin: &signer, user: &signer, framework: &signer
    ) acquires YieldPosition {
        // 当前时间 1000
        // 设置初始时间为 1000秒
        let coins = setup_test(admin, user, framework, 1000);
        coin::deposit(signer::address_of(user), coins);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        // 锁仓到 2000
        deposit_and_stake(user, 100, vector[1], 2000);

        // 1. 快进时间到 2001 (刚过期，但还在缓冲期内)
        timestamp::update_global_time_for_test_secs(2001);
        // 缓冲期是 100秒 (CONST EMERGENCY_LOCK_DURATION)
        // 2001 < 2000 + 100，所以应该还不能取

        // 2. 快进到 2200 (超过缓冲期)
        timestamp::update_global_time_for_test_secs(2200);

        // 3. 即使被冻结，也应该能取 (逃生舱最高优先级)
        freeze_position(signer::address_of(user));

        emergency_withdraw(user);

        // 钱应该回到余额里
        assert!(
            coin::balance<TestUSD>(signer::address_of(user)) == 1100,
            1
        );
        assert!(
            !exists<YieldPosition>(signer::address_of(user)),
            2
        );
    }

    #[test(admin = @protocol_75, reporter = @0x456, framework = @0x1)]
    /// 测试保证金逻辑
    fun test_bond_logic(
        admin: &signer, reporter: &signer, framework: &signer
    ) acquires ReportBond {
        let coins = setup_test(admin, reporter, framework, 1000);
        coin::deposit(signer::address_of(reporter), coins);
        let reporter_addr = signer::address_of(reporter);

        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        // 1. 缴纳保证金 200
        collect_report_bond(reporter, 200);
        assert!(coin::balance<TestUSD>(reporter_addr) == 800, 1); // 1000 - 200

        // 2. 退还 100 (举报成功一半)
        release_or_seize_report_bond(reporter_addr, 100, true);
        assert!(coin::balance<TestUSD>(reporter_addr) == 900, 2); // 800 + 100

        // 3. 罚没 100 (恶意举报)
        release_or_seize_report_bond(reporter_addr, 100, false);
        // 钱应该进了 TREASURY (@protocol_75)
        // 注意：test setup 里 admin 也可能有钱，这里简单验证 reporter 没收到钱
        assert!(coin::balance<TestUSD>(reporter_addr) == 900, 3);

        // 验证 Bond 资源被销毁 (因为余额已空)
        assert!(!exists<ReportBond>(reporter_addr), 4);
    }
}

