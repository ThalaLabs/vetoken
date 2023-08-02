module vetoken::scripts {
    use std::signer;

    use aptos_std::type_info;
    use aptos_framework::coin;

    use vetoken::composable_vetoken;
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
        let coin_a = coin::withdraw<LockCoinA>(account, amount_a);
        let coin_b = coin::withdraw<LockCoinB>(account, amount_b);
        composable_vetoken::lock(account, coin_a, coin_b, epochs);
    }
    
    public entry fun increase_lock_amount_and_duration_composed<LockCoinA, LockCoinB>(account: &signer, amount_a: u64, amount_b: u64, increment_epochs: u64) {
        let account_addr = signer::address_of(account);
        if (coin::is_account_registered<LockCoinA>(account_addr)) {
            increase_lock_amount_and_duration<LockCoinA>(account, amount_a, increment_epochs);
        };
        if (coin::is_account_registered<LockCoinB>(account_addr)) {
            increase_lock_amount_and_duration<LockCoinB>(account, amount_b, increment_epochs);
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
}
