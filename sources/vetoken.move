module vetoken::vetoken {
    use std::signer;
    use std::vector;

    use aptos_std::math64;
    use aptos_std::type_info;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    #[test_only]
    use std::string;
    #[test_only]
    use vetoken::coin_helper;

    const ERR_VETOKEN_INFO_ADDRESS_MISMATCH: u64 = 0;
    const ERR_VETOKEN_NOT_ENDED: u64 = 1;
    const ERR_VETOKEN_DURATION_WEEKS_ZERO: u64 = 2;
    const ERR_VETOKEN_UNREGISTERED: u64 = 3;
    const ERR_VETOKEN_UNINITIALIZED: u64 = 4;
    const ERR_VETOKEN_MAX_DURATION_WEEKS_ZERO: u64 = 5;

    struct VeToken<phantom CoinType> has store {
        locked: Coin<CoinType>,
        start_weeks: u64,
        end_weeks: u64,
    }

    /// Holder of VeToken
    struct VeTokenStore<phantom CoinType> has key {
        vetoken: VeToken<CoinType>
    }

    /// Keep track of global info about VeToken
    struct VeTokenInfo<phantom CoinType> has key {
        max_duration_weeks: u64,

        /// Stores locked amounts in vetoken
        /// assertion: vector length = max_duration_weeks
        /// i-th element = summed locked amount that is expired in (i + 1) weeks
        /// for example, if locked_amounts[10] = 1000, it means 1000 coins will be locked for 11 more weeks
        locked_amounts: vector<u64>,

        /// number of weeks since epoch as of the latest checkpoint
        last_checkpoint_weeks: u64,
    }

    public entry fun initialize<CoinType>(account: &signer, max_duration_weeks: u64) {
        assert!(
            account_address<VeToken<CoinType>>() == signer::address_of(account),
            ERR_VETOKEN_INFO_ADDRESS_MISMATCH,
        );
        assert!(max_duration_weeks > 0, ERR_VETOKEN_MAX_DURATION_WEEKS_ZERO);

        let vetoken_info = VeTokenInfo<CoinType> {
            max_duration_weeks,
            locked_amounts: new_vector_filled(max_duration_weeks, 0),
            last_checkpoint_weeks: 0
        };
        move_to(account, vetoken_info);
    }

    public fun register<CoinType>(account: &signer) {
        let vetoken_store = VeTokenStore<CoinType> {
            vetoken: VeToken<CoinType> {
                locked: coin::zero(),
                start_weeks: 0,
                end_weeks: 0,
            }
        };
        move_to(account, vetoken_store)
    }

    public fun lock<CoinType>(
        account: &signer,
        lock_coin: Coin<CoinType>,
        duration_weeks: u64
    ) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_UNREGISTERED);
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(duration_weeks >= 1, ERR_VETOKEN_DURATION_WEEKS_ZERO);

        checkpoint<CoinType>();

        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<VeToken<CoinType>>());
        let locked_amount = vector::borrow_mut(&mut vetoken_info.locked_amounts, duration_weeks - 1);
        *locked_amount = *locked_amount + coin::value(&lock_coin);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        let vetoken = &mut vetoken_store.vetoken;
        let start_weeks = now_weeks();
        coin::merge(&mut vetoken.locked, lock_coin);
        vetoken.start_weeks = start_weeks;
        vetoken.end_weeks = start_weeks + duration_weeks;
    }

    public fun unlock<CoinType>(account: &signer): Coin<CoinType> acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(signer::address_of(account)), ERR_VETOKEN_UNREGISTERED);
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        checkpoint<CoinType>();

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(signer::address_of(account));
        let vetoken = &mut vetoken_store.vetoken;

        assert!(now_weeks() >= vetoken.end_weeks, ERR_VETOKEN_NOT_ENDED);

        vetoken.start_weeks = 0;
        vetoken.end_weeks = 0;
        coin::extract_all(&mut vetoken.locked)
    }

    public fun strength<CoinType>(owner: address): u128 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(owner), ERR_VETOKEN_UNREGISTERED);
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        checkpoint<CoinType>();

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(owner);
        let now_weeks = now_weeks();
        if (now_weeks >= vetoken_store.vetoken.end_weeks) return 0;

        // no need to divide by max_duration_weeks because it will be eliminated when divided by total_strength anyways
        (coin::value(&vetoken_store.vetoken.locked) * (vetoken_store.vetoken.end_weeks - now_weeks()) as u128)
    }

    public fun total_strength<CoinType>(): u128 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<VeToken<CoinType>>());
        let supply = 0u128;
        let i = 0;
        while (i < vector::length(&vetoken_info.locked_amounts)) {
            let locked_amount = *vector::borrow(&vetoken_info.locked_amounts, i);
            supply = supply + (locked_amount * (i + 1) as u128);
            i = i + 1;
        };
        supply
    }

    public fun initialized<CoinType>(): bool {
        exists<VeTokenInfo<CoinType>>(account_address<VeToken<CoinType>>())
    }

    public fun is_account_registered<CoinType>(account_addr: address): bool {
        exists<VeTokenStore<CoinType>>(account_addr)
    }

    /// Checkpoint ensures that VeTokenInfo::locked_amounts is up-to-date
    /// If last checkpoint is in this week, no need to change locked_amounts
    /// If last checkpoint is older than max_duration_weeks, then locked_amounts should be set all zeros
    /// Otherwise, should left-shift locked_amounts by weeks_past, then fill the tailing spots with zeros
    /// For example, let's say the last checkpoint was 2 weeks ago, and given max_duration_weeks = 4, and
    /// locked_amounts = [1000, 500, 2000, 1500]. Since 2 weeks has past since last checkpoint,
    /// the first 2 elements in locked_amounts are out-dated and should be evicted, therefore the latest
    /// locked_amounts = [2000, 1500, 0, 0].
    fun checkpoint<CoinType>() acquires VeTokenInfo {
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<VeToken<CoinType>>());
        let now_weeks = now_weeks();

        let weeks_past = now_weeks - vetoken_info.last_checkpoint_weeks;
        if (weeks_past == 0) return;
        vetoken_info.last_checkpoint_weeks = now_weeks;
        left_shift(&mut vetoken_info.locked_amounts, math64::min(vetoken_info.max_duration_weeks, weeks_past));
    }

    ///
    /// Helpers
    ///

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    fun now_weeks(): u64 {
        timestamp::now_seconds() / (7 * 24 * 60 * 60)
    }

    fun new_vector_filled(n: u64, e: u64): vector<u64> {
        let v = vector::empty<u64>();

        let i = 0;
        while (i < n) {
            vector::push_back(&mut v, e);
            i = i + 1;
        };

        v
    }

    /// In-place left shift a vector for `s` positions and fill the tailing blanks with zeros
    fun left_shift(v: &mut vector<u64>, s: u64) {
        let n = vector::length(v);
        let i = 0;
        while (i < n) {
            if (i < n - s) {
                vector::swap(v, i, i + s)
            } else {
                *vector::borrow_mut(v, i) = 0;
            };
            i = i + 1;
        };
    }

    // Utility tests

    #[test]
    fun new_vector_filled_ok() {
        assert!(new_vector_filled(5, 0) == vector[0, 0, 0, 0, 0], 0);
        assert!(new_vector_filled(5, 1) == vector[1, 1, 1, 1, 1], 0);
    }

    #[test]
    fun left_shift_ok() {
        let v = vector<u64>[1, 2, 3, 4, 5, 6];
        assert!(left_shift_result(v, 0) == vector<u64>[1, 2, 3, 4, 5, 6], 0);
        assert!(left_shift_result(v, 1) == vector<u64>[2, 3, 4, 5, 6, 0], 0);
        assert!(left_shift_result(v, 2) == vector<u64>[3, 4, 5, 6, 0, 0], 0);
        assert!(left_shift_result(v, 3) == vector<u64>[4, 5, 6, 0, 0, 0], 0);
        assert!(left_shift_result(v, 4) == vector<u64>[5, 6, 0, 0, 0, 0], 0);
        assert!(left_shift_result(v, 5) == vector<u64>[6, 0, 0, 0, 0, 0], 0);
        assert!(left_shift_result(v, 6) == vector<u64>[0, 0, 0, 0, 0, 0], 0);
    }

    #[test_only]
    fun left_shift_result(v: vector<u64>, s: u64): vector<u64> {
        left_shift(&mut v, s);
        v
    }

    // public api tests

    #[test_only]
    struct FakeCoin {}

    #[test(account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_INFO_ADDRESS_MISMATCH)]
    fun non_vetoken_initialize_err(account: &signer) {
        initialize<FakeCoin>(account, 52);
    }

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, max_duration_weeks: u64) {
        initialize<FakeCoin>(vetoken, max_duration_weeks);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        coin_helper::create_coin_for_test<FakeCoin>(
            vetoken,
            string::utf8(b"Fake Coin"),
            string::utf8(b"FAKE"),
            8,
            true
        );
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun lock_unlock_ok(
        aptos_framework: &signer,
        vetoken: &signer,
        account: &signer
    ) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // unlock
        timestamp::fast_forward_seconds(7 * 24 * 60 * 60);
        let unlocked = unlock<FakeCoin>(account);
        assert!(coin::value(&unlocked) == 1000, 0);

        // cleanup
        coin_helper::burn_coin_for_test(vetoken, unlocked);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_NOT_ENDED)]
    fun early_unlock_err(
        aptos_framework: &signer,
        vetoken: &signer,
        account: &signer
    ) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // early unlock: try to unlock in 6 days, even though the lock period is 1 week (7 days)
        timestamp::fast_forward_seconds(6 * 24 * 60 * 60);
        coin_helper::burn_coin_for_test(vetoken, unlock<FakeCoin>(account));
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB, u3 = @0xC, u4 = @0xD)]
    fun strength_ok(
        aptos_framework: &signer,
        vetoken: &signer,
        u1: &signer,
        u2: &signer,
        u3: &signer,
        u4: &signer
    ) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 3);

        // lock
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);
        register<FakeCoin>(u3);
        register<FakeCoin>(u4);
        lock(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 1);
        lock(u2, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        lock(u3, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 3);
        lock(u4, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 2000), 1);

        // at the beginning
        assert!(strength<FakeCoin>(signer::address_of(u1)) == 1000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u2)) == 2000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u3)) == 3000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u4)) == 2000, 0);
        assert!(total_strength<FakeCoin>() == 8000, 0);

        // 1 week later
        timestamp::fast_forward_seconds(7 * 24 * 60 * 60);
        assert!(strength<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u2)) == 1000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u3)) == 2000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_strength<FakeCoin>() == 3000, 0);

        // 2 weeks later
        timestamp::fast_forward_seconds(7 * 24 * 60 * 60);
        assert!(strength<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u3)) == 1000, 0);
        assert!(strength<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_strength<FakeCoin>() == 1000, 0);

        // 3 weeks later
        timestamp::fast_forward_seconds(7 * 24 * 60 * 60);
        assert!(strength<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u3)) == 0, 0);
        assert!(strength<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_strength<FakeCoin>() == 0, 0);
    }
}
