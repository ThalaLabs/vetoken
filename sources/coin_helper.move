#[test_only]
module vetoken::coin_helper {
    use aptos_framework::coin::{Self, Coin, BurnCapability, FreezeCapability, MintCapability};
    use std::string;
    use std::signer;

    struct Capabilities<phantom CoinType> has key {
        burn_cap: BurnCapability<CoinType>,
        freeze_cap: FreezeCapability<CoinType>,
        mint_cap: MintCapability<CoinType>
    }

    public fun create_coin_for_test<CoinType>(admin: &signer, name: string::String, symbol: string::String, decimals: u8, monitor_supply: bool) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(
            admin,
            name,
            symbol,
            decimals,
            monitor_supply
        );
        move_to(admin, Capabilities<CoinType> {
            burn_cap,
            freeze_cap,
            mint_cap
        });
    }

    public fun mint_coin_for_test<CoinType>(account: &signer, amount: u64): Coin<CoinType> acquires Capabilities {
        let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(account));
        coin::mint(amount, &caps.mint_cap)
    }

    public fun burn_coin_for_test<CoinType>(account: &signer, coin: Coin<CoinType>) acquires Capabilities {
        let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(account));
        coin::burn(coin, &caps.burn_cap)
    }
}
