module vetoken::composable_vetoken {
    use std::signer;
    use aptos_std::smart_vector::{Self, SmartVector};

    use aptos_std::type_info;

    use vetoken::dividend_distributor;
    use vetoken::vetoken;

    ///
    /// Errors
    ///

    const ERR_COMPOSABLE_VETOKEN2_INITIALIZED: u64 = 0;
    const ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED: u64 = 1;

    // VeToken Errors
    const ERR_VETOKEN_UNINITIALIZED: u64 = 50;

    // Composable VeToken Errors
    const ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH: u64 = 100;
    const ERR_COMPOSABLE_VETOKEN2_EPOCH_DURATION_MISMATCH: u64 = 101;
    const ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS: u64 = 102;
    const ERR_COMPOSABLE_VETOKEN2_IMMUTABLE_MULTIPLIERS: u64 = 103;
    const ERR_COMPOSABLE_VETOKEN2_INVALID_EPOCH: u64 = 104;

    ///
    /// Resources
    ///

    struct MultiplierSnapshot has store {
        multiplier_percent_a: u64,
        multiplier_percent_b: u64,
        epoch: u64,
    }

    struct ComposedVeToken2<phantom CoinTypeA, phantom CoinTypeB> has key {
        multiplier_percent_a: u64,
        multiplier_percent_b: u64,
        mutable_multipliers: bool,
        multiplier_snapshots: SmartVector<MultiplierSnapshot>
    }

    /// Create a ComposedVeToken2 over `CoinTypeA` and `CoinTypeB`. Only `CoinTypeA` is allowed to instantiate
    /// this configuration.
    ///
    /// @param multiplier_percent_a percent multiplier `CoinTypeA` contributes to the total balance
    /// @param multiplier_percent_b percent multiplier `CoinTypeB` contributes to the total balance
    /// @param mutable_multipliers indicator if the multiplier configuration can change post-initialization. Depending on the implementation,
    ///                        this is prone to centralization risk.
    ///
    /// Note: `ComposedVeToken2` does not lock coins seperately from the `vetoken::vetoken` module. Rather `ComposedVeToken2`
    /// is a sort-of "view-based" wrapper over `VeToken`.
    public entry fun initialize<CoinTypeA, CoinTypeB>(account: &signer, multiplier_percent_a: u64, multiplier_percent_b: u64, mutable_multipliers: bool) {
        assert!(!initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_INITIALIZED);
        assert!(vetoken::initialized<CoinTypeA>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(vetoken::initialized<CoinTypeB>(), ERR_VETOKEN_UNINITIALIZED);

        // assert composable vetoken configuration
        assert!(vetoken::seconds_in_epoch<CoinTypeA>() == vetoken::seconds_in_epoch<CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_EPOCH_DURATION_MISMATCH);
        assert!(multiplier_percent_a > 0 && multiplier_percent_b > 0, ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS);

        // the owner of the first coin slot controls configuration for this `ComposedVeToken2`.
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH);

        let multiplier_snapshots = smart_vector::singleton(
            MultiplierSnapshot {multiplier_percent_a, multiplier_percent_b, epoch: vetoken::now_epoch<CoinTypeA>()});
        move_to(account, ComposedVeToken2<CoinTypeA, CoinTypeB> { multiplier_percent_a, multiplier_percent_b, mutable_multipliers, multiplier_snapshots: multiplier_snapshots });
    }

    public entry fun update_multipliers<CoinTypeA, CoinTypeB>(account: &signer, multiplier_percent_a: u64, multiplier_percent_b: u64) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH);
        assert!(multiplier_percent_a > 0 && multiplier_percent_b > 0, ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS);

        let composable_vetoken = borrow_global_mut<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        assert!(composable_vetoken.mutable_multipliers, ERR_COMPOSABLE_VETOKEN2_IMMUTABLE_MULTIPLIERS);

        let now_epoch = vetoken::now_epoch<CoinTypeA>();
        let num_snapshots = smart_vector::length(&composable_vetoken.multiplier_snapshots);
        let last_snapshot = smart_vector::borrow_mut(&mut composable_vetoken.multiplier_snapshots, num_snapshots - 1);
        if (last_snapshot.epoch == now_epoch) {
            last_snapshot.multiplier_percent_a = multiplier_percent_a;
            last_snapshot.multiplier_percent_b = multiplier_percent_b;
        } else {
            smart_vector::push_back(&mut composable_vetoken.multiplier_snapshots, MultiplierSnapshot {multiplier_percent_a, multiplier_percent_b, epoch: now_epoch});
        };

        composable_vetoken.multiplier_percent_a = multiplier_percent_a;
        composable_vetoken.multiplier_percent_b = multiplier_percent_b;
    }

    #[view] /// Query for the current multiplier configuration
    public fun multiplier_percents<CoinTypeA, CoinTypeB>(): (u64, u64) acquires ComposedVeToken2 {
        let composable_vetoken = borrow_global<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        (composable_vetoken.multiplier_percent_a, composable_vetoken.multiplier_percent_b)
    }

    #[view] /// Query for the current ComposedVeToken2<CoinTypeA, CoinTypeB> balance of this account
    public fun balance<CoinTypeA, CoinTypeB>(account_addr: address): u128 acquires ComposedVeToken2 {
        // The epochs are the same between `CoinTypeA` & `CoinTypeB` since `initialize`
        // would fail if the epoch durations did not match
        past_balance<CoinTypeA, CoinTypeB>(account_addr, vetoken::now_epoch<CoinTypeA>())
    }

    #[view] /// Query for the current ComposedVeToken2<CoinTypeA, CoinTypeB> total supply
    public fun total_supply<CoinTypeA, CoinTypeB>(): u128 acquires ComposedVeToken2 {
        // The epochs are the same between `CoinTypeA` & `CoinTypeB` since `initialize`
        // would fail if the epoch durations did not match
        past_total_supply<CoinTypeA, CoinTypeB>(vetoken::now_epoch<CoinTypeA>())
    }

    #[view]
    /// Query for the current ComposedVeToken2<CoinTypeA, CoinTypeB> underlying total supply
    /// Note it returns total_supply * 100
    public fun multiplied_underlying_total_supply<CoinTypeA, CoinTypeB>(): (u128, u128) acquires ComposedVeToken2 {
        // The epochs are the same between `CoinTypeA` & `CoinTypeB` since `initialize`
        // would fail if the epoch durations did not match
        past_multiplied_underlying_total_supply<CoinTypeA, CoinTypeB>(vetoken::now_epoch<CoinTypeA>())
    }

    #[view] /// Query for the latest multiplier configuration at a given epoch
    public fun past_multiplier_percents<CoinTypeA, CoinTypeB>(epoch: u64): (u64, u64) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        let composable_vetoken = borrow_global<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        let snapshots = &composable_vetoken.multiplier_snapshots;
        let num_snapshots = smart_vector::length(snapshots);

        // Check if the latest snapshot suffices
        let snapshot = smart_vector::borrow(snapshots, num_snapshots - 1);
        if (epoch >= snapshot.epoch) return (snapshot.multiplier_percent_a, snapshot.multiplier_percent_b);

        // Check if the first snapshot sufficies or the supplied epoch is too far in the past
        let snapshot = smart_vector::borrow(snapshots, 0);
        if (epoch < snapshot.epoch) return (0, 0)
        else if (epoch == snapshot.epoch) return (snapshot.multiplier_percent_a, snapshot.multiplier_percent_b);

        // Binary search a snapshot where the epoch is the highest behind the target epoch. The checks
        // before reaching this search ensures that the supplied epoch is in range of [low, hi]
        //
        // NOTE: If we reach the terminating condition, low >= hi, then that indicates the index
        // (low - 1) is the right snapshot with the highest epoch below the target
        let low = 0;
        let high = num_snapshots - 1;
        while (low < high) {
            let mid = (low + high) / 2;
            let snapshot = smart_vector::borrow(snapshots, mid);

            // return early if we find an exact epoch
            if (epoch == snapshot.epoch) return (snapshot.multiplier_percent_a, snapshot.multiplier_percent_b);

            if (epoch > snapshot.epoch) low = mid + 1
            else high = mid
        };

        let snapshot = smart_vector::borrow(snapshots, low - 1);
        (snapshot.multiplier_percent_a, snapshot.multiplier_percent_b)
    }

    #[view] /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> balance of this account at a given epoch
    public fun past_balance<CoinTypeA, CoinTypeB>(account_addr: address, epoch: u64): u128 acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        // VeToken<CoinTypeA> Component
        let balance_a = (vetoken::past_balance<CoinTypeA>(account_addr, epoch) as u128);

        // VeToken<CoinTypeB> Component
        let balance_b = (vetoken::past_balance<CoinTypeB>(account_addr, epoch) as u128);

        // Apply Multipliers
        let (multiplier_percent_a, multiplier_percent_b) = past_multiplier_percents<CoinTypeA, CoinTypeB>(epoch);
        ((balance_a * (multiplier_percent_a as u128)) + (balance_b * (multiplier_percent_b as u128))) / 100
    }

    #[view] /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> total supply at a given epoch
    public fun past_total_supply<CoinTypeA, CoinTypeB>(epoch: u64): u128 acquires ComposedVeToken2 {
        let (multiplied_total_supply_a, multiplied_total_supply_b) = past_multiplied_underlying_total_supply<CoinTypeA, CoinTypeB>(epoch);
        (multiplied_total_supply_a + multiplied_total_supply_b) / 100
    }

    #[view]
    /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> total supply at a given epoch
    /// Note it returns total_supply * 100
    public fun past_multiplied_underlying_total_supply<CoinTypeA, CoinTypeB>(epoch: u64): (u128, u128) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        // VeToken<CoinTypeA> Component
        let total_supply_a = vetoken::past_total_supply<CoinTypeA>(epoch);

        // VeToken<CoinTypeB> Component
        let total_supply_b = vetoken::past_total_supply<CoinTypeB>(epoch);

        // Apply Mutlipliers
        let (multiplier_percent_a, multiplier_percent_b) = past_multiplier_percents<CoinTypeA, CoinTypeB>(epoch);
        (total_supply_a * (multiplier_percent_a as u128), total_supply_b * (multiplier_percent_b as u128))
    }

    #[view] /// Return the total amount of `DividendCoin` claimable for two types of underlying VeToken
    public fun claimable<CoinTypeA, CoinTypeB, DividendCoin>(account_addr: address): u64 {
        dividend_distributor::claimable<CoinTypeA, DividendCoin>(account_addr) + dividend_distributor::claimable<CoinTypeB, DividendCoin>(account_addr)
    }

    #[view] /// Check if this coin pair has a `ComposedVeToken2<CoinTypeA, CoinTypeB>` configuration
    public fun initialized<CoinTypeA, CoinTypeB>(): bool {
        exists<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>())
    }

    #[view] /// For frontend use case: we want to know what the balance will be after increasing lock amount / duration
    public fun preview_balance_after_increase<CoinTypeA, CoinTypeB>(account_addr: address, amount_a: u64, increment_epochs_a: u64, amount_b: u64, increment_epochs_b: u64): u128 acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        // VeToken<CoinTypeA> Component
        let balance_a = (vetoken::preview_balance_after_increase<CoinTypeA>(account_addr, amount_a, increment_epochs_a) as u128);

        // VeToken<CoinTypeB> Component
        let balance_b = (vetoken::preview_balance_after_increase<CoinTypeB>(account_addr, amount_b, increment_epochs_b) as u128);

        // Apply Multipliers
        let (multiplier_percent_a, multiplier_percent_b) = multiplier_percents<CoinTypeA, CoinTypeB>();
        ((balance_a * (multiplier_percent_a as u128)) + (balance_b * (multiplier_percent_b as u128))) / 100
    }

    // Internal Helpers

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    #[test_only]
    use vetoken::coin_test;

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    struct FakeCoinA {}

    #[test_only]
    struct FakeCoinB {}

    #[test_only]
    const SECONDS_IN_WEEK: u64 = 7 * 24 * 60 * 60;

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, min_locked_epochs: u64, max_locked_epochs: u64) {
        vetoken::initialize<FakeCoinA>(vetoken, min_locked_epochs, max_locked_epochs, SECONDS_IN_WEEK);
        vetoken::initialize<FakeCoinB>(vetoken, min_locked_epochs, max_locked_epochs, SECONDS_IN_WEEK);

        timestamp::set_time_has_started_for_testing(aptos_framework);
        coin_test::initialize_fake_coin_with_decimals<FakeCoinA>(vetoken, 8);
        coin_test::initialize_fake_coin_with_decimals<FakeCoinB>(vetoken, 8);
    }

    #[test(vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_UNINITIALIZED)]
    fun composable_vetoken_vetoken_both_uninitialized_err(vetoken: &signer) {
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50, true);
    }

    #[test(vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_UNINITIALIZED)]
    fun composable_vetoken_vetoken_cointype_a_uninitialized_err(vetoken: &signer) {
        vetoken::initialize<FakeCoinB>(vetoken, 1, 4, SECONDS_IN_WEEK);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50, true);
    }

    #[test(vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_UNINITIALIZED)]
    fun composable_vetoken_vetoken_cointype_b_uninitialized_err(vetoken: &signer) {
        vetoken::initialize<FakeCoinA>(vetoken, 1, 4, SECONDS_IN_WEEK);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH)]
    fun composable_vetoken_initialize_address_mismatch_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        let account = &account::create_account_for_test(@0xA);
        initialize<FakeCoinA, FakeCoinB>(account, 50, 50, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS)]
    fun composable_vetoken_initialize_cointype_a_invalid_multipliers_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 0, 50, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS)]
    fun composable_vetoken_initialize_cointype_b_invalid_multipliers_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_multiplier_configuration_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        let (mulitplier_a, multiplier_b) = multiplier_percents<FakeCoinA, FakeCoinB>();
        assert!(mulitplier_a == 100, 0);
        assert!(multiplier_b == 50, 0);

        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 33, 67);
        let (multiplier_a, multiplier_b) = multiplier_percents<FakeCoinA, FakeCoinB>();
        assert!(multiplier_a == 33, 0);
        assert!(multiplier_b == 67, 0);

    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_past_multiplier_configuration_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        // Epoch 0 holds no multiplier configuration

        // Epoch 5
        timestamp::fast_forward_seconds(5*vetoken::seconds_in_epoch<FakeCoinA>());
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);
        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 33, 67); // changed in the same epoch

        // Epoch 10
        timestamp::fast_forward_seconds(5*vetoken::seconds_in_epoch<FakeCoinA>());
        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 50, 50);

        // Epoch 20
        timestamp::fast_forward_seconds(10*vetoken::seconds_in_epoch<FakeCoinA>());
        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 80, 20);

        // Epoch [0, 4]
        {
            let (i, end) = (0, 4);
            while (i <= end) {
                let (multiplier_a, multiplier_b) = past_multiplier_percents<FakeCoinA, FakeCoinB>(i);
                assert!(multiplier_a == 0, 0);
                assert!(multiplier_b == 0, 0);
                i = i + 1;
            }
        };

        // Epoch [5, 9]
        {
            let (i, end) = (5, 9);
            while (i <= end) {
                let (multiplier_a, multiplier_b) = past_multiplier_percents<FakeCoinA, FakeCoinB>(i);
                assert!(multiplier_a == 33, 0);
                assert!(multiplier_b == 67, 0);
                i = i + 1;
            }
        };

        // Epoch [10, 19]
        {
            let (i, end) = (10, 19);
            while (i <= end) {
                let (multiplier_a, multiplier_b) = past_multiplier_percents<FakeCoinA, FakeCoinB>(i);
                assert!(multiplier_a == 50, 0);
                assert!(multiplier_b == 50, 0);
                i = i + 1;
            }
        };

        // Epoch [20, 100]
        {
            let (i, end) = (20, 100);
            while (i <= end) {
                let (multiplier_a, multiplier_b) = past_multiplier_percents<FakeCoinA, FakeCoinB>(i);
                assert!(multiplier_a == 80, 0);
                assert!(multiplier_b == 20, 0);
                i = i + 1;
            }
        };
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS)]
    fun composable_vetoken_update_multiplers_cointype_a_invalid_multipliers_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 0, 67);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_MULTIPLIERS)]
    fun composable_vetoken_update_multipliers_cointype_b_invalid_multipliers_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 50, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH)]
    fun composable_vetoken_update_multipliers_coin_address_mismatch_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        let account = &account::create_account_for_test(@0xA);
        update_multipliers<FakeCoinA, FakeCoinB>(account, 50, 100);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_IMMUTABLE_MULTIPLIERS)]
    fun composable_vetoken_update_multipliers_nonmutable_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, false);

        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 50, 100);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_balance_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        // lock the same amounts for both coins
        let account = &account::create_account_for_test(@0xA);
        let preview_balance = preview_balance_after_increase<FakeCoinA, FakeCoinB>(@0xA, 1000, 1, 1000, 1);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 1);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 1);
        assert!(vetoken::balance<FakeCoinA>(@0xA) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(@0xA) == 250, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(@0xA) == 375, 0);
        assert!((balance<FakeCoinA, FakeCoinB>(@0xA) as u128) == preview_balance, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_past_balance_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        // lock the same amounts for both coins
        let account = &account::create_account_for_test(@0xA);
        let preview_balance = preview_balance_after_increase<FakeCoinA, FakeCoinB>(@0xA, 1000, 2, 1000, 2);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 2);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);
        assert!(vetoken::balance<FakeCoinA>(@0xA) == 500, 0);
        assert!(vetoken::balance<FakeCoinB>(@0xA) == 500, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(@0xA) == 750, 0);
        assert!(preview_balance == 750, 0);

        // Move into Epoch 1. Update multipliers such that both balances contribute equally
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 100, 100);

        // Epoch 0 stays the same with old multipliers
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 0) == 750, 0);

        // balances decay in half. Both balances contribute equally. In this Epoch
        assert!(vetoken::balance<FakeCoinA>(@0xA) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(@0xA) == 250, 0);
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 1) == 500, 0);

        // Move into Epoch 2. Balances are unlocked
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        update_multipliers<FakeCoinA, FakeCoinB>(vetoken, 100, 50);

        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 0) == 750, 0);
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 1) == 500, 0);
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 2) == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_differing_lock_period_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        // lock the same amounts for both coins. However `FakeCoinB` has twice as long a lock duration.
        let account = &account::create_account_for_test(@0xA);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 1);
        let preview_balance = preview_balance_after_increase<FakeCoinA, FakeCoinB>(@0xA, 0, 0, 1000, 2);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);
        assert!(vetoken::balance<FakeCoinA>(@0xA) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(@0xA) == 500, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(@0xA) == 500, 0);
        assert!((balance<FakeCoinA, FakeCoinB>(@0xA) as u128) == preview_balance, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_zero_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        let account = &account::create_account_for_test(@0xA);
        vetoken::register<FakeCoinA>(account);
        vetoken::register<FakeCoinB>(account);
        assert!(balance<FakeCoinA, FakeCoinB>(@0xA) == 0, 0);
    }
}
