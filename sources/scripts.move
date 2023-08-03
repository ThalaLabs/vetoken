module vetoken::scripts {
    use std::signer;

    use aptos_std::type_info;
    use aptos_framework::coin;

    use vetoken::dividend_distributor;
    use vetoken::vetoken;
    
    /// NullDividend is used to indicate that the dividend coin type is not present
    struct NullDividend {}

    public entry fun lock<CoinType>(account: &signer, amount: u64, epochs: u64) {
        let coin = coin::withdraw<CoinType>(account, amount);
        vetoken::lock(account, coin, epochs);
    }

    public entry fun unlock<CoinType>(account: &signer) {
        let coin = vetoken::unlock<CoinType>(account);
        coin::deposit(signer::address_of(account), coin);
    }

    public entry fun increase_lock_amount<CoinType>(account: &signer, amount: u64) {
        increase_lock_amount_and_duration<CoinType>(account, amount, 0);
    }

    public entry fun increase_lock_amount_and_duration<CoinType>(account: &signer, amount: u64, increment_epochs: u64) {
        let coin = coin::withdraw<CoinType>(account, amount);
        vetoken::increase_lock_amount_and_duration(account, coin, increment_epochs);
    }

    public entry fun claim<LockCoin, DividendCoin>(account: &signer) {
        let dividend = dividend_distributor::claim<LockCoin, DividendCoin>(account);
        let account_addr = signer::address_of(account);
        coin::register<DividendCoin>(account);
        coin::deposit<DividendCoin>(account_addr, dividend);
    }

    public entry fun lock_composed<LockCoinA, LockCoinB>(account: &signer, amount_a: u64, amount_b: u64, epochs: u64) {
        if (amount_a > 0) {
            vetoken::lock(account, coin::withdraw<LockCoinA>(account, amount_a), epochs);
        };
        if (amount_b > 0) {
            vetoken::lock(account, coin::withdraw<LockCoinB>(account, amount_b), epochs);
        };
    }
    
    /// (1) If neither A nor B is registered, do nothing (users should call `lock_composed` instead)
    /// (2) If both A and B are registered, this function assumes two tokens have the same lock duration (which is true if user only interacts with Dapp) 
    /// and increases the lock amount/duration of both tokens
    /// (3) If only one of A and B is registered, this function increases the lock amount/duration of the registered token, and create a new lock for the other token,
    /// with the same lock duration as the registered token
    /// If any of the two tokens is unlockable, this function will abort in the first `increase_lock_amount_and_duration` call of that token. We don't handle such an edge case
    public entry fun increase_lock_amount_and_duration_composed<LockCoinA, LockCoinB>(account: &signer, amount_a: u64, amount_b: u64, increment_epochs: u64) {
        let account_addr = signer::address_of(account);
        let registered_a = vetoken::is_account_registered<LockCoinA>(account_addr);
        let registered_b = vetoken::is_account_registered<LockCoinB>(account_addr);
        let now_epoch = vetoken::now_epoch<LockCoinA>();

        // Handle LockCoinA
        if (registered_a) {
            if (amount_a > 0 || increment_epochs > 0) {
                increase_lock_amount_and_duration<LockCoinA>(account, amount_a, increment_epochs);
            };
        }
        else if (registered_b && amount_a > 0) {
            // A not locked, B is locked, create a new lock for A with the same duration as B
            vetoken::lock(account, coin::withdraw<LockCoinA>(account, amount_a), vetoken::unlockable_epoch<LockCoinB>(account_addr) + increment_epochs - now_epoch);
        };

        // Handle LockCoinB
        if (registered_b) {
            if (amount_b > 0 || increment_epochs > 0) {
                increase_lock_amount_and_duration<LockCoinB>(account, amount_b, increment_epochs);
            };
        }
        else if (registered_a && amount_b > 0) {
            // B not locked, A is locked, create a new lock for B with the same duration as A
            // Current unlockable epoch of A is already updated, so we can use it directly without incrementing
            vetoken::lock(account, coin::withdraw<LockCoinB>(account, amount_b), vetoken::unlockable_epoch<LockCoinA>(account_addr) - now_epoch);
        };
    }

    public entry fun unlock_composed<LockCoinA, LockCoinB>(account: &signer) {
        let account_addr = signer::address_of(account);
        if (vetoken::can_unlock<LockCoinA>(account_addr)) {
            unlock<LockCoinA>(account);
        };
        if (vetoken::can_unlock<LockCoinB>(account_addr)) {
            unlock<LockCoinB>(account);
        };
    }

    public entry fun claim_composed<LockCoinA, LockCoinB, DividendCoin>(account: &signer) {
        let dividend = dividend_distributor::claim<LockCoinA, DividendCoin>(account);
        coin::merge(&mut dividend, dividend_distributor::claim<LockCoinB, DividendCoin>(account));
        let account_addr = signer::address_of(account);
        coin::register<DividendCoin>(account);
        coin::deposit<DividendCoin>(account_addr, dividend);
    }

    /// Claim up to 10 dividend coins in 1 tx
    /// T0 ~ T9 are dividend coin types. Can be `NullDividend` if not present
    public entry fun claim_composed_multi<LockCoinA, LockCoinB, T0, T1, T2, T3, T4, T5, T6, T7, T8, T9>(account: &signer) {
        if (!is_null<T0>()) {
            claim_composed<LockCoinA, LockCoinB, T0>(account);
        };
        if (!is_null<T1>()) {
            claim_composed<LockCoinA, LockCoinB, T1>(account);
        };
        if (!is_null<T2>()) {
            claim_composed<LockCoinA, LockCoinB, T2>(account);
        };
        if (!is_null<T3>()) {
            claim_composed<LockCoinA, LockCoinB, T3>(account);
        };
        if (!is_null<T4>()) {
            claim_composed<LockCoinA, LockCoinB, T4>(account);
        };
        if (!is_null<T5>()) {
            claim_composed<LockCoinA, LockCoinB, T5>(account);
        };
        if (!is_null<T6>()) {
            claim_composed<LockCoinA, LockCoinB, T6>(account);
        };
        if (!is_null<T7>()) {
            claim_composed<LockCoinA, LockCoinB, T7>(account);
        };
        if (!is_null<T8>()) {
            claim_composed<LockCoinA, LockCoinB, T8>(account);
        };
        if (!is_null<T9>()) {
            claim_composed<LockCoinA, LockCoinB, T9>(account);
        };
    }
    
    fun is_null<CoinType>(): bool {
        type_info::type_of<CoinType>() == type_info::type_of<NullDividend>()
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

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun increase_amount_duration_composed_with_existing_both_tokens_ok(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        // lock the same amount and duration for both coins
        let account = &account::create_account_for_test(@0xA);
        coin::register<FakeCoinA>(account);
        coin::register<FakeCoinB>(account);
        coin::deposit(@0xA, coin_test::mint_coin<FakeCoinA>(vetoken, 1000));
        coin::deposit(@0xA, coin_test::mint_coin<FakeCoinB>(vetoken, 1000));
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 2);
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);
        
        increase_lock_amount_and_duration_composed<FakeCoinA, FakeCoinB>(account, 1000, 500, 2);
        assert!(vetoken::locked_coin_amount<FakeCoinA>(@0xA) == 2000, 0);
        assert!(vetoken::locked_coin_amount<FakeCoinB>(@0xA) == 1500, 0);
        assert!(vetoken::unlockable_epoch<FakeCoinA>(@0xA) == 4, 0);
        assert!(vetoken::unlockable_epoch<FakeCoinB>(@0xA) == 4, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun increase_amount_duration_composed_with_existing_one_token_ok(aptos_framework: &signer, vetoken: &signer) {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        // for account @0xA, create lock for coin A only
        let account = &account::create_account_for_test(@0xA);
        coin::register<FakeCoinA>(account);
        coin::register<FakeCoinB>(account);
        coin::deposit(@0xA, coin_test::mint_coin<FakeCoinA>(vetoken, 1000));
        coin::deposit(@0xA, coin_test::mint_coin<FakeCoinB>(vetoken, 1000));
        vetoken::lock(account, coin_test::mint_coin<FakeCoinA>(vetoken, 1000), 2);
        
        increase_lock_amount_and_duration_composed<FakeCoinA, FakeCoinB>(account, 1000, 500, 2);
        assert!(vetoken::locked_coin_amount<FakeCoinA>(@0xA) == 2000, 0); // existing 1000 + new 1000
        assert!(vetoken::locked_coin_amount<FakeCoinB>(@0xA) == 500, 0); // new 500
        assert!(vetoken::unlockable_epoch<FakeCoinA>(@0xA) == 4, 0);
        assert!(vetoken::unlockable_epoch<FakeCoinB>(@0xA) == 4, 0);

        // for account @0xB, create lock for coin B only
        let account = &account::create_account_for_test(@0xB);
        coin::register<FakeCoinA>(account);
        coin::register<FakeCoinB>(account);
        coin::deposit(@0xB, coin_test::mint_coin<FakeCoinA>(vetoken, 1000));
        coin::deposit(@0xB, coin_test::mint_coin<FakeCoinB>(vetoken, 1000));
        vetoken::lock(account, coin_test::mint_coin<FakeCoinB>(vetoken, 1000), 2);

        increase_lock_amount_and_duration_composed<FakeCoinA, FakeCoinB>(account, 1000, 500, 2);
        assert!(vetoken::locked_coin_amount<FakeCoinA>(@0xB) == 1000, 0); // new 1000
        assert!(vetoken::locked_coin_amount<FakeCoinB>(@0xB) == 1500, 0); // existing 1000 + new 500
        assert!(vetoken::unlockable_epoch<FakeCoinA>(@0xB) == 4, 0);
        assert!(vetoken::unlockable_epoch<FakeCoinB>(@0xB) == 4, 0);
    }
}
