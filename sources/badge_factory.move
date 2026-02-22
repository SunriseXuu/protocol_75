/// # 勋章工厂模块 (Badge Factory)
///
/// 该模块负责协议内所有 NFT 勋章的定义与铸造，包括：
/// 1. **资产定义**：基于 Object 模型的 `AchievementBadge` 核心资产。
/// 2. **勋章铸造**：支持“系统勋章”（如连胜、贡献者）与“商业勋章”的定向铸造。
/// 3. **权限控制**：通过 Friend 机制授权 `challenge_manager` 进行调用。
///
/// 主要用于为完成特定挑战或任务的用户颁发链上荣誉证明。
module protocol_75::badge_factory {
    use std::string::{Self, String};
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;

    // 授权 challenge_manager 调用铸造函数
    friend protocol_75::challenge_manager;

    // 核心勋章资产 (NFT)
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct AchievementBadge has key {
        name: String,
        badge_type: u8, // 1=系统勋章, 2=商业勋章
        metadata_uri: String,
        issuer: address,
        timestamp: u64
    }

    /// 铸造系统勋章 (仅限 Friend 调用)
    public(friend) fun mint_system_badge(
        creator: &signer, recipient_addr: address, badge_type: u8
    ): Object<AchievementBadge> {
        // 构造元数据
        let name =
            if (badge_type == 1) {
                string::utf8(b"Protocol75 Streak Master")
            } else {
                string::utf8(b"Protocol75 Contributor")
            };

        let metadata_uri =
            string::utf8(
                b"https://api.protocol75.com/badges/system_v1.json"
            );

        // 创建独立对象
        let constructor_ref = object::create_object_from_account(creator);
        let object_signer = constructor_ref.generate_signer();

        // 构造资源并移入对象
        let badge = AchievementBadge {
            name,
            badge_type,
            metadata_uri,
            issuer: signer::address_of(creator),
            timestamp: timestamp::now_seconds()
        };
        move_to(&object_signer, badge);

        // 转移对象所有权给接收者
        let object_addr = constructor_ref.address_from_constructor_ref();
        if (object_addr != recipient_addr) {
            let badge_obj = object::address_to_object<AchievementBadge>(object_addr);
            object::transfer(creator, badge_obj, recipient_addr);
        };

        object::address_to_object<AchievementBadge>(object_addr)
    }

    /// 铸造商业勋章 (仅限 Friend 调用)
    public(friend) fun mint_commercial_badge(
        creator: &signer,
        recipient_addr: address,
        brand_name: String,
        metadata_uri: String
    ): Object<AchievementBadge> {
        let constructor_ref = object::create_object_from_account(creator);
        let object_signer = constructor_ref.generate_signer();

        let badge = AchievementBadge {
            name: brand_name,
            badge_type: 2,
            metadata_uri,
            issuer: signer::address_of(creator),
            timestamp: timestamp::now_seconds()
        };
        move_to(&object_signer, badge);

        let object_addr = constructor_ref.address_from_constructor_ref();
        let badge_obj = object::address_to_object<AchievementBadge>(object_addr);
        object::transfer(creator, badge_obj, recipient_addr);

        object::address_to_object<AchievementBadge>(object_addr)
    }

    #[view]
    /// 视图函数：获取勋章信息
    public fun get_badge_info(
        badge_obj: Object<AchievementBadge>
    ): (String, u8, u64) acquires AchievementBadge {
        let badge_addr = badge_obj.object_address();
        let badge = borrow_global<AchievementBadge>(badge_addr);
        (badge.name, badge.badge_type, badge.timestamp)
    }

    #[test_only]
    use aptos_framework::account;

    #[test(user = @0x123)]
    /// 测试铸造系统勋章
    fun test_mint_badge(user: &signer) acquires AchievementBadge {
        // 初始化时间环境
        let framework_signer = account::create_signer_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&framework_signer);

        let user_addr = signer::address_of(user);

        // 模拟铸造
        let badge_obj = mint_system_badge(user, user_addr, 1);

        // 验证数据
        let (name, badge_type, _) = get_badge_info(badge_obj);
        assert!(name == string::utf8(b"Protocol75 Streak Master"), 0);
        assert!(badge_type == 1, 1);

        // 验证所有权
        assert!(badge_obj.owner() == user_addr, 2);
    }
}

