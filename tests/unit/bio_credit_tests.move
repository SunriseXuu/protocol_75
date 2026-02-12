#[test_only]
module protocol_75::bio_credit_tests {
    use std::signer;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use protocol_75::bio_credit;
    use protocol_75::bio_math;

    #[test(user = @0x123)]
    fun test_register_success(user: &signer) {
        setup_test(user);
        let device_hash = b"device_fingerprint";
        bio_credit::register_user(user, device_hash);

        let user_addr = signer::address_of(user);
        assert!(bio_credit::get_score(user_addr) == bio_math::get_credit_init(), 1);
        assert!(bio_credit::get_personal_streak(user_addr) == 0, 2);
    }

    #[test(user = @0x123)]
    #[expected_failure(abort_code = bio_credit::E_ALREADY_REGISTERED)]
    fun test_register_twice(user: &signer) {
        setup_test(user);
        let device_hash = b"device_fingerprint";
        bio_credit::register_user(user, device_hash);
        bio_credit::register_user(user, device_hash);
    }

    #[test(user = @0x123)]
    fun test_score_reward(user: &signer) {
        setup_test(user);
        bio_credit::register_user(user, b"device");
        let user_addr = signer::address_of(user);
        let initial_score = bio_math::get_credit_init();

        // Simulate task: Difficulty 500, Count 1
        bio_credit::update_score_and_streak_for_test(user_addr, true, 500, 1);

        let new_score = bio_credit::get_score(user_addr);
        assert!(new_score > initial_score, 1);
        assert!(bio_credit::get_personal_streak(user_addr) == 1, 2);
    }

    #[test(user = @0x123)]
    fun test_score_slash(user: &signer) {
        setup_test(user);
        bio_credit::register_user(user, b"device");
        let user_addr = signer::address_of(user);
        let initial_score = bio_math::get_credit_init();

        // Simulate failure
        bio_credit::update_score_and_streak_for_test(user_addr, false, 500, 1);

        let new_score = bio_credit::get_score(user_addr);
        assert!(new_score < initial_score, 1);
        assert!(bio_credit::get_personal_streak(user_addr) == 0, 2);
    }

    #[test(user = @0x123)]
    fun test_daily_checkin(user: &signer) {
        setup_test(user);
        bio_credit::register_user(user, b"device");
        let user_addr = signer::address_of(user);

        let date = string::utf8(b"2026-02-13");
        bio_credit::record_daily_checkin_for_test(
            user_addr,
            date,
            true,
            timestamp::now_seconds(),
            b"sig"
        );
    }

    fun setup_test(user: &signer) {
        let addr = signer::address_of(user);
        if (!account::exists_at(addr)) {
            account::create_account_for_test(addr);
        };
        // Timestamp needs @0x1
        let framework = account::create_signer_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&framework);
    }

    fun advance_time(seconds: u64) {
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + seconds);
    }
}

