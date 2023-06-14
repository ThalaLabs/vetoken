#[test_only]
module vetoken::coin_test {
    use std::signer;
    use std::string;

    use aptos_std::type_info;
    use aptos_framework::coin::{Self, Coin, BurnCapability, MintCapability, FreezeCapability};

    struct Capabilities<phantom CoinType> has key {
        burn_capability: BurnCapability<CoinType>,
        freeze_capability: FreezeCapability<CoinType>,
        mint_capability: MintCapability<CoinType>,
    }

    public fun initialize_fake_coin<CoinType>(account: &signer) {
        initialize_fake_coin_with_decimals<CoinType>(account, 6)
    }

    public fun initialize_fake_coin_with_decimals<CoinType>(account: &signer, decimals: u8) {
        let name = string::utf8(type_info::struct_name(&type_info::type_of<CoinType>()));
        let symbol = string::utf8(b"FAKE");
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(account, name, symbol, decimals, false);
        move_to(account, Capabilities<CoinType> {
            burn_capability: burn_cap,
            freeze_capability: freeze_cap,
            mint_capability: mint_cap
        });
    }

    public fun mint_coin<CoinType>(account: &signer, amount: u64): Coin<CoinType> acquires Capabilities {
        let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(account));
        coin::mint(amount, &caps.mint_capability)
    }

    public fun burn_coin<CoinType>(account: &signer, coin: Coin<CoinType>) acquires Capabilities {
        let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(account));
        if (coin::value(&coin) == 0) coin::destroy_zero(coin) else coin::burn(coin, &caps.burn_capability)
    }

    /// This function is used to deposit a coin into an account. If the account is not registered, it will register the account first.
    public fun deposit_coin<CoinType>(account: &signer, coin: Coin<CoinType>) {
        if (!coin::is_account_registered<CoinType>(signer::address_of(account))) {
            coin::register<CoinType>(account);
        };

        coin::deposit(signer::address_of(account), coin);
    }
}