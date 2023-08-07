module vetoken::composable_vetoken {
    use std::signer;
    use std::vector;

    use aptos_std::type_info;
    use aptos_framework::coin::Coin;

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
    const ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS: u64 = 102;
    const ERR_COMPOSABLE_VETOKEN2_NONMUTABLE_WEIGHTS: u64 = 103;
    const ERR_COMPOSABLE_VETOKEN2_INVALID_EPOCH: u64 = 104;

    ///
    /// Resources
    ///

    struct WeightSnapshot<phantom CoinTypeA, phantom CoinTypeB> has store {
        weight_percent_coin_a: u128,
        weight_percent_coin_b: u128,
        epoch: u64,
    }

    struct ComposedVeToken2<phantom CoinTypeA, phantom CoinTypeB> has key {
        weight_percent_coin_a: u128,
        weight_percent_coin_b: u128,
        mutable_weights: bool,

        weight_snapshots: vector<WeightSnapshot<CoinTypeA, CoinTypeB>>,
    }

    /// Create a ComposedVeToken2 over `CoinTypeA` and `CoinTypeB`. Only `CoinTypeA` is allowed to instantiate
    /// this configuration.
    ///
    /// @param weight_percent_coin_a percent weight `CoinTypeA` contributes to the total balance
    /// @param weight_percent_coin_b percent weight `CoinTypeB` contributes to the total balance
    /// @param mutable_weights indicator if the weight configuration can change post-initialization. Depending on the implementation,
    ///                        this is prone to centralization risk.
    ///
    /// Note: `ComposedVeToken2` does not lock coins seperately from the `vetoken::vetoken` module. Rather `ComposedVeToken2`
    /// is a sort-of "view-based" wrapper over `VeToken`.
    public entry fun initialize<CoinTypeA, CoinTypeB>(account: &signer, weight_percent_coin_a: u128, weight_percent_coin_b: u128, mutable_weights: bool) {
        assert!(!initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_INITIALIZED);
        assert!(vetoken::initialized<CoinTypeA>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(vetoken::initialized<CoinTypeB>(), ERR_VETOKEN_UNINITIALIZED);

        // assert composable vetoken configuration
        assert!(vetoken::seconds_in_epoch<CoinTypeA>() == vetoken::seconds_in_epoch<CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_EPOCH_DURATION_MISMATCH);
        assert!(weight_percent_coin_a > 0 && weight_percent_coin_b > 0, ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS); 

        // the owner of the first coin slot controls configuration for this `ComposedVeToken2`.
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH);

        let weight_snapshots = vector[WeightSnapshot<CoinTypeA, CoinTypeB>{weight_percent_coin_a, weight_percent_coin_b, epoch: vetoken::now_epoch<CoinTypeA>()}];
        move_to(account, ComposedVeToken2<CoinTypeA, CoinTypeB> { weight_percent_coin_a, weight_percent_coin_b, mutable_weights, weight_snapshots });
    }

    public entry fun update_weights<CoinTypeA, CoinTypeB>(account: &signer, weight_percent_coin_a: u128, weight_percent_coin_b: u128) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH);
        assert!(weight_percent_coin_a > 0 && weight_percent_coin_b > 0, ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS); 

        let composable_vetoken = borrow_global_mut<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        assert!(composable_vetoken.mutable_weights, ERR_COMPOSABLE_VETOKEN2_NONMUTABLE_WEIGHTS);

        let now_epoch = vetoken::now_epoch<CoinTypeA>();
        let num_snapshots = vector::length(&composable_vetoken.weight_snapshots);
        let last_snapshot = vector::borrow_mut(&mut composable_vetoken.weight_snapshots, num_snapshots - 1);
        if (last_snapshot.epoch == now_epoch) {
            last_snapshot.weight_percent_coin_a = weight_percent_coin_a;
            last_snapshot.weight_percent_coin_b = weight_percent_coin_b;
        } else {
            let weights = WeightSnapshot<CoinTypeA, CoinTypeB>{weight_percent_coin_a, weight_percent_coin_b, epoch: now_epoch};
            vector::push_back(&mut composable_vetoken.weight_snapshots, weights);
        };

        composable_vetoken.weight_percent_coin_a = weight_percent_coin_a;
        composable_vetoken.weight_percent_coin_b = weight_percent_coin_b;
    }

    /// Lock two tokens for the `ComposedVeToken2` configuration.
    public fun lock<CoinTypeA, CoinTypeB>(account: &signer, coin_a: Coin<CoinTypeA>, coin_b: Coin<CoinTypeB>, locked_epochs: u64) {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        vetoken::lock(account, coin_a, locked_epochs);
        vetoken::lock(account, coin_b, locked_epochs);
    }

    #[view] /// Query for the current weight configuration
    public fun weight_percents<CoinTypeA, CoinTypeB>(): (u128, u128) acquires ComposedVeToken2 {
        let composable_vetoken = borrow_global<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        (composable_vetoken.weight_percent_coin_a, composable_vetoken.weight_percent_coin_b)
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
    public fun weighted_underlying_total_supply<CoinTypeA, CoinTypeB>(): (u128, u128) acquires ComposedVeToken2 {
        // The epochs are the same between `CoinTypeA` & `CoinTypeB` since `initialize`
        // would fail if the epoch durations did not match
        past_weighted_underlying_total_supply<CoinTypeA, CoinTypeB>(vetoken::now_epoch<CoinTypeA>())
    }

    #[view] /// Query for the latest weight configuration at a given epoch
    public fun past_weight_percents<CoinTypeA, CoinTypeB>(epoch: u64): (u128, u128) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        let composable_vetoken = borrow_global<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        let snapshots = &composable_vetoken.weight_snapshots;
        let num_snapshots = vector::length(snapshots);

        // Check if the latest snapshot suffices
        let snapshot = vector::borrow(snapshots, num_snapshots - 1);
        if (epoch == snapshot.epoch) return (snapshot.weight_percent_coin_a, snapshot.weight_percent_coin_b);

        // Check if the first snapshot sufficies or the supplied epoch is too far in the past
        let snapshot = vector::borrow(snapshots, 0);
        if (epoch < snapshot.epoch) return (0, 0)
        else if (epoch == snapshot.epoch) return (snapshot.weight_percent_coin_a, snapshot.weight_percent_coin_b);

        // Binary search a snapshot where the epoch is the highest behind the target epoch. The checks
        // before reaching this search ensures that the supplied epoch is in range of [low, hi]
        //
        // NOTE: If we reach the terminating condition, low >= hi, then that indicates the index
        // (low - 1) is the right snapshot with the highest epoch below the target
        let low = 0;
        let high = num_snapshots - 1;
        while (low < high) {
            let mid = (low + high) / 2;
            snapshot = vector::borrow(snapshots, mid);

            // return early if we find an exact epoch
            if (epoch == snapshot.epoch) return (snapshot.weight_percent_coin_a, snapshot.weight_percent_coin_b);

            if (epoch > snapshot.epoch) low = mid + 1
            else high = mid
        };

        snapshot = vector::borrow(snapshots, low - 1);
        return (snapshot.weight_percent_coin_a, snapshot.weight_percent_coin_b)
    }

    #[view] /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> balance of this account at a given epoch
    public fun past_balance<CoinTypeA, CoinTypeB>(account_addr: address, epoch: u64): u128 acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        // VeToken<CoinTypeA> Component
        let balance_a = (vetoken::past_balance<CoinTypeA>(account_addr, epoch) as u128);

        // VeToken<CoinTypeB> Component
        let balance_b = (vetoken::past_balance<CoinTypeB>(account_addr, epoch) as u128);

        // Apply Multipliers
        let (weight_percent_coin_a, weight_percent_coin_b) = past_weight_percents<CoinTypeA, CoinTypeB>(epoch);
        ((balance_a * weight_percent_coin_a) + (balance_b * weight_percent_coin_b)) / 100
    }

    #[view] /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> total supply at a given epoch
    public fun past_total_supply<CoinTypeA, CoinTypeB>(epoch: u64): u128 acquires ComposedVeToken2 {
        let (weighted_total_supply_a, weighted_total_supply_b) = past_weighted_underlying_total_supply<CoinTypeA, CoinTypeB>(epoch);
        (weighted_total_supply_a + weighted_total_supply_b) / 100
    }

    #[view]
    /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> total supply at a given epoch
    /// Note it returns total_supply * 100
    public fun past_weighted_underlying_total_supply<CoinTypeA, CoinTypeB>(epoch: u64): (u128, u128) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);

        // VeToken<CoinTypeA> Component
        let total_supply_a = vetoken::past_total_supply<CoinTypeA>(epoch);

        // VeToken<CoinTypeB> Component
        let total_supply_b = vetoken::past_total_supply<CoinTypeB>(epoch);

        // Apply Mutlipliers
        let (weight_percent_coin_a, weight_percent_coin_b) = weight_percents<CoinTypeA, CoinTypeB>();
        (total_supply_a * weight_percent_coin_a, total_supply_b * weight_percent_coin_b)
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
        let (weight_percent_coin_a, weight_percent_coin_b) = weight_percents<CoinTypeA, CoinTypeB>();
        ((balance_a * weight_percent_coin_a) + (balance_b * weight_percent_coin_b)) / 100
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
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS)]
    fun composable_vetoken_initialize_cointype_a_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 0, 50, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS)]
    fun composable_vetoken_initialize_cointype_b_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_weight_configuration_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        let (weight_a, weight_b) = weight_percents<FakeCoinA, FakeCoinB>();
        assert!(weight_a == 100, 0);
        assert!(weight_b == 50, 0);

        update_weights<FakeCoinA, FakeCoinB>(vetoken, 33, 67);
        let (weight_a, weight_b) = weight_percents<FakeCoinA, FakeCoinB>();
        assert!(weight_a == 33, 0);
        assert!(weight_b == 67, 0);

    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_past_weight_configuration_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        // Epoch 0 holds no weight configuration
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        // Epoch 1
        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(0);
        assert!(weight_a == 0, 0);
        assert!(weight_b == 0, 0);

        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(1);
        assert!(weight_a == 100, 0);
        assert!(weight_b == 50, 0);

        update_weights<FakeCoinA, FakeCoinB>(vetoken, 33, 67);
        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(1);
        assert!(weight_a == 33, 0);
        assert!(weight_b == 67, 0);

        // Epoch 2
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        update_weights<FakeCoinA, FakeCoinB>(vetoken, 50, 50);

        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(0);
        assert!(weight_a == 0, 0);
        assert!(weight_b == 0, 0);

        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(1);
        assert!(weight_a == 33, 0);
        assert!(weight_b == 67, 0);

        let (weight_a, weight_b) = past_weight_percents<FakeCoinA, FakeCoinB>(2);
        assert!(weight_a == 50, 0);
        assert!(weight_b == 50, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS)]
    fun composable_vetoken_update_weights_cointype_a_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        update_weights<FakeCoinA, FakeCoinB>(vetoken, 0, 67);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS)]
    fun composable_vetoken_update_weights_cointype_b_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        update_weights<FakeCoinA, FakeCoinB>(vetoken, 50, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH)]
    fun composable_vetoken_update_weights_coin_address_mismatch_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, true);

        let account = &account::create_account_for_test(@0xA);
        update_weights<FakeCoinA, FakeCoinB>(account, 50, 100);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN2_NONMUTABLE_WEIGHTS)]
    fun composable_vetoken_update_weights_nonmutable_err(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 150, 100, false);

        update_weights<FakeCoinA, FakeCoinB>(vetoken, 50, 100);
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

        // Move into Epoch 1. Update weights such that both balances contribute equally
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        update_weights<FakeCoinA, FakeCoinB>(vetoken, 100, 100);

        // Epoch 0 stays the same with old weights
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 0) == 750, 0);

        // balances decay in half. Both balances contribute equally. In this Epoch
        assert!(vetoken::balance<FakeCoinA>(@0xA) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(@0xA) == 250, 0);
        assert!(past_balance<FakeCoinA, FakeCoinB>(@0xA, 1) == 500, 0);

        // Move into Epoch 2. Balances are unlocked
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeCoinA>());
        update_weights<FakeCoinA, FakeCoinB>(vetoken, 100, 50);

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
