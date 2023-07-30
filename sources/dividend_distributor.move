/// dividend_distributor module is used to distribute dividend to VeToken<LockCoin> holders.
/// The dividend amount is proportional to the VeToken<LockCoin> balance
/// at the time of distribution.
module vetoken::dividend_distributor {
    use std::signer;

    use aptos_std::smart_table;
    use aptos_std::smart_vector;
    use aptos_std::type_info;
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;

    use vetoken::vetoken::{Self, now_epoch, seconds_to_epoch};

    #[test_only]
    use vetoken::coin_test;

    const ERR_DIVIDEND_DISTRIBUTOR_UNAUTHORIZED: u64 = 0;
    const ERR_DIVIDEND_DISTRIBUTOR_UNINITIALIZED: u64 = 1;
    const ERR_DIVIDEND_DISTRIBUTOR_ALREADY_INITIALIZED: u64 = 2;

    struct DividendDistributor<phantom LockCoin, phantom DividendCoin> has key {
        /// Total claimable dividend
        dividend: Coin<DividendCoin>,

        /// Track dividend distribution for each epoch
        epoch_dividend: smart_vector::SmartVector<EpochDividend>,

        /// Track dividend claim status for each user
        /// 0xA -> 18 means the user 0xA has claimed records[0...17]
        /// Therefore the next claim should be records[18]
        next_claimable: smart_table::SmartTable<address, u64>,

        distribute_dividend_events: EventHandle<DistributeDividendEvent<LockCoin, DividendCoin>>,
        claim_dividend_events: EventHandle<ClaimDividendEvent<LockCoin, DividendCoin>>
    }

    struct EpochDividend has store {
        epoch: u64,
        /// Accumulated dividend amount in this epoch
        dividend_amount: u64,
    }

    struct DistributeDividendEvent<phantom LockCoin, phantom DividendCoin> has drop, store {
        epoch: u64,
        distributed_amount: u64,
    }

    struct ClaimDividendEvent<phantom LockCoin, phantom DividendCoin> has drop, store {
        account_addr: address,
        /// The event is emitted when the user has claimed dividend up to (including) this epoch
        epoch_until: u64,
        claimed_amount: u64,
    }

    public fun initialize<LockCoin, DividendCoin>(account: &signer) {
        assert!(
            signer::address_of(account) == account_address<LockCoin>(),
            ERR_DIVIDEND_DISTRIBUTOR_UNAUTHORIZED
        );
        assert!(!initialized<LockCoin, DividendCoin>(), ERR_DIVIDEND_DISTRIBUTOR_ALREADY_INITIALIZED);

        move_to(account, DividendDistributor<LockCoin, DividendCoin> {
            dividend: coin::zero(),
            epoch_dividend: smart_vector::empty(),
            next_claimable: smart_table::new(),
            distribute_dividend_events: account::new_event_handle<DistributeDividendEvent<LockCoin, DividendCoin>>(
                account
            ),
            claim_dividend_events: account::new_event_handle<ClaimDividendEvent<LockCoin, DividendCoin>>(account)
        });
    }

    /// Distribute dividend to VeToken<LockCoin> holders
    public fun distribute<LockCoin, DividendCoin>(dividend: Coin<DividendCoin>) acquires DividendDistributor {
        assert!(initialized<LockCoin, DividendCoin>(), ERR_DIVIDEND_DISTRIBUTOR_UNINITIALIZED);

        let distributor = borrow_global_mut<DividendDistributor<LockCoin, DividendCoin>>(account_address<LockCoin>());
        let dividend_amount = coin::value(&dividend);
        coin::merge(&mut distributor.dividend, dividend);

        let epoch = seconds_to_epoch<LockCoin>(timestamp::now_seconds());
        let length = smart_vector::length(&distributor.epoch_dividend);

        // if last record is in the same epoch, merge the dividend amount
        // otherwise, push a new record
        if (length == 0 || smart_vector::borrow(&distributor.epoch_dividend, length - 1).epoch != epoch) {
            smart_vector::push_back(&mut distributor.epoch_dividend, EpochDividend {
                epoch,
                dividend_amount
            });
        } else {
            let epoch_dividend = &mut smart_vector::borrow_mut(&mut distributor.epoch_dividend, length - 1).dividend_amount;
            *epoch_dividend = *epoch_dividend + dividend_amount;
        };

        event::emit_event<DistributeDividendEvent<LockCoin, DividendCoin>>(
            &mut distributor.distribute_dividend_events,
            DistributeDividendEvent {
                epoch,
                distributed_amount: dividend_amount,
            }
        );
    }

    /// Claim dividend as a VeToken<LockCoin> holder
    public fun claim<LockCoin, DividendCoin>(account: &signer): Coin<DividendCoin> acquires DividendDistributor {
        assert!(initialized<LockCoin, DividendCoin>(), ERR_DIVIDEND_DISTRIBUTOR_UNINITIALIZED);

        let account_addr = signer::address_of(account);
        let (claimable, next_claimable_index) = claimable_internal<LockCoin, DividendCoin>(account_addr);

        // there's no dividend distributed yet
        if (next_claimable_index == 0) {
            return coin::zero()
        };

        let distributor = borrow_global_mut<DividendDistributor<LockCoin, DividendCoin>>(account_address<LockCoin>());
        smart_table::upsert(&mut distributor.next_claimable, account_addr, next_claimable_index);
        event::emit_event<ClaimDividendEvent<LockCoin, DividendCoin>>(
            &mut distributor.claim_dividend_events,
            ClaimDividendEvent {
                account_addr,
                epoch_until: smart_vector::borrow(&distributor.epoch_dividend, next_claimable_index - 1).epoch,
                claimed_amount: claimable
            }
        );

        coin::extract(&mut distributor.dividend, claimable)
    }

    #[view]
    public fun initialized<LockCoin, DividendCoin>(): bool {
        exists<DividendDistributor<LockCoin, DividendCoin>>(account_address<LockCoin>())
    }

    #[view]
    /// Claimable dividend as a VeToken<LockCoin> holder.
    public fun claimable<LockCoin, DividendCoin>(account_addr: address): u64 acquires DividendDistributor {
        let (total_claimable, _) = claimable_internal<LockCoin, DividendCoin>(account_addr);
        total_claimable
    }

    fun account_address<Type>(): address {
        let type_info = type_info::type_of<Type>();
        type_info::account_address(&type_info)
    }

    /// Returns (claimable amount, next claimable index)
    /// Claimable dividend as a VeToken<LockCoin> holder.
    /// Only past epochs are claimable, this is b/c holder's weight in the current epoch subjects to changes
    /// through increase_lock_duration or increase_lock_amount.
    fun claimable_internal<LockCoin, DividendCoin>(account_addr: address): (u64, u64) acquires DividendDistributor {
        let total_claimable = 0;
        let distributor = borrow_global<DividendDistributor<LockCoin, DividendCoin>>(account_address<LockCoin>());
        let now_epoch = now_epoch<LockCoin>();

        let i = *smart_table::borrow_with_default(&distributor.next_claimable, account_addr, &0);
        let n = smart_vector::length(&distributor.epoch_dividend);
        while (i < n) {
            let record = smart_vector::borrow(&distributor.epoch_dividend, i);
            // Only past epochs are claimable
            if (record.epoch >= now_epoch) {
                break
            };
            let epoch_balance = vetoken::unnormalized_past_balance<LockCoin>(account_addr, record.epoch);
            if (epoch_balance == 0) {
                i = i + 1;
                continue
            };

            let epoch_total_supply = vetoken::unnormalized_past_total_supply<LockCoin>(record.epoch);
            let claimable = (((record.dividend_amount as u128) * epoch_balance / epoch_total_supply) as u64);
            total_claimable = total_claimable + claimable;

            i = i + 1;
        };

        (total_claimable, i)
    }

    #[test_only]
    struct FakeLockCoin {}

    #[test_only]
    struct FakeDividendCoin {}

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, min_locked_epochs: u64, max_locked_epochs: u64) {
        coin_test::initialize_fake_coin<FakeLockCoin>(vetoken);
        coin_test::initialize_fake_coin<FakeDividendCoin>(vetoken);
        vetoken::initialize<FakeLockCoin>(vetoken, min_locked_epochs, max_locked_epochs, 7 * 24 * 60 * 60);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(vetoken));
        initialize<FakeLockCoin, FakeDividendCoin>(vetoken);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun claim_past_epoch_dividend_ok(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let user = &account::create_account_for_test(@0xA);
        vetoken::register<FakeLockCoin>(user);

        vetoken::lock(user, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        // cannot claim dividend distributed in the current epoch
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 0, 0);

        // can claim dividend distributed in the past epochs
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 100000000, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun claim_current_epoch_dividend_ok(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let user = &account::create_account_for_test(@0xA);
        vetoken::register<FakeLockCoin>(user);
        vetoken::lock(user, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);

        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 0, 0);
        let dividend = claim<FakeLockCoin, FakeDividendCoin>(user);
        assert!(coin::value(&dividend) == 0, 0);
        coin_test::burn_coin(vetoken, dividend);

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 200000000));
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 100000000, 0);
        let dividend = claim<FakeLockCoin, FakeDividendCoin>(user);
        assert!(coin::value(&dividend) == 100000000, 0);
        coin_test::burn_coin(vetoken, dividend);

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        let dividend = claim<FakeLockCoin, FakeDividendCoin>(user);
        assert!(coin::value(&dividend) == 200000000, 0);
        coin_test::burn_coin(vetoken, dividend);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun claimable_accumulate_over_epoch(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        vetoken::register<FakeLockCoin>(u1);
        vetoken::register<FakeLockCoin>(u2);

        // epoch 0
        vetoken::lock(u1, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);
        vetoken::lock(u2, coin_test::mint_coin<FakeLockCoin>(vetoken, 40000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        // epoch 1
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        // can claim dividend distributed in the past epochs
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 40000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xB) == 160000000, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun end_to_end_ok(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 1, 52);

        let u1 = &account::create_account_for_test(@0xA);
        let u2 = &account::create_account_for_test(@0xB);
        let u3 = &account::create_account_for_test(@0xC);
        vetoken::register<FakeLockCoin>(u1);
        vetoken::register<FakeLockCoin>(u2);
        vetoken::register<FakeLockCoin>(u3);

        // epoch 0
        // (w1, w2, w3) = (1, 0, 0)
        // distribute 100000000
        vetoken::lock(u1, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 100000000, 0);
        let reward_u1_epoch0 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        assert!(coin::value(&reward_u1_epoch0) == 100000000, 0);
        coin_test::burn_coin(vetoken, reward_u1_epoch0);

        // epoch 1
        // (w1, w2, w3) = (0.5, 0.5, 0)
        // distribute 100000000

        vetoken::lock(u2, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 51);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 50000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xB) == 50000000, 0);
        let reward_u1_epoch1 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        let reward_u2_epoch1 = claim<FakeLockCoin, FakeDividendCoin>(u2);
        assert!(coin::value(&reward_u1_epoch1) == 50000000, 0);
        assert!(coin::value(&reward_u2_epoch1) == 50000000, 0);
        coin_test::burn_coin(vetoken, reward_u1_epoch1);
        coin_test::burn_coin(vetoken, reward_u2_epoch1);

        // epoch 2
        // (w1, w2, w3) = (0.25, 0.25, 0.5)
        // distribute 100000000

        vetoken::lock(u3, coin_test::mint_coin<FakeLockCoin>(vetoken, 20000), 50);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 25000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xB) == 25000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xC) == 50000000, 0);
        let reward_u1_epoch2 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        let reward_u2_epoch2 = claim<FakeLockCoin, FakeDividendCoin>(u2);
        let reward_u3_epoch2 = claim<FakeLockCoin, FakeDividendCoin>(u3);
        assert!(coin::value(&reward_u1_epoch2) == 25000000, 0);
        assert!(coin::value(&reward_u2_epoch2) == 25000000, 0);
        assert!(coin::value(&reward_u3_epoch2) == 50000000, 0);
        coin_test::burn_coin(vetoken, reward_u1_epoch2);
        coin_test::burn_coin(vetoken, reward_u2_epoch2);
        coin_test::burn_coin(vetoken, reward_u3_epoch2);

        // epoch 52
        // (w1, w2, w3) = (0, 0, 1)
        // distribute 100000000

        timestamp::fast_forward_seconds(48 * vetoken::seconds_in_epoch<FakeLockCoin>());
        vetoken::increase_lock_duration<FakeLockCoin>(u3, 1);

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 0, 0);
        let unlocked_u1 = vetoken::unlock<FakeLockCoin>(u1);
        let unlocked_u2 = vetoken::unlock<FakeLockCoin>(u2);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xA) == 0, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xB) == 0, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(@0xC) == 100000000, 0);
        let reward_u1_epoch52 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        let reward_u2_epoch52 = claim<FakeLockCoin, FakeDividendCoin>(u2);
        let reward_u3_epoch52 = claim<FakeLockCoin, FakeDividendCoin>(u3);
        assert!(coin::value(&reward_u1_epoch52) == 0, 0);
        assert!(coin::value(&reward_u2_epoch52) == 0, 0);
        assert!(coin::value(&reward_u3_epoch52) == 100000000, 0);

        coin_test::burn_coin(vetoken, reward_u1_epoch52);
        coin_test::burn_coin(vetoken, reward_u2_epoch52);
        coin_test::burn_coin(vetoken, reward_u3_epoch52);
        coin_test::burn_coin(vetoken, unlocked_u1);
        coin_test::burn_coin(vetoken, unlocked_u2);
    }
}
