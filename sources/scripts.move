module vetoken::scripts {
    use std::signer;

    use aptos_framework::coin;

    use vetoken::dividend_distributor;
    use vetoken::vetoken;

    public entry fun lock<CoinType>(account: &signer, amount: u64, epochs: u64) {
        let coin = coin::withdraw<CoinType>(account, amount);
        vetoken::lock(account, coin, epochs);
    }

    public entry fun unlock<CoinType>(account: &signer) {
        let coin = vetoken::unlock<CoinType>(account);
        coin::deposit<CoinType>(signer::address_of(account), coin);
    }

    public entry fun increase_lock_amount<CoinType>(account: &signer, amount: u64) {
        let coin = coin::withdraw<CoinType>(account, amount);
        vetoken::increase_lock_amount<CoinType>(account, coin);
    }

    public entry fun claim<LockCoin, DividendCoin>(account: &signer) {
        let dividend = dividend_distributor::claim<LockCoin, DividendCoin>(account);
        let account_addr = signer::address_of(account);
        if (!coin::is_account_registered<DividendCoin>(account_addr)) {
            coin::register<DividendCoin>(account);
        };
        coin::deposit<DividendCoin>(account_addr, dividend);
    }
}
