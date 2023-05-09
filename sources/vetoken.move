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
    const ERR_VETOKEN_INVALID_EPOCH_DURATION: u64 = 6;
    const ERR_VETOKEN_INVALID_END_EPOCH: u64 = 7;
    const ERR_VETOKEN_INVALID_PAST_EPOCH: u64 = 8;

    // Other
    const ERR_VETOKEN_ACCOUNT_UNREGISTERED: u64 = 100;
    const ERR_VETOKEN_COIN_ADDRESS_MISMATCH: u64 = 101;
    const ERR_VETOKEN_INTERNAL_ERROR: u64 = 102;

    struct VeToken<phantom CoinType> has store {
        locked: Coin<CoinType>,
        unlockable_epoch: u64,
    }

    struct VeTokenSnapshot has store, drop {
        locked: u64,
        unlockable_epoch: u64,

        // The epoch in which this snapshot was taken
        epoch: u64,
    }

    struct VeTokenStore<phantom CoinType> has key {
        vetoken: VeToken<CoinType>,
        snapshots: vector<VeTokenSnapshot>
    }

    struct VeTokenInfo<phantom CoinType> has key {
        // ***NOTE*** These values cannot be configurable! The token snapshotting logic
        // assumes that the parameters of a VeToken is fixed post-initialization.

        min_locked_epochs: u64,
        max_locked_epochs: u64,
        epoch_duration_seconds: u64,

        // Stores the total supply for a given epoch i, updated as vetokens are locked. The value
        // store is "unnormalized" meaning the (1/max_locked_epochs) factor is left out.
        unnormalized_total_supply: Table<u64, u128>,
    }

    /// Initialize a `VeToken` based on `CoinType`. The parameters set on the VeToken are not changeable after init.
    ///
    /// When setting the min/max epochs for a VeToken, it is important to note that these values must be > 0. This
    /// is because a locked token is forced at least partially observe the epoch it was locked in. Asserted since
    /// a VeToken immediately unlockable holds no balance. Therefore, all locked tokens will observe at a minimum 1 epoch
    /// automatically when locked.
    public entry fun initialize<CoinType>(
        account: &signer,
        min_locked_epochs: u64,
        max_locked_epochs: u64,
        epoch_duration_seconds: u64
    ) {
        assert!(!initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);
        assert!(account_address<CoinType>() == signer::address_of(account), ERR_VETOKEN_COIN_ADDRESS_MISMATCH);
        assert!(max_locked_epochs > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        assert!(min_locked_epochs > 0 && min_locked_epochs <= max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);
        assert!(epoch_duration_seconds > 0, ERR_VETOKEN_INVALID_EPOCH_DURATION);
        move_to(account, VeTokenInfo<CoinType> {
            min_locked_epochs,
            max_locked_epochs,
            epoch_duration_seconds,
            unnormalized_total_supply: table::new(),
        });
    }

    /// Update the minimum epochs a token must be locked for. We can do this unlike `max_locked_epochs` as the
    /// snapshotting logic works independently of the minimum
    public entry fun set_min_locked_epochs<CoinType>(account: &signer, min_locked_epochs: u64) acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);

        let account_addr = signer::address_of(account);
        assert!(account_address<CoinType>() == account_addr, ERR_VETOKEN_COIN_ADDRESS_MISMATCH);

        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_addr);
        assert!(min_locked_epochs > 0 && min_locked_epochs <= vetoken_info.max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);

        vetoken_info.min_locked_epochs = min_locked_epochs;
    }

    /// Register `account` to be able to hold `VeToken<CoinType>`.
    public entry fun register<CoinType>(account: &signer) {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        move_to(account, VeTokenStore<CoinType> {
            vetoken: VeToken<CoinType> { locked: coin::zero(), unlockable_epoch: 0 },
            snapshots: vector::empty(),
        });
    }

    /// Lock `CoinType` up until `end_epoch`. Time is referenced in terms of the epoch number in order to keep an accurate
    /// total supply of `VeToken` on an epoch basis. This implies that locked tokens are only eligible to be unlocked
    /// at the start of a new epoch.
    public fun lock<CoinType>(account: &signer, coin: Coin<CoinType>, end_epoch: u64) acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_epoch = now_epoch<CoinType>();
        assert!(end_epoch > now_epoch, ERR_VETOKEN_INVALID_END_EPOCH);

        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(now_epoch + vetoken_info.min_locked_epochs <= end_epoch
            && now_epoch + vetoken_info.max_locked_epochs >= end_epoch, ERR_VETOKEN_INVALID_END_EPOCH);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) == 0, ERR_VETOKEN_LOCKED);

        // Update the supply for the epochs this VeToken is locked
        let epoch = now_epoch;
        while (epoch < end_epoch) {
            let epochs_till_unlock = (end_epoch - epoch as u128);
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, epoch, 0);
            *total_supply = *total_supply + (amount * epochs_till_unlock);

            epoch = epoch + 1;
        };

        // Update the VeToken & snapshot
        vetoken_store.vetoken.unlockable_epoch = end_epoch;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
        snapshot_vetoken(vetoken_store, now_epoch);
    }

    /// Extend the period in which the `VeToken` remains locked
    public fun increase_lock_duration<CoinType>(account: &signer, increment_epochs: u64) acquires VeTokenInfo, VeTokenStore {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(increment_epochs >= 1, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let now_epoch = now_epoch<CoinType>();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_epoch < vetoken_store.vetoken.unlockable_epoch, ERR_VETOKEN_NOT_LOCKED);

        let new_end_epoch = vetoken_store.vetoken.unlockable_epoch + increment_epochs;
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(new_end_epoch - now_epoch <= vetoken_info.max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);

        // Update the supply for the epochs this VeToken is locked
        let epoch = now_epoch;
        while (epoch < new_end_epoch) {
            // For epochs the token was already locked prior, an extra `increment_epochs` factor of `locked_amount`
            // is added. For the new epochs, the supply is updated as normal (epochs left till unlock)
            let strength_factor = if (epoch < vetoken_store.vetoken.unlockable_epoch) increment_epochs else new_end_epoch - epoch;
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, epoch, 0);
            *total_supply = *total_supply + (locked_amount * (strength_factor as u128));

            epoch = epoch + 1;
        };

        // Update the VeToken & snapshot
        vetoken_store.vetoken.unlockable_epoch = new_end_epoch;
        snapshot_vetoken(vetoken_store, now_epoch);
    }

    /// Extend how much `CoinType` is locked within `VeToken`.
    public fun increase_lock_amount<CoinType>(account: &signer, coin: Coin<CoinType>) acquires VeTokenInfo, VeTokenStore {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_epoch = now_epoch<CoinType>();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_epoch < vetoken_store.vetoken.unlockable_epoch, ERR_VETOKEN_NOT_LOCKED);

        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());

        // Update the supply for the applicable epochs.
        let epoch = now_epoch;
        while (epoch < vetoken_store.vetoken.unlockable_epoch) {
            let epochs_till_unlock = (vetoken_store.vetoken.unlockable_epoch- epoch as u128);
            let total_supply = table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, epoch, 0);
            *total_supply = *total_supply + (amount * epochs_till_unlock);

            epoch = epoch + 1;
        };

        // Update the VeToken & snapshot
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
        snapshot_vetoken(vetoken_store, now_epoch);
    }

    /// Unlock a `VeToken` that reached `end_epoch`.
    public fun unlock<CoinType>(account: &signer): Coin<CoinType> acquires VeTokenInfo, VeTokenStore {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) > 0, ERR_VETOKEN_NOT_LOCKED);

        let now_epoch = now_epoch<CoinType>();
        assert!(now_epoch >= vetoken_store.vetoken.unlockable_epoch, ERR_VETOKEN_LOCKED);

        // Update the VeToken
        vetoken_store.vetoken.unlockable_epoch = 0;
        coin::extract_all(&mut vetoken_store.vetoken.locked)

        // Note: We dont have to take a snapshot here as the balance in this epoch and
        // beyond will be zero since the entire lock duration will have elapsed. This
        // operation has no effect on the total supply
    }

    fun snapshot_vetoken<CoinType>(vetoken_store: &mut VeTokenStore<CoinType>, epoch: u64) {
        let num_snapshots = vector::length(&vetoken_store.snapshots);
        if (num_snapshots > 0) {
            let last_snapshot = vector::borrow_mut(&mut vetoken_store.snapshots, num_snapshots - 1);
            assert!(epoch >= last_snapshot.epoch, ERR_VETOKEN_INTERNAL_ERROR);

            // Simply alter the last snapshot since we are still in the epoch
            if (last_snapshot.epoch == epoch) {
                last_snapshot.locked = coin::value(&vetoken_store.vetoken.locked);
                last_snapshot.unlockable_epoch = vetoken_store.vetoken.unlockable_epoch;
                return
            }
        };

        // Append a new snapshot for this epoch
        vector::push_back(&mut vetoken_store.snapshots, VeTokenSnapshot {
            epoch,
            locked: coin::value(&vetoken_store.vetoken.locked),
            unlockable_epoch: vetoken_store.vetoken.unlockable_epoch,
        });
    }

    fun find_snapshot(snapshots: &vector<VeTokenSnapshot>, epoch: u64): &VeTokenSnapshot {
        // (1) Caller should ensure `epoch` is within bounds
        let num_snapshots = vector::length(snapshots);
        assert!(num_snapshots > 0, ERR_VETOKEN_INTERNAL_ERROR);

        let first_snapshot = vector::borrow(snapshots, 0);
        assert!(epoch >= first_snapshot.epoch, ERR_VETOKEN_INTERNAL_ERROR);

        // (2) Check if first or last snapshot sufficies this query
        if (epoch == first_snapshot.epoch) return first_snapshot;
        let last_snapshot = vector::borrow(snapshots, num_snapshots - 1);
        if (epoch >= last_snapshot.epoch) return last_snapshot;

        // (3) Binary search the checkpoints
        // We expect queries to most often query a time not too far ago (i.e a recent governance proposal).
        // For this reason, we try to narrow our search range to the more recent checkpoints
        let low = 0;
        let high = num_snapshots;
        if (num_snapshots > 5) {
            let mid = num_snapshots - math64::sqrt(num_snapshots);

            // If we found the exact snapshot, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (epoch == snapshot.epoch) return snapshot;

            if (epoch < snapshot.epoch) high = mid
            else low = mid + 1
        };

        // Move the low/high markers to a point where `high` is lowest checkpoint that was at a point `epoch`.
        while (low < high) {
            let mid = low + (high - low) / 2;

            // If we found the exact snapshot, we can return early
            let snapshot = vector::borrow(snapshots, mid);
            if (epoch == snapshot.epoch) return snapshot;

            if (epoch < snapshot.epoch) high = mid
            else low = mid + 1;
        };

        // If high == 0, then we know `epoch` is a marker too far in the past for this account which should
        // never happen given the bound checks in (1). The right snapshot is the one previous to `high`.
        assert!(high > 0, ERR_VETOKEN_INTERNAL_ERROR);
        vector::borrow(snapshots, high - 1)
    }

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }


    // Public Getters

    #[view]
    public fun initialized<CoinType>(): bool {
        exists<VeTokenInfo<CoinType>>(account_address<CoinType>())
    }

    #[view]
    public fun is_account_registered<CoinType>(account_addr: address): bool {
        exists<VeTokenStore<CoinType>>(account_addr)
    }

    #[view]
    public fun total_supply<CoinType>(): u128 acquires VeTokenInfo {
        past_total_supply<CoinType>(now_epoch<CoinType>())
    }

    #[view]
    public fun balance<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        past_balance<CoinType>(account_addr, now_epoch<CoinType>())
    }

    #[view]
    public fun unnormalized_past_total_supply<CoinType>(epoch: u64): u128 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(epoch <= now_epoch<CoinType>(), ERR_VETOKEN_INVALID_PAST_EPOCH);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        *table::borrow_with_default(&vetoken_info.unnormalized_total_supply, epoch, &0)
    }

    #[view]
    public fun past_total_supply<CoinType>(epoch: u64): u128 acquires VeTokenInfo {
        unnormalized_past_total_supply<CoinType>(epoch) / (max_locked_epochs<CoinType>() as u128)
    }

    #[view]
    public fun unnormalized_past_balance<CoinType>(account_addr: address, epoch: u64): u128 acquires VeTokenStore, VeTokenInfo {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(epoch <= now_epoch<CoinType>(), ERR_VETOKEN_INVALID_PAST_EPOCH);

        // ensure `epoch` is within bounds. no need to check the upper bound as the latest snapshot is valid for
        // any future epoch up until `now_epoch<CoinType>()`
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        let snapshots = &vetoken_store.snapshots;
        if (vector::is_empty(snapshots) || epoch < vector::borrow(snapshots, 0).epoch) {
            return 0
        };

        // find the appropriate snapshot and compute the balance
        let snapshot = find_snapshot(snapshots, epoch);
        if (epoch >= snapshot.unlockable_epoch) 0
        else {
            (snapshot.locked as u128) * ((snapshot.unlockable_epoch - epoch) as u128)
        }
    }

    #[view]
    public fun past_balance<CoinType>(account_addr: address, epoch: u64): u64 acquires VeTokenInfo, VeTokenStore {
        let unnormalized = unnormalized_past_balance<CoinType>(account_addr, epoch);
        let max_locked_epochs = (max_locked_epochs<CoinType>() as u128);
        ((unnormalized / max_locked_epochs) as u64)
    }

    #[view]
    public fun now_epoch<CoinType>(): u64 acquires VeTokenInfo {
        seconds_to_epoch<CoinType>(timestamp::now_seconds())
    }

    #[view]
    public fun seconds_to_epoch<CoinType>(time_seconds: u64): u64 acquires VeTokenInfo {
        time_seconds / seconds_in_epoch<CoinType>()
    }

    #[view]
    public fun seconds_in_epoch<CoinType>(): u64 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        vetoken_info.epoch_duration_seconds
    }

    #[view]
    public fun max_locked_epochs<CoinType>(): u64 acquires VeTokenInfo {
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        vetoken_info.max_locked_epochs
    }

    #[test_only]
    use test_utils::coin_test;

    #[test_only]
    struct FakeCoin {}

    #[test_only]
    const SECONDS_IN_WEEK: u64 = 7 * 24 * 60 * 60;

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, min_locked_epochs: u64, max_locked_epochs: u64) {
        initialize<FakeCoin>(vetoken, min_locked_epochs, max_locked_epochs, SECONDS_IN_WEEK);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        coin_test::initialize_fake_coin_with_decimals<FakeCoin>(vetoken, 8);
    }

    #[test(account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_COIN_ADDRESS_MISMATCH)]
    fun non_vetoken_initialize_err(account: &signer) {
        initialize<FakeCoin>(account, 1, 52, SECONDS_IN_WEEK);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, accountA = @0xA, accountB = @0xB)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_END_EPOCH)]
    fun set_min_locked_epochs_ok(aptos_framework: &signer, vetoken: &signer, accountA: &signer, accountB: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 52);
        register<FakeCoin>(accountA);
        register<FakeCoin>(accountB);

        // we can unlock in the next epoch with a minimum of 1
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(accountA, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);

        // Fails as the minimum is now 2
        set_min_locked_epochs<FakeCoin>(vetoken, 2);
        lock(accountB, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun lock_unlock_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_test::mint_coin<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // unlock
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        let unlocked = unlock<FakeCoin>(account);
        assert!(coin::value(&unlocked) == 1000, 0);

        // cleanup
        coin_test::burn_coin(vetoken, unlocked);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun lock_max_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore { 
        initialize_for_test(aptos_framework, vetoken, 1, 52);
        register<FakeCoin>(account);

        // Including epoch 0, ending in week 52 implies a total of 52 weeks locked
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 52);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_END_EPOCH)]
    fun lock_beyond_max_invalid_end_epoch_err(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 52);
        register<FakeCoin>(account);

        // Total of 53 weeks including epoch 0
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 53);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun lock_below_min_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 52);
        register<FakeCoin>(account);

        // Including epoch 0, user can unlock in the next epoch with a min 1
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_END_EPOCH)]
    fun lock_below_min_invalid_end_epoch_err(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 2, 52);
        register<FakeCoin>(account);

        // Only locked for total of 1 week (epoch 0) with a min of 2
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    #[expected_failure(abort_code = ERR_VETOKEN_LOCKED)]
    fun early_unlock_err(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        // lock
        register<FakeCoin>(account);
        let lock_coin = coin_test::mint_coin<FakeCoin>(vetoken, 1000);
        lock(account, lock_coin, 1);

        // early unlock: try to unlock before the epoch ends
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>() - 1);
        coin_test::burn_coin(vetoken, unlock<FakeCoin>(account));
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun increase_lock_duration_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        // lock
        register<FakeCoin>(account);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 2000 / 5, 0);

        // extend 2 epochs
        increase_lock_duration<FakeCoin>(account, 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);

        // 3 epochs later, extend 3 more epochs
        timestamp::fast_forward_seconds(3 * seconds_in_epoch<FakeCoin>());
        increase_lock_duration<FakeCoin>(account, 3);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, account = @0xA)]
    fun increase_lock_amount_ok(aptos_framework: &signer, vetoken: &signer, account: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        // lock
        register<FakeCoin>(account);
        lock(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(account)) == 2000 / 5, 0);

        // increase lock amount
        increase_lock_amount<FakeCoin>(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(account)) == 4000 / 5, 0);

        // 1 epochs later, further increase lock amount
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        increase_lock_amount<FakeCoin>(account, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(account)) == 3000 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB, u3 = @0xC, u4 = @0xD)]
    fun balance_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer, u3: &signer, u4: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 3);

        // no locks
        assert!(total_supply<FakeCoin>() == 0, 0);

        // lock
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);
        register<FakeCoin>(u3);
        register<FakeCoin>(u4);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        lock(u2, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        lock(u3, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 3);
        lock(u4, coin_test::mint_coin<FakeCoin>(vetoken, 2000), 1);

        // at the beginning
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 1000, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 666, 0);
        assert!(total_supply<FakeCoin>() == 2666, 0);

        // 1 epoch later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // 2 epochs later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 333, 0);

        // 3 epochs later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken, u1 = @0xA, u2 = @0xB)]
    fun past_balance_and_supply_ok(aptos_framework: &signer, vetoken: &signer, u1: &signer, u2: &signer) acquires VeTokenInfo, VeTokenStore {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        // (1) Returns 0 when there's no locked token at all
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_total_supply<FakeCoin>(0) == 0, 0);

        // new epoch == 1
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        lock(u2, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 3);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 1); // 1000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 1); // 2000/4
        assert!(total_supply<FakeCoin>() == 750, 0);

        increase_lock_duration<FakeCoin>(u1, 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0); // 2000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 0); // 2000/4
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // new epoch == 2
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // (3) Persists Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // introduce change in the current epoch for u1. u2 balance decays as expected
        increase_lock_amount(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 250, 0);
        assert!(total_supply<FakeCoin>() == 750, 0);

        // new_epoch == 3
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // (4) Same Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // (5) Persists Epoch (2)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 2) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 2) == 250, 0);
        assert!(past_total_supply<FakeCoin>(2) == 750, 0);

        // new_epoch == 4
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

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
