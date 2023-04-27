module vetoken::vetoken {
    use std::signer;
    use std::vector;

    use aptos_std::math64;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

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
    const ERR_VETOKEN_INVALID_PAST_WEEK: u64 = 7;

    // Other
    const ERR_VETOKEN_ACCOUNT_UNREGISTERED: u64 = 100;
    const ERR_VETOKEN_COIN_ADDRESS_MISMATCH: u64 = 101;
    const ERR_VETOKEN_INTERNAL_ERROR: u64 = 102;

    ///
    /// Constants
    ///

    const SECONDS_IN_WEEK: u64 = 7 * 24 * 60 * 60;

    struct VeToken<phantom CoinType> has store {
        locked: Coin<CoinType>,
        unlockable_week: u64,
    }

    struct VeTokenSnapshot has store, drop {
        locked: u64,
        unlockable_week: u64,

        // The week epoch in which this snapshot was taken
        week: u64,
    }

    struct VeTokenStore<phantom CoinType> has key {
        vetoken: VeToken<CoinType>,
        snapshots: vector<VeTokenSnapshot>
    }

    struct VeTokenInfo<phantom CoinType> has key {
        // ***NOTE*** This cannot be configurable! If this module is updated in which the
        // account which governs `CoinType` can alter this max post-initialization, then
        // the token snapshotting logic must also be updated such that this max is also saved
        // alongside the snapshots in order to compute past weights & balances correctly.
        max_locked_weeks: u64,

        // Stores the total supply for a given week i, updated as vetokens are locked. The value
        // store is "unnormalized" meaning the (1/max_locked_weeks) factor is left out.
        unnormalized_total_supply: Table<u64, u128>,
    }

    /// Initialize a `Vetoken` based on `CoinType`. The maximum duration in which a VeToken can be locked more
    /// must be specified ahead of time and cannot be changed post initialization
    public entry fun initialize<CoinType>(account: &signer, max_locked_weeks: u64) {
        assert!(!initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);
        assert!(account_address<CoinType>() == signer::address_of(account), ERR_VETOKEN_COIN_ADDRESS_MISMATCH);
        assert!(max_locked_weeks > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        move_to(account, VeTokenInfo<CoinType> {
            max_locked_weeks,
            unnormalized_total_supply: table::new(),
        });
    }

    /// Register `account` to be able to create `VeToken`.
    public entry fun register<CoinType>(account: &signer) {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        move_to(account, VeTokenStore<CoinType> {
            vetoken: VeToken<CoinType> { locked: coin::zero(), unlockable_week: 0 },
            snapshots: vector::empty(),
        });
    }

    /// Lock `CoinType` up until `end_week`. Time is referenced in terms of the week number in order to keep an accurate
    /// total supply of `VeToken` on a week-by-week basis. This implies that locked tokens are only eligible to be unlocked
    /// at the start of a new week's period (starting from the Unix epoch).
    public fun lock<CoinType>(account: &signer, coin: Coin<CoinType>, end_week: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_week = now_weeks();
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(end_week > now_week && end_week - now_week <= vetoken_info.max_locked_weeks, ERR_VETOKEN_INVALID_END_WEEK);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) == 0, ERR_VETOKEN_LOCKED);

        // Update the supply for the weeks this VeToken is locked
        let week = now_week;
        while (week < end_week) {
            let weeks_till_unlock = (end_week - week as u128);
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, week, 0);
            *total_supply = *total_supply + (amount * weeks_till_unlock);

            week = week + 1;
        };

        // Update the VeToken & snapshot
        vetoken_store.vetoken.unlockable_week = end_week;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
        snapshot_vetoken(vetoken_store, now_week);
    }

    /// Extend the period in which the `VeToken` remains locked
    public fun increase_lock_duration<CoinType>(account: &signer, increment_weeks: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(increment_weeks >= 1, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let now_week = now_weeks();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_week < vetoken_store.vetoken.unlockable_week, ERR_VETOKEN_NOT_LOCKED);

        let new_end_week = vetoken_store.vetoken.unlockable_week + increment_weeks;
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(new_end_week - now_week <= vetoken_info.max_locked_weeks, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);

        // Update the supply for the weeks this VeToken is locked
        // For weeks the token was already locked prior, an extra `increment_weeks` factor or `locked_amount` can
        // simply be added. For the new weeks, the supply is updated as normal
        let week = now_week;
        while (week < new_end_week) {
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, week, 0);
            if (week < vetoken_store.vetoken.unlockable_week) {
                // extra `increment_weeks` factor
                *total_supply = *total_supply + (locked_amount * (increment_weeks as u128));
            } else {
                // new balance
                let weeks_till_unlock = (new_end_week - week as u128);
                *total_supply = *total_supply + (locked_amount * weeks_till_unlock);
            };

            week = week + 1;
        };

        // Update the VeToken & snapshot
        vetoken_store.vetoken.unlockable_week = new_end_week;
        snapshot_vetoken(vetoken_store, now_week);
    }

    /// Extend how much `CoinType` is locked within `VeToken`.
    public fun increase_lock_amount<CoinType>(account: &signer, coin: Coin<CoinType>) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_week = now_weeks();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_week < vetoken_store.vetoken.unlockable_week, ERR_VETOKEN_NOT_LOCKED);

        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());

        // Update the supply for the applicable weeks.
        let week = now_week;
        while (week < vetoken_store.vetoken.unlockable_week) {
            let weeks_till_unlock = (vetoken_store.vetoken.unlockable_week- week as u128);
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, week, 0);
            *total_supply = *total_supply + (amount * weeks_till_unlock);

            week = week + 1;
        };

        // Update the VeToken & snapshot
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
        snapshot_vetoken(vetoken_store, now_week);
    }

    /// Unlock a `VeToken` that reached `end_week`.
    public fun unlock<CoinType>(account: &signer): Coin<CoinType> acquires VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) > 0, ERR_VETOKEN_NOT_LOCKED);

        let now_week = now_weeks();
        assert!(now_week >= vetoken_store.vetoken.unlockable_week, ERR_VETOKEN_LOCKED);

        // Update the VeToken
        vetoken_store.vetoken.unlockable_week = 0;
        coin::extract_all(&mut vetoken_store.vetoken.locked)

        // Note: We dont have to take a snapshot here as the balance in this week and
        // beyond will be zero since the entire lock duration will have elapsed. This
        // operation has no effect on the total supply
    }

    fun snapshot_vetoken<CoinType>(vetoken_store: &mut VeTokenStore<CoinType>, week: u64) {
        let num_snapshots = vector::length(&vetoken_store.snapshots);
        if (num_snapshots > 0) {
            let last_snapshot = vector::borrow_mut(&mut vetoken_store.snapshots, num_snapshots - 1);
            assert!(week >= last_snapshot.week, ERR_VETOKEN_INTERNAL_ERROR);

            // Simply alter the last snapshot since we are still in the week
            if (last_snapshot.week == week) {
                last_snapshot.locked = coin::value(&vetoken_store.vetoken.locked);
                last_snapshot.unlockable_week = vetoken_store.vetoken.unlockable_week;
                return
            }
        };

        // Append a new snapshot for this week
        vector::push_back(&mut vetoken_store.snapshots, VeTokenSnapshot {
            locked: coin::value(&vetoken_store.vetoken.locked),
            unlockable_week: vetoken_store.vetoken.unlockable_week,
            week,
        });
    }

    fun find_snapshot(snapshots: &vector<VeTokenSnapshot>, week: u64): &VeTokenSnapshot {
        // (1) Caller should ensure `week` is within bounds
        let num_snapshots = vector::length(snapshots);
        assert!(num_snapshots > 0, ERR_VETOKEN_INTERNAL_ERROR);

        let first_snapshot = vector::borrow(snapshots, 0);
        assert!(week >= first_snapshot.week, ERR_VETOKEN_INTERNAL_ERROR);

        // (2) Check if first or last snapshot sufficies this query
        if (week == first_snapshot.week) return first_snapshot;
        let last_snapshot = vector::borrow(snapshots, num_snapshots - 1);
        if (week >= last_snapshot.week) return last_snapshot;

        // (3) Binary search the checkpoints
        // We expect queries to most often query a time not too far ago (i.e a recent governance proposal).
        // For this reason, we try to narrow our search range to the more recent checkpoints
        let low = 0;
        let high = num_snapshots;
        if (num_snapshots > 5) {
            let mid = num_snapshots - math64::sqrt(num_snapshots);

            // If we found the exact snapshot, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (week == snapshot.week) return snapshot;

            if (week < snapshot.week) high = mid
            else low = mid + 1
        };

        // Move the low/high markers to a point where `high` is lowest checkpoint that was at a point `week`.
        while (low < high) {
            let mid = low + (high - low) / 2;

            // If we found the exact snapshot, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (week == snapshot.week) return snapshot;

            if (week < snapshot.week) high = mid
            else low = mid + 1;
        };

        // If high == 0, then we know `week` is a marker too far in the past for this account which should
        // never happen given the bound checks in (1). The right snapshot is the one previous to `high`.
        assert!(high > 0, ERR_VETOKEN_INTERNAL_ERROR);
        vector::borrow(snapshots, high - 1)
    }

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    fun now_weeks(): u64 {
        timestamp::now_seconds() / SECONDS_IN_WEEK
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
    public fun total_supply<CoinType>(): u128 acquires VeTokenInfo {
        past_total_supply<CoinType>(now_weeks())
    }

    #[view]
    public fun balance<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        past_balance<CoinType>(account_addr, now_weeks())
    }

    #[view]
    public fun past_total_supply<CoinType>(week: u64): u128 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(week <= now_weeks(), ERR_VETOKEN_INVALID_PAST_WEEK);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        let unnormalized_supply = *table::borrow_with_default(&vetoken_info.unnormalized_total_supply, week, &0);
        unnormalized_supply / (vetoken_info.max_locked_weeks as u128)
    }

    #[view]
    public fun past_balance<CoinType>(account_addr: address, week: u64): u64 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(week <= now_weeks(), ERR_VETOKEN_INVALID_PAST_WEEK);

        // ensure `week` is within bounds. no need to check the upper bound as the latest snapshot is valid for
        // any future week up until `now_weeks()`
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        let snapshots = &vetoken_store.snapshots;
        if (vector::is_empty(snapshots) || week < vector::borrow(snapshots, 0).week) {
            return 0
        };

        // find the appropriate snapshot and compute the balance
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        let snapshot = find_snapshot(snapshots, week);
        if (week >= snapshot.unlockable_week) 0
        else {
            let remaining_weeks = snapshot.unlockable_week - week;
            math64::mul_div(snapshot.locked, remaining_weeks, vetoken_info.max_locked_weeks)
        }
    }

    #[test_only]
    use vetoken::coin_helper;

    #[test_only]
    struct FakeCoin {}

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, max_duration_weeks: u64) {
        initialize<FakeCoin>(vetoken, max_duration_weeks);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        coin_helper::create_coin_for_test<FakeCoin>(vetoken,
            std::string::utf8(b"FakeCoin"), std::string::utf8(b"FC"), 8, true);
    }

    #[test(account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_COIN_ADDRESS_MISMATCH)]
    fun non_vetoken_initialize_err(account: &signer) {
        initialize<FakeCoin>(account, 52);
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
    fun increase_lock_amount_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
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
    fun past_balance_and_supply_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 4);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        // (1) Returns 0 when there's no locked token at all
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_total_supply<FakeCoin>(0) == 0, 0);

        // new epoch == 1
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);
        lock(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        lock(u2, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 3);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 1); // 1000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 1); // 2000/4
        assert!(total_supply<FakeCoin>() == 750, 0);

        increase_lock_duration<FakeCoin>(u1, 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0); // 2000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 0); // 2000/4
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // new epoch == 2
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        // (3) Persists Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // introduce change in the current epoch for u1. u2 balance decays as expected
        increase_lock_amount(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 250, 0);
        assert!(total_supply<FakeCoin>() == 750, 0);

        // new_epoch == 3
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        // (4) Same Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // (5) Persists Epoch (2)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 2) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 2) == 250, 0);
        assert!(past_total_supply<FakeCoin>(2) == 750, 0);

        // new_epoch == 4
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        // (6) All balances are expired in Epoch (3)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 3) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 3) == 0, 0);
        assert!(past_total_supply<FakeCoin>(3) == 0, 0);

        // (7) No balance is held in Epoch (0)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 0) == 0, 0);
        assert!(past_total_supply<FakeCoin>(0) == 0, 0);
    }
}
