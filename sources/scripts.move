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

    /// If the lock is expired, relock it for `epochs` epochs
    /// Abort with ERR_VETOKEN_CANNOT_UNLOCK in `vetoken::unlock` function
    public entry fun relock<CoinType>(account: &signer, epochs: u64) {
        let unlocked_coin = vetoken::unlock<CoinType>(account);
        vetoken::lock(account, unlocked_coin, epochs);
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

    /// If existing locked position is unlockable, use this function to unlock and then lock again
    /// Warning: This function assumes both tokens have the same lock duration. It may fail if this is not true.
    public entry fun relock_composed<LockCoinA, LockCoinB>(account: &signer, epochs: u64) {
        let account_addr = signer::address_of(account);
        if (vetoken::can_unlock<LockCoinA>(account_addr)) {
            let unlocked_coin = vetoken::unlock<LockCoinA>(account);
            vetoken::lock(account, unlocked_coin, epochs);
        };
        if (vetoken::can_unlock<LockCoinB>(account_addr)) {
            let unlocked_coin = vetoken::unlock<LockCoinB>(account);
            vetoken::lock(account, unlocked_coin, epochs);
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
