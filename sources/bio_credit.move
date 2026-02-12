/// # 身份与信用模块 (Bio Credit)
///
/// 该模块是协议的用户存储层 (Storage Layer)，负责管理用户的核心信用资产。
/// 它实现了 BioSoul SBT 的逻辑，结合了“时间衰减”与“能量成本积分”的数值模型。
///
/// ## 核心机制
/// 1. **BioSoul SBT**：用户的灵魂绑定资产，记录信用分、连胜、设备指纹。
/// 2. **数值系统 (Dynamic Energy Cost)**：
///    - **区间**：35.000000 (Min) - 95.000000 (Max)。
///    - **精度**：6 位小数 (u64 存储，1_000_000 = 1.0)。
///    - **成本模型**：分段线性成本 (Linear Marginal Cost)。
///         - **修复期 (35-50)**: Cost 1.0 -> 1.25
///         - **积累期 (50-75)**: Cost 1.25 -> 3.0
///         - **精英期 (75-95)**: Cost 3.0 -> 10.0
///    - **积分算法**：加分和扣分均通过积分计算，解决边界不连续问题。
///         - 加分：消耗能量，克服阻力向上爬。
///         - 扣分：损失能量，顺着阻力向下滑。
///    - **对称性**：分数越高，Cost 越高，意味着加分越难 (High Resistance)，扣分越快 (High Acceleration)。
/// 3. **数据聚合**：挂载勋章 (Badges)，并使用 Table 存储海量每日打卡日志。
///
/// ## 模块依赖
/// - `badge_factory`: 引用勋章对象类型。
/// - 仅 `challenge_manager` (Friend) 可修改分数与日志。
module protocol_75::bio_credit {
    use std::string::String;
    use std::vector;
    use std::signer;
    use std::math64;
    use aptos_std::table::{Self, Table};
    use aptos_framework::object::Object;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::account;

    use protocol_75::badge_factory::AchievementBadge;
    use protocol_75::bio_math;

    friend protocol_75::challenge_manager;

    // 错误码 (Error Codes) --------------------------------------------

    /// 错误：用户未注册
    const E_NOT_REGISTERED: u64 = 1;
    /// 错误：用户已注册
    const E_ALREADY_REGISTERED: u64 = 2;
    /// 错误：配置不存在
    const E_CONFIG_NOT_FOUND: u64 = 3;
    /// 错误：权限不足
    const E_NOT_ADMIN: u64 = 4;

    // 数值常量 (Constants) ---------------------------------------------

    /// 奖励事件
    const EVENT_REWARD: u8 = 1;
    /// 惩罚事件
    const EVENT_SLASH: u8 = 2;
    /// 衰减事件
    const EVENT_DECAY: u8 = 3;

    // 数据结构 (Data Structures) ---------------------------------------

    /// 用户每日行为数据 (轻量级结构)
    struct DailyData has store, drop {
        /// 目标是否达成
        is_goal_achieved: bool,
        /// 时间戳
        timestamp: u64,
        /// 签名哈希
        signature_hash: vector<u8>
    }

    /// 用户灵魂绑定资源 (SBT)
    struct BioSoul has key {
        /// 当前信用分 (精度6)
        score: u64,
        /// 历史最高分
        highest_score: u64,
        /// 个人连胜场次
        personal_streak: u64,
        /// 上次分数更新时间 (用于懒惰计算衰减)
        last_update_time: u64,
        /// 设备指纹哈希 (绑定常用设备)
        device_hash: vector<u8>,
        /// 获得的勋章列表
        badges: vector<Object<AchievementBadge>>,
        /// 每日打卡日志 (Key: YYYY-MM-DD)
        daily_checkin_log: Table<String, DailyData>
    }

    /// 信用变更事件
    struct ScoreUpdateEvent has store, drop {
        /// 用户地址
        user: address,
        /// 旧分数
        old_score: u64,
        /// 新分数
        new_score: u64,
        /// 事件类型
        event_type: u8,
        /// 时间戳
        timestamp: u64
    }

    /// 事件句柄容器
    struct Events has key {
        score_events: event::EventHandle<ScoreUpdateEvent>
    }

    // 用户接口 (User Entries) ------------------------------------------

    /// 用户注册 (Register User) 并初始化 BioSoul
    ///
    /// @param user: 签名者
    /// @param device_hash: 设备指纹哈希
    public entry fun register_user(user: &signer, device_hash: vector<u8>) {
        let user_addr = signer::address_of(user);

        // 不允许重复注册
        assert!(!exists<BioSoul>(user_addr), E_ALREADY_REGISTERED);

        // 创建 BioSoul 资源
        move_to(
            user,
            BioSoul {
                score: bio_math::get_credit_init(),
                highest_score: bio_math::get_credit_init(),
                personal_streak: 0,
                last_update_time: timestamp::now_seconds(),
                device_hash,
                badges: vector::empty(),
                daily_checkin_log: table::new()
            }
        );

        // 如果没有创建 Events 资源，则创建
        if (!exists<Events>(user_addr)) {
            move_to(
                user,
                Events {
                    score_events: account::new_event_handle<ScoreUpdateEvent>(user)
                }
            );
        }
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 记录每日打卡 (Record Daily Check-in)
    ///
    /// 本函数仅负责“记账”，不负责“算分”、“连胜”和“能量”。
    /// 算分逻辑由 challenge_manager 在确认合规后调用 `update_score_and_streak`。
    ///
    /// @param user: 用户地址
    /// @param date_key: 日期键 e.g. "2026-02-12"
    /// @param is_goal_achieved: 目标是否达成
    /// @param timestamp: 时间戳
    /// @param signature_hash: 签名哈希
    public(friend) fun record_daily_checkin(
        user: address,
        date_key: String,
        is_goal_achieved: bool,
        timestamp: u64,
        signature_hash: vector<u8>
    ) acquires BioSoul {
        // 若用户未注册，则报错
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        let bio_soul = borrow_global_mut<BioSoul>(user);
        let daily_data = DailyData { is_goal_achieved, timestamp, signature_hash };

        // 若用户已打卡，则更新
        if (bio_soul.daily_checkin_log.contains(date_key)) {
            let ref = bio_soul.daily_checkin_log.borrow_mut(date_key);
            *ref = daily_data;
        }
        // 若用户未打卡，则添加
        else {
            bio_soul.daily_checkin_log.add(date_key, daily_data);
        };
    }

    /// 更新分数与连胜 (Update Score and Streak)
    ///
    /// 包含核心的“能量成本积分”逻辑
    ///
    /// @param user: 用户地址
    /// @param is_task_achieved: 任务是否达成
    /// @param difficulty: 任务组合的综合难度系数
    /// @param achieved_goal_count: 累积的达成目标次数
    public(friend) fun update_score_and_streak(
        user: address,
        is_task_achieved: bool,
        difficulty: u64,
        achieved_goal_count: u64
    ) acquires BioSoul, Events {
        // 若用户未注册，则报错
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        let bio_soul = borrow_global_mut<BioSoul>(user);
        let old_score = bio_soul.score;

        // 先应用衰减
        let new_score =
            bio_math::calculate_decayed_score(
                old_score,
                bio_soul.last_update_time,
                timestamp::now_seconds()
            );
        // 如果分数发生变化，则更新并发出事件
        if (new_score != old_score) {
            bio_soul.score = new_score;
            emit_score_event(user, old_score, new_score, EVENT_DECAY);
        };

        // 如果任务达成
        if (is_task_achieved) {
            // 增加连胜
            bio_soul.personal_streak += 1;

            // 计算本次达成目标产生的总能量
            let energy_gain =
                bio_math::calculate_energy_gain(difficulty, achieved_goal_count);

            // 加分积分计算：根据 cost 曲线消耗能量
            let new_score =
                bio_math::integrate_energy_to_score(bio_soul.score, energy_gain);
            bio_soul.score = math64::min(new_score, bio_math::get_credit_max());

            // 更新最高分记录
            if (bio_soul.score > bio_soul.highest_score) {
                bio_soul.highest_score = bio_soul.score;
            };

            // 发出奖励事件
            emit_score_event(user, old_score, bio_soul.score, EVENT_REWARD);
        }
        // 如果任务失败
        else {
            // 清零连胜
            bio_soul.personal_streak = 0;

            // 计算原本应得的能量 (作为惩罚基数)
            // 对称性原则: 假如你完成了这个难度的任务，你能得多少能量
            // 现在你失败了，我们就用这个能量值反向积分扣除
            let energy_base =
                bio_math::calculate_energy_gain(difficulty, achieved_goal_count);

            // 扣分计算 (Slash) - 使用积分逻辑
            bio_soul.score = bio_math::calculate_slashed_score(
                bio_soul.score, energy_base
            );

            // 发出惩罚事件
            emit_score_event(user, old_score, bio_soul.score, EVENT_SLASH);
        };

        // 更新时间戳
        bio_soul.last_update_time = timestamp::now_seconds();
    }

    /// 挂载勋章 (Attach Badge)
    ///
    /// @param user: 用户地址
    /// @param badge: 勋章对象
    public(friend) fun attach_badge(
        user: address, badge: Object<AchievementBadge>
    ) acquires BioSoul {
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        let bio_soul = borrow_global_mut<BioSoul>(user);
        bio_soul.badges.push_back(badge);
    }

    // 私有方法 (Private Methods) ---------------------------------------

    /// 发出分数变化事件 (Emit Score Event)
    ///
    /// @param user: 用户地址
    /// @param old: 旧分数
    /// @param new: 新分数
    /// @param event_type: 事件类型
    fun emit_score_event(
        user: address, old: u64, new: u64, event_type: u8
    ) acquires Events {
        if (exists<Events>(user)) {
            let events = borrow_global_mut<Events>(user);
            event::emit_event(
                &mut events.score_events,
                ScoreUpdateEvent {
                    user,
                    old_score: old,
                    new_score: new,
                    event_type,
                    timestamp: timestamp::now_seconds()
                }
            );
        }
    }

    // 视图方法 (View Functions) ----------------------------------------

    #[view]
    /// 预览做任务后的分数 (Preview Reward)
    /// 模拟“衰减 + 结算”，不改变状态
    ///
    /// @param user: 用户地址
    /// @param is_task_achieved: 假设任务是否合规
    /// @param difficulty: 任务难度
    /// @param achieved_goal_count: 达成目标次数
    /// @return: (预计分数, 分数变化量)
    public fun preview_reward(
        user: address,
        is_task_achieved: bool,
        difficulty: u64,
        achieved_goal_count: u64
    ): (u64, u64) acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return (0, 0)
        };

        let bio_soul = borrow_global<BioSoul>(user);

        // 1. 模拟衰减
        let score_after_decay =
            bio_math::calculate_decayed_score(
                bio_soul.score,
                bio_soul.last_update_time,
                timestamp::now_seconds()
            );

        // 2. 模拟结算
        let final_score =
            if (is_task_achieved) {
                // 计算能量
                let energy_gain =
                    bio_math::calculate_energy_gain(difficulty, achieved_goal_count);

                // 加分积分
                let integrated_score =
                    bio_math::integrate_energy_to_score(score_after_decay, energy_gain);
                math64::min(integrated_score, bio_math::get_credit_max())
            } else {
                // 扣分倍率
                let energy_base =
                    bio_math::calculate_energy_gain(difficulty, achieved_goal_count);

                bio_math::calculate_slashed_score(score_after_decay, energy_base)
            };

        let delta =
            if (final_score > score_after_decay) {
                final_score - score_after_decay
            } else {
                score_after_decay - final_score
            };

        (final_score, delta)
    }

    #[view]
    /// 获取用户当前的链上分数
    ///
    /// @param user: 用户地址
    /// @return u64: 用户链上分数
    public fun get_score(user: address): u64 acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return 0
        };

        borrow_global<BioSoul>(user).score
    }

    #[view]
    /// 获取用户包含“预测衰减”的实时有效分数
    /// 前端展示时应优先使用此函数，以反映实时状态
    ///
    /// @param user: 用户地址
    /// @return u64: 用户实时有效分数
    public fun get_effective_score(user: address): u64 acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return 0
        };

        let bio_soul = borrow_global<BioSoul>(user);

        // 使用公共逻辑计算
        bio_math::calculate_decayed_score(
            bio_soul.score,
            bio_soul.last_update_time,
            timestamp::now_seconds()
        )
    }

    #[view]
    /// 获取用户个人的连胜场次
    ///
    /// @param user: 用户地址
    /// @return u64: 用户连胜场次
    public fun get_personal_streak(user: address): u64 acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return 0
        };

        borrow_global<BioSoul>(user).personal_streak
    }

    // 单元测试 (Unit Tests) --------------------------------------------

    #[test_only]
    /// 为单元测试封装的 record_daily_checkin
    public fun record_daily_checkin_for_test(
        user: address,
        date_key: String,
        is_goal_achieved: bool,
        timestamp: u64,
        signature_hash: vector<u8>
    ) acquires BioSoul {
        record_daily_checkin(
            user,
            date_key,
            is_goal_achieved,
            timestamp,
            signature_hash
        )
    }

    #[test_only]
    /// 为单元测试封装的 update_score_and_streak
    public fun update_score_and_streak_for_test(
        user: address,
        is_task_achieved: bool,
        difficulty: u64,
        achieved_goal_count: u64
    ) acquires BioSoul {
        update_score_and_streak(
            user,
            is_task_achieved,
            difficulty,
            achieved_goal_count
        )
    }
}

