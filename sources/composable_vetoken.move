module vetoken::composable_vetoken {
    use std::signer;

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
    const ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS: u64 = 102;
    const ERR_COMPOSABLE_VETOKEN2_NONMUTABLE_WEIGHTS: u64 = 103;

    ///
    /// Resources
    ///

    struct ComposedVeToken2<phantom CoinTypeA, phantom CoinTypeB> has key {
        weight_percent_coin_a: u128,
        weight_percent_coin_b: u128,
        mutable_weights: bool
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
        move_to(account, ComposedVeToken2<CoinTypeA, CoinTypeB> { weight_percent_coin_a, weight_percent_coin_b, mutable_weights });
    }

    public entry fun update_weights<CoinTypeA, CoinTypeB>(account: &signer, weight_percent_coin_a: u128, weight_percent_coin_b: u128) acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN2_COIN_ADDRESS_MISMATCH);
        assert!(weight_percent_coin_a > 0 && weight_percent_coin_b > 0, ERR_COMPOSABLE_VETOKEN2_INVALID_WEIGHTS); 

        let composable_vetoken = borrow_global_mut<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        assert!(composable_vetoken.mutable_weights, ERR_COMPOSABLE_VETOKEN2_NONMUTABLE_WEIGHTS);

        composable_vetoken.weight_percent_coin_a = weight_percent_coin_a;
        composable_vetoken.weight_percent_coin_b = weight_percent_coin_b;
    }

    #[view] /// Query for the weight configuration
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

    #[view] /// Query for the ComposedVeToken2<CoinTypeA, CoinTypeB> balance of this account at a given epoch
    public fun past_balance<CoinTypeA, CoinTypeB>(account_addr: address, epoch: u64): u128 acquires ComposedVeToken2 {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN2_UNINITIALIZED);
        
        // VeToken<CoinTypeA> Component
        let balance_a = (vetoken::past_balance<CoinTypeA>(account_addr, epoch) as u128);

        // VeToken<CoinTypeB> Component
        let balance_b = (vetoken::past_balance<CoinTypeB>(account_addr, epoch) as u128);

        // Apply Multipliers
        let (weight_percent_coin_a, weight_percent_coin_b) = weight_percents<CoinTypeA, CoinTypeB>();
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

    #[view]
    /// Returns true if the account has either token locked
    public fun has_lock<CoinType>(account_addr: address): bool {
        vetoken::is_account_registered<CoinType>(account_addr) || vetoken::is_account_registered<CoinType>(account_addr)
    }

    #[view]
    /// Return the total amount of `DividendCoin` claimable for two types of underlying VeToken
    public fun claimable<CoinTypeA, CoinTypeB, DividendCoin>(account_addr: address): u64 {
        dividend_distributor::claimable<CoinTypeA, DividendCoin>(account_addr) + dividend_distributor::claimable<CoinTypeB, DividendCoin>(account_addr)
    }

    #[view] /// Check if this coin pair has a `ComposedVeToken2<CoinTypeA, CoinTypeB>` configuration
    public fun initialized<CoinTypeA, CoinTypeB>(): bool {
        exists<ComposedVeToken2<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>())
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
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 1);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 1);
        assert!(vetoken::balance<FakeCoinA>(signer::address_of(account)) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(signer::address_of(account)) == 250, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(signer::address_of(account)) == 375, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_differing_lock_period_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        // lock the same amounts for both coins. However `FakeCoinB` has twice as long a lock duration.
        let account = &account::create_account_for_test(@0xA);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 1);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);
        assert!(vetoken::balance<FakeCoinA>(signer::address_of(account)) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(signer::address_of(account)) == 500, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(signer::address_of(account)) == 500, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_zero_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposedVeToken2 {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50, true);

        let account = &account::create_account_for_test(@0xA);
        vetoken::register<FakeCoinA>(account);
        vetoken::register<FakeCoinB>(account);
        assert!(balance<FakeCoinA, FakeCoinB>(signer::address_of(account)) == 0, 0);
    }
}
