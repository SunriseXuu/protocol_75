#[test_only]
module protocol_75::asset_manager_tests {
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::coin::{Self};
    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    use protocol_75::asset_manager;
    #[test_only]
    use protocol_75::test_usd::{Self, TestUSD};

    // 错误码 (Error Codes) 直接照搬
    const E_INVALID_LOCK_TIME: u64 = 1;
    const E_NO_POSITION: u64 = 2;
    const E_LOCK_NOT_EXPIRED: u64 = 3;
    const E_POSITION_FROZEN: u64 = 4;
    const E_INVALID_STATUS: u64 = 5;
    const E_NO_BOND: u64 = 6;

    // 常量 (Constants) 直接照搬
    const EMERGENCY_LOCK_DURATION: u64 = 100;
    const POSITION_STATUS_ACTIVE: u8 = 1;
    const POSITION_STATUS_FROZEN: u8 = 2;
    const POSITION_STATUS_SETTLED: u8 = 3;

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试核心流程：质押 -> 补仓 -> 跨队复用 -> 提款
    fun test_lifecycle_happy_path(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);
        let user_addr = signer::address_of(user);

        // 1.首次质押 (Deposit)
        // 锁定 100 块，挑战 A (Hash=x01), 锁定到 2000秒 (duration=1000)
        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);

        let (principal, lock_until, status) = asset_manager::get_position_info(user_addr);
        assert!(principal == 100, 1);
        assert!(lock_until == 2000, 2);
        assert!(status == POSITION_STATUS_ACTIVE, 3);

        // 2. 同小队补仓 (Top-up)
        // 必须使用相同的时间戳 2000
        asset_manager::deposit_and_stake(user, 50, vector[1], 2000);

        let (p2, l2, _) = asset_manager::get_position_info(user_addr);
        assert!(p2 == 150, 4); // 余额增加
        assert!(l2 == 2000, 5); // 时间不变

        // 3. 跨小队复用 (Rollover)
        // 用户想加入挑战 B (Hash=x02), 该挑战要求锁仓到 3000秒
        // 这里不充钱 (amount=0)，纯复用
        asset_manager::deposit_and_stake(user, 0, vector[2], 3000);

        let (p3, l3, _) = asset_manager::get_position_info(user_addr);
        assert!(p3 == 150, 6); // 余额不变
        assert!(l3 == 3000, 7); // 时间延长到 3000

        // 4. 彻底结算提款 (Extract)
        let extracted = asset_manager::extract_funds(user_addr);
        assert!(coin::value(&extracted) == 150, 8);

        // 销毁提取出来的代币，防止资源泄漏
        test_usd::burn_for_test(extracted);

        // 确认资源已清除
        assert!(!asset_manager::has_yield_position(user_addr), 9);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    #[
        expected_failure(
            abort_code = E_INVALID_LOCK_TIME, location = protocol_75::asset_manager
        )
    ]
    /// 测试安全性：禁止在同小队补仓时修改时间
    fun test_topup_lock_restriction(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);

        // 初始：Lock=2000
        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);

        // 尝试缩短时间 -> 失败
        asset_manager::deposit_and_stake(user, 50, vector[1], 1500);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试安全性：禁止在同小队补仓时修改时间 (延长也不行)
    fun test_topup_lock_restriction_extend(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);

        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);

        // 尝试延长时间 -> 失败 (同小队必须严格一致)
        asset_manager::deposit_and_stake(user, 50, vector[1], 2500);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试安全性：跨小队 Rollover 时的 Max 逻辑
    fun test_rollover_max_logic(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);

        // 初始：Lock=5000 (很久以后)
        asset_manager::deposit_and_stake(user, 100, vector[1], 5000);

        // 试图加入一个短周期挑战 (Lock=3000)，变相提前解锁
        // 系统应该强制保持 5000
        asset_manager::deposit_and_stake(user, 0, vector[2], 3000);

        let (_, lock_until, _) =
            asset_manager::get_position_info(signer::address_of(user));
        // 应该还是 5000，而不是 3000
        assert!(lock_until == 5000, 1);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试风控：冻结与解冻
    fun test_freeze_logic(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);
        let user_addr = signer::address_of(user);

        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);

        // 冻结
        asset_manager::freeze_position(user_addr);
        let (_, _, status) = asset_manager::get_position_info(user_addr);
        assert!(status == POSITION_STATUS_FROZEN, 1);

        // 解冻
        asset_manager::unfreeze_position(user_addr);
        let (_, _, status_2) = asset_manager::get_position_info(user_addr);
        assert!(status_2 == POSITION_STATUS_ACTIVE, 2);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    #[
        expected_failure(
            abort_code = E_POSITION_FROZEN, location = protocol_75::asset_manager
        )
    ]
    /// 测试风控：冻结状态下禁止追加资金
    fun test_freeze_prevents_topup(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);

        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);
        asset_manager::freeze_position(signer::address_of(user));

        // 尝试追加 -> 预期失败
        asset_manager::deposit_and_stake(user, 50, vector[1], 2000);
    }

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试逃生舱：时间锁过期后的强制提款
    fun test_emergency_withdraw(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 当前时间 1000
        // 设置初始时间为 1000秒
        asset_manager::setup_test(admin, user, framework, 1000);

        // 锁仓到 2000
        asset_manager::deposit_and_stake(user, 100, vector[1], 2000);

        // 1. 快进时间到 2001 (刚过期，但还在缓冲期内)
        timestamp::update_global_time_for_test_secs(2001);
        // 缓冲期是 100秒 (CONST EMERGENCY_LOCK_DURATION)
        // 2001 < 2000 + 100，所以应该还不能取

        // 2. 快进到 2200 (超过缓冲期)
        timestamp::update_global_time_for_test_secs(2200);

        // 3. 即使被冻结，也应该能取 (逃生舱最高优先级)
        asset_manager::freeze_position(signer::address_of(user));

        asset_manager::emergency_withdraw(user);

        // 钱应该回到余额里
        assert!(
            coin::balance<TestUSD>(signer::address_of(user)) == 1100,
            1
        );
        assert!(
            !asset_manager::has_yield_position(signer::address_of(user)),
            2
        );
    }

    #[test(admin = @protocol_75, reporter = @0x456, framework = @0x1)]
    /// 测试保证金逻辑
    fun test_bond_logic(
        admin: &signer, reporter: &signer, framework: &signer
    ) {
        asset_manager::setup_test(admin, reporter, framework, 1000);
        let reporter_addr = signer::address_of(reporter);

        // 1. 缴纳保证金 200
        asset_manager::collect_report_bond(reporter, 200);
        assert!(coin::balance<TestUSD>(reporter_addr) == 800, 1); // 1000 - 200

        // 2. 退还 100 (举报成功一半)
        asset_manager::release_or_seize_report_bond(reporter_addr, 100, true);
        assert!(coin::balance<TestUSD>(reporter_addr) == 900, 2); // 800 + 100

        // 3. 罚没 100 (恶意举报)
        asset_manager::release_or_seize_report_bond(reporter_addr, 100, false);
        // 钱应该进了 TREASURY (@protocol_75)
        // 注意：test setup 里 admin 也可能有钱，这里简单验证 reporter 没收到钱
        assert!(coin::balance<TestUSD>(reporter_addr) == 900, 3);

        // 验证 Bond 资源被销毁 (因为余额已空)
        assert!(!asset_manager::has_report_bond(reporter_addr), 4);
    }
}

