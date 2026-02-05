/// # 身份与信用模块 (Bio Credit)
///
/// 该模块是协议的用户存储层 (Storage Layer)，负责管理用户的核心信用资产。
/// 它实现了 BioSoul SBT 的逻辑，结合了“时间衰减”与“阻尼增长”的数值模型。
///
/// ## 核心机制
/// 1. **BioSoul SBT**：用户的灵魂绑定资产，记录信用分、连胜、设备指纹。
/// 2. **数值系统**：
///    - **区间**：35.000000 (Min) - 95.000000 (Max)。
///    - **精度**：6 位小数 (u64 存储，1_000_000 = 1.0)。
///    - **分水岭**：75.0 分。超过此分数进入高难度模式。
///    - **阻尼增长**：分数越高，获取积分越难 (模拟 Logistic 曲线特性)。
///    - **自然衰减**：随时间流逝自动扣分，逼迫用户持续活跃。
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

    friend protocol_75::challenge_manager;

    // 错误码 (Error Codes) --------------------------------------------

    /// 错误：用户未注册
    const E_NOT_REGISTERED: u64 = 1;
    /// 错误：用户已注册
    const E_ALREADY_REGISTERED: u64 = 2;

    // 数值常量 (Constants) ---------------------------------------------

    /// 精度因子 (6位小数)
    const SCALING_FACTOR: u64 = 1_000_000;

    /// 最低信用分 (35.0)
    const CREDIT_MIN: u64 = 35_000_000;
    /// 最高信用分 (95.0)
    const CREDIT_MAX: u64 = 95_000_000;
    /// 初始信用分 (50.0)
    const CREDIT_INIT: u64 = 50_000_000;
    /// 精英分水岭 (75.0)
    const CREDIT_ELITE: u64 = 75_000_000;

    /// 奖励基础速率 (每次成功后 1.0)
    const REWARD_BASE_RATE: u64 = 1_000_000;
    /// 衰减基础速率 (超过豁免期后 0.5)
    const DECAY_BASE_RATE: u64 = 500_000;
    /// 衰减豁免期 (48小时)
    const DECAY_GRACE_PERIOD: u64 = 172800;

    /// 奖励事件
    const EVENT_REWARD: u8 = 1;
    /// 惩罚事件
    const EVENT_SLASH: u8 = 2;
    /// 衰减事件
    const EVENT_DECAY: u8 = 3;

    // 数据结构 (Data Structures) ---------------------------------------

    /// 用户每日行为数据 (轻量级结构)
    struct DailyData has store, drop {
        /// 任务完成情况
        task_status: bool,
        /// 时间戳
        timestamp: u64,
        /// 签名哈希
        signature_hash: vector<u8>
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
        /// 每日活动日志
        activity_log: Table<String, DailyData>
    }

    // 公开接口 (Public Entries) ----------------------------------------

    /// 用户注册 (Register User)
    ///
    /// 初始化 BioSoul
    ///
    /// @param user: 签名者
    /// @param device_hash: 设备指纹哈希
    public entry fun register_user(user: &signer, device_hash: vector<u8>) {
        let user_addr = signer::address_of(user);
        // 若用户已注册，则报错
        assert!(!exists<BioSoul>(user_addr), E_ALREADY_REGISTERED);

        // 创建 BioSoul 资源
        move_to(
            user,
            BioSoul {
                score: CREDIT_INIT,
                highest_score: CREDIT_INIT,
                personal_streak: 0,
                last_update_time: timestamp::now_seconds(),
                device_hash,
                badges: vector::empty(),
                activity_log: table::new()
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

    /// 记录每日打卡 (Record Daily Activity)
    ///
    /// 本函数仅负责“记账”，不负责“算分”。
    /// 算分逻辑由 challenge_manager 在确认合规后调用 `update_score`。
    ///
    /// @param user: 用户地址
    /// @param date_key: 日期键 e.g. "2023-10-01"
    /// @param task_status: 任务状态
    /// @param timestamp: 时间戳
    /// @param signature_hash: 签名哈希
    public(friend) fun record_daily_activity(
        user: address,
        date_key: String,
        task_status: bool,
        timestamp: u64,
        signature_hash: vector<u8>
    ) acquires BioSoul {
        // 若用户未注册，则报错
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        let soul = borrow_global_mut<BioSoul>(user);
        let daily_data = DailyData { task_status, timestamp, signature_hash };

        // 若用户已打卡，则更新
        if (soul.activity_log.contains(date_key)) {
            let ref = soul.activity_log.borrow_mut(date_key);
            *ref = daily_data;
        }
        // 若用户未打卡，则添加
        else {
            soul.activity_log.add(date_key, daily_data);
        };
    }

    /// 更新分数与连胜 (Update Score and Streak)
    ///
    /// 核心数值逻辑：
    /// 1. 先结算时间衰减 (Decay)。
    /// 2. 如果合规 (Compliant)：增加阻尼分数。
    /// 3. 如果违规 (Not Compliant)：扣除固定惩罚并清零连胜。
    ///
    /// 简易的阻尼增长算法：
    /// - 公式：实际增量 = 基础分 * (1 - (当前分 - 最低分) / (最高分 - 最低分))
    /// - 解释：分数越接近 95，(1 - Ratio) 越小，增量越少。
    /// - 当分数 = 35 时，增量 = 1.0
    /// - 当分数 = 95 时，增量 = 0.0
    ///
    /// @param user: 用户地址
    /// @param is_compliant: 是否合规
    /// @param _difficulty: 预留参数，未来可根据任务难度调整权重
    public(friend) fun update_score_and_streak(
        user: address, is_compliant: bool, _difficulty: u64
    ) acquires BioSoul, Events {
        // 若用户未注册，则报错
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        // 先应用懒惰衰减
        apply_lazy_decay(user);

        let soul = borrow_global_mut<BioSoul>(user);
        let old_score = soul.score;

        // 如果合规
        if (is_compliant) {
            soul.personal_streak += 1;

            let range = CREDIT_MAX - CREDIT_MIN;
            let current_pos = soul.score - CREDIT_MIN;

            // 为了避免浮点运算，使用乘法先放大
            let dampening_factor = range - current_pos;
            let increment = (REWARD_BASE_RATE * dampening_factor) / range;

            // 确保至少有微小的增长 (0.000001)，防止彻底停滞
            if (increment == 0 && soul.score < CREDIT_MAX) {
                increment = 1;
            };

            soul.score = math64::min(soul.score + increment, CREDIT_MAX);

            // 更新最高分记录
            if (soul.score > soul.highest_score) {
                soul.highest_score = soul.score;
            };

            // 发出奖励事件
            emit_score_event(user, old_score, soul.score, EVENT_REWARD);

        }
        // 如果违规
        else {
            // 清零连胜
            soul.personal_streak = 0;

            // 扣分逻辑：固定扣除 REWARD_BASE_RATE 信用分 (TODO: 根据难度动态调整)
            if (soul.score > CREDIT_MIN + REWARD_BASE_RATE) {
                soul.score -= REWARD_BASE_RATE;
            } else {
                soul.score = CREDIT_MIN;
            };

            // 发出惩罚事件
            emit_score_event(user, old_score, soul.score, EVENT_SLASH);
        };

        // 更新时间戳
        soul.last_update_time = timestamp::now_seconds();
    }

    /// 挂载勋章 (Attach Badge)
    ///
    /// @param user: 用户地址
    /// @param badge: 勋章对象
    public(friend) fun attach_badge(
        user: address, badge: Object<AchievementBadge>
    ) acquires BioSoul {
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);
        let soul = borrow_global_mut<BioSoul>(user);
        soul.badges.push_back(badge);
    }

    // 私有方法 (Private Methods) ---------------------------------------

    /// 应用自然衰减 (Apply Lazy Decay)
    ///
    /// 逻辑：
    /// - 计算距离上次更新的时间差。
    /// - 减去豁免期 (Grace Period)。
    /// - 剩余时间按天扣除分数。
    ///
    /// @param user: 用户地址
    fun apply_lazy_decay(user: address) acquires BioSoul, Events {
        let soul = borrow_global_mut<BioSoul>(user);
        let now = timestamp::now_seconds();

        // 还没过豁免期，无需衰减
        if (now <= soul.last_update_time + DECAY_GRACE_PERIOD) { return };

        let decay_duration = (now - soul.last_update_time) - DECAY_GRACE_PERIOD;
        let days_passed = decay_duration / 86400; // 86400s = 1 day

        // 已经过了豁免期
        if (days_passed > 0) {
            let total_decay = days_passed * DECAY_BASE_RATE;
            let old_score = soul.score;

            // 扣分逻辑：固定扣除 total_decay 分 (TODO: 根据阻尼动态调整)
            if (soul.score > CREDIT_MIN + total_decay) {
                soul.score -= total_decay;
            } else {
                soul.score = CREDIT_MIN;
            };

            // 如果发生了分数变化，发出衰减事件
            if (soul.score != old_score) {
                emit_score_event(user, old_score, soul.score, EVENT_DECAY);
            };

            // 注意：此处不更新 last_update_time
            // 把它留给后续的 update_score_and_streak 统一更新到 now
        }
    }

    /// 发出分数变化事件
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

    // 视图函数 (View Functions) ----------------------------------------

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
        let soul = borrow_global<BioSoul>(user);

        let now = timestamp::now_seconds();
        if (now <= soul.last_update_time + DECAY_GRACE_PERIOD) {
            return soul.score
        };

        let decay_duration = (now - soul.last_update_time) - DECAY_GRACE_PERIOD;
        let days = decay_duration / 86400;
        let decay = days * DECAY_BASE_RATE;

        if (soul.score > CREDIT_MIN + decay) {
            soul.score - decay
        } else {
            CREDIT_MIN
        }
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
}

