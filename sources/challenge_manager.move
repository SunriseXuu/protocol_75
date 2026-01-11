/// # 挑战大管家 (Challenge Manager)
///
/// 协议的业务逻辑核心层 (Controller Layer)。
/// 负责协调任务市场、资产托管、信用记录和勋章工厂。
module protocol_75::challenge_manager {
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use aptos_std::table::{Self, Table};
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;

    use protocol_75::task_market;
    use protocol_75::bio_credit;
    use protocol_75::asset_manager;
    use protocol_75::badge_factory;

    /// 非管理员权限
    const E_NOT_ADMIN: u64 = 1;
    /// 签名验证失败
    const E_INVALID_SIGNATURE: u64 = 2;
    /// 数组长度不匹配
    const E_LENGTH_MISMATCH: u64 = 3;

    /// 小队统计数据
    struct SquadStats has store, drop {
        squad_streak: u64,
        total_challenges: u64,
        total_wins: u64,
        last_active_timestamp: u64
    }

    /// 全局小队注册表 (单例资源)
    struct SquadRegistry has key {
        records: Table<vector<u8>, SquadStats>
    }

    /// 模块初始化：自动创建 Registry
    fun init_module(account: &signer) {
        move_to(account, SquadRegistry { records: table::new() });
    }

    /// Seq 2: 创建挑战
    /// user: 发起人
    /// task_ids: 任务 ID 列表
    /// task_params: 任务参数列表
    /// stake_amount: 质押金额
    /// team_hash: 小队哈希
    public entry fun create_challenge(
        user: &signer,
        task_ids: vector<u8>,
        task_params: vector<u64>,
        team_hash: vector<u8>,
        stake_amount: u64
    ) {
        // 构造 TaskCombo
        // 使用 helper 避免直接引用私有 Struct TaskType (如果未导入)
        let tasks = vector::empty();
        let len = task_ids.length();
        let i = 0;
        while (i < len) {
            let id = task_ids[i];
            let task = task_market::create_task(id, task_params[i]);
            tasks.push_back(task);
            i += 1;
        };
        task_market::create_task_combo(tasks);

        // 1. 提取资金 (从用户钱包取钱)
        // 真实场景：需要先 coin::withdraw 出来
        // 注意：Aptos 中 entry 函数不能直接传 Coin 对象，所以得在这里 withdraw
        let coins = coin::withdraw<AptosCoin>(user, stake_amount);

        // 2. 存入资产管理器 (调用 asset_manager)
        // 假设锁定 7 天 (604800秒)
        asset_manager::deposit_and_stake(user, coins, team_hash, 604800);
    }

    /// Seq 3: 每日打卡
    /// steps: 今日步数
    /// oracle_sig: 预言机签名 (模拟验证)
    public entry fun submit_daily_checkin(
        user: &signer, steps: u64, oracle_sig: vector<u8>
    ) {
        // 1. 验证签名 (Mock: 假设非空即通过)
        assert!(!oracle_sig.is_empty(), E_INVALID_SIGNATURE);

        // 2. 生成日期 Key (从区块时间推导)
        // 简单做法：将 timestamp / 86400 转为字符串 "19650" (天数索引)
        let day_idx = timestamp::now_seconds() / 86400;
        let date_key = u64_to_string(day_idx);

        // 3. 记录数据 (调用 bio_credit)
        let user_addr = signer::address_of(user);
        bio_credit::record_daily_activity(
            user_addr,
            date_key,
            steps,
            timestamp::now_seconds(),
            oracle_sig
        );
    }

    /// Seq 4: 结算挑战 (由 Admin 调用)
    /// users: 队员列表
    /// results: 对应的结果 (true=达标, false=违约)
    public entry fun settle_challenge(
        admin: &signer, users: vector<address>, results: vector<bool>
    ) {
        // 验证 Admin 权限 (这里假设部署者即 Admin)
        assert!(signer::address_of(admin) == @protocol_75, E_NOT_ADMIN);

        let len = users.length();
        assert!(len == results.length(), E_LENGTH_MISMATCH);

        let i = 0;
        while (i < len) {
            let user_addr = users[i];
            let is_success = results[i];

            // 1. 资金清算 (调用 asset_manager)
            // 简化逻辑：成功=0(退款), 失败=1(罚没)
            // 注意：liquidate 返回的是 Coin，我们需要存回用户或国库
            // 这里为了简化演示，假设全部退回或销毁，不处理复杂的受益人分账
            let liquidation_type = if (is_success) { 0 }
            else { 1 };

            // 只有当用户真的有资产锁仓时才清算
            // 真实生产环境需要更严谨的检查，防止 abort
            let returned_coin =
                asset_manager::liquidate_position(
                    user_addr, liquidation_type, vector::empty()
                );

            // 将钱还给用户 (如果 coin 不为 0)
            if (coin::value(&returned_coin) > 0) {
                coin::deposit(user_addr, returned_coin);
            } else {
                coin::destroy_zero(returned_coin);
            };

            // 2. 信用分更新 (调用 bio_credit)
            bio_credit::update_score_and_streak(user_addr, is_success, 10);

            // 3. 尝试发奖 (如果连胜 > 3)
            let current_streak = bio_credit::get_personal_streak(user_addr);
            if (current_streak > 3) {
                // 调用 badge_factory 铸造勋章
                // 这里的 creator 用 admin 代替
                let badge = badge_factory::mint_system_badge(admin, user_addr, 1);
                // 挂载到 SBT
                bio_credit::attach_badge(user_addr, badge);
            };

            i += 1;
        }
    }

    /// 简单的 u64 转 String 辅助函数
    fun u64_to_string(value: u64): String {
        if (value == 0) {
            return string::utf8(b"0")
        };

        let buffer = vector::empty<u8>();
        while (value != 0) {
            buffer.push_back(((48 + value % 10) as u8));
            value /= 10;
        };
        buffer.reverse();

        string::utf8(buffer)
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test(admin = @protocol_75, user = @0x123, framework = @0x1)]
    /// 测试完整流程
    fun test_full_flow(
        admin: &signer, user: &signer, framework: &signer
    ) {
        // 1. 初始化环境
        timestamp::set_time_has_started_for_testing(framework);
        let (burn, mint) = aptos_coin::initialize_for_test(framework);

        // 2. 初始化合约 (模拟部署)
        init_module(admin);
        task_market::init_module_for_test(admin); // Initialize task_market for tests

        // 3. 准备用户
        let user_addr = signer::address_of(user);
        account::create_account_for_test(user_addr);
        coin::register<AptosCoin>(user);
        let coins = coin::mint<AptosCoin>(1000, &mint);
        coin::deposit(user_addr, coins);

        // 4. 用户注册 SBT
        bio_credit::register_user(user, vector::empty());

        // 5. 创建挑战 (质押 100)
        // 使用非空列表以通过验证 (id=1 跑步, param=100米)
        let task_ids = vector::singleton<u8>(1);
        let task_params = vector::singleton<u64>(300);
        create_challenge(
            user,
            task_ids,
            task_params,
            vector::empty(),
            100
        );

        // 6. 每日打卡
        submit_daily_checkin(user, 5000, b"sig");

        // 7. 结算 (User 成功)
        let users = vector::singleton(user_addr);
        let results = vector::singleton(true);
        settle_challenge(admin, users, results);

        // 8. 验证
        // 钱应该退回来了 (1000 - 100 + 100 = 1000)
        assert!(coin::balance<AptosCoin>(user_addr) == 1000, 0);
        // 分数应该增加
        assert!(bio_credit::get_score(user_addr) == 51, 1);

        // 清理
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }
}

