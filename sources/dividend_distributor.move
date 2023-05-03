/// dividend_distributor module is used to distribute dividend to VeToken<LockCoin> holders.
/// The dividend amount is proportional to the VeToken<LockCoin> balance
/// at the time of distribution.
module vetoken::dividend_distributor {
    use std::signer;

    use aptos_std::smart_table;
    use aptos_std::smart_vector;
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;

    use vetoken::vetoken::{Self, now_epoch};

    #[test_only]
    use test_utils::coin_test;

    const ERR_DIVIDEND_DISTRIBUTOR_UNAUTHORIZED: u64 = 0;

    struct DividendDistributor<phantom LockCoin, phantom DividendCoin> has key {
        dividend: Coin<DividendCoin>,
        records: smart_vector::SmartVector<DividendRecord>,

        /// Track dividend claim for each user
        /// 0xA -> 18 means the user 0xA has claimed records[0 ... 17]
        /// Therefore the next claim should start from records[18]
        next_claimable: smart_table::SmartTable<address, u64>,

        events: DividendDistributorEvents<LockCoin, DividendCoin>
    }

    struct DividendRecord has store {
        timestamp_seconds: u64,
        dividend_amount: u64,
    }

    struct DividendDistributorEvents<phantom LockCoin, phantom DividendCoin> has store {
        distribute_dividend_events: EventHandle<DistributeDividendEvent<LockCoin, DividendCoin>>,
        claim_dividend_events: EventHandle<ClaimDividendEvent<LockCoin, DividendCoin>>
    }

    struct DistributeDividendEvent<phantom LockCoin, phantom DividendCoin> has drop, store {
        distributed_amount: u64,
    }

    struct ClaimDividendEvent<phantom LockCoin, phantom DividendCoin> has drop, store {
        account_addr: address,
        claimed_amount: u64,
    }

    public fun initialize<LockCoin, DividendCoin>(account: &signer) {
        assert!(signer::address_of(account) == @vetoken, ERR_DIVIDEND_DISTRIBUTOR_UNAUTHORIZED);

        move_to(account, DividendDistributor<LockCoin, DividendCoin> {
            dividend: coin::zero(),
            records: smart_vector::empty(),
            next_claimable: smart_table::new(),
            events: DividendDistributorEvents<LockCoin, DividendCoin> {
                distribute_dividend_events: account::new_event_handle<DistributeDividendEvent<LockCoin, DividendCoin>>(
                    account
                ),
                claim_dividend_events: account::new_event_handle<ClaimDividendEvent<LockCoin, DividendCoin>>(account)
            }
        });
    }

    /// Distribute dividend to VeToken<LockCoin> holders
    public fun distribute<LockCoin, DividendCoin>(dividend: Coin<DividendCoin>) acquires DividendDistributor {
        let distributor = borrow_global_mut<DividendDistributor<LockCoin, DividendCoin>>(@vetoken);
        let dividend_amount = coin::value(&dividend);
        coin::merge(&mut distributor.dividend, dividend);

        smart_vector::push_back(&mut distributor.records, DividendRecord {
            timestamp_seconds: timestamp::now_seconds(),
            dividend_amount,
        });

        event::emit_event<DistributeDividendEvent<LockCoin, DividendCoin>>(
            &mut distributor.events.distribute_dividend_events,
            DistributeDividendEvent {
                distributed_amount: dividend_amount,
            }
        );
    }

    /// Claim dividend as a VeToken<LockCoin> holder
    public fun claim<LockCoin, DividendCoin>(account: &signer): Coin<DividendCoin> acquires DividendDistributor {
        let claimable = claimable<LockCoin, DividendCoin>(account);

        let account_addr = signer::address_of(account);
        let distributor = borrow_global_mut<DividendDistributor<LockCoin, DividendCoin>>(@vetoken);
        smart_table::upsert(&mut distributor.next_claimable, account_addr, smart_vector::length(&distributor.records));

        event::emit_event<ClaimDividendEvent<LockCoin, DividendCoin>>(
            &mut distributor.events.claim_dividend_events,
            ClaimDividendEvent {
                account_addr,
                claimed_amount: claimable
            }
        );

        coin::extract(&mut distributor.dividend, claimable)
    }

    #[view]
    /// Claimable dividend as a VeToken<LockCoin> holder.
    /// Only past epochs are claimable, this is b/c holder's weight in the current epoch subjects to changes
    /// through increase_lock_duration or increase_lock_amount.
    public fun claimable<LockCoin, DividendCoin>(account: &signer): u64 acquires DividendDistributor {
        let account_addr = signer::address_of(account);
        let total_claimable = 0;
        let distributor = borrow_global<DividendDistributor<LockCoin, DividendCoin>>(@vetoken);
        let now_epoch = now_epoch<LockCoin>();

        let i = *smart_table::borrow_with_default(&distributor.next_claimable, account_addr, &0);
        let n = smart_vector::length(&distributor.records);
        while (i < n) {
            let record = smart_vector::borrow(&distributor.records, i);
            let epoch = vetoken::seconds_to_epoch<LockCoin>(record.timestamp_seconds);
            if (epoch >= now_epoch) {
                break
            };
            let epoch_balance = vetoken::unnormalized_past_balance<LockCoin>(account_addr, epoch);
            if (epoch_balance == 0) {
                i = i + 1;
                continue
            };

            let epoch_total_supply = vetoken::unnormalized_past_total_supply<LockCoin>(epoch);
            let claimable = (((record.dividend_amount as u128) * epoch_balance / epoch_total_supply) as u64);
            total_claimable = total_claimable + claimable;

            i = i + 1;
        };
        total_claimable
    }

    #[test_only]
    struct FakeLockCoin {}

    #[test_only]
    struct FakeDividendCoin {}

    #[test_only]
    fun initialize_for_test(aptos_framework: &signer, vetoken: &signer, max_duration_epochs: u64) {
        coin_test::initialize_fake_coin<FakeLockCoin>(vetoken);
        coin_test::initialize_fake_coin<FakeDividendCoin>(vetoken);
        vetoken::initialize<FakeLockCoin>(vetoken, max_duration_epochs, 7 * 24 * 60 * 60);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(vetoken));
        initialize<FakeLockCoin, FakeDividendCoin>(vetoken);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun past_epochs_claimable(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 52);

        let user = &account::create_account_for_test(@0xA);
        vetoken::register<FakeLockCoin>(user);

        vetoken::lock(user, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        // cannot claim dividend distributed in the current epoch
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(user) == 0, 0);

        // can claim dividend distributed in the past epochs
        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(user) == 100000000, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun claimable_accumulate_over_epoch(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 52);

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
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 40000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u2) == 160000000, 0);
    }

    #[test(aptos_framework = @aptos_framework, vetoken = @vetoken)]
    fun end_to_end_ok(aptos_framework: &signer, vetoken: &signer) acquires DividendDistributor {
        initialize_for_test(aptos_framework, vetoken, 52);

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
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 100000000, 0);
        let reward_u1_epoch0 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        assert!(coin::value(&reward_u1_epoch0) == 100000000, 0);
        coin_test::burn_coin(vetoken, reward_u1_epoch0);

        // epoch 1
        // (w1, w2, w3) = (0.5, 0.5, 0)
        // distribute 100000000

        vetoken::lock(u2, coin_test::mint_coin<FakeLockCoin>(vetoken, 10000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 50000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u2) == 50000000, 0);
        let reward_u1_epoch1 = claim<FakeLockCoin, FakeDividendCoin>(u1);
        let reward_u2_epoch1 = claim<FakeLockCoin, FakeDividendCoin>(u2);
        assert!(coin::value(&reward_u1_epoch1) == 50000000, 0);
        assert!(coin::value(&reward_u2_epoch1) == 50000000, 0);
        coin_test::burn_coin(vetoken, reward_u1_epoch1);
        coin_test::burn_coin(vetoken, reward_u2_epoch1);

        // epoch 2
        // (w1, w2, w3) = (0.25, 0.25, 0.5)
        // distribute 100000000

        vetoken::lock(u3, coin_test::mint_coin<FakeLockCoin>(vetoken, 20000), 52);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 25000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u2) == 25000000, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u3) == 50000000, 0);
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
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 0, 0);
        let unlocked_u1 = vetoken::unlock<FakeLockCoin>(u1);
        let unlocked_u2 = vetoken::unlock<FakeLockCoin>(u2);
        distribute<FakeLockCoin, FakeDividendCoin>(coin_test::mint_coin<FakeDividendCoin>(vetoken, 100000000));

        timestamp::fast_forward_seconds(vetoken::seconds_in_epoch<FakeLockCoin>());
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u1) == 0, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u2) == 0, 0);
        assert!(claimable<FakeLockCoin, FakeDividendCoin>(u3) == 100000000, 0);
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
