/// # 任务市场模块 (Task Market)
///
/// ## 功能描述
/// 本模块主要负责定义和管理“自律任务”，为上层 Challenge 应用提供基础的任务验证与难度计算服务。
/// 核心功能包括：
/// 1. **任务定义**：定义标准的任务原子类型（如运动时长、卡路里消耗、睡眠等）。
/// 2. **任务池管理**：管理员可配置各类任务的权重、目标上下限及启用状态。
/// 3. **难度计算**：根据任务权重和设定的目标值，计算任务组合的综合难度系数。
///
/// ## 设计原则
/// - **客观性**：任务数据来源于可信的第三方健康平台，并通过预言机验签，拒绝人为造假。
/// - **原子化**：任务被拆解为不可再分的“原子”，支持灵活组合。
/// - **安全性**：在计算难度时严格校验任务参数的有效性（存在性、激活状态、数值范围）。
/// - **合理化**：
///     - 卡路里消耗和锻炼时长不依赖锻炼方式，测量方便、人人皆宜
///     - 合规睡眠时长等于承诺的窗口期与实际睡眠时间的交集
///
/// ## 模块依赖
/// - 本模块为底层基础模块，无外部依赖。
/// - 被 `challenge_manager` 等上层业务模块调用。
module protocol_75::task_market {
    use std::signer;
    use aptos_std::table::{Self, Table};

    friend protocol_75::challenge_manager;

    // 错误码 (Error Codes) --------------------------------------------

    /// 错误：权限不足 (非管理员调用)
    const E_NOT_ADMIN: u64 = 1;
    /// 错误：无效的任务 ID (未通过配置表检查)
    const E_INVALID_TASK_ID: u64 = 2;
    /// 错误：无效的任务目标值 (超出允许的 Min/Max 范围)
    const E_INVALID_TASK_GOAL: u64 = 3;
    /// 错误：无效的任务边界值 (例如 Min > Max)
    const E_INVALID_TASK_EDGES: u64 = 4;
    /// 错误：该任务类型已被禁用
    const E_TASK_DISABLED: u64 = 5;

    // 常量 (Constants) -----------------------------------------------

    /// 任务 ID: 卡路里消耗 (Calories Burned)
    const TASK_CALORIES_BURNED: u8 = 1;
    /// 任务 ID: 锻炼时长 (Exercise Duration)
    const TASK_EXERCISE_DURATION: u8 = 2;
    /// 任务 ID: 合规睡眠时长 (Sleep Duration)
    const TASK_SLEEP_DURATION: u8 = 3;
    /// 任务 ID: 冥想时长 (Meditation Duration)
    const TASK_MEDITATION_DURATION: u8 = 4;

    /// 管理员/部署者地址
    const ADMIN_ADDR: address = @protocol_75;

    // 数据结构 (Data Structures) ---------------------------------------

    /// 任务原子 (Task Atom)
    /// 代表一个具体的、可量化的任务单元。
    struct TaskAtom has store, drop, copy {
        /// 任务类型 ID
        task_id: u8,
        /// 任务目标数值 (单位取决于具体任务类型，如 kcal, min)
        goal: u64
    }

    /// 任务组合 (Task Combo)
    /// 包含一组任务原子及其计算出的综合难度。
    struct TaskCombo has store, drop, copy {
        /// 任务原子列表
        task_atoms: vector<TaskAtom>,
        /// 综合难度系数
        difficulty: u64,
        /// 达成目标的次数下限
        achieved_goal_min: u64
    }

    /// 任务配置项 (Task Config Item)
    /// 存储每种任务类型的规则参数。
    struct TaskConfigItem has store, drop, copy {
        /// 任务名称 (如 "Calories Burned")
        name: vector<u8>,
        /// 任务难度权重 (每单位目标值对应的难度分数)
        weight: u64,
        /// 任务目标下限
        goal_min: u64,
        /// 任务目标上限
        goal_max: u64,
        /// 任务是否启用 (False 表示暂时废弃该任务类型)
        is_active: bool
    }

    /// 任务池 (Task Pool)
    /// 单例资源，存储在 ADMIN_ADDR 下，维护所有任务配置。
    struct TaskPool has key {
        /// 任务池映射关系: task_id -> task_config_item
        pool: Table<u8, TaskConfigItem>
    }

    /// 模块初始化 (仅在部署时调用)
    /// 设置默认支持的任务类型与参数
    fun init_module(admin: &signer) {
        // 创建任务池的默认配置表
        let pool = table::new<u8, TaskConfigItem>();

        // 默认任务1. 卡路里消耗 (Calories Burned)
        // 目标：200千卡 - 10000千卡
        pool.add(
            TASK_CALORIES_BURNED,
            TaskConfigItem {
                name: b"Calories Burned",
                weight: 1,
                goal_min: 200,
                goal_max: 10000,
                is_active: true
            }
        );
        // 默认任务2. 锻炼时长 (Exercise Duration)
        // 目标：30分钟 - 300分钟
        pool.add(
            TASK_EXERCISE_DURATION,
            TaskConfigItem {
                name: b"Exercise Duration",
                weight: 10,
                goal_min: 30,
                goal_max: 300,
                is_active: true
            }
        );
        // 默认任务3. 合规睡眠时长 (Sleep Duration)
        // 目标：420分钟(7h) - 540分钟(9h)
        pool.add(
            TASK_SLEEP_DURATION,
            TaskConfigItem {
                name: b"Sleep Duration",
                weight: 1,
                goal_min: 420,
                goal_max: 540,
                is_active: true
            }
        );
        // 默认任务4. 冥想时长 (Meditation Duration)
        // 目标：10分钟 - 120分钟
        pool.add(
            TASK_MEDITATION_DURATION,
            TaskConfigItem {
                name: b"Meditation Duration",
                weight: 20,
                goal_min: 10,
                goal_max: 120,
                is_active: true
            }
        );

        // 将 TaskPool 资源发布到管理员账户下
        move_to(admin, TaskPool { pool });
    }

    // 管理员接口 (Admin Entries) ----------------------------------------

    /// 更新或新增任务配置 (Upsert Task Pool)
    ///
    /// @param admin: 管理员账户签名
    /// @param task_id: 任务类型 ID
    /// @param name: 任务名称
    /// @param weight: 难度权重
    /// @param goal_min: 最小目标值
    /// @param goal_max: 最大目标值
    /// @param is_active: 是否启用
    public entry fun upsert_task_pool(
        admin: &signer,
        task_id: u8,
        name: vector<u8>,
        weight: u64,
        goal_min: u64,
        goal_max: u64,
        is_active: bool
    ) acquires TaskPool {
        // 鉴权检查
        assert!(signer::address_of(admin) == ADMIN_ADDR, E_NOT_ADMIN);
        // 参数边界检查
        assert!(goal_min <= goal_max, E_INVALID_TASK_EDGES);

        let task_pool = borrow_global_mut<TaskPool>(ADMIN_ADDR);
        let pool = &mut task_pool.pool;

        let task_config_item = TaskConfigItem {
            name,
            weight,
            goal_min,
            goal_max,
            is_active
        };
        // 存在则更新，不存在则添加
        if (pool.contains(task_id)) {
            *pool.borrow_mut(task_id) = task_config_item;
        } else {
            pool.add(task_id, task_config_item);
        }
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 构建并验证一个新的任务原子 (New Task Atom)
    ///
    /// @param task_id: 任务类型 ID
    /// @param goal: 用户承诺或完成的任务数值
    /// @return TaskAtom: 验证通过的任务原子对象
    public(friend) fun new_task_atom(task_id: u8, goal: u64): TaskAtom acquires TaskPool {
        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);
        let pool = &task_pool.pool;
        let task_config_item = pool.borrow(task_id);

        // 检查任务配置是否存在
        assert!(pool.contains(task_id), E_INVALID_TASK_ID);
        // 检查任务是否处于启用状态
        assert!(task_config_item.is_active, E_TASK_DISABLED);
        // 检查任务目标是否在允许范围内
        assert!(
            goal >= task_config_item.goal_min && goal <= task_config_item.goal_max,
            E_INVALID_TASK_GOAL
        );

        TaskAtom { task_id, goal }
    }

    /// 构建任务组合 (New Task Combo)
    ///
    /// @param task_atoms: 用于组合任务的任务原子列表
    /// @param achieved_goal_min: 达成目标的次数下限
    /// @return TaskCombo: 新的任务组合
    public(friend) fun new_task_combo(
        task_atoms: vector<TaskAtom>, achieved_goal_min: u64
    ): TaskCombo acquires TaskPool {
        // 根据传入的任务原子列表，计算总难度并打包
        let difficulty = calculate_difficulty(&task_atoms);

        TaskCombo { task_atoms, difficulty, achieved_goal_min }
    }

    // 私有方法 (Private Methods) ---------------------------------------

    /// 计算任务组合的综合难度系数 (Calculate Difficulty)
    ///
    /// 计算公式：Sum(TaskConfig.weight * TaskAtom.goal)
    /// 遍历任务列表，再次验证每个任务原子的有效性，并累加难度。
    ///
    /// @param task_atoms: 任务原子列表引用
    /// @return u64: 总难度系数
    fun calculate_difficulty(task_atoms: &vector<TaskAtom>): u64 acquires TaskPool {
        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);
        let pool = &task_pool.pool;

        let total_difficulty = 0;
        let len = task_atoms.length();

        for (i in 0..len) {
            let task_atom = task_atoms[i];
            let task_config_item = pool.borrow(task_atom.task_id);

            // Double Check: 虽然 new_task_atom 已做过检查，但在组合计算时再次校验
            // 可以防止配置在 TaskAtom 创建后被修改导致的潜在风险。

            // 检查任务配置是否存在
            assert!(pool.contains(task_atom.task_id), E_INVALID_TASK_ID);
            // 检查任务是否处于启用状态
            assert!(task_config_item.is_active, E_TASK_DISABLED);
            // 检查任务目标是否在允许范围内
            assert!(
                task_atom.goal >= task_config_item.goal_min
                    && task_atom.goal <= task_config_item.goal_max,
                E_INVALID_TASK_GOAL
            );

            // 累加难度：权重 * 目标值
            total_difficulty += task_config_item.weight * task_atom.goal;
        };

        total_difficulty
    }

    // 视图方法 (View Methods) ------------------------------------------

    #[view]
    /// 获取指定任务 ID 的配置详情 (Get Task Config)
    ///
    /// @param task_id: 指定任务 ID
    /// @return name: 任务名称
    /// @return weight: 难度权重
    /// @return goal_min: 目标下限
    /// @return goal_max: 目标上限
    /// @return is_active: 是否启用
    public fun get_task_config(task_id: u8): (vector<u8>, u64, u64, u64, bool) acquires TaskPool {
        let task_pool = borrow_global<TaskPool>(ADMIN_ADDR);
        let pool = &task_pool.pool;

        if (!pool.contains(task_id)) {
            return (b"", 0, 0, 0, false)
        };

        let TaskConfigItem { name, weight, goal_min, goal_max, is_active } =
            *pool.borrow(task_id);
        (name, weight, goal_min, goal_max, is_active)
    }

    // 单元测试 (Unit Tests) --------------------------------------------

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
    ///
    /// **测试场景**：
    /// - 任务原子 1：消耗卡路里 (Weight=1)，Goal=300 -> Difficulty=300
    /// - 任务原子 2：锻炼时长 (Weight=10)，Goal=30 -> Difficulty=300
    /// - **预期结果**：总难度 = 600
    fun test_calculate_difficulty(admin: &signer) acquires TaskPool {
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
    /// 测试异常场景：无效的任务目标值
    ///
    /// **测试场景**：
    /// - 提交一个 Goal=0 的任务原子 (低于 Min=200)
    /// - **预期结果**：触发 E_INVALID_TASK_GOAL (Code=3) 并中止
    fun test_fail_goal(admin: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 测试非法参数：消耗 0 kcal (小于配置下限)
        let task_atoms = vector::singleton<TaskAtom>(new_task_atom(1, 0));

        // 预期报错
        calculate_difficulty(&task_atoms);
    }

    #[test(admin = @protocol_75)]
    /// 测试管理员配置更新 (Upsert)
    ///
    /// **测试场景**：
    /// - 验证默认睡眠任务难度 (480min = 480分)
    /// - Admin 修改睡眠任务：权重设为 2，范围调整为 400-800
    /// - 验证修改后的难度 (480min * 2 = 960分)
    /// - Admin 新增任务类型 (ID=5)，并验证新任务计算
    fun test_upsert_task(admin: &signer) acquires TaskPool {
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

    #[test(admin = @protocol_75, user = @0x123)]
    #[expected_failure(abort_code = E_NOT_ADMIN)]
    /// 测试权限安全性：非管理员尝试更新配置
    fun test_upsert_task_not_admin(admin: &signer, user: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 普通用户尝试修改配置 -> 预期失败
        upsert_task_pool(user, 1, b"Hacked", 1, 0, 100, true);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_INVALID_TASK_EDGES)]
    /// 测试配置边界安全性：Min > Max
    fun test_upsert_task_invalid_edges(admin: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 设置 Min(100) > Max(50) -> 预期失败
        upsert_task_pool(admin, 1, b"Bad Config", 1, 100, 50, true);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_TASK_DISABLED)]
    /// 测试任务状态：尝试使用已禁用的任务
    fun test_task_disabled(admin: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 禁用卡路里任务 (ID=1)
        upsert_task_pool(
            admin,
            TASK_CALORIES_BURNED,
            b"Calories Burned",
            1,
            200,
            10000,
            false // is_active = false
        );

        // 尝试创建该类型的任务原子 -> 预期失败
        new_task_atom(TASK_CALORIES_BURNED, 500);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_INVALID_TASK_ID)]
    /// 测试无效 ID：尝试使用不存在的任务 ID
    fun test_invalid_task_id(admin: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // ID 99 不存在 -> 预期失败
        new_task_atom(99, 100);
    }

    #[test(admin = @protocol_75)]
    #[expected_failure(abort_code = E_INVALID_TASK_GOAL)]
    /// 测试双重校验逻辑 (Double Check)
    /// 测试场景：Atom 创建时合法，但随后配置变更（门槛提高），
    /// 在组合计算时应当拦截该“过时”的 Atom。
    fun test_double_check_logic(admin: &signer) acquires TaskPool {
        account::create_account_for_test(signer::address_of(admin));
        init_module(admin);

        // 创建合法的 Atom: Goal=300 (当前 Min=200)
        let atom = new_task_atom(TASK_CALORIES_BURNED, 300);
        let task_atoms = vector::singleton(atom);

        // 此时计算应该是成功的
        assert!(calculate_difficulty(&task_atoms) == 300, 0);

        // 管理员更新配置，将 Min 提高到 400
        upsert_task_pool(
            admin,
            TASK_CALORIES_BURNED,
            b"Harder Calories",
            1,
            400, // 新 Min > 这里的 Atom Goal(300)
            10000,
            true
        );

        // 4. 再次计算 -> Double Check 应发现 Goal(300) < Min(400) -> 预期失败
        calculate_difficulty(&task_atoms);
    }
}

