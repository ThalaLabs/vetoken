module vetoken::vetoken {
    use std::signer;
    use std::vector;

    use aptos_std::math64;
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

        // Stores the total amounts unlockable vetoken in the key i which represents week i
        total_unlockable: Table<u64, u128>,
    }

    /// Initialize a `Vetoken` based on `CoinType`. The maximum duration in which a VeToken can be locked more
    /// must be specified ahead of time and cannot be changed post initialization
    public entry fun initialize<CoinType>(account: &signer, max_locked_weeks: u64) {
        assert!(!initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);
        assert!(account_address<CoinType>() == signer::address_of(account), ERR_VETOKEN_COIN_ADDRESS_MISMATCH);
        assert!(max_locked_weeks > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        move_to(account, VeTokenInfo<CoinType> {
            max_locked_weeks,

            // Bookkeeping
            total_unlockable: table::new(),
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

        // Update the total unlockable amount in the week to unlock
        let total_unlockable = table::borrow_mut_with_default(&mut vetoken_info.total_unlockable, end_week, 0);
        *total_unlockable = *total_unlockable + amount;

        // Update the VeToken
        vetoken_store.vetoken.unlockable_week = end_week;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);

        // Take a snapshot
        snapshot_vetoken(vetoken_store, now_week);
    }

    /// Extend the period in which the `VeToken` remains locked
    public fun increase_lock_duration<CoinType>(account: &signer, increment_weeks: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(increment_weeks >= 1, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());

        let now_week = now_weeks();
        let new_end_week = vetoken_store.vetoken.unlockable_week + increment_weeks;
        assert!(now_week < vetoken_store.vetoken.unlockable_week, ERR_VETOKEN_NOT_LOCKED);
        assert!(new_end_week - now_week <= vetoken_info.max_locked_weeks, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);

        // Update the total unlockable amounts in the new & old end weeks
        //  - unlockable[old_end_week] -= vetoken.locked
        //  - unlockable[new_end_week] += vetoken.locked
        let old_total_unlockable = table::borrow_mut(&mut vetoken_info.total_unlockable, vetoken_store.vetoken.unlockable_week);
        *old_total_unlockable = *old_total_unlockable - locked_amount;

        let new_total_unlockable = table::borrow_mut_with_default(&mut vetoken_info.total_unlockable, new_end_week, 0);
        *new_total_unlockable = *new_total_unlockable + locked_amount;

        // Update the VeToken
        vetoken_store.vetoken.unlockable_week = new_end_week;

        // Take a snapshot
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

        // Update the total unlockable in the end week with the incremental amount
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        let total_unlockable = table::borrow_mut(&mut vetoken_info.total_unlockable, vetoken_store.vetoken.unlockable_week);
        *total_unlockable = *total_unlockable + amount;

        // Update the VeToken
        coin::merge(&mut vetoken_store.vetoken.locked, coin);

        // Take a snapshot
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
        // beyond will be zero since the entire lock duration will have elapsed
    }

    fun snapshot_vetoken<CoinType>(vetoken_store: &mut VeTokenStore<CoinType>, week: u64) {
        let num_snapshots = vector::length(&vetoken_store.snapshots);
        if (num_snapshots > 0) {
            let last_snapshot = vector::borrow_mut(&mut vetoken_store.snapshots, num_snapshots - 1);
            assert!(week >= last_snapshot.week, ERR_VETOKEN_INTERNAL_ERROR);

            // Simply alter the last snapshot since we are still in the latest epoch
            if (last_snapshot.week == week) {
                last_snapshot.locked = coin::value(&vetoken_store.vetoken.locked);
                last_snapshot.unlockable_week = vetoken_store.vetoken.unlockable_week;
                return
            }
        };

        // Append a new snapshot for this epoch
        vector::push_back(&mut vetoken_store.snapshots, VeTokenSnapshot {
            locked: coin::value(&vetoken_store.vetoken.locked),
            unlockable_week: vetoken_store.vetoken.unlockable_week,
            week,
        });
    }

    fun snapshot_balance<CoinType>(snapshot: &VeTokenSnapshot, vetoken_info: &VeTokenInfo<CoinType>, week: u64): u64 {
        if (week >= snapshot.unlockable_week) 0
        else {
            let remaining_weeks = snapshot.unlockable_week - week;
            math64::mul_div(snapshot.locked, remaining_weeks, vetoken_info.max_locked_weeks)
        }
    }

    fun unnormalized_total_supply<CoinType>(vetoken_info: &VeTokenInfo<CoinType>, week: u64): u128 {
        let end_in_weeks = 1;
        let supply = 0u128;
        while (end_in_weeks <= vetoken_info.max_locked_weeks) {
            // we do not divide by the the max lock duration because it will be eliminated when
            // dividing by unnormalized_total_supply in computing the weight
            let locked_amount = *table::borrow_with_default(&vetoken_info.total_unlockable, week + end_in_weeks, &0);
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
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        unnormalized_total_supply(vetoken_info, now_weeks()) / (vetoken_info.max_locked_weeks as u128)
    }

    #[view]
    public fun balance<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        past_balance<CoinType>(account_addr, now_weeks())
    }

    #[view]
    public fun weight<CoinType>(account_addr: address): FixedPoint64 acquires VeTokenInfo, VeTokenStore {
        let supply = total_supply<CoinType>();
        if (supply == 0) fixed_point64::zero()
        else {
            let balance = (balance<CoinType>(account_addr) as u128);
            fixed_point64::from_u128((balance << 64) / supply)
        }
    }

    #[view]
    public fun past_balance<CoinType>(account_addr: address, week: u64): u64 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(week <= now_weeks(), ERR_VETOKEN_INVALID_PAST_WEEK);

        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        let snapshots = &vetoken_store.snapshots;

        let num_snapshots = vector::length(snapshots);
        if (num_snapshots == 0) return 0;

        // (1) Check if the last snapshot sufficies this query
        let last_snapshot = vector::borrow(snapshots, num_snapshots - 1);
        if (week >= last_snapshot.week) return snapshot_balance(last_snapshot, vetoken_info, week);
        let first_snapshot = vector::borrow(snapshots, 0);

        // (2) Check if the week is too stale for this account
        if (week < first_snapshot.week) return 0
        else if (week == first_snapshot.week) return snapshot_balance(first_snapshot, vetoken_info, week);

        // (3) Binary search the checkpoints
        // We expect queries to most often query timestamps not too far ago (i.e a recent governance proposal).
        // For this reason, we try to narrow our search range to the more recent checkpoints
        let low = 0;
        let high = num_snapshots;
        if (num_snapshots > 5) {
            let mid = num_snapshots - math64::sqrt(num_snapshots);

            // If we found the epoch directly, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (week == snapshot.week) return snapshot_balance(snapshot, vetoken_info, week);

            if (week < snapshot.week) high = mid
            else low = mid + 1
        };

        // Move the low/high markers to a point where `high` is lowest checkpoint that was at a point `week`.
        while (low < high) {
            let mid = low + (high - low) / 2;

            // If we found the epoch directly, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (week == snapshot.week) return snapshot_balance(snapshot, vetoken_info, week);

            if (week < snapshot.week) high = mid
            else low = mid + 1;
        };

        // If high == 0, then we know `week` is a marker too far in the past for this account.
        // Otherwise, the right checkpoint to query is the checkpoint right before `high`.
        if (high == 0) 0
        else snapshot_balance(vector::borrow(snapshots, high - 1), vetoken_info, week)
    }

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
            std::string::utf8(b"Fake Coin"),
            std::string::utf8(b"FAKE"),
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

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB)]
    fun past_balance_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 4);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        // (1) No balance / weight
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);

        // new epoch == 1
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        lock(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 2);
        lock(u2, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000), 3);
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 250, 1); // 1000/4
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 1); // 2000/4

        // (2) Reflects changes in the current epoch
        increase_lock_duration<FakeCoin>(u1, 1);
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0); // 2000/4
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0); // 2000/4

        // new epoch == 2
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        // (3) Persists Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);

        // some change in the current epoch (2) for u1. u2 balance decays as expected
        increase_lock_amount(u1, coin_helper::mint_coin_for_test<FakeCoin>(vetoken, 1000));
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 2) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 2) == 250, 0);

        // new_epoch == 3
        timestamp::fast_forward_seconds(SECONDS_IN_WEEK);

        // (4) Same Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);

        // (5) Persists Epoch (1) -- including the change
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 2) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 2) == 250, 0);

        // (6) All balances are expired in Epoch (2)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 3) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 3) == 0, 0);

        // (7) No balance is held in Epoch (0)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 0) == 0, 0);
    }
}
