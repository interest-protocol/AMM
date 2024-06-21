module amm::interest_protocol_amm {
    // === Imports ===
  
    use std::{
        ascii,
        string,
        type_name::{Self, TypeName}
    };

    use sui::{
        math::pow,
        dynamic_field as df,
        table::{Self, Table},
        transfer::share_object,
        balance::{Self, Balance},
        coin::{Self, Coin, CoinMetadata, TreasuryCap}
    };

    use suitears::{
        math64::{min, mul_div_down},
        math256::{sqrt_down, mul_div_up}
    }; 

    use amm::{
        utils,
        errors,
        events,
        stable,
        volatile,
        admin::Admin,
        fees::{Self, Fees},
        curves::{Self, Volatile, Stable}
    };

    // === Constants ===

    const PRECISION: u256 = 1_000_000_000_000_000_000;
    const MINIMUM_LIQUIDITY: u64 = 100;
    const INITIAL_STABLE_FEE_PERCENT: u256 = 250_000_000_000_000; // 0.025%
    const INITIAL_VOLATILE_FEE_PERCENT: u256 = 3_000_000_000_000_000; // 0.3%
    const INITIAL_ADMIN_FEE: u256 = 200_000_000_000_000_000; // 20%
    const FLASH_LOAN_FEE_PERCENT: u256 = 5_000_000_000_000_000; //0.5% 

    // === Structs ===

    public struct Registry has key {
        id: UID,
        pools: Table<TypeName, address>,
        lp_coins: Table<TypeName, address>
    }
  
    public struct InterestPool has key {
        id: UID 
    }

    public struct RegistryKey<phantom Curve, phantom CoinX, phantom CoinY> has drop {}

    public struct PoolStateKey has drop, copy, store {}

    public struct PoolState<phantom CoinX, phantom CoinY, phantom LpCoin> has store {
        lp_coin_cap: TreasuryCap<LpCoin>,
        balance_x: Balance<CoinX>,
        balance_y: Balance<CoinY>,
        decimals_x: u64,
        decimals_y: u64,
        admin_balance_x: Balance<CoinX>,
        admin_balance_y: Balance<CoinY>,
        seed_liquidity: Balance<LpCoin>,
        admin_lp_coin_balance: Balance<LpCoin>,
        fees: Fees,
        volatile: bool,
        locked: bool     
    } 

    public struct SwapAmount has store, drop, copy {
        amount_out: u64,
        admin_fee_in: u64,
        admin_fee_out: u64,
        standard_fee_in: u64,
        standard_fee_out: u64,
    }

    public struct Invoice {
        pool_address: address,
        repay_amount_x: u64,
        repay_amount_y: u64,
        prev_k: u256
    }

    // === Public-Mutative Functions ===

    #[allow(unused_function)]
    fun init(ctx: &mut TxContext) {
        share_object(
            Registry {
                id: object::new(ctx),
                pools: table::new(ctx),
                lp_coins: table::new(ctx)
            }
        );
    }  

    // === DEX ===

    #[lint_allow(share_owned)]
    public fun new<CoinX, CoinY, LpCoin>(
        registry: &mut Registry,
        coin_x: Coin<CoinX>,
        coin_y: Coin<CoinY>,
        lp_coin_cap: TreasuryCap<LpCoin>,
        coin_x_metadata: &CoinMetadata<CoinX>,
        coin_y_metadata: &CoinMetadata<CoinY>,  
        lp_coin_metadata: &mut CoinMetadata<LpCoin>,
        volatile: bool,
        ctx: &mut TxContext    
    ): Coin<LpCoin> {
        utils::assert_lp_coin_integrity<CoinX, CoinY, LpCoin>(lp_coin_metadata, volatile);
    
        lp_coin_cap.update_name(lp_coin_metadata, utils::get_lp_coin_name(coin_x_metadata, coin_y_metadata, volatile));
        lp_coin_cap.update_symbol(lp_coin_metadata, utils::get_lp_coin_symbol(coin_x_metadata, coin_y_metadata, volatile));

        let decimals_x = pow(10, coin_x_metadata.get_decimals());
        let decimals_y = pow(10, coin_y_metadata.get_decimals());

        if (volatile)
            new_pool_internal<Volatile, CoinX, CoinY, LpCoin>(registry, coin_x, coin_y, lp_coin_cap, decimals_x, decimals_y, true, ctx)
        else 
            new_pool_internal<Stable, CoinX, CoinY, LpCoin>(registry, coin_x, coin_y, lp_coin_cap, decimals_x, decimals_y, false, ctx)
    }

    public fun swap<CoinIn, CoinOut, LpCoin>(
        pool: &mut InterestPool, 
        coin_in: Coin<CoinIn>,
        coin_min_value: u64,
        ctx: &mut TxContext    
    ): Coin<CoinOut> {
        assert!(coin_in.value() != 0, errors::no_zero_coin());

        if (utils::is_coin_x<CoinIn, CoinOut>()) 
            swap_coin_x<CoinIn, CoinOut, LpCoin>(pool, coin_in, coin_min_value, ctx)
        else 
            swap_coin_y<CoinOut, CoinIn, LpCoin>(pool, coin_in, coin_min_value, ctx)
    }

    public fun add_liquidity<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        mut coin_x: Coin<CoinX>,
        mut coin_y: Coin<CoinY>,
        lp_coin_min_amount: u64,
        ctx: &mut TxContext 
    ): (Coin<LpCoin>, Coin<CoinX>, Coin<CoinY>) {
        let coin_x_value = coin_x.value();
        let coin_y_value = coin_y.value();       

        assert!(coin_x_value != 0 && coin_y_value != 0, errors::provide_both_coins());

        let pool_address = pool.id.uid_to_address();
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);
        assert!(!pool_state.locked, errors::pool_is_locked());

        let (balance_x, balance_y, lp_coin_supply) = amounts(pool_state);

        let (optimal_x_amount, optimal_y_amount) = utils::get_optimal_add_liquidity(
            coin_x_value,
            coin_y_value,
            balance_x,
            balance_y
        );   

        let extra_x = if (coin_x_value > optimal_x_amount) coin_x.split(coin_x_value - optimal_x_amount, ctx) else coin::zero<CoinX>(ctx); 
        let extra_y = if (coin_y_value > optimal_y_amount) coin_y.split(coin_y_value - optimal_y_amount, ctx) else coin::zero<CoinY>(ctx); 

        // round down to give the protocol an edge
        let shares_to_mint = min(
            mul_div_down(coin_x.value(), lp_coin_supply, balance_x),
            mul_div_down(coin_y.value(), lp_coin_supply, balance_y)
        );

        assert!(shares_to_mint >= lp_coin_min_amount, errors::slippage());

        pool_state.balance_x.join(coin_x.into_balance());
        pool_state.balance_y.join(coin_y.into_balance());

        events::add_liquidity<CoinX, CoinY>(pool_address, optimal_x_amount, optimal_y_amount, shares_to_mint);

        (pool_state.lp_coin_cap.supply_mut().increase_supply(shares_to_mint).into_coin(ctx), extra_x, extra_y)
    }

    public fun remove_liquidity<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        lp_coin: Coin<LpCoin>,
        coin_x_min_amount: u64,
        coin_y_min_amount: u64,
        ctx: &mut TxContext
    ): (Coin<CoinX>, Coin<CoinY>) {
        let lp_coin_value = lp_coin.value();

        assert!(lp_coin_value != 0, errors::no_zero_coin());
    
        let pool_address = pool.id.uid_to_address();
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);
        assert!(!pool_state.locked, errors::pool_is_locked());

        let (balance_x, balance_y, lp_coin_supply) = amounts(pool_state);

        let coin_x_removed = mul_div_down(lp_coin_value, balance_x, lp_coin_supply);
        let coin_y_removed = mul_div_down(lp_coin_value, balance_y, lp_coin_supply);

        pool_state.lp_coin_cap.supply_mut().decrease_supply(lp_coin.into_balance());

        let coin_x = pool_state.balance_x.split(coin_x_removed).into_coin(ctx);
        let coin_y = pool_state.balance_y.split(coin_y_removed).into_coin(ctx);

        assert!(coin_x.value() >= coin_x_min_amount, errors::slippage());
        assert!(coin_y.value() >= coin_y_min_amount, errors::slippage());

        events::remove_liquidity<CoinX, CoinY>(
            pool_address, 
            coin_x.value(), 
            coin_y.value(), 
            lp_coin_value
        );

        (coin_x, coin_y)
    }  

    // === Flash Loans ===

    public fun flash_loan<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        amount_x: u64,
        amount_y: u64,
        ctx: &mut TxContext
    ): (Invoice, Coin<CoinX>, Coin<CoinY>) {
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);
    
        assert!(!pool_state.locked, errors::pool_is_locked());
    
        pool_state.locked = true;

        let (balance_x, balance_y, _) = amounts(pool_state);

        let prev_k = if (pool_state.volatile) 
            volatile::invariant_(balance_x, balance_y) 
        else 
            stable::invariant_(balance_x, balance_y, pool_state.decimals_x, pool_state.decimals_y);

        assert!(balance_x >= amount_x && balance_y >= amount_y, errors::not_enough_funds_to_lend());

        let coin_x = pool_state.balance_x.split(amount_x).into_coin(ctx);
        let coin_y = pool_state.balance_y.split(amount_y).into_coin(ctx);

        let invoice = Invoice { 
            pool_address: pool.id.uid_to_address(),  
            repay_amount_x: amount_x + (mul_div_up((amount_x as u256), FLASH_LOAN_FEE_PERCENT, PRECISION) as u64),
            repay_amount_y: amount_y + (mul_div_up((amount_y as u256), FLASH_LOAN_FEE_PERCENT, PRECISION) as u64),
            prev_k
        };
    
        (invoice, coin_x, coin_y)
    }  

    public fun repay_flash_loan<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        invoice: Invoice,
        coin_x: Coin<CoinX>,
        coin_y: Coin<CoinY>
    ) {
        let Invoice { pool_address, repay_amount_x, repay_amount_y, prev_k } = invoice;
   
        assert!(pool.id.uid_to_address() == pool_address, errors::wrong_pool());
        assert!(coin_x.value() >= repay_amount_x, errors::wrong_repay_amount());
        assert!(coin_y.value() >= repay_amount_y, errors::wrong_repay_amount());
   
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);

        pool_state.balance_x.join(coin_x.into_balance());
        pool_state.balance_y.join(coin_y.into_balance());

        let (balance_x, balance_y, _) = amounts(pool_state);

        let k = if (pool_state.volatile) 
            volatile::invariant_(balance_x, balance_y) 
        else 
            stable::invariant_(balance_x, balance_y, pool_state.decimals_x, pool_state.decimals_y);

        assert!(k > prev_k, errors::invalid_invariant());
    
        pool_state.locked = false;
    }    

    // === Public-View Functions ===

    public fun pools(registry: &Registry): &Table<TypeName, address> {
        &registry.pools
    }

    public fun pool_address<Curve, CoinX, CoinY>(registry: &Registry): Option<address> {
        let registry_key = type_name::get<RegistryKey<Curve, CoinX, CoinY>>();

        if (registry.pools.contains(registry_key))
            option::some(*registry.pools.borrow(registry_key))
        else
            option::none()
    }

    public fun pool_address_from_lp_coin<LpCoin>(registry: &Registry): Option<address> {
        let lp_coin_key = type_name::get<LpCoin>();

        if (registry.pools.contains(lp_coin_key))
            option::some(*registry.pools.borrow(lp_coin_key))
        else
        option::none()
    }

    public fun lp_coin_exists<LpCoin>(registry: &Registry): bool {
        registry.lp_coins.contains(type_name::get<LpCoin>())   
    }

    public fun exists_<Curve, CoinX, CoinY>(registry: &Registry): bool {
        registry.pools.contains(type_name::get<RegistryKey<Curve, CoinX, CoinY>>())   
    }

    public fun lp_coin_supply<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.lp_coin_cap.supply_immut().supply_value()
    }

    public fun balance_x<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.balance_x.value()
    }

    public fun balance_y<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.balance_y.value()
    }

    public fun decimals_x<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.decimals_x
    }

    public fun decimals_y<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.decimals_y
    }

    public fun stable<CoinX, CoinY, LpCoin>(pool: &InterestPool): bool {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        !pool_state.volatile
    }

    public fun volatile<CoinX, CoinY, LpCoin>(pool: &InterestPool): bool {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.volatile
    }

    public fun fees<CoinX, CoinY, LpCoin>(pool: &InterestPool): Fees {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.fees
    }

    public fun locked<CoinX, CoinY, LpCoin>(pool: &InterestPool): bool {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.locked
    }

    public fun admin_balance_x<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.admin_balance_x.value()
    }

    public fun admin_balance_y<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.admin_balance_y.value()
    }

    public fun repay_amount_x(invoice: &Invoice): u64 {
        invoice.repay_amount_x
    }

    public fun repay_amount_y(invoice: &Invoice): u64 {
        invoice.repay_amount_y
    }

    public fun previous_k(invoice: &Invoice): u256 {
        invoice.prev_k
    }  

    // === Admin Functions ===

    public fun update_fees<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &mut InterestPool,
        fee_in_percent: Option<u256>,
        fee_out_percent: Option<u256>, 
        admin_fee_percent: Option<u256>,  
    ) {
        let pool_address = pool.id.uid_to_address();
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);

        pool_state.fees.update_fee_in_percent(fee_in_percent);
        pool_state.fees.update_fee_out_percent(fee_out_percent);  
        pool_state.fees.update_admin_fee_percent(admin_fee_percent);

        events::update_fees(pool_address, pool_state.fees);
    }

    public fun take_fees<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &mut InterestPool,
        ctx: &mut TxContext
    ): (Coin<LpCoin>, Coin<CoinX>, Coin<CoinY>) {
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);

        (
            pool_state.admin_lp_coin_balance.withdraw_all().into_coin(ctx),
            pool_state.admin_balance_x.withdraw_all().into_coin(ctx),
            pool_state.admin_balance_y.withdraw_all().into_coin(ctx),    
        )
    }

    public fun update_name<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &InterestPool, 
        metadata: &mut CoinMetadata<LpCoin>, 
        name: string::String
    ) {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.lp_coin_cap.update_name(metadata, name);  
    }

    public fun update_symbol<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &InterestPool, 
        metadata: &mut CoinMetadata<LpCoin>, 
        symbol: ascii::String
    ) {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.lp_coin_cap.update_symbol(metadata, symbol);
    }

    public fun update_description<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &InterestPool, 
        metadata: &mut CoinMetadata<LpCoin>, 
        description: string::String
    ) {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.lp_coin_cap.update_description(metadata, description);
    }

    public fun update_icon_url<CoinX, CoinY, LpCoin>(
        _: &Admin,
        pool: &InterestPool, 
        metadata: &mut CoinMetadata<LpCoin>, 
        url: ascii::String
    ) {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.lp_coin_cap.update_icon_url(metadata, url);
    }  

    // === Private Functions ===    

    fun new_pool_internal<Curve, CoinX, CoinY, LpCoin>(
        registry: &mut Registry,
        coin_x: Coin<CoinX>,
        coin_y: Coin<CoinY>,
        mut lp_coin_cap: TreasuryCap<LpCoin>,
        decimals_x: u64,
        decimals_y: u64,
        volatile: bool,
        ctx: &mut TxContext
    ): Coin<LpCoin> {
        assert!(
            lp_coin_cap.supply_immut().supply_value() == 0, 
            errors::supply_must_have_zero_value()
        );

        let coin_x_value = coin_x.value();
        let coin_y_value = coin_y.value();

        assert!(coin_x_value != 0 && coin_y_value != 0, errors::provide_both_coins());

        let registry_key = type_name::get<RegistryKey<Curve, CoinX, CoinY>>();

        assert!(!registry.pools.contains(registry_key), errors::pool_already_deployed());

        let shares = (sqrt_down(((coin_x_value as u256) * (coin_y_value as u256))) as u64);

        let seed_liquidity = lp_coin_cap.supply_mut().increase_supply( 
            MINIMUM_LIQUIDITY
        );
    
        let sender_balance = lp_coin_cap.mint(shares, ctx);

        let pool_state = PoolState {
            lp_coin_cap,
            balance_x: coin_x.into_balance(),
            balance_y: coin_y.into_balance(),
            decimals_x,
            decimals_y,
            volatile,
            seed_liquidity,
            fees: new_fees<Curve>(),
            locked: false,
            admin_balance_x: balance::zero(),
            admin_balance_y: balance::zero(),
            admin_lp_coin_balance: balance::zero()
        };

        let mut pool = InterestPool {
            id: object::new(ctx)
        };

        let pool_address = pool.id.uid_to_address();

        df::add(&mut pool.id, PoolStateKey {}, pool_state);

        registry.pools.add(registry_key, pool_address);
        registry.lp_coins.add(type_name::get<LpCoin>(), pool_address);

        events::new_pool<Curve, CoinX, CoinY>(pool_address, coin_x_value, coin_y_value);

        share_object(pool);
    
        sender_balance
    }

    fun swap_coin_x<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        mut coin_x: Coin<CoinX>,
        coin_y_min_value: u64,
        ctx: &mut TxContext
    ): Coin<CoinY> {
        let pool_address = object::uid_to_address(&pool.id);
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);
        assert!(!pool_state.locked, errors::pool_is_locked());

        let coin_in_amount = coin_x.value();
    
        let swap_amount = swap_amounts(
            pool_state, 
            coin_in_amount, 
            coin_y_min_value, 
            true,
        );

        if (swap_amount.admin_fee_in != 0) {
            pool_state.admin_balance_x.join(coin_x.split(swap_amount.admin_fee_in, ctx).into_balance());
        };

        if (swap_amount.admin_fee_out != 0) {
            pool_state.admin_balance_y.join(pool_state.balance_y.split(swap_amount.admin_fee_out));  
        };

        pool_state.balance_x.join(coin_x.into_balance());

        events::swap<CoinX, CoinY, SwapAmount>(pool_address, coin_in_amount, swap_amount);

        pool_state.balance_y.split(swap_amount.amount_out).into_coin(ctx) 
    }

    fun swap_coin_y<CoinX, CoinY, LpCoin>(
        pool: &mut InterestPool,
        mut coin_y: Coin<CoinY>,
        coin_x_min_value: u64,
        ctx: &mut TxContext
    ): Coin<CoinX> {
        let pool_address = pool.id.uid_to_address();
        let pool_state = pool_state_mut<CoinX, CoinY, LpCoin>(pool);
        assert!(!pool_state.locked, errors::pool_is_locked());

        let coin_in_amount = coin_y.value();

        let swap_amount = swap_amounts(
            pool_state, 
            coin_in_amount, 
            coin_x_min_value, 
            false
        );

        if (swap_amount.admin_fee_in != 0) {
            pool_state.admin_balance_y.join(coin_y.split(swap_amount.admin_fee_in, ctx).into_balance());
        };

        if (swap_amount.admin_fee_out != 0) {
            pool_state.admin_balance_x.join(pool_state.balance_x.split(swap_amount.admin_fee_out)); 
        };
      

        pool_state.balance_y.join(coin_y.into_balance());

        events::swap<CoinY, CoinX, SwapAmount>(pool_address, coin_in_amount,swap_amount);

        pool_state.balance_x.split(swap_amount.amount_out).into_coin(ctx) 
    }  

    fun new_fees<Curve>(): Fees {
        if (curves::is_volatile<Curve>())
            fees::new(INITIAL_VOLATILE_FEE_PERCENT, INITIAL_VOLATILE_FEE_PERCENT, INITIAL_ADMIN_FEE)
        else
            fees::new(INITIAL_STABLE_FEE_PERCENT, INITIAL_STABLE_FEE_PERCENT, INITIAL_ADMIN_FEE)
    }

    fun amounts<CoinX, CoinY, LpCoin>(state: &PoolState<CoinX, CoinY, LpCoin>): (u64, u64, u64) {
        ( 
            state.balance_x.value(), 
            state.balance_y.value(),
            state.lp_coin_cap.supply_immut().supply_value()
        )
    }

    fun swap_amounts<CoinX, CoinY, LpCoin>(
        pool_state: &PoolState<CoinX, CoinY, LpCoin>,
        coin_in_amount: u64,
        coin_out_min_value: u64,
        is_x: bool
    ): SwapAmount {
        let (balance_x, balance_y, _) = amounts(pool_state);

        let prev_k = if (pool_state.volatile) 
            volatile::invariant_(balance_x, balance_y) 
        else 
            stable::invariant_(balance_x, balance_y, pool_state.decimals_x, pool_state.decimals_y);

        let standard_fee_in = pool_state.fees.get_fee_in_amount(coin_in_amount);
        let admin_fee_in =  pool_state.fees.get_admin_amount(standard_fee_in);

        let coin_in_amount = coin_in_amount - standard_fee_in;

        let amount_out = if (pool_state.volatile) {
            if (is_x) 
                volatile::get_amount_out(coin_in_amount, balance_x, balance_y)
            else 
                volatile::get_amount_out(coin_in_amount, balance_y, balance_x)
        } else {
            stable::get_amount_out(
                coin_in_amount, 
                balance_x, 
                balance_y, 
                pool_state.decimals_x, 
                pool_state.decimals_y, 
                is_x
            )
        };

        let standard_fee_out = pool_state.fees.get_fee_out_amount(amount_out);
        let admin_fee_out = pool_state.fees.get_admin_amount(standard_fee_out);

        let amount_out = amount_out - standard_fee_out;

        assert!(amount_out >= coin_out_min_value, errors::slippage());

        let new_k = if (pool_state.volatile) {
            if (is_x)
                volatile::invariant_(balance_x + coin_in_amount + standard_fee_in - admin_fee_in, balance_y - amount_out - admin_fee_out)
            else
                volatile::invariant_(balance_x - amount_out - admin_fee_out, balance_y + coin_in_amount + standard_fee_in - admin_fee_in)
        } else {
            if (is_x) 
                stable::invariant_(balance_x + coin_in_amount + standard_fee_in - admin_fee_in, balance_y - amount_out - admin_fee_out, pool_state.decimals_x, pool_state.decimals_y)
            else
                stable::invariant_(balance_x - amount_out - admin_fee_out, balance_y + standard_fee_in + coin_in_amount - admin_fee_in, pool_state.decimals_x, pool_state.decimals_y)
        };

        assert!(new_k >= prev_k, errors::invalid_invariant());

        SwapAmount {
            amount_out,
            standard_fee_in,
            standard_fee_out,
            admin_fee_in,
            admin_fee_out,
        }  
    }

    fun pool_state<CoinX, CoinY, LpCoin>(pool: &InterestPool): &PoolState<CoinX, CoinY, LpCoin> {
        df::borrow(&pool.id, PoolStateKey {})
    }

    fun pool_state_mut<CoinX, CoinY, LpCoin>(pool: &mut InterestPool): &mut PoolState<CoinX, CoinY, LpCoin> {
        df::borrow_mut(&mut pool.id, PoolStateKey {})
    }

    // === Test Functions ===
  
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun seed_liquidity<CoinX, CoinY, LpCoin>(pool: &InterestPool): u64 {
        let pool_state = pool_state<CoinX, CoinY, LpCoin>(pool);
        pool_state.seed_liquidity.value()
    }
}