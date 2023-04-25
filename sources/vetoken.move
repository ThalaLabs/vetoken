module vetoken::vetoken {
    use std::signer;

    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    use fixed_point64::fixed_point64::{Self, FixedPoint64};

    ///
    /// Errors
    ///

    // Initialization
    const ERR_VETOKEN_INITIALIZED: u64 = 0;
    const ERR_VETOKEN_UNINITIALIZED: u64 = 1;

    // VeToken Errors
    const ERR_VETOKEN_LOCKED: u64 = 2;
    const ERR_VETOKEN_NOT_LOCKED: u64 = 3;
    const ERR_VETOKEN_ZERO_LOCK_AMOUNT: u64 = 4;
    const ERR_VETOKEN_INVALID_LOCK_DURATION: u64 = 5;
    const ERR_VETOKEN_INVALID_END_WEEK: u64 = 6;

    // Other
    const ERR_VETOKEN_ACCOUNT_UNREGISTERED: u64 = 100;
    const ERR_VETOKEN_COIN_ADDRESS_MISMATCH: u64 = 101;

    ///
    /// Constants
    ///

    const SECONDS_IN_WEEK: u64 = 7 * 24 * 60 * 60;

    struct VeToken<phantom CoinType> has store {
        locked: Coin<CoinType>,
        locked_end_week: u64,
    }

    /// Holder of VeToken
    struct VeTokenStore<phantom CoinType> has key {
        vetoken: VeToken<CoinType>
    }

    /// Keep track of global info about VeToken
    struct VeTokenInfo<phantom CoinType> has key {
        max_locked_weeks: u64,

        // Stores the total unlockable amounts in vetoken where the key i represents
        // the amount of vetokens that will be unlockable in week i
        total_unlockable: Table<u64, u128>,
    }

    public entry fun initialize<CoinType>(account: &signer, max_locked_weeks: u64) {
        assert!(!initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);
        assert!(account_address<VeToken<CoinType>>() == signer::address_of(account), ERR_VETOKEN_COIN_ADDRESS_MISMATCH);
        assert!(max_locked_weeks > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        move_to(account, VeTokenInfo<CoinType> {
            max_locked_weeks,
            total_unlockable: table::new()
        });
    }

    public entry fun register<CoinType>(account: &signer) {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        move_to(account, VeTokenStore<CoinType> {
            vetoken: VeToken<CoinType> {
                locked: coin::zero(),
                locked_end_week: 0,
            }
        });
    }

    /// Lock `CoinType` up until `end_week`. Time is referenced in terms of the week number in order to keep an accurate
    /// total supply of `VeToken` on a week-by-week basis. This implies that locked tokens are only eligible to be unlocked
    /// at the start of a new week's period (starting from the Unix epoch).
    public fun lock<CoinType>(account: &signer, coin: Coin<CoinType>, end_week: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let amount = coin::value(&coin);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_week = now_weeks();
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(end_week > now_week && end_week - now_week <= vetoken_info.max_locked_weeks, ERR_VETOKEN_INVALID_END_WEEK);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) == 0, ERR_VETOKEN_LOCKED);

        // Update the total locked amount in the week prior to unlock.
        let unlockable = table::borrow_mut_with_default(&mut vetoken_info.total_unlockable, end_week, 0);
        *unlockable = *unlockable + (amount as u128);

        // Update the VeToken
        vetoken_store.vetoken.locked_end_week = end_week;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
    }

    /// Extend the period in which the `VeToken` remains locked
    public fun increase_lock_duration<CoinType>(account: &signer, increment_weeks: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(increment_weeks >= 1, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());

        let now_week = now_weeks();
        let new_end_week = vetoken_store.vetoken.locked_end_week + increment_weeks;
        assert!(now_week < vetoken_store.vetoken.locked_end_week, ERR_VETOKEN_NOT_LOCKED);
        assert!(new_end_week - now_week <= vetoken_info.max_locked_weeks, ERR_VETOKEN_INVALID_LOCK_DURATION);

        // Update the total locked amounts
        // locked_amounts[current_end_week] -= vetoken.locked
        // locked_amounts[new_end_week] += vetoken.locked
        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);
        let total_unlockable = &mut vetoken_info.total_unlockable;
        let current_total_unlockable = table::borrow_mut(total_unlockable, vetoken_store.vetoken.locked_end_week);
        *current_total_unlockable = *current_total_unlockable - locked_amount;

        let new_total_unlockable = table::borrow_mut_with_default(total_unlockable, new_end_week, 0);
        *new_total_unlockable = *new_total_unlockable + locked_amount;

        // Update the VeToken
        vetoken_store.vetoken.locked_end_week = new_end_week;
    }

    /// Extend how much `CoinType` is locked within `VeToken`.
    public fun increase_lock_amount<CoinType>(account: &signer, coin: Coin<CoinType>) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_weeks = now_weeks();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_weeks < vetoken_store.vetoken.locked_end_week, ERR_VETOKEN_NOT_LOCKED);

        // Update the total unlockable in the week ready for unlock.
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        let unlockable = table::borrow_mut(&mut vetoken_info.total_unlockable, vetoken_store.vetoken.locked_end_week);
        *unlockable = *unlockable + amount;

        // Update the VeToken
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
    }

    /// Unlock a `VeToken` that reached `end_week`.
    public fun unlock<CoinType>(account: &signer): Coin<CoinType> acquires VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) > 0, ERR_VETOKEN_NOT_LOCKED);

        let now_week = now_weeks();
        assert!(now_week >= vetoken_store.vetoken.locked_end_week, ERR_VETOKEN_LOCKED);

        // Update the VeToken
        vetoken_store.vetoken.locked_end_week = 0;
        coin::extract_all(&mut vetoken_store.vetoken.locked)
    }

    /// Compute the weight of `account_addr` relative to the amount of `CoinType` locked.
    public fun weight<CoinType>(account_addr: address): FixedPoint64 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());

        // We explicity return zero to avoid the edge case where `total_strength == 0` which would cause
        // a div by zero error. This would occur on initiailzation where no tokens have been locked yet
        // or the entire locked supply has expired
        let balance = unnormalized_balance(&vetoken_store.vetoken);
        if (balance == 0) return fixed_point64::zero();

        // We dont use `fixed_point64::fraction` since `total_supply` is a u128. Casting this to a u64
        // can cause an arithmetic error -- hece we construct the fraction manually
        let total_supply = unnormalized_total_supply(vetoken_info);
        fixed_point64::from_u128((balance << 64) / total_supply)
    }

    // Public Getters

    #[view]
    public fun initialized<CoinType>(): bool {
        exists<VeTokenInfo<CoinType>>(account_address<VeToken<CoinType>>())
    }

    #[view]
    public fun is_account_registered<CoinType>(account_addr: address): bool {
        exists<VeTokenStore<CoinType>>(account_addr)
    }

    #[view]
    public fun balance<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());

        let balance = unnormalized_balance(&vetoken_store.vetoken) / (vetoken_info.max_locked_weeks as u128);
        (balance as u64)
    }

    #[view]
    public fun total_supply<CoinType>(): u128 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        unnormalized_total_supply(vetoken_info) / (vetoken_info.max_locked_weeks as u128)
    }

    fun unnormalized_balance<CoinType>(vetoken: &VeToken<CoinType>): u128 {
        let now_week = now_weeks();
        if (now_week >= vetoken.locked_end_week) return 0;

        // we do not divide by the the max lock duration because it will be eliminated when
        // dividing by unnormalized_total_supply for computing the weight
        (coin::value(&vetoken.locked) * (vetoken.locked_end_week - now_week) as u128)
    }

    fun unnormalized_total_supply<CoinType>(vetoken_info: &VeTokenInfo<CoinType>): u128 {
        let now_week = now_weeks();

        let end_in_weeks = 1;
        let supply = 0u128;
        while (end_in_weeks <= vetoken_info.max_locked_weeks) {
            // we do not divide by the the max lock duration because it will be eliminated when
            // dividing by unnormalized_total_supply in computing the weight
            let locked_amount = *table::borrow_with_default(&vetoken_info.total_unlockable, now_week + end_in_weeks, &0);
            supply = supply + (locked_amount * (end_in_weeks as u128));

            end_in_weeks = end_in_weeks + 1;
        };

        supply
    }

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    fun now_weeks(): u64 {
        timestamp::now_seconds() / SECONDS_IN_WEEK
    }

    #[test_only]
    use std::string;

    #[test_only]
    use vetoken::coin_helper;

    #[test_only]
    struct FakeCoin {}

    #[test_only]
    fun fp_to_percent(fp: FixedPoint64): u64 {
        fixed_point64::decode(fixed_point64::mul(fp, 100))
    }

    #[test(account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_COIN_ADDRESS_MISMATCH)]
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
    fun lock_unlock_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // unlock
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        let unlocked = unlock<FakeCoin>(account);
        assert!(coin::value(&unlocked) == 1000, 0);

        // cleanup
        coin_helper::burn_coin_for_test(vetoken, unlocked);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_LOCKED)]
    fun early_unlock_err(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // early unlock: try to unlock in 6 days, even though the lock period is 1 week (7 days)
        timestamp::fast_forward_seconds(6 * 86400);
        coin_helper::burn_coin_for_test(vetoken, unlock<FakeCoin>(account));
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun increase_lock_duration_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 5);

        // lock
        register<FakeCoin>(account);
        lock(account, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 2000 / 5, 0);

        // extend 2 weeks
        increase_lock_duration<FakeCoin>(account, 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);

        // 3 weeks later, extend 3 more weeks
        timestamp::fast_forward_seconds(3 * SECONDS_IN_WEEK);
        increase_lock_duration<FakeCoin>(account, 3);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun increase_lock_amount_ok(
        aptos_framework: &signer,
        vetoken: &signer,
        account: &signer
    ) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 5);

        // lock
        register<FakeCoin>(account);
        lock(account, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 2000 / 5, 0);

        // increase lock amount
        increase_lock_amount<FakeCoin>(account, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);

        // 1 weeks later, further increase lock amount
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        increase_lock_amount<FakeCoin>(account, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(account)) == 3000 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB, u3 = @0xC, u4 = @0xD)]
    fun balance_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer, u3: &signer, u4: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 3);

        // no locks
        assert!(total_supply<FakeCoin>() == 0, 0);

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
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 1000, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 666, 0);
        assert!(total_supply<FakeCoin>() == 2666, 0);

        // 1 week later
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // 2 weeks later
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 333, 0);

        // 3 weeks later
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB)]
    fun weight_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 3);

        // lock
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);
        lock(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 1);
        lock(u2, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 666, 0);
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // no change
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u1))) == 33, 0);
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u2))) == 67, 0);

        // 1 week later
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u1))) == 0, 0); // expired
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u2))) == 100, 0);

        // 2 weeks later
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u1))) == 0, 0);
        assert!(fp_to_percent(weight<FakeCoin>(signer::address_of(u2))) == 0, 0);
    }
}
