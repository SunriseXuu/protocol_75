/// 任务市场模块 - Task Market Module
///
/// 功能描述：
/// - 定义任务原子类型，包括：
///   - 卡路里消耗 calories_burned - id: 1
///   - 锻炼时长 exercise_duration - id: 2
///   - 合规睡眠时长 sleep_duration - id: 3
///   - 冥想时长 meditation_duration - id: 4
/// - 创建、验证任务，创建任务组合
/// - 根据任务权重和参数，计算综合难度分
/// - 主要用于链上验证用户的任务难度，作为自律依据
///
/// 设计说明：
/// - 任务数据只依赖第三方健康数据平台，拒绝人为填写，记录时需验签
/// - 卡路里消耗和锻炼时长不依赖锻炼方式，测量方便、人人皆宜
/// - 合规睡眠时长等于承诺的窗口期与实际睡眠时间的交集
///
/// 模块关系：
/// - 本模块不依赖任何其他模块
/// - challenge_manager：调用本模块的 create_task_combo 方法
module protocol_75::task_market {
    use std::signer;
    use aptos_std::table::{Self, Table};

    /// 无效的任务 ID
    const E_INVALID_TASK_ID: u64 = 4;
    /// 无效的任务目标
    const E_INVALID_TASK_GOAL: u64 = 1;
    /// 权限不足 (非管理员)
    const E_NOT_ADMIN: u64 = 2;
    /// 限制设置错误 (Min > Max)
    const E_INVALID_LIMITS: u64 = 3;

    /// u64 最大值 - 用于表示无上限
    const U64_MAX: u64 = 18446744073709551615;

    /// 任务原子
    struct TaskAtom has copy, drop, store {
        id: u8, // 任务 ID
        goal: u64 // 任务目标
    }

    /// 任务组合
    struct TaskCombo has copy, drop, store {
        task_atoms: vector<TaskAtom> // 任务列表
    }

    /// 任务限制
    struct TaskLimit has copy, drop, store {
        weight: u64, // 任务权重
        goal_min: u64, // 任务目标下限
        goal_max: u64 // 任务目标上限
    }

    /// 任务配置 (单例资源，存储在 Admin 账户下)
    struct TaskConfig has key {
        task_names: Table<u8, vector<u8>>, // 任务名称
        task_limits: Table<u8, TaskLimit> // 任务限制
    }

    /// 模块初始化：设置默认配置
    fun init_module(admin: &signer) {
        // 初始化默认任务名称
        let task_names = table::new<u8, vector<u8>>();

        task_names.add(1, b"Calories Burned");
        task_names.add(2, b"Exercise Duration");
        task_names.add(3, b"Sleep Duration");
        task_names.add(4, b"Meditation Duration");

        // 初始化默认任务限制
        let task_limits = table::new<u8, TaskLimit>();

        // 卡路里消耗 - 默认下限 200千卡
        task_limits.add(
            1, TaskLimit { weight: 1, goal_min: 200, goal_max: U64_MAX }
        );
        // 锻炼时长 - 默认下限 30分钟
        task_limits.add(
            2, TaskLimit { weight: 10, goal_min: 30, goal_max: U64_MAX }
        );
        // 合规睡眠时长 - 默认下限 7小时 上限 9小时
        task_limits.add(
            3, TaskLimit { weight: 1, goal_min: 420, goal_max: 540 }
        );
        // 冥想时长 - 默认下限 10分钟
        task_limits.add(
            4, TaskLimit { weight: 20, goal_min: 10, goal_max: U64_MAX }
        );

        // 创建任务配置到 Admin 账户
        move_to(admin, TaskConfig { task_names, task_limits });
    }

    /// 管理员入口：更新或新增一个任务
    public entry fun upsert_task(
        admin: &signer,
        id: u8,
        weight: u64,
        goal_min: u64,
        goal_max: u64
    ) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);
        assert!(goal_min <= goal_max, E_INVALID_LIMITS);

        let task_limits = &mut borrow_global_mut<TaskConfig>(@protocol_75).task_limits;

        if (task_limits.contains(id)) {
            *task_limits.borrow_mut(id) = TaskLimit { weight, goal_min, goal_max };
        } else {
            task_limits.add(
                id, TaskLimit { weight, goal_min, goal_max }
            );
        }
    }

    /// 创建一个任务原子
    public fun create_task_atom(id: u8, goal: u64): TaskAtom {
        // 任务目标边界检查
        let task_limit = get_task_limits(id);
        assert!(
            goal >= task_limit.goal_min && goal <= task_limit.goal_max,
            E_INVALID_TASK_GOAL
        );

        TaskAtom { id, goal }
    }

    /// 创建一个任务组合
    public fun create_task_combo(task_atoms: vector<TaskAtom>): TaskCombo {
        TaskCombo { task_atoms }
    }

    /// 计算综合难度系数 - e.g. Sum(TaskWeight * Param)
    public fun calculate_difficulty(task_combo: &TaskCombo): u64 {
        let total_difficulty = 0;
        let len = task_combo.task_atoms.length();

        for (i in 0..len) {
            let task_atom = &task_combo.task_atoms[i];
            let task_limit = get_task_limits(task_atom.id);

            total_difficulty += task_limit.weight * task_atom.goal;
        };

        total_difficulty
    }

    #[view]
    /// 视图函数：获取某个任务的限制
    public fun get_task_limits(id: u8): TaskLimit {
        let task_limits = &borrow_global<TaskConfig>(@protocol_75).task_limits;
        assert!(task_limits.contains(id), E_INVALID_TASK_ID);

        *task_limits.borrow(id)
    }

    #[test_only]
    use std::vector;

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    /// 为其他模块提供 init_module 的接口
    public fun init_module_for_test(admin: &signer) {
        init_module(admin);
    }

    #[test(admin = @protocol_75)]
    /// 测试正常情况下的难度计算
    /// 场景：
    /// - 任务原子 1：消耗卡路里（权重1），参数300 kcal -> 300
    /// - 任务原子 2：锻炼时长（权重10），参数20 min -> 200
    /// 预期结果：总难度 600
    fun test_calculate_difficulty(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 准备任务原子
        let task_atoms = vector::empty<TaskAtom>();
        // 卡路里 300 > 200 (Min), 锻炼 30 >= 30 (Min) -> 合法
        task_atoms.push_back(create_task_atom(1, 300));
        task_atoms.push_back(create_task_atom(2, 30));

        let task_combo = create_task_combo(task_atoms);

        // 计算：(1 * 300) + (10 * 30) = 300 + 300 = 600
        let difficulty = calculate_difficulty(&task_combo);
        assert!(difficulty == 600, 0);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_INVALID_TASK_GOAL)]
    /// 测试错误处理：非法任务目标
    /// 场景：任务参数为0（例如消耗0卡路里）
    /// 预期结果：触发 E_INVALID_TASK_GOAL 错误并中止
    fun test_fail_goal(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 测试非法参数：消耗 0 kcal (小于配置)
        let task_atoms = vector::singleton<TaskAtom>(create_task_atom(1, 0));
        let task_combo = create_task_combo(task_atoms);

        // 应该报错
        calculate_difficulty(&task_combo);
    }

    #[test(admin = @protocol_75)]
    /// 测试 upsert 任务
    /// 场景：
    /// - Admin 创建任务：睡眠 8小时 (480分钟)
    /// - Admin 修改配置：将睡眠权重改为 2
    /// - Admin 修改配置：将睡眠限制改为 500-800分钟
    /// - Admin 新增任务：任务代号 4，带有上下限
    /// 预期结果：全部通过
    fun test_upsert_task(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 声明睡眠时长任务 ID
        let task_sleep_duration = 3;

        // 睡眠 480 (在 420-540 之间) -> 合法
        let task_atoms = vector::singleton<TaskAtom>(
            create_task_atom(task_sleep_duration, 480)
        );
        let task_combo = create_task_combo(task_atoms);
        assert!(calculate_difficulty(&task_combo) == 480, 0);

        // 修改任务原子权重
        upsert_task(admin, task_sleep_duration, 2, 420, 540);
        assert!(calculate_difficulty(&task_combo) == 960, 1);

        // 修改任务原子限制
        upsert_task(admin, task_sleep_duration, 2, 500, 800);
        // 480 < 500，虽然非法了，但是已经存在的任务组合不受影响
        assert!(calculate_difficulty(&task_combo) == 960, 2);

        // 新增任务原子，权重 25，上下限 10-120
        upsert_task(admin, 4, 25, 10, 120);
        let task_atoms = vector::singleton<TaskAtom>(create_task_atom(4, 80));
        let task_combo = create_task_combo(task_atoms);
        assert!(calculate_difficulty(&task_combo) == 2000, 3);
    }
}

