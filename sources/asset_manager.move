/// # 资产托管模块 (Asset Manager)
///
/// 该模块是协议的资金层，负责管理用户的质押资产。
/// 实现了“非托管”架构：资金凭证 (YieldPosition) 存在用户自己账户下。
///
/// 主要功能：
/// 1. **资金锁仓**：接收代币并生成存单。
/// 2. **清算分发**：根据挑战结果执行退款或罚没。
/// 3. **逃生舱**：超时强制提款机制。
module protocol_75::asset_manager {
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin; // TODO: 开发阶段用 APT 代替 USDT
    use aptos_framework::timestamp;

    friend protocol_75::challenge_manager;

    /// 用户未质押
    const E_NO_POSITION: u64 = 1;
    /// 锁仓未到期
    const E_LOCK_NOT_EXPIRED: u64 = 2;
    /// 余额不足
    const E_INSUFFICIENT_BALANCE: u64 = 3;

    /// 逃生舱等待期 (例如 7 天 = 604800 秒)，此处测试设为 100 秒
    const EMERGENCY_LOCK_DURATION: u64 = 100;

    /// 资金存单 (非托管资源)
    /// 真实场景中，这里可能还会持有 DeFi 协议的 LP Token 对象
    struct YieldPosition has key {
        principal: Coin<AptosCoin>, // 质押本金
        lock_until: u64, // 锁仓截止时间
        team_hash: vector<u8> // 绑定的小队哈希
    }

    /// Seq 2.2: 存款并锁仓 (仅限 Friend)
    /// user: 用户
    /// payment: 用户传入的资金对象
    /// lock_duration: 挑战持续时间
    public(friend) fun deposit_and_stake(
        user: &signer,
        payment: Coin<AptosCoin>,
        team_hash: vector<u8>,
        lock_duration: u64
    ) {
        let user_addr = signer::address_of(user);

        // 如果用户已有存单，合并资金 (简化逻辑：通常一个用户一次只能有一个挑战)
        if (exists<YieldPosition>(user_addr)) {
            let position = borrow_global_mut<YieldPosition>(user_addr);
            coin::merge(&mut position.principal, payment);
            // 更新哈希和时间
            position.team_hash = team_hash;
            position.lock_until = timestamp::now_seconds() + lock_duration;
        } else {
            let position = YieldPosition {
                principal: payment,
                lock_until: timestamp::now_seconds() + lock_duration,
                team_hash
            };
            move_to(user, position);
        };
    }

    /// Seq 4.1: 清算资金 (仅限 Friend)
    /// 注意：asset_manager 只负责“解锁并提取”资金。
    /// 具体的资金分配（退款/赔付/罚没）逻辑由上层 challenge_manager 完成。
    public(friend) fun liquidate_position(
        user: address, _liquidation_type: u8, _beneficiaries: vector<address>
    ): Coin<AptosCoin> acquires YieldPosition {
        assert!(exists<YieldPosition>(user), E_NO_POSITION);

        // 1. 销毁资源，解构出本金
        let YieldPosition { principal, lock_until: _, team_hash: _ } =
            move_from<YieldPosition>(user);

        // 2. 直接返回本金对象
        principal
    }

    /// 用户逃生舱 (Entry)
    /// 当协议长时间未响应（超过 lock_until + 缓冲期），用户可强制提款
    public entry fun emergency_withdraw(user: &signer) acquires YieldPosition {
        let user_addr = signer::address_of(user);
        assert!(exists<YieldPosition>(user_addr), E_NO_POSITION);

        let position = borrow_global<YieldPosition>(user_addr);

        // 检查时间锁：当前时间 > 锁仓时间 + 逃生等待期
        assert!(
            timestamp::now_seconds() > position.lock_until + EMERGENCY_LOCK_DURATION,
            E_LOCK_NOT_EXPIRED
        );

        // 执行提款
        let YieldPosition { principal, lock_until: _, team_hash: _ } =
            move_from<YieldPosition>(user_addr);

        // 存入用户钱包
        if (!coin::is_account_registered<AptosCoin>(user_addr)) {
            coin::register<AptosCoin>(user);
        };
        coin::deposit(user_addr, principal);
    }

    #[test_only]
    use std::vector;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test(user = @0x123, framework = @0x1)]
    fun test_deposit_and_withdraw(user: &signer, framework: &signer) acquires YieldPosition {
        // 1. 初始化时间
        timestamp::set_time_has_started_for_testing(framework);

        // 2. 初始化 AptosCoin 并铸造测试币
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(framework);

        let user_addr = signer::address_of(user);
        if (!account::exists_at(user_addr)) {
            account::create_account_for_test(user_addr);
        };
        // 注册 CoinStore 以便后续接收退款
        coin::register<AptosCoin>(user);

        // 铸造 100 APT 用于测试
        let coins = coin::mint<AptosCoin>(100, &mint_cap);

        // 3. 存入锁仓
        let team_hash = vector::empty<u8>();
        deposit_and_stake(user, coins, team_hash, 50); // 锁 50 秒

        // 销毁 capability 避免资源泄露
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        // 4. 验证资源存在
        assert!(exists<YieldPosition>(user_addr), 0);

        // 5. 尝试立即逃生 (应该失败)
        // timestamp::update_global_time_for_test(10000000); // 如果不开这行
        // emergency_withdraw(user); // 这里应该报错

        // 6. 模拟时间流逝: 50(锁仓) + 100(逃生等待) + 1 = 151
        timestamp::update_global_time_for_test_secs(151);

        // 7. 成功逃生
        emergency_withdraw(user);

        // 8. 验证资源已销毁且钱回到了钱包 (需要先注册 coin store，test 简化略过余额检查)
        assert!(!exists<YieldPosition>(user_addr), 1);
    }
}

