/// # 身份与信用模块 (Bio Credit)
///
/// 该模块是协议的用户存储层 (Storage Layer)，负责管理用户的核心信用资产。
///
/// 主要功能：
/// 1. **BioSoul SBT**：用户的灵魂绑定资产，记录信用分、连胜、设备指纹。
/// 2. **数据聚合**：SBT 作为容器，挂载了用户获得的所有勋章 (Badges)。
/// 3. **行为日志**：使用 Table 存储用户海量的每日打卡数据，支持无限扩展。
module protocol_75::bio_credit {
    use std::string::String;
    use std::vector;
    use std::signer;
    use aptos_std::table::{Self, Table};
    use aptos_framework::object::Object;

    use protocol_75::badge_factory::AchievementBadge;

    friend protocol_75::challenge_manager;

    /// 用户未注册
    const E_NOT_REGISTERED: u64 = 1;
    /// 用户已注册
    const E_ALREADY_REGISTERED: u64 = 2;

    /// 用户每日行为数据
    struct DailyData has store, drop {
        step_count: u64,
        timestamp: u64,
        signature_hash: vector<u8>
    }

    /// 用户灵魂绑定资源 (SBT)
    struct BioSoul has key {
        score: u64,
        personal_streak: u64,
        device_hash: vector<u8>,
        badges: vector<Object<AchievementBadge>>,
        activity_log: Table<String, DailyData>
    }

    /// Seq 1: 用户注册，初始化 BioSoul
    public entry fun register_user(user: &signer, device_hash: vector<u8>) {
        let user_addr = signer::address_of(user);
        assert!(!exists<BioSoul>(user_addr), E_ALREADY_REGISTERED);

        let soul = BioSoul {
            score: 50,
            personal_streak: 0,
            device_hash,
            badges: vector::empty(),
            activity_log: table::new()
        };
        move_to(user, soul);
    }

    /// Seq 3.1: 记录每日打卡 (仅限 Friend)
    public(friend) fun record_daily_activity(
        user: address,
        date_key: String,
        step_count: u64,
        timestamp: u64,
        signature_hash: vector<u8>
    ) acquires BioSoul {
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);

        let soul = borrow_global_mut<BioSoul>(user);
        let daily_data = DailyData { step_count, timestamp, signature_hash };

        if (soul.activity_log.contains(date_key)) {
            let ref = soul.activity_log.borrow_mut(date_key);
            *ref = daily_data;
        } else {
            soul.activity_log.add(date_key, daily_data);
        };
    }

    /// Seq 4.2: 更新分数与连胜 (仅限 Friend)
    public(friend) fun update_score_and_streak(
        user: address, is_compliant: bool, _difficulty: u64
    ) acquires BioSoul {
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);
        let soul = borrow_global_mut<BioSoul>(user);

        if (is_compliant) {
            soul.personal_streak += 1;
            if (soul.score < 100) {
                soul.score += 1;
            };
        } else {
            soul.personal_streak = 0;
            if (soul.score > 0) {
                soul.score -= 1;
            };
        };
    }

    /// Seq 5.2: 挂载勋章 (仅限 Friend)
    public(friend) fun attach_badge(
        user: address, badge: Object<AchievementBadge>
    ) acquires BioSoul {
        assert!(exists<BioSoul>(user), E_NOT_REGISTERED);
        
        let soul = borrow_global_mut<BioSoul>(user);
        soul.badges.push_back(badge);
    }

    #[view]
    public fun get_score(user: address): u64 acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return 0
        };
        borrow_global<BioSoul>(user).score
    }

    #[view]
    public fun get_personal_streak(user: address): u64 acquires BioSoul {
        if (!exists<BioSoul>(user)) {
            return 0
        };
        borrow_global<BioSoul>(user).personal_streak
    }

    #[test_only]
    use std::string;

    #[test(user = @0x123)]
    /// 测试 Bio Credit 流程
    fun test_bio_credit_flow(user: &signer) acquires BioSoul {
        let user_addr = signer::address_of(user);

        // 1. 注册
        register_user(user, vector::empty());
        assert!(get_score(user_addr) == 50, 0);

        // 2. 记录打卡
        let date = string::utf8(b"2023-10-01");
        record_daily_activity(user_addr, date, 5000, 10000, vector::empty());

        // 3. 更新连胜
        update_score_and_streak(user_addr, true, 10);
        assert!(get_personal_streak(user_addr) == 1, 1);
        assert!(get_score(user_addr) == 51, 2);
    }
}

