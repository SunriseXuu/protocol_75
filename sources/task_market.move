/// 任务市场模块 - Task Market Module
///
/// 功能描述：
/// - 定义原子任务类型，包括：
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

    /// 无效的任务ID
    const E_INVALID_TASK_ID: u64 = 4;
    /// 无效的任务目标
    const E_INVALID_TASK_GOAL: u64 = 1;
    /// 权限不足 (非管理员)
    const E_NOT_ADMIN: u64 = 2;
    /// 配置未初始化
    const E_CONFIG_NOT_FOUND: u64 = 3;
    /// 限制设置错误 (Min > Max)
    const E_INVALID_LIMITS: u64 = 5;

    /// 卡路里消耗任务ID
    const TASK_CALORIES_BURNED: u8 = 1;
    /// 锻炼时长任务ID
    const TASK_EXERCISE_DURATION: u8 = 2;
    /// 合规睡眠时长任务ID
    const TASK_SLEEP_DURATION: u8 = 3;
    /// 冥想时长任务ID
    const TASK_MEDITATION_DURATION: u8 = 4;

    /// 原子任务
    struct Task has copy, drop, store {
        id: u8,
        goal: u64
    }

    /// 任务组合
    struct TaskCombo has copy, drop, store {
        tasks: vector<Task>
    }

    /// 任务配置 (单例资源，存储在 Admin 账户下)
    struct TaskConfig has key {
        // 映射关系：Task ID (u8) -> Weight (u64)
        // 我们人为约定：Calories=1, Exercise=2, Sleep=3, Meditation=4
        task_weights: Table<u8, u64>,

        // 卡路里消耗限制配置
        task_calories_min: u64,

        // 锻炼时长限制配置
        task_exercise_min: u64,

        // 睡眠限制配置
        task_sleep_min: u64,
        task_sleep_max: u64,

        // 冥想时长限制配置
        task_meditation_min: u64
    }

    /// 模块初始化：设置默认配置
    fun init_module(admin: &signer) {
        // 初始化默认权重
        let weights = table::new();
        weights.add(1, 1);
        weights.add(2, 10);
        weights.add(3, 1);
        weights.add(4, 20);

        // 创建任务配置到 Admin 账户
        move_to(
            admin,
            TaskConfig {
                task_weights: weights,
                task_calories_min: 200, // 默认卡路里消耗下限 200千卡
                task_exercise_min: 30, // 默认锻炼时长下限 30分钟
                task_sleep_min: 420, // 默认合法的睡眠时长下限 7小时
                task_sleep_max: 540, // 默认合法的睡眠时长上限 9小时
                task_meditation_min: 10 // 默认冥想时长下限 10分钟
            }
        );
    }

    /// 管理员入口：新增一个任务
    public entry fun add_task(admin: &signer, task_id: u8, weight: u64) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);

        let task_weights = &mut borrow_global_mut<TaskConfig>(@protocol_75).task_weights;
        assert!(!task_weights.contains(task_id), E_INVALID_TASK_ID);

        task_weights.add(task_id, weight);
    }

    /// 管理员入口：更新某个任务的权重
    public entry fun update_task_weight(
        admin: &signer, task_id: u8, new_weight: u64
    ) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);

        let task_weights = &mut borrow_global_mut<TaskConfig>(@protocol_75).task_weights;
        assert!(task_weights.contains(task_id), E_INVALID_TASK_ID);

        task_weights.add(task_id, new_weight);
    }

    /// 管理员入口：更新卡路里消耗任务的参数的合法范围
    public entry fun update_task_calories(admin: &signer, min: u64) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);
        assert!(min > 0, E_INVALID_LIMITS);

        let config = borrow_global_mut<TaskConfig>(@protocol_75);
        config.task_calories_min = min;
    }

    /// 管理员入口：更新锻炼时长任务的参数的合法范围
    public entry fun update_task_exercise(admin: &signer, min: u64) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);
        assert!(min > 0, E_INVALID_LIMITS);

        let config = borrow_global_mut<TaskConfig>(@protocol_75);
        config.task_exercise_min = min;
    }

    /// 管理员入口：更新睡眠任务的参数的合法范围
    public entry fun update_task_sleep(admin: &signer, min: u64, max: u64) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);
        assert!(min < max, E_INVALID_LIMITS);

        let config = borrow_global_mut<TaskConfig>(@protocol_75);
        config.task_sleep_min = min;
        config.task_sleep_max = max;
    }

    /// 管理员入口：更新冥想任务的参数的合法范围
    public entry fun update_task_meditation(admin: &signer, min: u64) {
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);
        assert!(min > 0, E_INVALID_LIMITS);

        let config = borrow_global_mut<TaskConfig>(@protocol_75);
        config.task_meditation_min = min;
    }

    /// 创建一个 Task
    public fun create_task(task_id: u8, goal: u64): Task {
        let config = borrow_global<TaskConfig>(@protocol_75);

        // 任务ID检查
        assert!(config.task_weights.contains(task_id), E_INVALID_TASK_ID);

        // 任务目标边界检查
        let is_goal_invalid =
            if (task_id == TASK_CALORIES_BURNED) {
                goal < config.task_calories_min
            } else if (task_id == TASK_EXERCISE_DURATION) {
                goal < config.task_exercise_min
            } else if (task_id == TASK_SLEEP_DURATION) {
                goal < config.task_sleep_min || goal > config.task_sleep_max
            } else if (task_id == TASK_MEDITATION_DURATION) {
                goal < config.task_meditation_min
            } else { false };
        assert!(!is_goal_invalid, E_INVALID_TASK_GOAL);

        Task { id: task_id, goal }
    }

    /// 创建一个 TaskCombo
    public fun create_task_combo(tasks: vector<Task>): TaskCombo {
        TaskCombo { tasks }
    }

    /// 计算综合难度系数 - e.g. Sum(TaskWeight * Param)
    public fun calculate_difficulty(task_combo: &TaskCombo): u64 {
        let total_difficulty = 0;
        let len = task_combo.tasks.length();

        for (i in 0..len) {
            let task = &task_combo.tasks[i];
            let weight = get_task_weight(task.id);

            total_difficulty += weight * task.goal;
        };

        total_difficulty
    }

    #[view]
    /// 视图函数：获取某个任务ID的权重
    public fun get_task_weight(task_id: u8): u64 {
        let task_weights = &borrow_global<TaskConfig>(@protocol_75).task_weights;

        if (task_weights.contains(task_id)) {
            *task_weights.borrow(task_id)
        } else { 0 }
    }

    #[test_only]
    use std::vector;

    #[test_only]
    use aptos_framework::account;

    #[test(admin = @protocol_75)]
    /// 测试正常情况下的难度计算
    /// 场景：
    /// - 任务1：消耗卡路里（权重1），参数300 kcal -> 300
    /// - 任务2：锻炼时长（权重10），参数20 min -> 200
    /// 预期结果：总难度 600
    fun test_calculate_difficulty(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 准备任务
        let tasks = vector::empty<Task>();
        // 卡路里 300 > 200 (Min), 锻炼 30 >= 30 (Min) -> 合法
        tasks.push_back(create_task(1, 300));
        tasks.push_back(create_task(2, 30));

        let task_combo = create_task_combo(tasks);

        // 计算：(1 * 300) + (10 * 30) = 300 + 300 = 600
        let difficulty = calculate_difficulty(&task_combo);

        assert!(difficulty == 600, 0);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_INVALID_TASK)]
    /// 测试错误处理：非法参数
    /// 场景：任务参数为0（例如消耗0卡路里）
    /// 预期结果：触发 E_INVALID_TASK 错误并中止
    fun test_fail_zero_param(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 测试非法参数：消耗 0 kcal (小于配置)
        let tasks = vector::singleton(create_task(1, 0));
        let task_combo = create_task_combo(tasks);

        // 应该报错
        calculate_difficulty(&task_combo);
    }

    #[test(admin = @protocol_75)]
    /// 测试配置逻辑
    /// 场景：
    /// - Admin 创建任务：睡眠 8小时 (480分钟)
    /// - Admin 修改配置：将睡眠权重改为 2
    /// 预期结果：总难度 960
    fun test_config_logic(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        let tasks = vector::empty();
        // 睡眠 480 (在 420-540 之间) -> 合法
        tasks.push_back(create_task(TASK_SLEEP_DURATION, 480));
        let task_combo = create_task_combo(tasks);

        assert!(calculate_difficulty(&task_combo) == 480, 0);

        // 修改权重
        update_task_weight(admin, TASK_SLEEP_DURATION, 2);
        assert!(calculate_difficulty(&task_combo) == 960, 1);

        // 修改限制
        update_task_sleep(admin, 500, 800);
        // 480 < 500，现在非法了，但是已经存在的任务组合不受影响
        assert!(calculate_difficulty(&task_combo) == 960, 2);
    }
}

