module vetoken::vetoken {
    use std::signer;

    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::type_info;
    use aptos_std::event::{Self, EventHandle};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::account;

    ///
    /// Errors
    ///

    // Initialization
    const ERR_VETOKEN_INITIALIZED: u64 = 0;
    const ERR_VETOKEN_UNINITIALIZED: u64 = 1;

    // VeToken Errors
    const ERR_VETOKEN_LOCKED: u64 = 2;
    const ERR_VETOKEN_NOT_LOCKED: u64 = 3;
    const ERR_VETOKEN_ZERO_LOCK_AMOUNT: u64 = 4;
    const ERR_VETOKEN_INVALID_LOCK_DURATION: u64 = 5;
    const ERR_VETOKEN_INVALID_EPOCH_DURATION: u64 = 6;
    const ERR_VETOKEN_INVALID_UNLOCKABLE_EPOCH: u64 = 7;
    const ERR_VETOKEN_INVALID_PAST_EPOCH: u64 = 8;
    const ERR_VETOKEN_INVALID_LOCK_INCREASE: u64 = 9;
    const ERR_VETOKEN_CANNOT_UNLOCK: u64 = 10;

    // Delegation Errors
    const ERR_VETOKEN_DELEGATE_UNREGISTERED: u64 = 50;
    const ERR_VETOKEN_DELEGATE_ALREADY_SET: u64 = 51;

    // Other
    const ERR_VETOKEN_ACCOUNT_UNREGISTERED: u64 = 100;
    const ERR_VETOKEN_COIN_ADDRESS_MISMATCH: u64 = 101;
    const ERR_VETOKEN_INTERNAL_ERROR: u64 = 102;

    ///
    /// Resources
    ///

    struct VeToken<phantom CoinType> has store {
        locked: Coin<CoinType>,
        unlockable_epoch: u64,
    }

    struct VeTokenStore<phantom CoinType> has key {
        vetoken: VeToken<CoinType>,

        /// Represents the balance a user has in a given epoch `i`. The value
        /// is represented in an unnormalized format.
        unnormalized_balance: SmartTable<u64, u128>,

        /// The delegate to which the current `vetoken` balance should be attributed to.
        /// Delegated vetokens are not transitive, meaning `delegate_to` cannot re-delegate
        /// to another address. To disable delegating, simply set to the account address.
        delegate_to: address,
    }

    /// This is stored seperately from `VeTokenStore` so we can obtain mutable references
    /// to this resource to update delegations whilst referencing VeTokenStore
    struct VeTokenDelegations<phantom CoinType> has key {
        /// Running total of the balanced delegated to this account per `epoch` key. This
        /// value is unnormalized similar to `unnormalized_total_supply`.
        unnormalized_delegation_balance: SmartTable<u64, u128>
    }

    struct VeTokenInfo<phantom CoinType> has key {
        // ***NOTE*** These values cannot be configurable! Computing balances & supply
        // assumes that the parameters of a VeToken is fixed post-initialization.

        min_locked_epochs: u64,
        max_locked_epochs: u64,
        epoch_duration_seconds: u64,

        /// Stores the total supply for a given epoch i, updated as vetokens are locked. The value
        /// store is "unnormalized" meaning the (1/max_locked_epochs) factor is left out.
        unnormalized_total_supply: SmartTable<u64, u128>,
    }

    struct VeTokenEvents<phantom CoinType> has key, store {  
        lock_events: EventHandle<VeTokenLockEvent<CoinType>>, 
        update_events: EventHandle<VeTokenUpdateEvent<CoinType>>,
        unlock_events: EventHandle<VeTokenUnlockEvent<CoinType>>,  
        delegate_events: EventHandle<VeTokenDelegateEvent<CoinType>>
    }

    struct VeTokenLockEvent<phantom CoinType> has drop, store {  
        epoch: u64,  
        locked_amount: u128,
        locked_epochs: u64,
        unlockable_epoch: u64
    }

    struct VeTokenUpdateEvent<phantom CoinType> has drop, store {  
        epoch: u64,  
        prev_locked_amount: u128,
        locked_amount: u128,
        peviously_unlockable_epoch: u64,
        unlockable_epoch: u64
    }  

    struct VeTokenUnlockEvent<phantom CoinType> has drop, store {  
        epoch: u64,  
        unlocked_amount: u128,
        unlockable_epoch: u64
    }

    struct VeTokenDelegateEvent<phantom CoinType> has drop, store {  
        epoch: u64,  
        delegated_amount: u128,
        unlockable_epoch: u64,
        delegate_from: address,
        delegate_to: address,
    }


    /// Initialize a `VeToken` based on `CoinType`. The parameters set on the VeToken are not changeable after init.
    ///
    /// When setting the min/max epochs for a VeToken, it is important to note that these values must be > 0. This
    /// is because a locked token is forced at least partially observe the epoch it was locked in. Asserted since
    /// a VeToken immediately unlockable holds no balance. Therefore, all locked tokens will observe at a minimum 1 epoch
    /// automatically when locked.
    public entry fun initialize<CoinType>(
        account: &signer,
        min_locked_epochs: u64,
        max_locked_epochs: u64,
        epoch_duration_seconds: u64
    ) {
        assert!(!initialized<CoinType>(), ERR_VETOKEN_INITIALIZED);
        assert!(account_address<CoinType>() == signer::address_of(account), ERR_VETOKEN_COIN_ADDRESS_MISMATCH);
        assert!(max_locked_epochs > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        assert!(min_locked_epochs > 0 && min_locked_epochs <= max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);
        assert!(epoch_duration_seconds > 0, ERR_VETOKEN_INVALID_EPOCH_DURATION);
        move_to(account, VeTokenInfo<CoinType> {
            min_locked_epochs,
            max_locked_epochs,
            epoch_duration_seconds,
            unnormalized_total_supply: smart_table::new(),
        });
        move_to(account, VeTokenEvents<CoinType> {
                lock_events: account::new_event_handle<VeTokenLockEvent<CoinType>>(account),
                update_events: account::new_event_handle<VeTokenUpdateEvent<CoinType>>(account),
                unlock_events: account::new_event_handle<VeTokenUnlockEvent<CoinType>>(account),
                delegate_events: account::new_event_handle<VeTokenDelegateEvent<CoinType>>(account),
            })
    }

    /// Register `account` to be able to hold `VeToken<CoinType>`.
    public entry fun register<CoinType>(account: &signer) {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        move_to(account, VeTokenDelegations<CoinType> { unnormalized_delegation_balance: smart_table::new() });
        move_to(account, VeTokenStore<CoinType> {
            vetoken: VeToken<CoinType> { locked: coin::zero(), unlockable_epoch: 0 },
            unnormalized_balance: smart_table::new(),
            delegate_to: signer::address_of(account),
        });
    }

    /// Lock `CoinType` for `locked_epochs`. Time is referenced in terms of the epoch number in order to keep an accurate
    /// total supply of `VeToken` on an epoch basis. This implies that locked tokens are only eligible to be unlocked
    /// at the start of a new epoch.
    public fun lock<CoinType>(account: &signer, coin: Coin<CoinType>, locked_epochs: u64) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        let account_addr = signer::address_of(account);
        if (!is_account_registered<CoinType>(account_addr)) {
            register<CoinType>(account);
        };

        let amount = (coin::value(&coin) as u128);
        assert!(amount > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);

        let now_epoch = now_epoch<CoinType>();
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(vetoken_info.min_locked_epochs <= locked_epochs
            && vetoken_info.max_locked_epochs >= locked_epochs, ERR_VETOKEN_INVALID_UNLOCKABLE_EPOCH);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(coin::value(&vetoken_store.vetoken.locked) == 0, ERR_VETOKEN_LOCKED);

        let unlockable_epoch = now_epoch + locked_epochs;

        // Update the supply for the epochs this VeToken is locked
        let epoch = now_epoch;
        let delegate = vetoken_store.delegate_to;
        let delegate_store = borrow_global_mut<VeTokenDelegations<CoinType>>(delegate);
        while (epoch < unlockable_epoch) {
            let epochs_till_unlock = (unlockable_epoch - epoch as u128);
            let unnormalized_balance = amount * epochs_till_unlock;

            let total_supply = smart_table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, epoch, 0);
            *total_supply = *total_supply + unnormalized_balance;

            // this will never abort since on `lock`, there is no other entry point for these keys to be populated
            smart_table::add(&mut vetoken_store.unnormalized_balance, epoch, unnormalized_balance);

            let delegate_balance = smart_table::borrow_mut_with_default(&mut delegate_store.unnormalized_delegation_balance, epoch, 0);
            *delegate_balance = *delegate_balance + unnormalized_balance;

            epoch = epoch + 1;
        };

        let event_info = borrow_global_mut<VeTokenEvents<CoinType>>(account_address<CoinType>());
        event::emit_event<VeTokenLockEvent<CoinType>>(
            &mut event_info.lock_events, VeTokenLockEvent {
                epoch: now_epoch,
                locked_amount: amount,
                locked_epochs,
                unlockable_epoch
            }
        );

        // Update the VeToken
        vetoken_store.vetoken.unlockable_epoch = unlockable_epoch;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
    }

    /// Extend the period in which the `VeToken` remains locked
    public entry fun increase_lock_duration<CoinType>(account: &signer, increment_epochs: u64) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        assert!(increment_epochs > 0, ERR_VETOKEN_INVALID_LOCK_DURATION);
        increase_lock_amount_and_duration(account, coin::zero<CoinType>(), increment_epochs);
    }

    /// Extend how much `CoinType` is locked within `VeToken`.
    public fun increase_lock_amount<CoinType>(account: &signer, coin: Coin<CoinType>) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        assert!(coin::value(&coin) > 0, ERR_VETOKEN_ZERO_LOCK_AMOUNT);
        increase_lock_amount_and_duration(account, coin, 0);
    }

    /// Extend both the amount of `CoinType` locked within `VeToken` as well as the lock duration.
    public fun increase_lock_amount_and_duration<CoinType>(account: &signer, coin: Coin<CoinType>, increment_epochs: u64) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let added_amount = (coin::value(&coin) as u128);
        assert!(added_amount > 0 || increment_epochs > 0, ERR_VETOKEN_INVALID_LOCK_INCREASE);

        let now_epoch = now_epoch<CoinType>();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(now_epoch < vetoken_store.vetoken.unlockable_epoch, ERR_VETOKEN_NOT_LOCKED);

        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);

        let old_unlockable_epoch = vetoken_store.vetoken.unlockable_epoch;
        let new_unlockable_epoch = old_unlockable_epoch + increment_epochs;
        let vetoken_info = borrow_global_mut<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(new_unlockable_epoch - now_epoch <= vetoken_info.max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);

        // Update the supply for the applicable epochs.
        let epoch = now_epoch;
        let delegate = vetoken_store.delegate_to;
        let delegate_store = borrow_global_mut<VeTokenDelegations<CoinType>>(delegate);
        while (epoch < new_unlockable_epoch) {
            let epochs_till_unlock = (new_unlockable_epoch - epoch as u128);

            // For epochs the token was already locked prior, an extra `increment_epochs` factor of `locked_amount`
            // is added. For the new epochs or added amounts, the supply is updated as normal (epochs left till unlock)
            let unnormalized_added_balance = {
                if (epoch < old_unlockable_epoch) {
                    (locked_amount * (increment_epochs as u128)) + (added_amount * epochs_till_unlock)
                } else {
                    (locked_amount + added_amount) * epochs_till_unlock
                }
            };

            let balance = smart_table::borrow_mut_with_default(&mut vetoken_store.unnormalized_balance, epoch, 0);
            *balance = *balance + unnormalized_added_balance;

            let delegate_balance = smart_table::borrow_mut_with_default(&mut delegate_store.unnormalized_delegation_balance, epoch, 0);
            *delegate_balance = *delegate_balance + unnormalized_added_balance;

            let total_supply = smart_table::borrow_mut_with_default(&mut vetoken_info.unnormalized_total_supply, epoch, 0);
            *total_supply = *total_supply + unnormalized_added_balance;

            epoch = epoch + 1;
        };

        let event_info = borrow_global_mut<VeTokenEvents<CoinType>>(account_address<CoinType>());
        event::emit_event<VeTokenUpdateEvent<CoinType>>(
            &mut event_info.update_events, VeTokenUpdateEvent {
                epoch: now_epoch,
                prev_locked_amount: locked_amount,
                locked_amount: locked_amount + added_amount,
                peviously_unlockable_epoch: old_unlockable_epoch,
                unlockable_epoch: new_unlockable_epoch
            }
        );

        vetoken_store.vetoken.unlockable_epoch = new_unlockable_epoch;
        coin::merge(&mut vetoken_store.vetoken.locked, coin);
    }

    /// Unlock a `VeToken` that reached `unlockable_epoch`.
    public fun unlock<CoinType>(account: &signer): Coin<CoinType> acquires VeTokenInfo, VeTokenStore, VeTokenEvents {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        assert!(can_unlock<CoinType>(account_addr), ERR_VETOKEN_CANNOT_UNLOCK);

        let epoch = now_epoch<CoinType>();
        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);

        let event_info = borrow_global_mut<VeTokenEvents<CoinType>>(account_address<CoinType>());
        event::emit_event<VeTokenUnlockEvent<CoinType>>(
            &mut event_info.unlock_events, VeTokenUnlockEvent {
                epoch,  
                unlocked_amount: (coin::value(&vetoken_store.vetoken.locked) as u128),
                unlockable_epoch: vetoken_store.vetoken.unlockable_epoch
            }
        );

        // Update the VeToken
        vetoken_store.vetoken.unlockable_epoch = 0;
        coin::extract_all(&mut vetoken_store.vetoken.locked)

        // Note: We dont have to update balance or supply from this epoch onwards since
        // the entire lock duration will have elapsed. No effect on balance/supply
    }

    /// Set the desired delegate. This operation is cheapest on gas when the account does not have any funds locked
    /// since no additional operations are required for delegate balances to be reflected correctly.
    ///
    /// @note in order to disable delgation, simply self-delegate, delegate == address_of(account)
    public fun delegate_to<CoinType>(account: &signer, delegate: address) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        let account_addr = signer::address_of(account);
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);
        assert!(is_account_registered<CoinType>(delegate), ERR_VETOKEN_DELEGATE_UNREGISTERED);

        let vetoken_store = borrow_global_mut<VeTokenStore<CoinType>>(account_addr);
        assert!(delegate != vetoken_store.delegate_to, ERR_VETOKEN_DELEGATE_ALREADY_SET);

        let locked_amount = (coin::value(&vetoken_store.vetoken.locked) as u128);

        // If this account has locked funds (now_epoch < unlockable_epoch), we update the delegate
        // balance amounts. We have to `borrow_global_mut` on every iteration since the compiler will
        // complain about invalids borrows with references still being used for both delegates
        let epoch = now_epoch<CoinType>();
        while (epoch < vetoken_store.vetoken.unlockable_epoch) {
            let epochs_till_unlock = (vetoken_store.vetoken.unlockable_epoch - epoch as u128);
            let unnormalized_balance = locked_amount * epochs_till_unlock;

            // remove from previous delegate
            let delegate_store = borrow_global_mut<VeTokenDelegations<CoinType>>(vetoken_store.delegate_to);
            let old_delegate_balance = smart_table::borrow_mut_with_default(&mut delegate_store.unnormalized_delegation_balance, epoch, 0);
            *old_delegate_balance = *old_delegate_balance - unnormalized_balance;

            // add to new delegate
            let delegate_store = borrow_global_mut<VeTokenDelegations<CoinType>>(delegate);
            let new_delegate_balance = smart_table::borrow_mut_with_default(&mut delegate_store.unnormalized_delegation_balance, epoch, 0);
            *new_delegate_balance = *new_delegate_balance + unnormalized_balance;

            epoch = epoch + 1;
        };

        let event_info = borrow_global_mut<VeTokenEvents<CoinType>>(account_address<CoinType>());

        event::emit_event<VeTokenDelegateEvent<CoinType>>(
            &mut event_info.delegate_events, VeTokenDelegateEvent {
                epoch,  
                delegated_amount: locked_amount,
                unlockable_epoch: vetoken_store.vetoken.unlockable_epoch,
                delegate_from: account_addr,
                delegate_to: delegate,
            }
        );

        // Update VeTokenStore
        vetoken_store.delegate_to = delegate;
    }

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    // Public Getters

    #[view]
    public fun initialized<CoinType>(): bool {
        exists<VeTokenInfo<CoinType>>(account_address<CoinType>())
    }

    #[view]
    public fun is_account_registered<CoinType>(account_addr: address): bool {
        exists<VeTokenStore<CoinType>>(account_addr)
    }

    #[view] /// Returns the total supply of VeToken<CoinType> locked at the supplied epoch
    public fun total_supply<CoinType>(): u128 acquires VeTokenInfo {
        past_total_supply<CoinType>(now_epoch<CoinType>())
    }

    #[view] /// Returns the epoch in which this VeToken is unlockable
    public fun unlockable_epoch<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        assert!(is_account_registered<CoinType>(account_addr), ERR_VETOKEN_ACCOUNT_UNREGISTERED);

        let now_epoch = now_epoch<CoinType>();
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        assert!(vetoken_store.vetoken.unlockable_epoch > now_epoch, ERR_VETOKEN_NOT_LOCKED);

        vetoken_store.vetoken.unlockable_epoch
    }

    #[view] /// Returns the current balance derived by the funds locked by this account
    public fun balance<CoinType>(account_addr: address): u64 acquires VeTokenInfo, VeTokenStore {
        past_balance<CoinType>(account_addr, now_epoch<CoinType>())
    }

    #[view] /// Returns the address this account is actively delegating to
    public fun delegate<CoinType>(account_addr: address): address acquires VeTokenStore {
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        vetoken_store.delegate_to
    }

    #[view] /// Returns the total delegated balance. If self-delegating, the account's balance is also included
    public fun delegated_balance<CoinType>(account_addr: address): u128 acquires VeTokenInfo, VeTokenDelegations {
        past_delegated_balance<CoinType>(account_addr, now_epoch<CoinType>())
    }

    #[view]
    public fun unnormalized_past_total_supply<CoinType>(epoch: u64): u128 acquires VeTokenInfo {
        if (!initialized<CoinType>()) return 0;
        assert!(epoch <= now_epoch<CoinType>(), ERR_VETOKEN_INVALID_PAST_EPOCH);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        *smart_table::borrow_with_default(&vetoken_info.unnormalized_total_supply, epoch, &0)
    }

    #[view]
    public fun past_total_supply<CoinType>(epoch: u64): u128 acquires VeTokenInfo {
        unnormalized_past_total_supply<CoinType>(epoch) / (max_locked_epochs<CoinType>() as u128)
    }

    #[view]
    public fun unnormalized_past_balance<CoinType>(account_addr: address, epoch: u64): u128 acquires VeTokenStore, VeTokenInfo {
        if (!is_account_registered<CoinType>(account_addr)) return 0;
        assert!(epoch <= now_epoch<CoinType>(), ERR_VETOKEN_INVALID_PAST_EPOCH);

        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        *smart_table::borrow_with_default(&vetoken_store.unnormalized_balance, epoch, &0)
    }

    #[view]
    public fun past_balance<CoinType>(account_addr: address, epoch: u64): u64 acquires VeTokenInfo, VeTokenStore {
        let unnormalized = unnormalized_past_balance<CoinType>(account_addr, epoch);
        let max_locked_epochs = (max_locked_epochs<CoinType>() as u128);
        (unnormalized / max_locked_epochs as u64)
    }

    #[view]
    public fun unnormalized_past_delegated_balance<CoinType>(account_addr: address, epoch: u64): u128 acquires VeTokenInfo, VeTokenDelegations {
        if (!is_account_registered<CoinType>(account_addr)) return 0;
        assert!(epoch <= now_epoch<CoinType>(), ERR_VETOKEN_INVALID_PAST_EPOCH);

        let delegate_store = borrow_global<VeTokenDelegations<CoinType>>(account_addr);
        *smart_table::borrow_with_default(&delegate_store.unnormalized_delegation_balance, epoch, &0)
    }

    #[view]
    public fun past_delegated_balance<CoinType>(account_addr: address, epoch: u64): u128 acquires VeTokenInfo, VeTokenDelegations {
        let unnormalized = unnormalized_past_delegated_balance<CoinType>(account_addr, epoch);
        let max_locked_epochs = (max_locked_epochs<CoinType>() as u128);
        unnormalized / max_locked_epochs
    }

    #[view]
    /// Returns the amount of coins locked in the account's VeTokenStore
    public fun locked_coin_amount<CoinType>(account_addr: address): u64 acquires VeTokenStore {
        if (!is_account_registered<CoinType>(account_addr)) return 0;
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        coin::value(&vetoken_store.vetoken.locked)
    }

    #[view]
    /// Returns true if user can unlock their VeToken
    /// Both conditions must be met: (1) non-zero amount is locked (2) unlockable epoch has been reached
    public fun can_unlock<CoinType>(account_addr: address): bool acquires VeTokenInfo, VeTokenStore {
        if (locked_coin_amount<CoinType>(account_addr) == 0) return false;
        let vetoken_store = borrow_global<VeTokenStore<CoinType>>(account_addr);
        vetoken_store.vetoken.unlockable_epoch <= now_epoch<CoinType>()
    }

    #[view]
    public fun now_epoch<CoinType>(): u64 acquires VeTokenInfo {
        seconds_to_epoch<CoinType>(timestamp::now_seconds())
    }

    #[view]
    public fun seconds_to_epoch<CoinType>(time_seconds: u64): u64 acquires VeTokenInfo {
        time_seconds / seconds_in_epoch<CoinType>()
    }

    #[view]
    public fun seconds_in_epoch<CoinType>(): u64 acquires VeTokenInfo {
        assert!(initialized<CoinType>(), ERR_VETOKEN_UNINITIALIZED);

        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        vetoken_info.epoch_duration_seconds
    }

    #[view]
    public fun min_locked_epochs<CoinType>(): u64 acquires VeTokenInfo {
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        vetoken_info.min_locked_epochs
    }

    #[view]
    public fun max_locked_epochs<CoinType>(): u64 acquires VeTokenInfo {
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        vetoken_info.max_locked_epochs
    }

    #[view]
    public fun preview_balance_after_increase<CoinType>(account_addr: address, added_amount: u64, increment_epochs: u64): u64 acquires VeTokenInfo, VeTokenStore {
        // If there's an existing unlockable position, user must unlock before increasing
        assert!(!can_unlock<CoinType>(account_addr), ERR_VETOKEN_NOT_LOCKED);
        let now_epoch = now_epoch<CoinType>();
        let locked_amount = locked_coin_amount<CoinType>(account_addr);
        // If there's no existing lock, it's equivalent to having a locked position of zero amount and unlockable epoch of now_epoch
        let old_unlockable_epoch = if (locked_amount == 0) now_epoch else unlockable_epoch<CoinType>(account_addr);

        let new_unlockable_epoch = old_unlockable_epoch + increment_epochs;
        let vetoken_info = borrow_global<VeTokenInfo<CoinType>>(account_address<CoinType>());
        assert!(new_unlockable_epoch - now_epoch <= vetoken_info.max_locked_epochs, ERR_VETOKEN_INVALID_LOCK_DURATION);

        let new_unnormalized_balance = ((locked_amount + added_amount) as u128) * ((new_unlockable_epoch - now_epoch) as u128);
        let max_locked_epochs = (vetoken_info.max_locked_epochs as u128);
        (new_unnormalized_balance / max_locked_epochs as u64)
    }

    #[test_only]
    use vetoken::coin_test;

    #[test_only]
    struct FakeCoin {}

    #[test_only]
    const SECONDS_IN_WEEK: u64 = 7 * 24 * 60 * 60;

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, min_locked_epochs: u64, max_locked_epochs: u64) {
        account::create_account_for_test(signer::address_of(vetoken));
        initialize<FakeCoin>(vetoken, min_locked_epochs, max_locked_epochs, SECONDS_IN_WEEK);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        coin_test::initialize_fake_coin_with_decimals<FakeCoin>(vetoken, 8);
    }

    #[test]
    #[expected_failure(abort_code = ERR_VETOKEN_COIN_ADDRESS_MISMATCH)]
    fun vetoken_initialize_address_mismatch_err() {
        let account = &account::create_account_for_test(@0xA);
        initialize<FakeCoin>(account, 1, 52, SECONDS_IN_WEEK);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun lock_unlock_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // cannot unlock because nothing is locked
        assert!(!can_unlock<FakeCoin>(@0xA), 0);

        // lock
        let lock_coin = coin_test::mint_coin<FakeCoin>(vetoken, 1000);
        lock(u1, lock_coin, 1);

        // cannot unlock because lock is still active
        assert!(!can_unlock<FakeCoin>(@0xA), 0);

        // unlock (view function flips even if `unlock` isn't explicitly called)
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // can unlock because lock is expired
        assert!(can_unlock<FakeCoin>(@0xA), 0);

        let unlocked = unlock<FakeCoin>(u1);
        assert!(coin::value(&unlocked) == 1000, 0);

        // cleanup
        coin_test::burn_coin(vetoken, unlocked);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun lock_max_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // Including epoch 0, ending in week 52 implies a total of 52 weeks locked
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 52);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_UNLOCKABLE_EPOCH)]
    fun lock_beyond_max_invalid_unlockable_epoch_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // Total of 53 weeks including epoch 0
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 53);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun lock_below_min_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // Including epoch 0, user can unlock in the next epoch with a min 1
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_UNLOCKABLE_EPOCH)]
    fun lock_below_min_invalid_unlockable_epoch_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 2, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // Only locked for total of 1 week (epoch 0) with a min of 2
        assert!(now_epoch<FakeCoin>() == 0, 0);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_CANNOT_UNLOCK)]
    fun early_unlock_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        let lock_coin = coin_test::mint_coin<FakeCoin>(vetoken, 1000);
        lock(u1, lock_coin, 1);

        // early unlock: try to unlock before the epoch ends
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>() - 1);
        coin_test::burn_coin(vetoken, unlock<FakeCoin>(u1));
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun increase_lock_duration_and_preview_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 2);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // extend 2 epochs
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 0, 2);
        increase_lock_duration<FakeCoin>(u1, 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 4 / 5, 0);

        // 3 epochs later, extend 3 more epochs
        timestamp::fast_forward_seconds(3 * seconds_in_epoch<FakeCoin>());
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 0, 3);
        increase_lock_duration<FakeCoin>(u1, 3);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 4 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_LOCK_DURATION)]
    fun increase_lock_duration_invalid_lock_duration_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // invalid
        increase_lock_duration<FakeCoin>(u1, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun increase_lock_amount_and_preview_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 2);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // increase lock amount
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 0);
        increase_lock_amount<FakeCoin>(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 2000 * 2 / 5, 0);

        // 1 epochs later, further increase lock amount
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 0);
        increase_lock_amount<FakeCoin>(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 3000 * 1 / 5, 0); // 1 epoch left till unlock
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_ZERO_LOCK_AMOUNT)]
    fun increase_lock_amount_zero_amount_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // invalid
        increase_lock_amount<FakeCoin>(u1, coin::zero<FakeCoin>());
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun increase_lock_amount_and_duration_and_preview_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 2);
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // double the amount and duration
        let preview_balance = preview_balance_after_increase<FakeCoin>(@0xA, 1000, 1);
        increase_lock_amount_and_duration<FakeCoin>(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == preview_balance, 0);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 2000 * 3 / 5, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    #[expected_failure(abort_code = ERR_VETOKEN_INVALID_LOCK_INCREASE)]
    fun increase_lock_amount_and_duration_invalid_increase_err(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 5);

        let u1 = &account::create_account_for_test(@0xA);
        register<FakeCoin>(u1);

        // lock
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000 * 2 / 5, 0);

        // invalid
        increase_lock_amount_and_duration<FakeCoin>(u1, coin::zero<FakeCoin>(), 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun balance_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 3);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        let u3 = &account::create_account_for_test(@0xC);
        let u4 = &account::create_account_for_test(@0xD);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);
        register<FakeCoin>(u3);
        register<FakeCoin>(u4);

        // no locks
        assert!(total_supply<FakeCoin>() == 0, 0);

        // lock
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        lock(u2, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        lock(u3, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 3);
        lock(u4, coin_test::mint_coin<FakeCoin>(vetoken, 2000), 1);

        // at the beginning
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 1000, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 666, 0);
        assert!(total_supply<FakeCoin>() == 2666, 0);

        // 1 epoch later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 666, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // 2 epochs later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 333, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 333, 0);

        // 3 epochs later
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u3)) == 0, 0);
        assert!(balance<FakeCoin>(signer::address_of(u4)) == 0, 0);
        assert!(total_supply<FakeCoin>() == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun past_balance_and_supply_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        // (1) Returns 0 when there's no locked token at all
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_total_supply<FakeCoin>(0) == 0, 0);

        // new epoch == 1
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        lock(u2, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 1); // 1000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 1); // 2000/4
        assert!(total_supply<FakeCoin>() == 750, 0);

        increase_lock_duration<FakeCoin>(u1, 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0); // 2000/4
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 500, 0); // 2000/4
        assert!(total_supply<FakeCoin>() == 1000, 0);

        // new epoch == 2
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // (3) Persists Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // introduce change in the current epoch for u1. u2 balance decays as expected
        increase_lock_amount(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 250, 0);
        assert!(total_supply<FakeCoin>() == 750, 0);

        // new_epoch == 3
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // (4) Same Epoch (1)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 1) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 1) == 500, 0);
        assert!(past_total_supply<FakeCoin>(1) == 1000, 0);

        // (5) Persists Epoch (2)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 2) == 500, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 2) == 250, 0);
        assert!(past_total_supply<FakeCoin>(2) == 750, 0);

        // new_epoch == 4
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // (6) All balances are expired in Epoch (3)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 3) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 3) == 0, 0);
        assert!(past_total_supply<FakeCoin>(3) == 0, 0);

        // (7) No balance is held in Epoch (0)
        assert!(past_balance<FakeCoin>(signer::address_of(u1), 0) == 0, 0);
        assert!(past_balance<FakeCoin>(signer::address_of(u2), 0) == 0, 0);
        assert!(past_total_supply<FakeCoin>(0) == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun delegate_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);

        // default self-delegate
        assert!(delegate<FakeCoin>(signer::address_of(u1)) == @0xA, 0);
        assert!(delegate<FakeCoin>(signer::address_of(u2)) == @0xB, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 250, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 0, 0);

        // delegate to u2 (u2's balance is still 0)
        delegate_to<FakeCoin>(u1, signer::address_of(u2));
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
        assert!(delegate<FakeCoin>(signer::address_of(u1)) == signer::address_of(u2), 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 250, 0);

        // disable by self-delegating
        delegate_to<FakeCoin>(u1, signer::address_of(u1));
        assert!(delegate<FakeCoin>(@0xA) == signer::address_of(u1), 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 250, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun delegate_nontransitive_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 0);
        assert!(balance<FakeCoin>(signer::address_of(u2)) == 0, 0);

        // Create a cycle
        delegate_to<FakeCoin>(u1, signer::address_of(u2));
        assert!(delegate<FakeCoin>(signer::address_of(u1)) == signer::address_of(u2), 0);

        delegate_to<FakeCoin>(u2, signer::address_of(u1));
        assert!(delegate<FakeCoin>(signer::address_of(u2)) == signer::address_of(u1), 0);

        // 0xB's delegation does nothing as 0xB has no locked tokens
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 250, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun delegate_changes_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 0);

        delegate_to<FakeCoin>(u1, signer::address_of(u2));
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 250, 0);

        // increase lock amount (double). Delegate balance is reactive
        increase_lock_amount(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 500, 0);

        // increase lock duration. Delegate balance is reactive appropriately
        increase_lock_duration<FakeCoin>(u1, 1);
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 1000, 0); // 2000 * 2/4
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 1000, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun past_delegated_balance_ok(aptos_framework: &signer, vetoken: &signer) acquires VeTokenInfo, VeTokenStore, VeTokenDelegations, VeTokenEvents {
        initialize_for_test(aptos_framework, vetoken, 1, 4);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        register<FakeCoin>(u1);
        register<FakeCoin>(u2);

        lock(u1, coin_test::mint_coin<FakeCoin>(vetoken, 1000), 2); // 2 epochs
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 500, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 0, 0);

        // epoch == 1
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());

        // balance decreases from 500 -> 250 after 1 epoch
        delegate_to<FakeCoin>(u1, signer::address_of(u2));
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 250, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u1)) == 0, 0);
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 250, 0);

        // epoch == 2
        timestamp::fast_forward_seconds(seconds_in_epoch<FakeCoin>());
        assert!(balance<FakeCoin>(signer::address_of(u1)) == 0, 0); // tokens are now unlockable
        assert!(delegated_balance<FakeCoin>(signer::address_of(u2)) == 0, 0);

        // Epochs persist
        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u1), 0) == 500, 0);
        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u2), 0) == 0, 0);

        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u1), 1) == 0, 0);
        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u2), 1) == 250, 0);

        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u1), 2) == 0, 0);
        assert!(past_delegated_balance<FakeCoin>(signer::address_of(u2), 2) == 0, 0);
    }
}
