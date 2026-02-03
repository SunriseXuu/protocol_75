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

    /// 权限不足 (非管理员)
    const E_NOT_ADMIN: u64 = 1;
    /// 无效的任务 ID
    const E_INVALID_TASK_ID: u64 = 2;
    /// 无效的任务目标
    const E_INVALID_TASK_GOAL: u64 = 3;
    /// 无效的任务配置
    const E_TASK_DISABLED: u64 = 4;
    /// 限制设置错误 (Min > Max)
    const E_INVALID_LIMITS: u64 = 5;

    /// 任务 ID 常量
    const TASK_CALORIES_BURNED: u8 = 1;
    const TASK_EXERCISE_DURATION: u8 = 2;
    const TASK_SLEEP_DURATION: u8 = 3;
    const TASK_MEDITATION_DURATION: u8 = 4;

    /// 管理员地址 (发布合约时需替换)
    const ADMIN_ADDR: address = @protocol_75;

    /// 任务原子
    struct TaskAtom has copy, drop, store {
        task_id: u8, // 任务 ID
        goal: u64 // 任务目标
    }

    /// 任务组合
    struct TaskCombo has copy, drop, store {
        task_atoms: vector<TaskAtom>, // 任务列表
        difficulty: u64 // 综合难度系数
    }

    /// 任务配置项
    struct TaskConfigItem has copy, drop, store {
        name: vector<u8>, // 任务名称
        weight: u64, // 任务难度权重 (每单位)
        goal_min: u64, // 任务目标下限
        goal_max: u64, // 任务目标上限
        is_active: bool // 任务是否启用
    }

    /// 管理员配置：任务池 (单例资源)
    struct TaskPool has key {
        pool: Table<u8, TaskConfigItem> // task_id -> task_config_item
    }

    /// 模块初始化：设置默认任务池
    fun init_module(admin: &signer) {
        // 初始化默认任务池
        let pool = table::new<u8, TaskConfigItem>();

        // 卡路里消耗
        pool.add(
            TASK_CALORIES_BURNED,
            TaskConfigItem {
                name: b"Calories Burned",
                weight: 1,
                goal_min: 200, // 默认下限 200千卡
                goal_max: 10000, // 默认上限 10000千卡
                is_active: true
            }
        );
        // 锻炼时长
        pool.add(
            TASK_EXERCISE_DURATION,
            TaskConfigItem {
                name: b"Exercise Duration",
                weight: 10,
                goal_min: 30, // 默认下限 30分钟
                goal_max: 300, // 默认上限 300分钟
                is_active: true
            }
        );
        // 合规睡眠时长
        pool.add(
            TASK_SLEEP_DURATION,
            TaskConfigItem {
                name: b"Sleep Duration",
                weight: 1,
                goal_min: 420, // 默认下限 420分钟 7小时
                goal_max: 540, // 默认上限 540分钟 9小时
                is_active: true
            }
        );
        // 冥想时长
        pool.add(
            TASK_MEDITATION_DURATION,
            TaskConfigItem {
                name: b"Meditation Duration",
                weight: 20,
                goal_min: 10, // 默认下限 10分钟
                goal_max: 120, // 默认上限 120分钟
                is_active: true
            }
        );

        // 创建任务池到 Admin 账户
        move_to(admin, TaskPool { pool });
    }

    /// 管理员：更新或新增任务配置
    public entry fun upsert_task_pool(
        admin: &signer,
        task_id: u8,
        name: vector<u8>,
        weight: u64,
        goal_min: u64,
        goal_max: u64,
        is_active: bool
    ) {
        assert!(signer::address_of(admin) == ADMIN_ADDR, E_NOT_ADMIN);
        assert!(goal_min <= goal_max, E_INVALID_LIMITS);

        let pool = &mut borrow_global_mut<TaskPool>(ADMIN_ADDR).pool;
        let item = TaskConfigItem { name, weight, goal_min, goal_max, is_active };

        if (pool.contains(task_id)) {
            *pool.borrow_mut(task_id) = item;
        } else {
            pool.add(task_id, item);
        }
    }

    /// 创建一个任务原子
    public fun new_task_atom(task_id: u8, goal: u64): TaskAtom {
        let pool = &borrow_global<TaskPool>(ADMIN_ADDR).pool;
        let task_config_item = pool.borrow(task_id);

        // 检查任务是否存在
        assert!(pool.contains(task_id), E_INVALID_TASK_ID);
        // 检查任务是否启用
        assert!(task_config_item.is_active, E_TASK_DISABLED);
        // 任务目标边界检查
        assert!(
            goal >= task_config_item.goal_min && goal <= task_config_item.goal_max,
            E_INVALID_TASK_GOAL
        );

        TaskAtom { task_id, goal }
    }

    /// 创建一个任务组合
    public fun new_task_combo(task_atoms: vector<TaskAtom>): TaskCombo {
        let difficulty = calculate_difficulty(&task_atoms);
        TaskCombo { task_atoms, difficulty }
    }

    /// 计算综合难度系数 - e.g. Sum(TaskWeight * Param)
    fun calculate_difficulty(task_atoms: &vector<TaskAtom>): u64 {
        let pool = &borrow_global<TaskPool>(ADMIN_ADDR).pool;

        let total_difficulty = 0;
        let len = task_atoms.length();

        for (i in 0..len) {
            let task_atom = task_atoms[i];
            let task_config_item = pool.borrow(task_atom.task_id);

            // 既然 TaskAtom 已经被 new_task_atom 验证过，这里理论上不需要再 assert
            // 但为了安全（防止配置被中途修改删除），还是检查一下

            // 检查任务是否存在
            assert!(pool.contains(task_atom.task_id), E_INVALID_TASK_ID);
            // 检查任务是否启用
            assert!(task_config_item.is_active, E_TASK_DISABLED);
            // 任务目标边界检查
            assert!(
                task_atom.goal >= task_config_item.goal_min
                    && task_atom.goal <= task_config_item.goal_max,
                E_INVALID_TASK_GOAL
            );

            total_difficulty += task_config_item.weight * task_atom.goal;
        };

        total_difficulty
    }

    #[view]
    /// 视图函数：获取某个任务的配置
    public fun get_task_config(task_id: u8): (vector<u8>, u64, u64, u64, bool) {
        let pool = &borrow_global<TaskPool>(ADMIN_ADDR).pool;
        if (!pool.contains(task_id)) {
            return (b"", 0, 0, 0, false)
        };

        let item = pool.borrow(task_id);
        (item.name, item.weight, item.goal_min, item.goal_max, item.is_active)
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
        task_atoms.push_back(new_task_atom(1, 300));
        task_atoms.push_back(new_task_atom(2, 30));

        // 计算：(1 * 300) + (10 * 30) = 300 + 300 = 600
        let difficulty = calculate_difficulty(&task_atoms);
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
        let task_atoms = vector::singleton<TaskAtom>(new_task_atom(1, 0));

        // 应该报错
        calculate_difficulty(&task_atoms);
    }

    #[test(admin = @protocol_75)]
    /// 测试 upsert 任务
    /// 场景：
    /// - Admin 创建任务：睡眠 8小时 (480分钟)
    /// - Admin 修改配置：将睡眠权重改为 2，上下限改为 400-800分钟
    /// - Admin 新增任务：任务代号 5，步数 10-30，假设单位是1000步
    /// 预期结果：全部通过
    fun test_upsert_task(admin: &signer) {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 睡眠 480 (一开始在 420-540 之间) -> 合法
        let task_atoms = vector::singleton<TaskAtom>(
            new_task_atom(TASK_SLEEP_DURATION, 480)
        );
        assert!(calculate_difficulty(&task_atoms) == 480, 0);

        // 修改任务原子配置
        upsert_task_pool(
            admin,
            TASK_SLEEP_DURATION,
            b"Sleep Duration",
            2, // 新的权重
            400, // 新的下限
            800, // 新的上限
            true
        );
        assert!(calculate_difficulty(&task_atoms) == 960, 1);

        // 新增任务原子，权重 25，上下限 10-30
        upsert_task_pool(admin, 5, b"Walk Steps", 25, 10, 30, true);
        let task_atoms = vector::singleton<TaskAtom>(new_task_atom(5, 20));
        assert!(calculate_difficulty(&task_atoms) == 500, 2);
    }
}

