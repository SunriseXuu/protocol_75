module protocol_75::tasks {
    use std::signer;
    // use std::vector;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};

    friend protocol_75::challenge_manager;

    /// 错误：权限不足 (非管理员调用)
    const E_NOT_ADMIN: u64 = 1;
    /// 错误：无效的任务原子 ID (未通过配置表检查)
    const E_INVALID_TASK_ATOM_ID: u64 = 2;
    /// 错误：无效的任务目标值 (超出允许的 Min/Max 范围)
    const E_INVALID_TASK_GOAL: u64 = 3;
    /// 错误：无效的任务边界值 (例如 Min > Max)
    const E_INVALID_TASK_EDGES: u64 = 4;
    /// 错误：该任务类型已被禁用
    const E_TASK_DISABLED: u64 = 5;

    /// 管理员/部署者地址
    const ADMIN_ADDR: address = @protocol_75;

    /// 任务 ID: 每日锻炼
    const TASK_DAILY_EXERCISE: u8 = 1;
    /// 任务 ID: 合规睡眠
    const TASK_COMPLIANT_SLEEP: u8 = 2;
    /// 任务 ID: 正念冥想
    const TASK_MINDFUL_MEDITATION: u8 = 3;

    /// 目标 ID: 卡路里消耗
    const GOAL_CALORIES_BURNED: u8 = 1;
    /// 目标 ID: 锻炼时长
    const GOAL_EXERCISE_DURATION: u8 = 2;
    /// 目标 ID: 入睡时间
    const GOAL_BEDTIME: u8 = 3;
    /// 目标 ID: 苏醒时间
    const GOAL_WAKE_TIME: u8 = 4;
    /// 目标 ID: 合规睡眠时长
    const GOAL_SLEEP_DURATION: u8 = 5;
    /// 目标 ID: 冥想时长
    const GOAL_MEDITATION_DURATION: u8 = 6;

    struct GoalParam has store, drop, copy {
        weight_per_unit: u64,
        goal: u64
    }

    struct TaskAtom has store, drop, copy {
        task_atom_id: u8,
        goal_params: SimpleMap<u8, GoalParam>
    }

    struct TaskCombo has store, drop, copy {
        task_atoms: vector<TaskAtom>,
        daily_energy_min: u64,
        achieved_count_min: u64
    }

    struct GoalConfig has store, drop, copy {
        weight_per_unit: u64,
        goal_min: u64,
        goal_max: u64
    }

    struct TaskConfig has store, drop, copy {
        goal_config: SimpleMap<u8, GoalConfig>,
        is_active: bool
    }

    struct TaskPool has key {
        task_configs: Table<u8, TaskConfig>
    }

    fun init_module(admin: &signer) {
        let task_configs = table::new<u8, TaskConfig>();

        let goal_config = simple_map::new();
        goal_config.add(
            GOAL_CALORIES_BURNED,
            GoalConfig { weight_per_unit: 1, goal_min: 200, goal_max: 2000 }
        );
        goal_config.add(
            GOAL_EXERCISE_DURATION,
            GoalConfig { weight_per_unit: 3, goal_min: 30, goal_max: 300 }
        );
        task_configs.add(TASK_DAILY_EXERCISE, TaskConfig { goal_config, is_active: true });

        let goal_config = simple_map::new();
        goal_config.add(
            GOAL_BEDTIME, GoalConfig { weight_per_unit: 0, goal_min: 0, goal_max: 86399 }
        );
        goal_config.add(
            GOAL_WAKE_TIME, GoalConfig { weight_per_unit: 0, goal_min: 0, goal_max: 86399 }
        );
        goal_config.add(
            GOAL_SLEEP_DURATION,
            GoalConfig { weight_per_unit: 5, goal_min: 28, goal_max: 36 }
        );
        task_configs.add(
            TASK_COMPLIANT_SLEEP, TaskConfig { goal_config, is_active: true }
        );

        let goal_config = simple_map::new();
        goal_config.add(
            GOAL_MEDITATION_DURATION,
            GoalConfig { weight_per_unit: 5, goal_min: 10, goal_max: 120 }
        );
        task_configs.add(
            TASK_MINDFUL_MEDITATION, TaskConfig { goal_config, is_active: true }
        );

        move_to(admin, TaskPool { task_configs });
    }

    public entry fun upsert_task_pool(
        admin: &signer,
        task_atom_id: u8,
        goal_ids: vector<u8>,
        weight_per_units: vector<u64>,
        goal_mins: vector<u64>,
        goal_maxs: vector<u64>,
        is_active: bool
    ) acquires TaskPool {
        // 鉴权检查
        assert!(signer::address_of(admin) == ADMIN_ADDR, E_NOT_ADMIN);

        // 检查参数长度一致性
        let len = goal_ids.length();
        assert!(weight_per_units.length() == len, E_INVALID_TASK_EDGES);
        assert!(goal_mins.length() == len, E_INVALID_TASK_EDGES);
        assert!(goal_maxs.length() == len, E_INVALID_TASK_EDGES);

        // 检查参数边界并构建 goal_config
        let goal_config = simple_map::new();
        let i = 0;
        while (i < len) {
            let goal_id = goal_ids[i];
            let weight_per_unit = weight_per_units[i];
            let goal_min = goal_mins[i];
            let goal_max = goal_maxs[i];

            assert!(goal_min <= goal_max, E_INVALID_TASK_EDGES);

            goal_config.add(
                goal_id, GoalConfig { weight_per_unit, goal_min, goal_max }
            );

            i += 1;
        };

        let task_pool = borrow_global_mut<TaskPool>(ADMIN_ADDR);
        let task_configs = &mut task_pool.task_configs;

        let task_config = TaskConfig { goal_config, is_active };

        // 该任务原子存在，则更新
        if (task_configs.contains(task_atom_id)) {
            *task_configs.borrow_mut(task_atom_id) = task_config;
        }
        // 该任务原子不存在，则添加
        else {
            task_configs.add(task_atom_id, task_config);
        }
    }

    public(friend) fun new_task_atom(
        task_atom_id: u8, goal_ids: vector<u8>, goals: vector<u64>
    ): TaskAtom acquires TaskPool {
        // 检查参数长度一致性
        let len = goal_ids.length();
        assert!(goal_ids.length() == len, E_INVALID_TASK_EDGES);
        assert!(goals.length() == len, E_INVALID_TASK_EDGES);

        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);
        let task_configs = &task_pool.task_configs;

        // 检查任务配置是否存在
        assert!(task_configs.contains(task_atom_id), E_INVALID_TASK_ATOM_ID);

        let task_config = task_configs.borrow(task_atom_id);

        // 检查任务是否处于启用状态
        assert!(task_config.is_active, E_TASK_DISABLED);

        // 检查参数边界并构建 goal
        let goal_params = simple_map::new();

        let i = 0;
        while (i < len) {
            let goal_id = goal_ids[i];
            let goal_value = goals[i];

            let goal_config = task_config.goal_config.borrow(&goal_id);

            // 检查任务目标是否在允许范围内
            assert!(
                goal_value >= goal_config.goal_min
                    && goal_value <= goal_config.goal_max,
                E_INVALID_TASK_GOAL
            );

            goal_params.add(
                goal_id,
                GoalParam { weight_per_unit: goal_config.weight_per_unit, goal: goal_value }
            );

            i += 1;
        };

        TaskAtom { task_atom_id, goal_params }
    }
}

