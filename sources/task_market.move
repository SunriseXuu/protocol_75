/// # 任务市场模块 (Task Market)
///
/// ## 功能描述
/// 该模块充当协议的行为定义中心，管理所有支持的自律指标与规则参数
/// 核心功能包括：
/// 1. **定义任务原子**：定义并维护了一组标准化的“任务原子”（如每日锻炼、合规睡眠、正念冥想）
/// 2. **任务池参数管理**：管理并校验各类任务原子的指标属性（如目标时长、卡路里消耗的上下限与对应的权重）
/// 3. **自由组合与难度合成**：允许用户自由设定参数，将多个任务原子合成为独立的“任务组合”，并根据设定的参数强度自动合成对应的每日最低能量下限，以此作为后续信用分计算的基础权重
///
/// ## 核心机制
/// - **基于客观数据**：所有任务验证均采用“链下计算，链上验证”模式，依赖高可信物理硬件（如原生智能手表）的数据作为输入，彻底防范人为表单造假
/// - **原子化与可扩展性**：采用面向资源的设计哲学，定义基础的标准任务单元，未来可灵活支持更多元的高阶健康指标
/// - **安全性与防作弊**：严格约束单次允许设置的健康指标范围（Min/Max）以阻断低门槛或超人类极限的刷分行为
/// - **非线性激励基础**：输出由各任务原子难度复合叠加而成的日能量下限，直接服务于信用算法模型中的积分阻尼与动态清算环节
///
/// ## 模块依赖
/// - 纯粹的底层数据与规则库，无上层依赖
/// - 作为基础模块，被 `challenge_manager` 在初始化组局和清算判定时调用
module protocol_75::task_market {
    use std::signer;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};

    friend protocol_75::challenge_manager;

    // 错误码 (Error Codes) --------------------------------------------

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

    // 常量 (Constants) -----------------------------------------------

    /// 管理员/部署者地址
    const ADMIN_ADDR: address = @protocol_75;
    /// 能量放大系数
    const ENERGY_SCALING_FACTOR: u64 = 500;

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

    // 数据结构 (Data Structures) ---------------------------------------

    /// 任务目标参数
    struct GoalParam has store, drop, copy {
        /// 每单位目标的权重
        weight_per_unit: u64,
        /// 目标值
        goal: u64
    }

    /// 任务原子 (Task Atom)
    struct TaskAtom has store, drop, copy {
        /// 任务原子 ID
        task_atom_id: u8,
        /// 任务目标 ID 列表
        goal_ids: vector<u8>,
        /// 任务目标参数映射 goal_id => GoalParam
        goal_params: SimpleMap<u8, GoalParam>
    }

    /// 任务组合 (Task Combo)
    struct TaskCombo has store, drop, copy {
        /// 任务原子列表
        task_atoms: vector<TaskAtom>,
        /// 每日至少所需的能量值
        daily_energy_least: u64,
        /// 至少所需的达成次数
        achieved_count_least: u64
    }

    /// 任务配置 (Task Config)
    struct GoalConfig has store, drop, copy {
        /// 每单位目标的权重
        weight_per_unit: u64,
        /// 目标最小值
        goal_min: u64,
        /// 目标最大值
        goal_max: u64
    }

    /// 任务配置 (Task Config)
    struct TaskConfig has store, drop, copy {
        /// 任务目标配置映射 goal_id => GoalConfig
        goal_config: SimpleMap<u8, GoalConfig>,
        /// 任务是否激活
        is_active: bool
    }

    /// 任务池 (Task Pool)
    struct TaskPool has key {
        /// 任务配置映射 task_atom_id => TaskConfig
        task_configs: Table<u8, TaskConfig>
    }

    // 初始化 (Init) ---------------------------------------------------

    fun init_module(admin: &signer) {
        let task_configs = table::new<u8, TaskConfig>();

        // 默认任务1. 每日锻炼 (Daily Exercise)
        // 目标1. 卡路里消耗 (Calories Burned)：每单位权重 1，合理范围 200-2000 卡路里
        // 目标2. 锻炼时长 (Exercise Duration)：每单位权重 3，合理范围 30-300 分钟
        let goal_config1 = simple_map::new();
        goal_config1.add(
            GOAL_CALORIES_BURNED,
            GoalConfig { weight_per_unit: 1, goal_min: 200, goal_max: 2000 }
        );
        goal_config1.add(
            GOAL_EXERCISE_DURATION,
            GoalConfig { weight_per_unit: 3, goal_min: 30, goal_max: 300 }
        );
        task_configs.add(
            TASK_DAILY_EXERCISE, TaskConfig { goal_config: goal_config1, is_active: true }
        );

        // 默认任务2. 合规睡眠 (Compliant Sleep)
        // 目标1. 入睡时间 (Bedtime)：每单位权重 0，合理范围 0-86399 秒（当天内的任意时刻）
        // 目标2. 苏醒时间 (Wake Time)：每单位权重 0，合理范围 0-86399 秒（当天内的任意时刻）
        // 目标3. 合规睡眠时长 (Compliant Sleep Duration)：每单位权重 5，合理范围 7-9 小时
        let goal_config2 = simple_map::new();
        goal_config2.add(
            GOAL_BEDTIME, GoalConfig { weight_per_unit: 0, goal_min: 0, goal_max: 86399 }
        );
        goal_config2.add(
            GOAL_WAKE_TIME, GoalConfig { weight_per_unit: 0, goal_min: 0, goal_max: 86399 }
        );
        goal_config2.add(
            GOAL_SLEEP_DURATION,
            GoalConfig { weight_per_unit: 5, goal_min: 28, goal_max: 36 }
        );
        task_configs.add(
            TASK_COMPLIANT_SLEEP, TaskConfig { goal_config: goal_config2, is_active: true }
        );

        // 默认任务3. 正念冥想 (Mindful Meditation)
        // 目标1. 冥想时长 (Meditation Duration)：每单位权重 5，合理范围 10-120 分钟
        let goal_config3 = simple_map::new();
        goal_config3.add(
            GOAL_MEDITATION_DURATION,
            GoalConfig { weight_per_unit: 5, goal_min: 10, goal_max: 120 }
        );
        task_configs.add(
            TASK_MINDFUL_MEDITATION,
            TaskConfig { goal_config: goal_config3, is_active: true }
        );

        move_to(admin, TaskPool { task_configs });
    }

    // 管理员接口 (Admin Entries) ----------------------------------------

    /// 新增或更新任务配置 (Upsert Task Config)
    /// 管理员可通过该接口新增或更新任务原子配置，包括目标权重、目标上下限及启用状态
    ///
    /// @param admin 管理员 signer
    /// @param task_atom_id 任务原子 ID
    /// @param goal_ids 目标 ID 列表
    /// @param weight_per_units 每单位目标的权重列表 (与 goal_ids 顺序对应)
    /// @param goal_mins 目标最小值列表 (与 goal_ids 顺序对应)
    /// @param goal_maxs 目标最大值列表 (与 goal_ids 顺序对应)
    /// @param is_active 任务是否启用
    public entry fun upsert_task_pool(
        admin: &signer,
        task_atom_id: u8,
        goal_ids: vector<u8>,
        weight_per_units: vector<u64>,
        goal_mins: vector<u64>,
        goal_maxs: vector<u64>,
        is_active: bool
    ) acquires TaskPool {
        // 鉴权检查是否是管理员调用
        assert!(signer::address_of(admin) == ADMIN_ADDR, E_NOT_ADMIN);

        // 检查参数长度一致性
        let len = goal_ids.length();
        assert!(weight_per_units.length() == len, E_INVALID_TASK_EDGES);
        assert!(goal_mins.length() == len, E_INVALID_TASK_EDGES);
        assert!(goal_maxs.length() == len, E_INVALID_TASK_EDGES);

        // 构建 goal_config
        let goal_config = simple_map::new();
        let i = 0;
        while (i < len) {
            let goal_id = goal_ids[i];
            let weight_per_unit = weight_per_units[i];
            let goal_min = goal_mins[i];
            let goal_max = goal_maxs[i];

            // 检查参数边界
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

    // 友元接口 (Friend Only) -------------------------------------------

    /// 新建任务原子 (New Task Atom)
    /// 仅可由上层 Challenge 模块通过该接口创建任务原子实例
    ///
    /// @param task_atom_id 任务原子 ID
    /// @param goal_ids 目标 ID 列表
    /// @param goals 目标值列表 (与 goal_ids 顺序对应)
    ///
    /// @return 任务原子实例
    public(friend) fun new_task_atom(
        task_atom_id: u8, goal_ids: vector<u8>, goals: vector<u64>
    ): TaskAtom acquires TaskPool {
        // 检查参数长度一致性
        let len = goal_ids.length();
        assert!(goals.length() == len, E_INVALID_TASK_EDGES);

        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);
        let task_configs = &task_pool.task_configs;

        // 检查任务配置是否存在
        assert!(task_configs.contains(task_atom_id), E_INVALID_TASK_ATOM_ID);

        let task_config = task_configs.borrow(task_atom_id);

        // 检查任务是否处于启用状态
        assert!(task_config.is_active, E_TASK_DISABLED);

        // 循环遍历目标 ID 列表，构建 goal_params 映射
        let goal_params = simple_map::new();
        let i = 0;
        while (i < len) {
            let goal_id = goal_ids[i];
            let goal_value = goals[i];

            let goal_config_item = task_config.goal_config.borrow(&goal_id);

            // 检查任务目标是否在允许范围内
            assert!(
                goal_value >= goal_config_item.goal_min
                    && goal_value <= goal_config_item.goal_max,
                E_INVALID_TASK_GOAL
            );

            goal_params.add(
                goal_id,
                GoalParam {
                    weight_per_unit: goal_config_item.weight_per_unit,
                    goal: goal_value
                }
            );

            i += 1;
        };

        TaskAtom { task_atom_id, goal_ids, goal_params }
    }

    /// 新建任务组合 (New Task Combo)
    /// 仅可由上层 Challenge 模块通过该接口创建任务组合实例
    ///
    /// @param task_atoms 任务原子列表
    /// @param achieved_count_least 至少所需的达成次数
    ///
    /// @return 任务组合实例
    public(friend) fun new_task_combo(
        task_atoms: vector<TaskAtom>, achieved_count_least: u64
    ): TaskCombo {
        let daily_energy_least = calc_daily_energy_least(&task_atoms);
        TaskCombo { task_atoms, daily_energy_least, achieved_count_least }
    }

    /// 计算每日至少所需的能量值 (Calculate Daily Minimum Energy)
    /// 仅可由上层 Challenge 模块通过该接口计算任务组合的每日至少所需的能量值，用于计算违约后的惩罚
    ///
    /// @param task_atoms 任务原子列表
    /// @return 每日至少所需的能量值
    public(friend) fun calc_daily_energy_least(
        task_atoms: &vector<TaskAtom>
    ): u64 {
        let total_difficulty = 0;

        // 遍历任务原子列表，计算每日至少所需的能量值
        let i = 0;
        while (i < task_atoms.length()) {
            let task_atom = task_atoms.borrow(i);

            let goal_ids = &task_atom.goal_ids;
            let goal_params = &task_atom.goal_params;

            // 遍历目标 ID 列表，获取其对应的权重并计算总能量值
            let j = 0;
            while (j < goal_ids.length()) {
                let key = goal_ids[j];
                let param = goal_params.borrow(&key);

                // 将所有目标的能量值累加
                total_difficulty += param.weight_per_unit * param.goal;

                j += 1;
            };

            i += 1;
        };

        // 将总能量值乘以全局能量放大系数，并返回
        ENERGY_SCALING_FACTOR * total_difficulty
    }

    // 视图方法 (View Methods) ------------------------------------------

    #[view]
    /// 视图函数：获取任务配置 (Get Task Config)
    /// 提供查询接口，允许外部调用者获取特定任务原子 ID 的配置
    ///
    /// @param task_atom_id 任务原子 ID
    /// @return 任务配置
    public fun get_task_config(task_atom_id: u8): TaskConfig acquires TaskPool {
        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);

        if (task_pool.task_configs.contains(task_atom_id)) {
            *task_pool.task_configs.borrow(task_atom_id)
        } else {
            TaskConfig { goal_config: simple_map::new(), is_active: false }
        }
    }

    // 单元测试 (Unit Tests) --------------------------------------------

    #[test_only]
    friend protocol_75::task_market_tests;

    #[test_only]
    /// 为单元测试封装的 init_module
    public fun init_module_for_test(admin: &signer) {
        init_module(admin);
    }
}

