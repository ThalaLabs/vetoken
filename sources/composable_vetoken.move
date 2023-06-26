module vetoken::composable_vetoken {
    use std::signer;

    use aptos_std::type_info;
    use aptos_std::math64;

    use vetoken::vetoken;

    ///
    /// Errors
    ///

    const ERR_VETOKEN_UNINITIALIZED: u64 = 0;
    const ERR_COMPOSABLE_VETOKEN_INITIALIZED: u64 = 1;
    const ERR_COMPOSABLE_VETOKEN_UNINITIALIZED: u64 = 2;

    // Composable VeToken Errors
    const ERR_COMPOSABLE_VETOKEN_COIN_ADDRESS_MISMATCH: u64 = 100;
    const ERR_COMPOSABLE_VETOKEN_EPOCH_DURATION_MISMATCH: u64 = 101;
    const ERR_COMPOSABLE_VETOKEN_INVALID_WEIGHTS: u64 = 102;

    ///
    /// Resources
    ///

    struct ComposableVeToken<phantom CoinTypeA, phantom CoinTypeB> has key {
        weight_percent_coin_a: u128,
        weight_percent_coin_b: u128
    }

    /// Create a ComposableVeToken over `CoinTypeA` and `CoinTypeB`. Only `CoinTypeA` is allowed to instantiate
    /// this configuration.
    ///
    /// @param weight_percent_coin_a percent weight `CoinTypeA` contributes to the total balance
    /// @param weight_percent_coin_b percent weight `CoinTypeB` contributes to the total balance
    ///
    /// Note: `ComposableVeToken` does not lock coins seperately from the `vetoken::vetoken` module. Rather `ComposableVetoken`
    /// is a sort-of "view-based" wrapper over `VeToken`.
    public entry fun initialize<CoinTypeA, CoinTypeB>(account: &signer, weight_percent_coin_a: u128, weight_percent_coin_b: u128) {
        assert!(!initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN_INITIALIZED);
        assert!(vetoken::initialized<CoinTypeA>(), ERR_VETOKEN_UNINITIALIZED);
        assert!(vetoken::initialized<CoinTypeB>(), ERR_VETOKEN_UNINITIALIZED);

        // assert composable vetoken configuration
        assert!(vetoken::seconds_in_epoch<CoinTypeA>() == vetoken::seconds_in_epoch<CoinTypeB>(), ERR_COMPOSABLE_VETOKEN_EPOCH_DURATION_MISMATCH);
        assert!(weight_percent_coin_a > 0 && weight_percent_coin_a <= 100, ERR_COMPOSABLE_VETOKEN_INVALID_WEIGHTS); 
        assert!(weight_percent_coin_b > 0 && weight_percent_coin_b <= 100, ERR_COMPOSABLE_VETOKEN_INVALID_WEIGHTS);

        // the owner of the first coin slot controls configuration for this `ComposableVeToken`.
        assert!(account_address<CoinTypeA>() == signer::address_of(account), ERR_COMPOSABLE_VETOKEN_COIN_ADDRESS_MISMATCH);
        move_to(account, ComposableVeToken<CoinTypeA, CoinTypeB> { weight_percent_coin_a, weight_percent_coin_b });
    }

    #[view] /// Query for the ComposableVeToken<CoinTypeA, CoinTypeB> balance of this account
    public fun balance<CoinTypeA, CoinTypeB>(account_addr: address): u128 acquires ComposableVeToken {
        assert!(initialized<CoinTypeA, CoinTypeB>(), ERR_COMPOSABLE_VETOKEN_UNINITIALIZED);
        if (!vetoken::locked<CoinTypeA>(account_addr) || !vetoken::locked<CoinTypeB>(account_addr)) {
            return 0
        };

        // The epochs are the same between `CoinTypeA` & `CoinTypeB` since `initialize` would fail if
        // the epoch durations did not match
        let epoch = vetoken::now_epoch<CoinTypeA>();

        let end_epoch_a = vetoken::unlockable_epoch<CoinTypeA>(account_addr);
        let end_epoch_b = vetoken::unlockable_epoch<CoinTypeB>(account_addr);
        let end_epoch = math64::min(end_epoch_a, end_epoch_b);
        if (epoch >= end_epoch) {
            return 0
        };

        let unnormalized_balance_a = 0u128;
        let unnormalized_balance_b = 0u128;
        while (epoch < end_epoch) {
            // NOTE: If the end epochs differ, the appropriate "strength" factor for the epoch must be used

            let epoch_balance_a = vetoken::unnormalized_past_balance<CoinTypeA>(account_addr, epoch);
            if (end_epoch_a > end_epoch) {
                let old_strength_factor = (end_epoch_a - epoch as u128);
                let new_strength_factor = (end_epoch - epoch as u128);
                epoch_balance_a = new_strength_factor * (epoch_balance_a / old_strength_factor);
            };


            let epoch_balance_b  = vetoken::unnormalized_past_balance<CoinTypeB>(account_addr, epoch);
            if (end_epoch_b > end_epoch) {
                let old_strength_factor = (end_epoch_b - epoch as u128);
                let new_strength_factor = (end_epoch - epoch as u128);
                epoch_balance_b = new_strength_factor * (epoch_balance_b / old_strength_factor);
            };

            unnormalized_balance_a = unnormalized_balance_a + epoch_balance_a;
            unnormalized_balance_b = unnormalized_balance_b + epoch_balance_b;
            epoch = epoch + 1;
        };

        let composable_vetoken = borrow_global<ComposableVeToken<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>());
        unnormalized_balance_a = unnormalized_balance_a * composable_vetoken.weight_percent_coin_a;
        unnormalized_balance_b = unnormalized_balance_b * composable_vetoken.weight_percent_coin_b;

        let unnormalized_balance = (unnormalized_balance_a + unnormalized_balance_b) / 100;
        unnormalized_balance / (vetoken::max_locked_epochs<CoinTypeA>() as u128)
    }

    #[view] /// Check if this coin pair has a `ComposableVeToken<CoinTypeA, CoinTypeB>` configuration
    public fun initialized<CoinTypeA, CoinTypeB>(): bool {
        exists<ComposableVeToken<CoinTypeA, CoinTypeB>>(account_address<CoinTypeA>())
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
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50);
    }

    #[test(vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_UNINITIALIZED)]
    fun composable_vetoken_vetoken_cointype_a_uninitialized_err(vetoken: &signer) {
        vetoken::initialize<FakeCoinB>(vetoken, 1, 4, SECONDS_IN_WEEK);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50);
    }

    #[test(vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_UNINITIALIZED)]
    fun composable_vetoken_vetoken_cointype_b_uninitialized_err(vetoken: &signer) {
        vetoken::initialize<FakeCoinA>(vetoken, 1, 4, SECONDS_IN_WEEK);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 50, 50);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN_COIN_ADDRESS_MISMATCH)]
    fun composable_vetoken_initialize_address_mismatch_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        let account = &account::create_account_for_test(@0xA);
        initialize<FakeCoinA, FakeCoinB>(account, 50, 50);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN_INVALID_WEIGHTS)]
    fun composable_vetoken_initialize_cointype_a_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 0, 50);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_COMPOSABLE_VETOKEN_INVALID_WEIGHTS)]
    fun composable_vetoken_initialize_cointype_b_invalid_weights_err(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 101);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_balance_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposableVeToken {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50);

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
    fun composable_vetoken_min_lock_period_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposableVeToken {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50);

        // lock the same amounts for both coins
        let account = &account::create_account_for_test(@0xA);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 1);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);
        assert!(vetoken::balance<FakeCoinA>(signer::address_of(account)) == 250, 0);
        assert!(vetoken::balance<FakeCoinB>(signer::address_of(account)) == 500, 0);

        // Only half of FakeCoinB contributes to the total balance
        assert!(balance<FakeCoinA, FakeCoinB>(signer::address_of(account)) == 375, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun composable_vetoken_zero_ok(aptos_framework: &signer, vetoken: &signer) acquires ComposableVeToken {
        initialize_for_test(aptos_framework, vetoken, 1, 4);
        initialize<FakeCoinA, FakeCoinB>(vetoken, 100, 50);

        let account = &account::create_account_for_test(@0xA);
        vetoken::register<FakeCoinA>(account);
        vetoken::register<FakeCoinB>(account);
        assert!(balance<FakeCoinA, FakeCoinB>(signer::address_of(account)) == 0, 0);
    }
}
