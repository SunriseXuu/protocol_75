#[test_only]
module protocol_75::task_market_tests {
    #[test_only]
    use std::vector;
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use protocol_75::task_market::{Self, TaskAtom};

    // 错误码 (Error Codes) 直接照搬
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_TASK_ID: u64 = 2;
    const E_INVALID_TASK_GOAL: u64 = 3;
    const E_INVALID_TASK_EDGES: u64 = 4;
    const E_TASK_DISABLED: u64 = 5;

    // 常量 (Constants) 直接照搬
    const TASK_CALORIES_BURNED: u8 = 1;
    const TASK_EXERCISE_DURATION: u8 = 2;
    const TASK_SLEEP_DURATION: u8 = 3;

    #[test(admin = @protocol_75)]
    /// 测试正常情况下的难度计算
    ///
    /// **测试场景**：
    /// - 任务原子 1：消耗卡路里 (Weight=1)，Goal=300 -> Difficulty=300
    /// - 任务原子 2：锻炼时长 (Weight=10)，Goal=30 -> Difficulty=300
    /// - **预期结果**：总难度 = 600
    fun test_calculate_difficulty(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 准备任务原子
        let task_atoms = vector::empty<TaskAtom>();
        // 卡路里 300 > 200 (Min), 锻炼 30 >= 30 (Min) -> 合法
        task_atoms.push_back(task_market::new_task_atom(TASK_CALORIES_BURNED, 300));
        task_atoms.push_back(task_market::new_task_atom(TASK_EXERCISE_DURATION, 30));

        // 计算：(1 * 300) + (10 * 30) = 300 + 300 = 600
        let difficulty = task_market::calculate_difficulty(&task_atoms);
        assert!(difficulty == 600, 0);
    }

    #[test(admin = @protocol_75)]
    #[
        expected_failure(
            abort_code = E_INVALID_TASK_GOAL, location = protocol_75::task_market
        )
    ]
    /// 测试异常场景：无效的任务目标值
    ///
    /// **测试场景**：
    /// - 提交一个 Goal=0 的任务原子 (低于 Min=200)
    /// - **预期结果**：触发 E_INVALID_TASK_GOAL (Code=3) 并中止
    fun test_fail_goal(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 测试非法参数：消耗 0 kcal (小于配置下限)
        let task_atoms = vector::singleton<TaskAtom>(task_market::new_task_atom(1, 0));

        // 预期报错
        task_market::calculate_difficulty(&task_atoms);
    }

    #[test(admin = @protocol_75)]
    /// 测试管理员配置更新 (Upsert)
    ///
    /// **测试场景**：
    /// - 验证默认睡眠任务难度 (480min = 480分)
    /// - Admin 修改睡眠任务：权重设为 2，范围调整为 400-800
    /// - 验证修改后的难度 (480min * 2 = 960分)
    /// - Admin 新增任务类型 (ID=5)，并验证新任务计算
    fun test_upsert_task(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 睡眠 480 (一开始在 420-540 之间) -> 合法
        let task_atoms = vector::singleton<TaskAtom>(
            task_market::new_task_atom(TASK_SLEEP_DURATION, 480)
        );
        assert!(task_market::calculate_difficulty(&task_atoms) == 480, 0);

        // 修改任务原子配置
        task_market::upsert_task_pool(
            admin,
            TASK_SLEEP_DURATION,
            b"Sleep Duration",
            2, // 新的权重
            400, // 新的下限
            800, // 新的上限
            true
        );
        assert!(task_market::calculate_difficulty(&task_atoms) == 960, 1);

        // 新增任务原子，权重 25，上下限 10-30
        task_market::upsert_task_pool(admin, 5, b"Walk Steps", 25, 10, 30, true);
        let task_atoms = vector::singleton<TaskAtom>(task_market::new_task_atom(5, 20));
        assert!(task_market::calculate_difficulty(&task_atoms) == 500, 2);
    }

    #[test(admin = @protocol_75, user = @0x123)]
    #[expected_failure(abort_code = E_NOT_ADMIN, location = protocol_75::task_market)]
    /// 测试权限安全性：非管理员尝试更新配置
    fun test_upsert_task_not_admin(admin: &signer, user: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 普通用户尝试修改配置 -> 预期失败
        task_market::upsert_task_pool(user, 1, b"Hacked", 1, 0, 100, true);
    }

    #[test(admin = @protocol_75)]
    #[
        expected_failure(
            abort_code = E_INVALID_TASK_EDGES, location = protocol_75::task_market
        )
    ]
    /// 测试配置边界安全性：Min > Max
    fun test_upsert_task_invalid_edges(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 设置 Min(100) > Max(50) -> 预期失败
        task_market::upsert_task_pool(admin, 1, b"Bad Config", 1, 100, 50, true);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_TASK_DISABLED, location = protocol_75::task_market)]
    /// 测试任务状态：尝试使用已禁用的任务
    fun test_task_disabled(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 禁用卡路里任务 (ID=1)
        task_market::upsert_task_pool(
            admin,
            TASK_CALORIES_BURNED,
            b"Calories Burned",
            1,
            200,
            10000,
            false // is_active = false
        );

        // 尝试创建该类型的任务原子 -> 预期失败
        task_market::new_task_atom(TASK_CALORIES_BURNED, 500);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(
        abort_code = E_INVALID_TASK_ID, location = protocol_75::task_market
    )]
    /// 测试无效 ID：尝试使用不存在的任务 ID
    fun test_invalid_task_id(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // ID 99 不存在 -> 预期失败
        task_market::new_task_atom(99, 100);
    }

    #[test(admin = @protocol_75)]
    #[
        expected_failure(
            abort_code = E_INVALID_TASK_GOAL, location = protocol_75::task_market
        )
    ]
    /// 测试双重校验逻辑 (Double Check)
    /// 测试场景：Atom 创建时合法，但随后配置变更（门槛提高），
    /// 在组合计算时应当拦截该“过时”的 Atom。
    fun test_double_check_logic(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        task_market::init_module_for_test(admin);

        // 创建合法的 Atom: Goal=300 (当前 Min=200)
        let atom = task_market::new_task_atom(TASK_CALORIES_BURNED, 300);
        let task_atoms = vector::singleton(atom);

        // 此时计算应该是成功的
        assert!(task_market::calculate_difficulty(&task_atoms) == 300, 0);

        // 管理员更新配置，将 Min 提高到 400
        task_market::upsert_task_pool(
            admin,
            TASK_CALORIES_BURNED,
            b"Harder Calories",
            1,
            400, // 新 Min > 这里的 Atom Goal(300)
            10000,
            true
        );

        // 4. 再次计算 -> Double Check 应发现 Goal(300) < Min(400) -> 预期失败
        task_market::calculate_difficulty(&task_atoms);
    }
}

