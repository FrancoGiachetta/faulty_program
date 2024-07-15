#[starknet::contract]
mod Market {
    use starknet::{ClassHash, ContractAddress};

    // Hack to simulate the `crate` keyword
    

    use super::interfaces::{IMarket, MarketReserveData};

    use super::{external, view};

    #[storage]
    struct Storage {
        oracle: ContractAddress,
        treasury: ContractAddress,
        reserves: LegacyMap::<ContractAddress, MarketReserveData>,
        reserve_count: felt252,
        // index -> token
        reserve_tokens: LegacyMap::<felt252, ContractAddress>,
        // token -> index
        reserve_indices: LegacyMap::<ContractAddress, felt252>,
        /// Bit 0: whether reserve #0 is used as collateral
        /// Bit 1: whether user has debt in reserve #0
        /// Bit 2: whether reserve #1 is used as collateral
        /// Bit 3: whether user has debt in reserve #1
        /// ...
        user_flags: LegacyMap::<ContractAddress, felt252>,
        // (user, token) -> debt
        raw_user_debts: LegacyMap::<(ContractAddress, ContractAddress), felt252>,
        // This weird naming is to maintain backward compatibility with the Cairo 0 version
        Ownable_owner: ContractAddress,
        // Used in `reentrancy_guard`
        entered: bool
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NewReserve: NewReserve,
        TreasuryUpdate: TreasuryUpdate,
        AccumulatorsSync: AccumulatorsSync,
        InterestRatesSync: InterestRatesSync,
        InterestRateModelUpdate: InterestRateModelUpdate,
        CollateralFactorUpdate: CollateralFactorUpdate,
        BorrowFactorUpdate: BorrowFactorUpdate,
        ReserveFactorUpdate: ReserveFactorUpdate,
        DebtLimitUpdate: DebtLimitUpdate,
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        Borrowing: Borrowing,
        Repayment: Repayment,
        Liquidation: Liquidation,
        FlashLoan: FlashLoan,
        CollateralEnabled: CollateralEnabled,
        CollateralDisabled: CollateralDisabled,
        ContractUpgraded: ContractUpgraded,
        OwnershipTransferred: OwnershipTransferred
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct NewReserve {
        token: ContractAddress,
        z_token: ContractAddress,
        decimals: felt252,
        interest_rate_model: ContractAddress,
        collateral_factor: felt252,
        borrow_factor: felt252,
        reserve_factor: felt252,
        flash_loan_fee: felt252,
        liquidation_bonus: felt252,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct TreasuryUpdate {
        new_treasury: ContractAddress
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct AccumulatorsSync {
        token: ContractAddress,
        lending_accumulator: felt252,
        debt_accumulator: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct InterestRatesSync {
        token: ContractAddress,
        lending_rate: felt252,
        borrowing_rate: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct InterestRateModelUpdate {
        token: ContractAddress,
        interest_rate_model: ContractAddress
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct CollateralFactorUpdate {
        token: ContractAddress,
        collateral_factor: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct BorrowFactorUpdate {
        token: ContractAddress,
        borrow_factor: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct ReserveFactorUpdate {
        token: ContractAddress,
        reserve_factor: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct DebtLimitUpdate {
        token: ContractAddress,
        limit: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Deposit {
        user: ContractAddress,
        token: ContractAddress,
        face_amount: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Withdrawal {
        user: ContractAddress,
        token: ContractAddress,
        face_amount: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Borrowing {
        user: ContractAddress,
        token: ContractAddress,
        raw_amount: felt252,
        face_amount: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Repayment {
        repayer: ContractAddress,
        beneficiary: ContractAddress,
        token: ContractAddress,
        raw_amount: felt252,
        face_amount: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Liquidation {
        liquidator: ContractAddress,
        user: ContractAddress,
        debt_token: ContractAddress,
        debt_raw_amount: felt252,
        debt_face_amount: felt252,
        collateral_token: ContractAddress,
        collateral_amount: felt252,
    }

    /// `fee` indicates the actual fee paid back, which could be higher than the minimum required.
    #[derive(Drop, PartialEq, starknet::Event)]
    struct FlashLoan {
        initiator: ContractAddress,
        receiver: ContractAddress,
        token: ContractAddress,
        amount: felt252,
        fee: felt252
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct CollateralEnabled {
        user: ContractAddress,
        token: ContractAddress
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct CollateralDisabled {
        user: ContractAddress,
        token: ContractAddress
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct ContractUpgraded {
        new_class_hash: ClassHash
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, oracle: ContractAddress) {
        external::initializer(ref self, owner, oracle)
    }

    #[abi(embed_v0)]
    impl IMarketImpl of IMarket<ContractState> {
        fn get_reserve_data(self: @ContractState, token: ContractAddress) -> MarketReserveData {
            view::get_reserve_data(self, token)
        }

        fn get_lending_accumulator(self: @ContractState, token: ContractAddress) -> felt252 {
            view::get_lending_accumulator(self, token)
        }

        fn get_debt_accumulator(self: @ContractState, token: ContractAddress) -> felt252 {
            view::get_debt_accumulator(self, token)
        }
        // WARN: this must be run BEFORE adjusting the accumulators (otherwise always returns 0)
        fn get_pending_treasury_amount(self: @ContractState, token: ContractAddress) -> felt252 {
            view::get_pending_treasury_amount(self, token)
        }

        fn get_total_debt_for_token(self: @ContractState, token: ContractAddress) -> felt252 {
            view::get_total_debt_for_token(self, token)
        }

        fn get_user_debt_for_token(
            self: @ContractState, user: ContractAddress, token: ContractAddress
        ) -> felt252 {
            view::get_user_debt_for_token(self, user, token)
        }

        /// Returns a bitmap of user flags.
        fn get_user_flags(self: @ContractState, user: ContractAddress) -> felt252 {
            view::get_user_flags(self, user)
        }

        fn is_user_undercollateralized(
            self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
        ) -> bool {
            view::is_user_undercollateralized(self, user, apply_borrow_factor)
        }

        fn is_collateral_enabled(
            self: @ContractState, user: ContractAddress, token: ContractAddress
        ) -> bool {
            view::is_collateral_enabled(self, user, token)
        }

        fn user_has_debt(self: @ContractState, user: ContractAddress) -> bool {
            view::user_has_debt(self, user)
        }

        fn deposit(ref self: ContractState, token: ContractAddress, amount: felt252) {
            external::deposit(ref self, token, amount)
        }

        fn withdraw_all(ref self: ContractState, token: ContractAddress) {
            external::withdraw_all(ref self, token)
        }

        fn borrow(ref self: ContractState, token: ContractAddress, amount: felt252) {
            external::borrow(ref self, token, amount)
        }

        fn repay(ref self: ContractState, token: ContractAddress, amount: felt252) {
            external::repay(ref self, token, amount)
        }

        fn repay_for(
            ref self: ContractState,
            token: ContractAddress,
            amount: felt252,
            beneficiary: ContractAddress
        ) {
            external::repay_for(ref self, token, amount, beneficiary)
        }

        fn repay_all(ref self: ContractState, token: ContractAddress) {
            external::repay_all(ref self, token)
        }

        fn enable_collateral(ref self: ContractState, token: ContractAddress) {
            external::enable_collateral(ref self, token)
        }

        fn disable_collateral(ref self: ContractState, token: ContractAddress) {
            external::disable_collateral(ref self, token)
        }

        /// With the current design, liquidators are responsible for calculating the maximum amount allowed.
        /// We simply check collteralization factor is below one after liquidation.
        /// TODO: calculate max amount on-chain because compute is cheap on StarkNet.
        fn liquidate(
            ref self: ContractState,
            user: ContractAddress,
            debt_token: ContractAddress,
            amount: felt252,
            collateral_token: ContractAddress
        ) {
            external::liquidate(ref self, user, debt_token, amount, collateral_token)
        }

        fn flash_loan(
            ref self: ContractState,
            receiver: ContractAddress,
            token: ContractAddress,
            amount: felt252,
            calldata: Span::<felt252>
        ) {
            external::flash_loan(ref self, receiver, token, amount, calldata)
        }

        fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
            external::upgrade(ref self, new_implementation)
        }

        fn add_reserve(
            ref self: ContractState,
            token: ContractAddress,
            z_token: ContractAddress,
            interest_rate_model: ContractAddress,
            collateral_factor: felt252,
            borrow_factor: felt252,
            reserve_factor: felt252,
            flash_loan_fee: felt252,
            liquidation_bonus: felt252
        ) {
            external::add_reserve(
                ref self,
                token,
                z_token,
                interest_rate_model,
                collateral_factor,
                borrow_factor,
                reserve_factor,
                flash_loan_fee,
                liquidation_bonus
            )
        }

        fn set_treasury(ref self: ContractState, new_treasury: ContractAddress) {
            external::set_treasury(ref self, new_treasury)
        }

        fn set_interest_rate_model(
            ref self: ContractState, token: ContractAddress, interest_rate_model: ContractAddress
        ) {
            external::set_interest_rate_model(ref self, token, interest_rate_model)
        }

        fn set_collateral_factor(
            ref self: ContractState, token: ContractAddress, collateral_factor: felt252
        ) {
            external::set_collateral_factor(ref self, token, collateral_factor)
        }

        fn set_borrow_factor(
            ref self: ContractState, token: ContractAddress, borrow_factor: felt252
        ) {
            external::set_borrow_factor(ref self, token, borrow_factor)
        }

        fn set_reserve_factor(
            ref self: ContractState, token: ContractAddress, reserve_factor: felt252
        ) {
            external::set_reserve_factor(ref self, token, reserve_factor)
        }

        fn set_debt_limit(ref self: ContractState, token: ContractAddress, limit: felt252) {
            external::set_debt_limit(ref self, token, limit)
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            external::transfer_ownership(ref self, new_owner)
        }

        fn renounce_ownership(ref self: ContractState) {
            external::renounce_ownership(ref self)
        }

        fn withdraw(ref self: ContractState, token: ContractAddress, amount: felt252) {
            external::withdraw(ref self, token, amount)

            //super::libraries::safe_math::sub(0, 1);
        }
    }
}

mod libraries {
    mod math {
        use integer::u256_overflow_mul;
use option::OptionTrait;
use traits::{Into, TryInto};

use super::{pow, safe_math};

/// Computes the logical left shift of `felt252`, with result in the range of [0, 2 ^ 251).
fn shl(a: felt252, b: felt252) -> felt252 {
    // For left shifting we pretend there're only 251 bits in `felt252`.
    if Into::<_, u256>::into(b) <= 250 {
        let shift = pow::two_pow(b);
        let shift: u256 = shift.into();
        let a: u256 = a.into();

        let (product, _) = u256_overflow_mul(a, shift);

        // Takes all 128 bits from low, and 123 bits from high
        let trimmed_high = product.high & 0x7ffffffffffffffffffffffffffffff;

        let res = (u256 { low: product.low, high: trimmed_high });

        // Safe to unwrap as this number always fits in `felt252`
        res.try_into().unwrap()
    } else {
        0
    }
}

// Computes the logical right shift of a field element
fn shr(a: felt252, b: felt252) -> felt252 {
    if Into::<_, u256>::into(b) <= 251 {
        let denominator = pow::two_pow(b);
        safe_math::div(a, denominator)
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use test::test_utils::assert_eq;

    #[test]
    fn test_shl() {
        assert_eq(@super::shl(0, 100), @0, 'FAILED');
        assert_eq(@super::shl(0x2, 1), @0x4, 'FAILED');
        assert_eq(@super::shl(0x4010000000001, 45), @0x802000000000200000000000, 'FAILED');
        assert_eq(
            @super::shl(0x800000000000000000000000000000000000000000000000000000000000000, 0),
            @0x0,
            'FAILED'
        );
        assert_eq(
            @super::shl(0x4010000000001, 210),
            @0x400000000040000000000000000000000000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    fn test_shr() {
        assert_eq(@super::shr(0x0, 100), @0x0, 'FAILED');
        assert_eq(@super::shr(0x2, 1), @0x1, 'FAILED');
        assert_eq(@super::shr(0x4010000000001, 45), @0x20, 'FAILED');
        assert_eq(
            @super::shr(0x800000000000011000000000000000000000000000000000000000000000000, 100),
            @0x80000000000001100000000000000000000000,
            'FAILED'
        );
        assert_eq(
            @super::shr(0x800000000000011000000000000000000000000000000000000000000000000, 251),
            @0x1,
            'FAILED'
        );
        assert_eq(
            @super::shr(0x800000000000011000000000000000000000000000000000000000000000000, 252),
            @0x0,
            'FAILED'
        );
    }
        }

    }
    mod pow {
        mod errors {
    const DECIMALS_OUT_OF_RANGE: felt252 = 'POW_DEC_TOO_LARGE';
}

const SCALE: felt252 = 1000000000000000000000000000;

// Lookup-table seems to be the most gas-efficient
fn two_pow(power: felt252) -> felt252 {
    if power == 0 {
        0x1
    } else if power == 1 {
        0x2
    } else if power == 2 {
        0x4
    } else if power == 3 {
        0x8
    } else if power == 4 {
        0x10
    } else if power == 5 {
        0x20
    } else if power == 6 {
        0x40
    } else if power == 7 {
        0x80
    } else if power == 8 {
        0x100
    } else if power == 9 {
        0x200
    } else if power == 10 {
        0x400
    } else if power == 11 {
        0x800
    } else if power == 12 {
        0x1000
    } else if power == 13 {
        0x2000
    } else if power == 14 {
        0x4000
    } else if power == 15 {
        0x8000
    } else if power == 16 {
        0x10000
    } else if power == 17 {
        0x20000
    } else if power == 18 {
        0x40000
    } else if power == 19 {
        0x80000
    } else if power == 20 {
        0x100000
    } else if power == 21 {
        0x200000
    } else if power == 22 {
        0x400000
    } else if power == 23 {
        0x800000
    } else if power == 24 {
        0x1000000
    } else if power == 25 {
        0x2000000
    } else if power == 26 {
        0x4000000
    } else if power == 27 {
        0x8000000
    } else if power == 28 {
        0x10000000
    } else if power == 29 {
        0x20000000
    } else if power == 30 {
        0x40000000
    } else if power == 31 {
        0x80000000
    } else if power == 32 {
        0x100000000
    } else if power == 33 {
        0x200000000
    } else if power == 34 {
        0x400000000
    } else if power == 35 {
        0x800000000
    } else if power == 36 {
        0x1000000000
    } else if power == 37 {
        0x2000000000
    } else if power == 38 {
        0x4000000000
    } else if power == 39 {
        0x8000000000
    } else if power == 40 {
        0x10000000000
    } else if power == 41 {
        0x20000000000
    } else if power == 42 {
        0x40000000000
    } else if power == 43 {
        0x80000000000
    } else if power == 44 {
        0x100000000000
    } else if power == 45 {
        0x200000000000
    } else if power == 46 {
        0x400000000000
    } else if power == 47 {
        0x800000000000
    } else if power == 48 {
        0x1000000000000
    } else if power == 49 {
        0x2000000000000
    } else if power == 50 {
        0x4000000000000
    } else if power == 51 {
        0x8000000000000
    } else if power == 52 {
        0x10000000000000
    } else if power == 53 {
        0x20000000000000
    } else if power == 54 {
        0x40000000000000
    } else if power == 55 {
        0x80000000000000
    } else if power == 56 {
        0x100000000000000
    } else if power == 57 {
        0x200000000000000
    } else if power == 58 {
        0x400000000000000
    } else if power == 59 {
        0x800000000000000
    } else if power == 60 {
        0x1000000000000000
    } else if power == 61 {
        0x2000000000000000
    } else if power == 62 {
        0x4000000000000000
    } else if power == 63 {
        0x8000000000000000
    } else if power == 64 {
        0x10000000000000000
    } else if power == 65 {
        0x20000000000000000
    } else if power == 66 {
        0x40000000000000000
    } else if power == 67 {
        0x80000000000000000
    } else if power == 68 {
        0x100000000000000000
    } else if power == 69 {
        0x200000000000000000
    } else if power == 70 {
        0x400000000000000000
    } else if power == 71 {
        0x800000000000000000
    } else if power == 72 {
        0x1000000000000000000
    } else if power == 73 {
        0x2000000000000000000
    } else if power == 74 {
        0x4000000000000000000
    } else if power == 75 {
        0x8000000000000000000
    } else if power == 76 {
        0x10000000000000000000
    } else if power == 77 {
        0x20000000000000000000
    } else if power == 78 {
        0x40000000000000000000
    } else if power == 79 {
        0x80000000000000000000
    } else if power == 80 {
        0x100000000000000000000
    } else if power == 81 {
        0x200000000000000000000
    } else if power == 82 {
        0x400000000000000000000
    } else if power == 83 {
        0x800000000000000000000
    } else if power == 84 {
        0x1000000000000000000000
    } else if power == 85 {
        0x2000000000000000000000
    } else if power == 86 {
        0x4000000000000000000000
    } else if power == 87 {
        0x8000000000000000000000
    } else if power == 88 {
        0x10000000000000000000000
    } else if power == 89 {
        0x20000000000000000000000
    } else if power == 90 {
        0x40000000000000000000000
    } else if power == 91 {
        0x80000000000000000000000
    } else if power == 92 {
        0x100000000000000000000000
    } else if power == 93 {
        0x200000000000000000000000
    } else if power == 94 {
        0x400000000000000000000000
    } else if power == 95 {
        0x800000000000000000000000
    } else if power == 96 {
        0x1000000000000000000000000
    } else if power == 97 {
        0x2000000000000000000000000
    } else if power == 98 {
        0x4000000000000000000000000
    } else if power == 99 {
        0x8000000000000000000000000
    } else if power == 100 {
        0x10000000000000000000000000
    } else if power == 101 {
        0x20000000000000000000000000
    } else if power == 102 {
        0x40000000000000000000000000
    } else if power == 103 {
        0x80000000000000000000000000
    } else if power == 104 {
        0x100000000000000000000000000
    } else if power == 105 {
        0x200000000000000000000000000
    } else if power == 106 {
        0x400000000000000000000000000
    } else if power == 107 {
        0x800000000000000000000000000
    } else if power == 108 {
        0x1000000000000000000000000000
    } else if power == 109 {
        0x2000000000000000000000000000
    } else if power == 110 {
        0x4000000000000000000000000000
    } else if power == 111 {
        0x8000000000000000000000000000
    } else if power == 112 {
        0x10000000000000000000000000000
    } else if power == 113 {
        0x20000000000000000000000000000
    } else if power == 114 {
        0x40000000000000000000000000000
    } else if power == 115 {
        0x80000000000000000000000000000
    } else if power == 116 {
        0x100000000000000000000000000000
    } else if power == 117 {
        0x200000000000000000000000000000
    } else if power == 118 {
        0x400000000000000000000000000000
    } else if power == 119 {
        0x800000000000000000000000000000
    } else if power == 120 {
        0x1000000000000000000000000000000
    } else if power == 121 {
        0x2000000000000000000000000000000
    } else if power == 122 {
        0x4000000000000000000000000000000
    } else if power == 123 {
        0x8000000000000000000000000000000
    } else if power == 124 {
        0x10000000000000000000000000000000
    } else if power == 125 {
        0x20000000000000000000000000000000
    } else if power == 126 {
        0x40000000000000000000000000000000
    } else if power == 127 {
        0x80000000000000000000000000000000
    } else if power == 128 {
        0x100000000000000000000000000000000
    } else if power == 129 {
        0x200000000000000000000000000000000
    } else if power == 130 {
        0x400000000000000000000000000000000
    } else if power == 131 {
        0x800000000000000000000000000000000
    } else if power == 132 {
        0x1000000000000000000000000000000000
    } else if power == 133 {
        0x2000000000000000000000000000000000
    } else if power == 134 {
        0x4000000000000000000000000000000000
    } else if power == 135 {
        0x8000000000000000000000000000000000
    } else if power == 136 {
        0x10000000000000000000000000000000000
    } else if power == 137 {
        0x20000000000000000000000000000000000
    } else if power == 138 {
        0x40000000000000000000000000000000000
    } else if power == 139 {
        0x80000000000000000000000000000000000
    } else if power == 140 {
        0x100000000000000000000000000000000000
    } else if power == 141 {
        0x200000000000000000000000000000000000
    } else if power == 142 {
        0x400000000000000000000000000000000000
    } else if power == 143 {
        0x800000000000000000000000000000000000
    } else if power == 144 {
        0x1000000000000000000000000000000000000
    } else if power == 145 {
        0x2000000000000000000000000000000000000
    } else if power == 146 {
        0x4000000000000000000000000000000000000
    } else if power == 147 {
        0x8000000000000000000000000000000000000
    } else if power == 148 {
        0x10000000000000000000000000000000000000
    } else if power == 149 {
        0x20000000000000000000000000000000000000
    } else if power == 150 {
        0x40000000000000000000000000000000000000
    } else if power == 151 {
        0x80000000000000000000000000000000000000
    } else if power == 152 {
        0x100000000000000000000000000000000000000
    } else if power == 153 {
        0x200000000000000000000000000000000000000
    } else if power == 154 {
        0x400000000000000000000000000000000000000
    } else if power == 155 {
        0x800000000000000000000000000000000000000
    } else if power == 156 {
        0x1000000000000000000000000000000000000000
    } else if power == 157 {
        0x2000000000000000000000000000000000000000
    } else if power == 158 {
        0x4000000000000000000000000000000000000000
    } else if power == 159 {
        0x8000000000000000000000000000000000000000
    } else if power == 160 {
        0x10000000000000000000000000000000000000000
    } else if power == 161 {
        0x20000000000000000000000000000000000000000
    } else if power == 162 {
        0x40000000000000000000000000000000000000000
    } else if power == 163 {
        0x80000000000000000000000000000000000000000
    } else if power == 164 {
        0x100000000000000000000000000000000000000000
    } else if power == 165 {
        0x200000000000000000000000000000000000000000
    } else if power == 166 {
        0x400000000000000000000000000000000000000000
    } else if power == 167 {
        0x800000000000000000000000000000000000000000
    } else if power == 168 {
        0x1000000000000000000000000000000000000000000
    } else if power == 169 {
        0x2000000000000000000000000000000000000000000
    } else if power == 170 {
        0x4000000000000000000000000000000000000000000
    } else if power == 171 {
        0x8000000000000000000000000000000000000000000
    } else if power == 172 {
        0x10000000000000000000000000000000000000000000
    } else if power == 173 {
        0x20000000000000000000000000000000000000000000
    } else if power == 174 {
        0x40000000000000000000000000000000000000000000
    } else if power == 175 {
        0x80000000000000000000000000000000000000000000
    } else if power == 176 {
        0x100000000000000000000000000000000000000000000
    } else if power == 177 {
        0x200000000000000000000000000000000000000000000
    } else if power == 178 {
        0x400000000000000000000000000000000000000000000
    } else if power == 179 {
        0x800000000000000000000000000000000000000000000
    } else if power == 180 {
        0x1000000000000000000000000000000000000000000000
    } else if power == 181 {
        0x2000000000000000000000000000000000000000000000
    } else if power == 182 {
        0x4000000000000000000000000000000000000000000000
    } else if power == 183 {
        0x8000000000000000000000000000000000000000000000
    } else if power == 184 {
        0x10000000000000000000000000000000000000000000000
    } else if power == 185 {
        0x20000000000000000000000000000000000000000000000
    } else if power == 186 {
        0x40000000000000000000000000000000000000000000000
    } else if power == 187 {
        0x80000000000000000000000000000000000000000000000
    } else if power == 188 {
        0x100000000000000000000000000000000000000000000000
    } else if power == 189 {
        0x200000000000000000000000000000000000000000000000
    } else if power == 190 {
        0x400000000000000000000000000000000000000000000000
    } else if power == 191 {
        0x800000000000000000000000000000000000000000000000
    } else if power == 192 {
        0x1000000000000000000000000000000000000000000000000
    } else if power == 193 {
        0x2000000000000000000000000000000000000000000000000
    } else if power == 194 {
        0x4000000000000000000000000000000000000000000000000
    } else if power == 195 {
        0x8000000000000000000000000000000000000000000000000
    } else if power == 196 {
        0x10000000000000000000000000000000000000000000000000
    } else if power == 197 {
        0x20000000000000000000000000000000000000000000000000
    } else if power == 198 {
        0x40000000000000000000000000000000000000000000000000
    } else if power == 199 {
        0x80000000000000000000000000000000000000000000000000
    } else if power == 200 {
        0x100000000000000000000000000000000000000000000000000
    } else if power == 201 {
        0x200000000000000000000000000000000000000000000000000
    } else if power == 202 {
        0x400000000000000000000000000000000000000000000000000
    } else if power == 203 {
        0x800000000000000000000000000000000000000000000000000
    } else if power == 204 {
        0x1000000000000000000000000000000000000000000000000000
    } else if power == 205 {
        0x2000000000000000000000000000000000000000000000000000
    } else if power == 206 {
        0x4000000000000000000000000000000000000000000000000000
    } else if power == 207 {
        0x8000000000000000000000000000000000000000000000000000
    } else if power == 208 {
        0x10000000000000000000000000000000000000000000000000000
    } else if power == 209 {
        0x20000000000000000000000000000000000000000000000000000
    } else if power == 210 {
        0x40000000000000000000000000000000000000000000000000000
    } else if power == 211 {
        0x80000000000000000000000000000000000000000000000000000
    } else if power == 212 {
        0x100000000000000000000000000000000000000000000000000000
    } else if power == 213 {
        0x200000000000000000000000000000000000000000000000000000
    } else if power == 214 {
        0x400000000000000000000000000000000000000000000000000000
    } else if power == 215 {
        0x800000000000000000000000000000000000000000000000000000
    } else if power == 216 {
        0x1000000000000000000000000000000000000000000000000000000
    } else if power == 217 {
        0x2000000000000000000000000000000000000000000000000000000
    } else if power == 218 {
        0x4000000000000000000000000000000000000000000000000000000
    } else if power == 219 {
        0x8000000000000000000000000000000000000000000000000000000
    } else if power == 220 {
        0x10000000000000000000000000000000000000000000000000000000
    } else if power == 221 {
        0x20000000000000000000000000000000000000000000000000000000
    } else if power == 222 {
        0x40000000000000000000000000000000000000000000000000000000
    } else if power == 223 {
        0x80000000000000000000000000000000000000000000000000000000
    } else if power == 224 {
        0x100000000000000000000000000000000000000000000000000000000
    } else if power == 225 {
        0x200000000000000000000000000000000000000000000000000000000
    } else if power == 226 {
        0x400000000000000000000000000000000000000000000000000000000
    } else if power == 227 {
        0x800000000000000000000000000000000000000000000000000000000
    } else if power == 228 {
        0x1000000000000000000000000000000000000000000000000000000000
    } else if power == 229 {
        0x2000000000000000000000000000000000000000000000000000000000
    } else if power == 230 {
        0x4000000000000000000000000000000000000000000000000000000000
    } else if power == 231 {
        0x8000000000000000000000000000000000000000000000000000000000
    } else if power == 232 {
        0x10000000000000000000000000000000000000000000000000000000000
    } else if power == 233 {
        0x20000000000000000000000000000000000000000000000000000000000
    } else if power == 234 {
        0x40000000000000000000000000000000000000000000000000000000000
    } else if power == 235 {
        0x80000000000000000000000000000000000000000000000000000000000
    } else if power == 236 {
        0x100000000000000000000000000000000000000000000000000000000000
    } else if power == 237 {
        0x200000000000000000000000000000000000000000000000000000000000
    } else if power == 238 {
        0x400000000000000000000000000000000000000000000000000000000000
    } else if power == 239 {
        0x800000000000000000000000000000000000000000000000000000000000
    } else if power == 240 {
        0x1000000000000000000000000000000000000000000000000000000000000
    } else if power == 241 {
        0x2000000000000000000000000000000000000000000000000000000000000
    } else if power == 242 {
        0x4000000000000000000000000000000000000000000000000000000000000
    } else if power == 243 {
        0x8000000000000000000000000000000000000000000000000000000000000
    } else if power == 244 {
        0x10000000000000000000000000000000000000000000000000000000000000
    } else if power == 245 {
        0x20000000000000000000000000000000000000000000000000000000000000
    } else if power == 246 {
        0x40000000000000000000000000000000000000000000000000000000000000
    } else if power == 247 {
        0x80000000000000000000000000000000000000000000000000000000000000
    } else if power == 248 {
        0x100000000000000000000000000000000000000000000000000000000000000
    } else if power == 249 {
        0x200000000000000000000000000000000000000000000000000000000000000
    } else if power == 250 {
        0x400000000000000000000000000000000000000000000000000000000000000
    } else if power == 251 {
        0x800000000000000000000000000000000000000000000000000000000000000
    } else {
        panic_with_felt252(errors::DECIMALS_OUT_OF_RANGE)
    }
}

// Lookup-table seems to be the most gas-efficient
fn ten_pow(power: felt252) -> felt252 {
    if power == 0 {
        1
    } else if power == 1 {
        10
    } else if power == 2 {
        100
    } else if power == 3 {
        1000
    } else if power == 4 {
        10000
    } else if power == 5 {
        100000
    } else if power == 6 {
        1000000
    } else if power == 7 {
        10000000
    } else if power == 8 {
        100000000
    } else if power == 9 {
        1000000000
    } else if power == 10 {
        10000000000
    } else if power == 11 {
        100000000000
    } else if power == 12 {
        1000000000000
    } else if power == 13 {
        10000000000000
    } else if power == 14 {
        100000000000000
    } else if power == 15 {
        1000000000000000
    } else if power == 16 {
        10000000000000000
    } else if power == 17 {
        100000000000000000
    } else if power == 18 {
        1000000000000000000
    } else if power == 19 {
        10000000000000000000
    } else if power == 20 {
        100000000000000000000
    } else if power == 21 {
        1000000000000000000000
    } else if power == 22 {
        10000000000000000000000
    } else if power == 23 {
        100000000000000000000000
    } else if power == 24 {
        1000000000000000000000000
    } else if power == 25 {
        10000000000000000000000000
    } else if power == 26 {
        100000000000000000000000000
    } else if power == 27 {
        1000000000000000000000000000
    } else if power == 28 {
        10000000000000000000000000000
    } else if power == 29 {
        100000000000000000000000000000
    } else if power == 30 {
        1000000000000000000000000000000
    } else if power == 31 {
        10000000000000000000000000000000
    } else if power == 32 {
        100000000000000000000000000000000
    } else if power == 33 {
        1000000000000000000000000000000000
    } else if power == 34 {
        10000000000000000000000000000000000
    } else if power == 35 {
        100000000000000000000000000000000000
    } else if power == 36 {
        1000000000000000000000000000000000000
    } else if power == 37 {
        10000000000000000000000000000000000000
    } else if power == 38 {
        100000000000000000000000000000000000000
    } else if power == 39 {
        1000000000000000000000000000000000000000
    } else if power == 40 {
        10000000000000000000000000000000000000000
    } else if power == 41 {
        100000000000000000000000000000000000000000
    } else if power == 42 {
        1000000000000000000000000000000000000000000
    } else if power == 43 {
        10000000000000000000000000000000000000000000
    } else if power == 44 {
        100000000000000000000000000000000000000000000
    } else if power == 45 {
        1000000000000000000000000000000000000000000000
    } else if power == 46 {
        10000000000000000000000000000000000000000000000
    } else if power == 47 {
        100000000000000000000000000000000000000000000000
    } else if power == 48 {
        1000000000000000000000000000000000000000000000000
    } else if power == 49 {
        10000000000000000000000000000000000000000000000000
    } else if power == 50 {
        100000000000000000000000000000000000000000000000000
    } else if power == 51 {
        1000000000000000000000000000000000000000000000000000
    } else if power == 52 {
        10000000000000000000000000000000000000000000000000000
    } else if power == 53 {
        100000000000000000000000000000000000000000000000000000
    } else if power == 54 {
        1000000000000000000000000000000000000000000000000000000
    } else if power == 55 {
        10000000000000000000000000000000000000000000000000000000
    } else if power == 56 {
        100000000000000000000000000000000000000000000000000000000
    } else if power == 57 {
        1000000000000000000000000000000000000000000000000000000000
    } else if power == 58 {
        10000000000000000000000000000000000000000000000000000000000
    } else if power == 59 {
        100000000000000000000000000000000000000000000000000000000000
    } else if power == 60 {
        1000000000000000000000000000000000000000000000000000000000000
    } else if power == 61 {
        10000000000000000000000000000000000000000000000000000000000000
    } else if power == 62 {
        100000000000000000000000000000000000000000000000000000000000000
    } else if power == 63 {
        1000000000000000000000000000000000000000000000000000000000000000
    } else if power == 64 {
        10000000000000000000000000000000000000000000000000000000000000000
    } else if power == 65 {
        100000000000000000000000000000000000000000000000000000000000000000
    } else if power == 66 {
        1000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 67 {
        10000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 68 {
        100000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 69 {
        1000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 70 {
        10000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 71 {
        100000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 72 {
        1000000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 73 {
        10000000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 74 {
        100000000000000000000000000000000000000000000000000000000000000000000000000
    } else if power == 75 {
        1000000000000000000000000000000000000000000000000000000000000000000000000000
    } else {
        panic_with_felt252(errors::DECIMALS_OUT_OF_RANGE)
    }
}

#[cfg(test)]
mod tests {
    use test::test_utils::assert_eq;

    #[test]
    fn test_two_pow() {
        assert_eq(@super::two_pow(0), @1, 'FAILED');
        assert_eq(@super::two_pow(1), @2, 'FAILED');
        assert_eq(@super::two_pow(2), @4, 'FAILED');
        assert_eq(@super::two_pow(3), @8, 'FAILED');
        assert_eq(@super::two_pow(4), @16, 'FAILED');
        assert_eq(@super::two_pow(5), @32, 'FAILED');
        assert_eq(@super::two_pow(100), @0x10000000000000000000000000, 'FAILED');
        assert_eq(@super::two_pow(101), @0x20000000000000000000000000, 'FAILED');
        assert_eq(
            @super::two_pow(251),
            @0x800000000000000000000000000000000000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    #[should_panic(expected: ('POW_DEC_TOO_LARGE',))]
    fn test_two_pow_overflow() {
        super::two_pow(252);
    }

    #[test]
    fn test_ten_pow() {
        assert_eq(@super::ten_pow(0), @1, 'FAILED');
        assert_eq(@super::ten_pow(1), @10, 'FAILED');
        assert_eq(@super::ten_pow(2), @100, 'FAILED');
        assert_eq(@super::ten_pow(3), @1000, 'FAILED');
        assert_eq(@super::ten_pow(4), @10000, 'FAILED');
        assert_eq(@super::ten_pow(5), @100000, 'FAILED');
        assert_eq(
            @super::ten_pow(75),
            @1000000000000000000000000000000000000000000000000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    #[should_panic(expected: ('POW_DEC_TOO_LARGE',))]
    fn test_ten_pow_overflow() {
        super::ten_pow(76);
    }
        }

    }
    mod safe_math {
        use integer::u256_checked_mul;
use option::OptionTrait;
use traits::{Into, TryInto};

mod errors {
    const ADDITION_OVERFLOW: felt252 = 'SM_ADD_OF';
    const DIVISION_BY_ZERO: felt252 = 'SM_DIV_ZERO';
    const MULTIPLICATION_OVERFLOW: felt252 = 'SM_MUL_OF';
    const SUBTRACTION_UNDERFLOW: felt252 = 'SM_SUB_UF';
}

fn add(a: felt252, b: felt252) -> felt252 {
    let sum = a + b;
    assert(Into::<_, u256>::into(a) <= Into::<_, u256>::into(sum), errors::ADDITION_OVERFLOW);
    sum
}

fn sub(a: felt252, b: felt252) -> felt252 {
    println!("---should be b <= a");
    println!("---a: {}", a);
    println!("---b: {}", b);
    assert(Into::<_, u256>::into(b) <= Into::<_, u256>::into(a), errors::SUBTRACTION_UNDERFLOW);
    a - b
}

fn mul(a: felt252, b: felt252) -> felt252 {
    let a: u256 = a.into();
    let b: u256 = b.into();
    let product = u256_checked_mul(a, b).expect(errors::MULTIPLICATION_OVERFLOW);

    product.try_into().expect(errors::MULTIPLICATION_OVERFLOW)
}

fn div(a: felt252, b: felt252) -> felt252 {
    assert(b != 0, errors::DIVISION_BY_ZERO);

    let a: u256 = a.into();
    let b: u256 = b.into();
    let quotient = a / b;

    // Safe to unwrap here as `quotient` is always in `felt252` range
    quotient.try_into().unwrap()
}

#[cfg(test)]
mod tests {
    use test::test_utils::assert_eq;

    #[test]
    fn test_add_1() {
        assert_eq(@super::add(1, 2), @3, 'FAILED');
    }

    #[test]
    fn test_add_2() {
        assert_eq(
            @super::add(0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, 1),
            @0x800000000000011000000000000000000000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    #[should_panic(expected: ('SM_ADD_OF',))]
    fn test_add_overflow_1() {
        super::add(0x800000000000011000000000000000000000000000000000000000000000000, 1);
    }

    #[test]
    #[should_panic(expected: ('SM_ADD_OF',))]
    fn test_add_overflow_2() {
        super::add(
            0x800000000000011000000000000000000000000000000000000000000000000,
            0x800000000000011000000000000000000000000000000000000000000000000
        );
    }

    #[test]
    fn test_sub_1() {
        assert_eq(@super::sub(3, 2), @1, 'FAILED');
    }

    #[test]
    fn test_sub_2() {
        assert_eq(
            @super::sub(0x800000000000011000000000000000000000000000000000000000000000000, 1),
            @0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff,
            'FAILED'
        );
    }

    #[test]
    #[should_panic(expected: ('SM_SUB_UF',))]
    fn test_sub_underflow_1() {
        super::sub(0, 1);
    }

    #[test]
    #[should_panic(expected: ('SM_SUB_UF',))]
    fn test_sub_underflow_2() {
        super::sub(
            0x100000000000000000000000000000000,
            0x400000000000000000000000000000000000000000000000000000000000000
        );
    }

    #[test]
    fn test_mul_1() {
        assert_eq(@super::mul(2, 3), @6, 'FAILED');
    }

    #[test]
    fn test_mul_2() {
        assert_eq(
            @super::mul(0x100000000000000000000000000000000, 0x400),
            @0x40000000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_felt_overflow() {
        super::mul(0x400000000000008800000000000000000000000000000000000000000000000, 3);
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_uint256_overflow() {
        super::mul(0x400000000000000000000000000000000000000000000000000000000000000, 0x20);
    }

    #[test]
    fn test_div_1() {
        assert_eq(@super::div(6, 3), @2, 'FAILED');
    }

    #[test]
    fn test_div_2() {
        assert_eq(
            @super::div(0x40000000000000000000000000000000000, 0x400),
            @0x100000000000000000000000000000000,
            'FAILED'
        );
    }

    #[test]
    fn test_div_3() {
        assert_eq(@super::div(100, 3), @33, 'FAILED');
    }

    #[test]
    #[should_panic(expected: ('SM_DIV_ZERO',))]
    fn test_div_division_by_zero() {
        super::div(999, 0);
    }
        }

    }
    mod safe_decimal_math { 
        use super::{pow, safe_math};

// These two consts MUST be the same.
const SCALE: felt252 = 1000000000000000000000000000;
const SCALE_U256: u256 = 1000000000000000000000000000;

/// This function assumes `b` is scaled by `SCALE`
fn mul(a: felt252, b: felt252) -> felt252 {
    let scaled_product = safe_math::mul(a, b);
    safe_math::div(scaled_product, SCALE)
}

/// This function assumes `b` is scaled by `SCALE`
fn div(a: felt252, b: felt252) -> felt252 {
    let scaled_a = safe_math::mul(a, SCALE);
    safe_math::div(scaled_a, b)
}

/// This function assumes `b` is scaled by `10 ^ b_decimals`
fn mul_decimals(a: felt252, b: felt252, b_decimals: felt252) -> felt252 {
    // `ten_pow` already handles overflow anyways
    let scale = pow::ten_pow(b_decimals);

    let scaled_product = safe_math::mul(a, b);
    safe_math::div(scaled_product, scale)
}

/// This function assumes `b` is scaled by `10 ^ b_decimals`
fn div_decimals(a: felt252, b: felt252, b_decimals: felt252) -> felt252 {
    // `ten_pow` already handles overflow anyways
    let scale = pow::ten_pow(b_decimals);

    let scaled_a = safe_math::mul(a, scale);
    safe_math::div(scaled_a, b)
}

#[cfg(test)]
mod tests {
    use test::test_utils::assert_eq;

    #[test]
    fn test_mul() {
        assert_eq(@super::mul(10, 2000000000000000000000000000), @20, 'FAILED');
    }

    #[test]
    fn test_mul_decimals() {
        assert_eq(@super::mul_decimals(10, 2000000000000000000000000000, 27), @20, 'FAILED');
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_overflow() {
        super::mul(
            0x400000000000000000000000000000000000000000000000000000000000000,
            2000000000000000000000000000
        );
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_decimals_overflow() {
        super::mul_decimals(
            0x400000000000000000000000000000000000000000000000000000000000000,
            2000000000000000000000000000,
            27
        );
    }

    #[test]
    fn test_div() {
        assert_eq(@super::div(10, 2000000000000000000000000000), @5, 'FAILED');
    }

    #[test]
    fn test_div_decimals() {
        assert_eq(@super::div_decimals(10, 2000000000000000000000000000, 27), @5, 'FAILED');
    }
        }

    }
    mod ownable {
        // This is a re-implementation of OpenZeppelin's Cairo 0 `Ownable` library (v0.6.1):
//
// https://github.com/OpenZeppelin/cairo-contracts/blob/4dd04250c55ae8a5bbcb72663c989bb204e8d998/src/openzeppelin/access/ownable/library.cairo
//
// Not using their own Cairo 1 version because, as of this writing:
//
// 1. It's not officially released yet (v0.6.1 is still the latest release);
// 2. It's implemented as a contract instead of a library, so there seems to be no way to integrate
//    into our contract;
// 3. It changed from using the `Ownable_owner` storage slot to `_owner`, which is a breaking
//    change. We need to maintain storage backward compatibility;
// 4. Our re-implementation here is more flexible by abstracting away storage and events.

use zeroable::Zeroable;

use starknet::{ContractAddress, contract_address_const, get_caller_address};

mod errors {
    const NOT_OWNER: felt252 = 'OWN_NOT_OWNER';
    const ZERO_ADDRESS: felt252 = 'OWN_ZERO_ADDRESS';
}

/// This trait abstracts away the `ownable` library's interaction with the parent contract.
trait Ownable<T> {
    // Storage proxy
    fn read_owner(self: @T) -> ContractAddress;

    // Storage proxy
    fn write_owner(ref self: T, owner: ContractAddress);

    // Event emission proxy
    fn emit_ownership_transferred(
        ref self: T, previous_owner: ContractAddress, new_owner: ContractAddress
    );
}

fn initializer<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(
    ref self: T, owner: ContractAddress
) {
    __private::_transfer_ownership(ref self, owner);
}

fn assert_only_owner<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(self: @T) {
    let owner = self.read_owner();
    let caller = get_caller_address();
    assert(caller.is_non_zero(), errors::ZERO_ADDRESS);
    assert(owner == caller, errors::NOT_OWNER);
}

fn owner<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(self: @T) -> ContractAddress {
    self.read_owner()
}

fn transfer_ownership<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(
    ref self: T, new_owner: ContractAddress
) {
    assert(new_owner.is_non_zero(), errors::ZERO_ADDRESS);
    assert_only_owner(@self);
    __private::_transfer_ownership(ref self, new_owner);
}

fn renounce_ownership<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(ref self: T) {
    assert_only_owner(@self);
    __private::_transfer_ownership(ref self, contract_address_const::<0>());
}

// Not public API (Cairo does not support _real_ private modules yet)
mod __private {
    use starknet::ContractAddress;

    use super::Ownable;

    fn _transfer_ownership<T, impl TOwnable: Ownable<T>, impl TDrop: Drop<T>>(
        ref self: T, new_owner: ContractAddress
    ) {
        let previous_owner = self.read_owner();
        self.write_owner(new_owner);
        self.emit_ownership_transferred(previous_owner, new_owner);
    }
        }

    }
    mod reentrancy_guard {
        // This is a re-implementation of OpenZeppelin's Cairo 0 `ReentrancyGuard` library (v0.6.1):
//
// https://github.com/OpenZeppelin/cairo-contracts/blob/70cbd05ed24ccd147f24b18c638dbd6e7fea88bb/src/openzeppelin/security/reentrancyguard/library.cairo
//
// Not using their own Cairo 1 version because, as of this writing:
//
// 1. It's not officially released yet (v0.6.1 is still the latest release);
// 2. It's implemented as a contract instead of a library, so there seems to be no way to integrate
//    into our contract;

use zeroable::Zeroable;

use starknet::{ContractAddress, contract_address_const, get_caller_address};

mod errors {
    const REENTRANT_CALL: felt252 = 'RG_REENTRANT_CALL';
}

/// This trait abstracts away the `reentrancy_guard` library's interaction with the parent contract.
trait ReentrancyGuard<T> {
    // Storage proxy
    fn read_entered(self: @T) -> bool;

    // Storage proxy
    fn write_entered(ref self: T, entered: bool);
}

fn start<T, impl TReentrancyGuard: ReentrancyGuard<T>, impl TDrop: Drop<T>>(ref self: T) {
    let has_entered = self.read_entered();
    assert(!has_entered, errors::REENTRANT_CALL);
    self.write_entered(true);
}

fn end<T, impl TReentrancyGuard: ReentrancyGuard<T>, impl TDrop: Drop<T>>(ref self: T) {
    self.write_entered(false);
        }

    }
}
mod interfaces {
    use starknet::{ClassHash, ContractAddress};

#[starknet::interface]
trait ITestContract<TContractState> {
    fn get_value(self: @TContractState) -> felt252;

    fn set_value(ref self: TContractState, value: felt252);
}

#[starknet::interface]
trait IMarket<TContractState> {
    //
    // Getters
    //

    fn get_reserve_data(self: @TContractState, token: ContractAddress) -> MarketReserveData;

    fn get_lending_accumulator(self: @TContractState, token: ContractAddress) -> felt252;

    fn get_debt_accumulator(self: @TContractState, token: ContractAddress) -> felt252;

    // NOTE: this function shouldn't have been made public as it always just returns 0 when called
    //       from external contracts. However, the original Cairo 0 version made it public by
    //       mistake. So we're retaining it here to be 100% backward-compatible.
    // WARN: this must be run BEFORE adjusting the accumulators (otherwise always returns 0)
    fn get_pending_treasury_amount(self: @TContractState, token: ContractAddress) -> felt252;

    fn get_total_debt_for_token(self: @TContractState, token: ContractAddress) -> felt252;

    fn get_user_debt_for_token(
        self: @TContractState, user: ContractAddress, token: ContractAddress
    ) -> felt252;

    /// Returns a bitmap of user flags.
    fn get_user_flags(self: @TContractState, user: ContractAddress) -> felt252;

    fn is_user_undercollateralized(
        self: @TContractState, user: ContractAddress, apply_borrow_factor: bool
    ) -> bool;

    fn is_collateral_enabled(
        self: @TContractState, user: ContractAddress, token: ContractAddress
    ) -> bool;

    fn user_has_debt(self: @TContractState, user: ContractAddress) -> bool;

    //
    // Permissionless entrypoints
    //

    fn deposit(ref self: TContractState, token: ContractAddress, amount: felt252);

    fn withdraw(ref self: TContractState, token: ContractAddress, amount: felt252);

    fn withdraw_all(ref self: TContractState, token: ContractAddress);

    fn borrow(ref self: TContractState, token: ContractAddress, amount: felt252);

    fn repay(ref self: TContractState, token: ContractAddress, amount: felt252);

    fn repay_for(
        ref self: TContractState,
        token: ContractAddress,
        amount: felt252,
        beneficiary: ContractAddress
    );

    fn repay_all(ref self: TContractState, token: ContractAddress);

    fn enable_collateral(ref self: TContractState, token: ContractAddress);

    fn disable_collateral(ref self: TContractState, token: ContractAddress);

    /// With the current design, liquidators are responsible for calculating the maximum amount allowed.
    /// We simply check collteralization factor is below one after liquidation.
    /// TODO: calculate max amount on-chain because compute is cheap on StarkNet.
    fn liquidate(
        ref self: TContractState,
        user: ContractAddress,
        debt_token: ContractAddress,
        amount: felt252,
        collateral_token: ContractAddress
    );

    fn flash_loan(
        ref self: TContractState,
        receiver: ContractAddress,
        token: ContractAddress,
        amount: felt252,
        calldata: Span::<felt252>
    );

    //
    // Permissioned entrypoints
    //

    fn upgrade(ref self: TContractState, new_implementation: ClassHash);

    fn add_reserve(
        ref self: TContractState,
        token: ContractAddress,
        z_token: ContractAddress,
        interest_rate_model: ContractAddress,
        collateral_factor: felt252,
        borrow_factor: felt252,
        reserve_factor: felt252,
        flash_loan_fee: felt252,
        liquidation_bonus: felt252
    );

    fn set_treasury(ref self: TContractState, new_treasury: ContractAddress);

    fn set_interest_rate_model(
        ref self: TContractState, token: ContractAddress, interest_rate_model: ContractAddress
    );

    fn set_collateral_factor(
        ref self: TContractState, token: ContractAddress, collateral_factor: felt252
    );

    fn set_borrow_factor(ref self: TContractState, token: ContractAddress, borrow_factor: felt252);

    fn set_reserve_factor(
        ref self: TContractState, token: ContractAddress, reserve_factor: felt252
    );

    fn set_debt_limit(ref self: TContractState, token: ContractAddress, limit: felt252);

    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);

    fn renounce_ownership(ref self: TContractState);
}

#[starknet::interface]
trait IZToken<TContractState> {
    //
    // Getters
    //

    fn name(self: @TContractState) -> felt252;

    fn symbol(self: @TContractState) -> felt252;

    fn decimals(self: @TContractState) -> felt252;

    fn totalSupply(self: @TContractState) -> u256;

    fn felt_total_supply(self: @TContractState) -> felt252;

    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;

    fn felt_balance_of(self: @TContractState, account: ContractAddress) -> felt252;

    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;

    fn felt_allowance(
        self: @TContractState, owner: ContractAddress, spender: ContractAddress
    ) -> felt252;

    fn underlying_token(self: @TContractState) -> ContractAddress;

    fn get_raw_total_supply(self: @TContractState) -> felt252;

    //
    // Permissionless entrypoints
    //

    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;

    fn felt_transfer(ref self: TContractState, recipient: ContractAddress, amount: felt252) -> bool;

    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    fn felt_transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: felt252
    ) -> bool;

    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;

    fn felt_approve(ref self: TContractState, spender: ContractAddress, amount: felt252) -> bool;

    /// This method exists because ZToken balances are always increasing (unless when no interest is
    /// accumulating). so it's hard for off-chain actors to clear balance completely.
    ///
    /// Returns the actual amount transferred.
    fn transfer_all(ref self: TContractState, recipient: ContractAddress) -> felt252;

    /// Emits raw balances of a list of users via the `EchoRawBalance` event.
    ///
    /// This function (and the event) exists as there used to be a bug in this contract where the
    /// `RawTransfer` event was missing in some cases, making it impossible to track accurate raw
    /// balances using `RawTransfer`. The bug itself has been fixed but the `RawTransfer` history of
    /// users before the fix is broken. This event enables indexers to calibrate raw balances. Once
    /// deployed, this event must be emitted for any user who has ever placed a deposit before the
    /// contract upgrade.
    fn echo_raw_balances(ref self: TContractState, users: Span<ContractAddress>);

    //
    // Permissioned entrypoints
    //

    fn upgrade(ref self: TContractState, new_implementation: ClassHash);

    /// Returns whether the user had zero balance before minting.
    fn mint(ref self: TContractState, to: ContractAddress, amount: felt252) -> bool;

    fn burn(ref self: TContractState, user: ContractAddress, amount: felt252);

    /// Returns the actual amount burnt.
    fn burn_all(ref self: TContractState, user: ContractAddress) -> felt252;

    fn move(
        ref self: TContractState,
        from_account: ContractAddress,
        to_account: ContractAddress,
        amount: felt252
    );

    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);

    fn renounce_ownership(ref self: TContractState);
}

#[starknet::interface]
trait IZklendFlashCallback<TContractState> {
    fn zklend_flash_callback(
        ref self: TContractState, initiator: ContractAddress, calldata: Span::<felt252>
    );
}

#[starknet::interface]
trait IPriceOracle<TContractState> {
    //
    // Getters
    //

    /// Get the price of the token in USD with 8 decimals.
    fn get_price(self: @TContractState, token: ContractAddress) -> felt252;

    /// Get the price of the token in USD with 8 decimals and update timestamp.
    fn get_price_with_time(self: @TContractState, token: ContractAddress) -> PriceWithUpdateTime;
}

#[starknet::interface]
trait IDefaultPriceOracle<TContractState> {
    //
    // Permissioned entrypoints
    //

    fn set_token_source(ref self: TContractState, token: ContractAddress, source: ContractAddress);
}

#[starknet::interface]
trait IPriceOracleSource<TContractState> {
    //
    // Getters
    //

    /// Get the price of the token in USD with 8 decimals.
    fn get_price(self: @TContractState) -> felt252;

    /// Get the price of the token in USD with 8 decimals and update timestamp.
    fn get_price_with_time(self: @TContractState) -> PriceWithUpdateTime;
}

#[starknet::interface]
trait IInterestRateModel<TContractState> {
    //
    // Getters
    //

    fn get_interest_rates(
        self: @TContractState, reserve_balance: felt252, total_debt: felt252
    ) -> ModelRates;
}

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    fn get_data_median(self: @TContractState, data_type: PragmaDataType) -> PragmaPricesResponse;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn decimals(self: @TContractState) -> felt252;

    fn balanceOf(self: @TContractState, user: ContractAddress) -> u256;

    // TODO: support non-standard tokens (without return values) by using helper instead
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;

    // TODO: support non-standard tokens (without return values) by using helper instead
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
}

#[derive(Drop, Serde, starknet::Store)]
struct MarketReserveData {
    enabled: bool,
    decimals: felt252,
    z_token_address: ContractAddress,
    interest_rate_model: ContractAddress,
    collateral_factor: felt252,
    borrow_factor: felt252,
    reserve_factor: felt252,
    last_update_timestamp: felt252,
    lending_accumulator: felt252,
    debt_accumulator: felt252,
    current_lending_rate: felt252,
    current_borrowing_rate: felt252,
    raw_total_debt: felt252,
    flash_loan_fee: felt252,
    liquidation_bonus: felt252,
    debt_limit: felt252
}

#[derive(Drop, Serde)]
struct ModelRates {
    lending_rate: felt252,
    borrowing_rate: felt252
}

#[derive(Drop, Serde)]
struct PriceWithUpdateTime {
    price: felt252,
    update_time: felt252
}

#[derive(Drop, Serde)]
enum PragmaDataType {
    SpotEntry: felt252,
    FutureEntry: (felt252, u64),
    GenericEntry: felt252,
}

#[derive(Drop, Serde)]
struct PragmaPricesResponse {
    price: u128,
    decimals: u32,
    last_updated_timestamp: u64,
    num_sources_aggregated: u32,
    expiration_timestamp: Option<u64>,
    }
}

mod view {
    use traits::Into;
use zeroable::Zeroable;

use starknet::{ContractAddress, get_block_timestamp};

// Hack to simulate the `crate` keyword

use super::interfaces::{IZTokenDispatcher, IZTokenDispatcherTrait, MarketReserveData};
use super::libraries::{safe_decimal_math, safe_math};

use super::internal;
use super::storage::{ReservesStorageShortcuts, ReservesStorageShortcutsImpl};

use super::Market as contract;

use contract::ContractState;

// These are hacks that depend on compiler implementation details :(
// But they're needed for refactoring the contract code into modules like this one.
use contract::raw_user_debtsContractMemberStateTrait;
use contract::reservesContractMemberStateTrait;
use contract::treasuryContractMemberStateTrait;
use contract::user_flagsContractMemberStateTrait;

const SECONDS_PER_YEAR: felt252 = 31536000;

fn get_reserve_data(self: @ContractState, token: ContractAddress) -> MarketReserveData {
    self.reserves.read(token)
}

fn get_lending_accumulator(self: @ContractState, token: ContractAddress) -> felt252 {
    internal::assert_reserve_enabled(self, token);
    let reserve = self.reserves.read_for_get_lending_accumulator(token);

    let block_timestamp: felt252 = get_block_timestamp().into();
    if reserve.last_update_timestamp == block_timestamp {
        // Accumulator already updated on the same block
        reserve.lending_accumulator
    } else {
        // Apply simple interest
        let time_diff = safe_math::sub(block_timestamp, reserve.last_update_timestamp);
        
        // Treats reserve factor as zero if treasury address is not set
        let treasury_addr = self.treasury.read();
        let effective_reserve_factor = if treasury_addr.is_zero() {
            0
        } else {
            reserve.reserve_factor
        };

        let one_minus_reserve_factor = safe_math::sub(
            safe_decimal_math::SCALE, effective_reserve_factor
        );

        // New accumulator
        // (current_lending_rate * (1 - reserve_factor) * time_diff / SECONDS_PER_YEAR + 1) * accumulator
        let temp_1 = safe_math::mul(reserve.current_lending_rate, time_diff);
        let temp_2 = safe_math::mul(temp_1, one_minus_reserve_factor);
        let temp_3 = safe_math::div(temp_2, SECONDS_PER_YEAR);
        let temp_4 = safe_math::div(temp_3, safe_decimal_math::SCALE);
        let temp_5 = safe_math::add(temp_4, safe_decimal_math::SCALE);
        let latest_accumulator = safe_decimal_math::mul(temp_5, reserve.lending_accumulator);

        latest_accumulator
    }
}

fn get_debt_accumulator(self: @ContractState, token: ContractAddress) -> felt252 {
    internal::assert_reserve_enabled(self, token);
    let reserve = self.reserves.read_for_get_debt_accumulator(token);

    let block_timestamp: felt252 = get_block_timestamp().into();
    if (reserve.last_update_timestamp == block_timestamp) {
        // Accumulator already updated on the same block
        reserve.debt_accumulator
    } else {
        //println!("---Debt accumulartor");
        // Apply simple interest
        let time_diff = safe_math::sub(block_timestamp, reserve.last_update_timestamp);

        // (current_borrowing_rate * time_diff / SECONDS_PER_YEAR + 1) * accumulator
        let temp_1 = safe_math::mul(reserve.current_borrowing_rate, time_diff);
        let temp_2 = safe_math::div(temp_1, SECONDS_PER_YEAR);
        let temp_3 = safe_math::add(temp_2, safe_decimal_math::SCALE);
        let latest_accumulator = safe_decimal_math::mul(temp_3, reserve.debt_accumulator);

        latest_accumulator
    }
}

// WARN: this must be run BEFORE adjusting the accumulators (otherwise always returns 0)
fn get_pending_treasury_amount(self: @ContractState, token: ContractAddress) -> felt252 {
    internal::assert_reserve_enabled(self, token);
    let reserve = self.reserves.read_for_get_pending_treasury_amount(token);

    // Nothing for treasury if address set to zero
    let treasury_addr = self.treasury.read();
    if treasury_addr.is_zero() {
        return 0;
    }

    let block_timestamp: felt252 = get_block_timestamp().into();
    if reserve.last_update_timestamp == block_timestamp {
        // Treasury amount already settled on the same block
        0
    } else {
        // Apply simple interest
        let time_diff = safe_math::sub(block_timestamp, reserve.last_update_timestamp);

        let raw_supply = IZTokenDispatcher { contract_address: reserve.z_token_address }
            .get_raw_total_supply();

        // Amount to be paid to treasury (based on the adjusted accumulator)
        // (current_lending_rate * reserve_factor * time_diff / SECONDS_PER_YEAR) * accumulator * raw_supply
        let temp_1 = safe_math::mul(reserve.current_lending_rate, time_diff);
        let temp_2 = safe_math::mul(temp_1, reserve.reserve_factor);
        let temp_3 = safe_math::div(temp_2, SECONDS_PER_YEAR);
        let temp_4 = safe_math::div(temp_3, safe_decimal_math::SCALE);
        let temp_5 = safe_decimal_math::mul(temp_4, reserve.lending_accumulator);
        let amount_to_treasury = safe_decimal_math::mul(raw_supply, temp_5);

        amount_to_treasury
    }
}

fn get_total_debt_for_token(self: @ContractState, token: ContractAddress) -> felt252 {
    internal::assert_reserve_enabled(self, token);
    let raw_total_debt = self.reserves.read_raw_total_debt(token);

    let debt_accumulator = get_debt_accumulator(self, token);
    let scaled_up_debt = safe_decimal_math::mul(raw_total_debt, debt_accumulator);
    scaled_up_debt
}

fn get_user_debt_for_token(
    self: @ContractState, user: ContractAddress, token: ContractAddress
) -> felt252 {
    let debt_accumulator = get_debt_accumulator(self, token);
    let raw_debt = self.raw_user_debts.read((user, token));

    let scaled_up_debt = safe_decimal_math::mul(raw_debt, debt_accumulator);
    scaled_up_debt
}

/// Returns a bitmap of user flags.
fn get_user_flags(self: @ContractState, user: ContractAddress) -> felt252 {
    self.user_flags.read(user)
}

fn is_user_undercollateralized(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) -> bool {
    let user_not_undercollateralized = internal::is_not_undercollateralized(
        self, user, apply_borrow_factor
    );

    !user_not_undercollateralized
}

fn is_collateral_enabled(
    self: @ContractState, user: ContractAddress, token: ContractAddress
) -> bool {
    internal::is_used_as_collateral(self, user, token)
}

    fn user_has_debt(self: @ContractState, user: ContractAddress) -> bool {
        internal::user_has_debt(self, user)
    }

}
mod external {
    use traits::Into;
use zeroable::Zeroable;

use starknet::{ClassHash, ContractAddress, SyscallResultTrait, replace_class_syscall};
use starknet::event::EventEmitter;

// Hack to simulate the `crate` keyword


use super::interfaces::{
    IERC20Dispatcher, IERC20DispatcherTrait, IZTokenDispatcher, IZTokenDispatcherTrait,
    MarketReserveData
};
use super::libraries::{ownable, reentrancy_guard, safe_decimal_math};

use super::storage::{ReservesStorageShortcuts, ReservesStorageShortcutsImpl};
use super::traits::{MarketOwnable, MarketReentrancyGuard};
use super::{errors, internal};

use super::Market as contract;
use super::UpdatedAccumulators;

use contract::ContractState;

// These are hacks that depend on compiler implementation details :(
// But they're needed for refactoring the contract code into modules like this one.
use contract::oracleContractMemberStateTrait;
use contract::reserve_countContractMemberStateTrait;
use contract::reserve_indicesContractMemberStateTrait;
use contract::reserve_tokensContractMemberStateTrait;
use contract::reservesContractMemberStateTrait;
use contract::treasuryContractMemberStateTrait;

fn initializer(ref self: ContractState, owner: ContractAddress, oracle: ContractAddress) {
    assert(owner.is_non_zero(), errors::ZERO_ADDRESS);
    assert(oracle.is_non_zero(), errors::ZERO_ADDRESS);

    ownable::initializer(ref self, owner);
    self.oracle.write(oracle);
}

fn deposit(ref self: ContractState, token: ContractAddress, amount: felt252) {
    reentrancy_guard::start(ref self);
    internal::deposit(ref self, token, amount);
    reentrancy_guard::end(ref self);
}

fn withdraw(ref self: ContractState, token: ContractAddress, amount: felt252) {
    reentrancy_guard::start(ref self);
    internal::withdraw(ref self, token, amount);
    reentrancy_guard::end(ref self);
}

fn withdraw_all(ref self: ContractState, token: ContractAddress) {
    reentrancy_guard::start(ref self);
    internal::withdraw_all(ref self, token);
    reentrancy_guard::end(ref self);
}

fn borrow(ref self: ContractState, token: ContractAddress, amount: felt252) {
    reentrancy_guard::start(ref self);
    internal::borrow(ref self, token, amount);
    reentrancy_guard::end(ref self);
}

fn repay(ref self: ContractState, token: ContractAddress, amount: felt252) {
    reentrancy_guard::start(ref self);
    internal::repay(ref self, token, amount);
    reentrancy_guard::end(ref self);
}

fn repay_for(
    ref self: ContractState, token: ContractAddress, amount: felt252, beneficiary: ContractAddress
) {
    reentrancy_guard::start(ref self);
    internal::repay_for(ref self, token, amount, beneficiary);
    reentrancy_guard::end(ref self);
}

fn repay_all(ref self: ContractState, token: ContractAddress) {
    reentrancy_guard::start(ref self);
    internal::repay_all(ref self, token);
    reentrancy_guard::end(ref self);
}

fn enable_collateral(ref self: ContractState, token: ContractAddress) {
    reentrancy_guard::start(ref self);
    internal::enable_collateral(ref self, token);
    reentrancy_guard::end(ref self);
}

fn disable_collateral(ref self: ContractState, token: ContractAddress) {
    reentrancy_guard::start(ref self);
    internal::disable_collateral(ref self, token);
    reentrancy_guard::end(ref self);
}

/// With the current design, liquidators are responsible for calculating the maximum amount allowed.
/// We simply check collteralization factor is below one after liquidation.
/// TODO: calculate max amount on-chain because compute is cheap on StarkNet.
fn liquidate(
    ref self: ContractState,
    user: ContractAddress,
    debt_token: ContractAddress,
    amount: felt252,
    collateral_token: ContractAddress
) {
    reentrancy_guard::start(ref self);
    internal::liquidate(ref self, user, debt_token, amount, collateral_token);
    reentrancy_guard::end(ref self);
}

fn flash_loan(
    ref self: ContractState,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: felt252,
    calldata: Span::<felt252>
) {
    reentrancy_guard::start(ref self);
    internal::flash_loan(ref self, receiver, token, amount, calldata);
    reentrancy_guard::end(ref self);
}

fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
    ownable::assert_only_owner(@self);
    replace_class_syscall(new_implementation).unwrap_syscall();

    self
        .emit(
            contract::Event::ContractUpgraded(
                contract::ContractUpgraded { new_class_hash: new_implementation }
            )
        );
}

fn add_reserve(
    ref self: ContractState,
    token: ContractAddress,
    z_token: ContractAddress,
    interest_rate_model: ContractAddress,
    collateral_factor: felt252,
    borrow_factor: felt252,
    reserve_factor: felt252,
    flash_loan_fee: felt252,
    liquidation_bonus: felt252
) {
    ownable::assert_only_owner(@self);

    assert(token.is_non_zero(), errors::ZERO_ADDRESS);
    assert(z_token.is_non_zero(), errors::ZERO_ADDRESS);
    assert(interest_rate_model.is_non_zero(), errors::ZERO_ADDRESS);

    let existing_reserve_z_token = self.reserves.read_z_token_address(token);
    assert(existing_reserve_z_token.is_zero(), errors::RESERVE_ALREADY_EXISTS);

    // Checks collateral_factor range
    assert(
        Into::<_, u256>::into(collateral_factor) <= safe_decimal_math::SCALE_U256,
        errors::COLLATERAL_FACTOR_RANGE
    );

    // Checks borrow_factor range
    assert(
        Into::<_, u256>::into(borrow_factor) <= safe_decimal_math::SCALE_U256,
        errors::BORROW_FACTOR_RANGE
    );

    // Checks reserve_factor range
    assert(
        Into::<_, u256>::into(reserve_factor) <= safe_decimal_math::SCALE_U256,
        errors::RESERVE_FACTOR_RANGE
    );

    // There's no need to limit `flash_loan_fee` range as it's charged on top of the loan amount.

    let decimals = IERC20Dispatcher { contract_address: token }.decimals();
    let z_token_decimals = IERC20Dispatcher { contract_address: z_token }.decimals();
    assert(decimals == z_token_decimals, errors::TOKEN_DECIMALS_MISMATCH);

    // Checks underlying token of the Z token contract
    let z_token_underlying = IZTokenDispatcher { contract_address: z_token }.underlying_token();
    assert(z_token_underlying == token, errors::UNDERLYING_TOKEN_MISMATCH);

    let new_reserve = MarketReserveData {
        enabled: true,
        decimals,
        z_token_address: z_token,
        interest_rate_model,
        collateral_factor,
        borrow_factor,
        reserve_factor,
        last_update_timestamp: 0,
        lending_accumulator: safe_decimal_math::SCALE,
        debt_accumulator: safe_decimal_math::SCALE,
        current_lending_rate: 0,
        current_borrowing_rate: 0,
        raw_total_debt: 0,
        flash_loan_fee,
        liquidation_bonus,
        debt_limit: 0,
    };
    self.reserves.write(token, new_reserve);

    self
        .emit(
            contract::Event::NewReserve(
                contract::NewReserve {
                    token,
                    z_token,
                    decimals,
                    interest_rate_model,
                    collateral_factor,
                    borrow_factor,
                    reserve_factor,
                    flash_loan_fee,
                    liquidation_bonus
                }
            )
        );

    self
        .emit(
            contract::Event::AccumulatorsSync(
                contract::AccumulatorsSync {
                    token,
                    lending_accumulator: safe_decimal_math::SCALE,
                    debt_accumulator: safe_decimal_math::SCALE
                }
            )
        );
    self
        .emit(
            contract::Event::InterestRatesSync(
                contract::InterestRatesSync { token, lending_rate: 0, borrowing_rate: 0 }
            )
        );

    let current_reserve_count = self.reserve_count.read();
    let new_reserve_count = current_reserve_count + 1;
    self.reserve_count.write(new_reserve_count);
    self.reserve_tokens.write(current_reserve_count, token);
    self.reserve_indices.write(token, current_reserve_count);

    // We can only have up to 125 reserves due to the use of bitmap for user collateral usage
    // and debt flags until we will change to use more than 1 felt for that.
    assert(Into::<_, u256>::into(new_reserve_count) <= 125, errors::TOO_MANY_RESERVES);
}

fn set_treasury(ref self: ContractState, new_treasury: ContractAddress) {
    ownable::assert_only_owner(@self);

    self.treasury.write(new_treasury);
    self.emit(contract::Event::TreasuryUpdate(contract::TreasuryUpdate { new_treasury }));
}

fn set_interest_rate_model(
    ref self: ContractState, token: ContractAddress, interest_rate_model: ContractAddress
) {
    ownable::assert_only_owner(@self);

    assert(interest_rate_model.is_non_zero(), errors::ZERO_ADDRESS);

    internal::assert_reserve_exists(@self, token);

    // Settles interest payments up until this point to prevent retrospective changes.
    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        internal::update_accumulators(
        ref self, token
    );

    self.reserves.write_interest_rate_model(token, interest_rate_model);
    self
        .emit(
            contract::Event::InterestRateModelUpdate(
                contract::InterestRateModelUpdate { token, interest_rate_model }
            )
        );

    internal::update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        false, // is_delta_reserve_balance_negative
        0, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        0 // abs_delta_raw_total_debt
    );
}

fn set_collateral_factor(
    ref self: ContractState, token: ContractAddress, collateral_factor: felt252
) {
    ownable::assert_only_owner(@self);

    // Checks collateral_factor range
    assert(
        Into::<_, u256>::into(collateral_factor) <= safe_decimal_math::SCALE_U256,
        errors::COLLATERAL_FACTOR_RANGE
    );

    internal::assert_reserve_exists(@self, token);
    self.reserves.write_collateral_factor(token, collateral_factor);
    self
        .emit(
            contract::Event::CollateralFactorUpdate(
                contract::CollateralFactorUpdate { token, collateral_factor }
            )
        );
}

fn set_borrow_factor(ref self: ContractState, token: ContractAddress, borrow_factor: felt252) {
    ownable::assert_only_owner(@self);

    // Checks borrow_factor range
    assert(
        Into::<_, u256>::into(borrow_factor) <= safe_decimal_math::SCALE_U256,
        errors::BORROW_FACTOR_RANGE
    );

    internal::assert_reserve_exists(@self, token);
    self.reserves.write_borrow_factor(token, borrow_factor);
    self
        .emit(
            contract::Event::BorrowFactorUpdate(
                contract::BorrowFactorUpdate { token, borrow_factor }
            )
        );
}

fn set_reserve_factor(ref self: ContractState, token: ContractAddress, reserve_factor: felt252) {
    ownable::assert_only_owner(@self);

    // Checks reserve_factor range
    assert(
        Into::<_, u256>::into(reserve_factor) <= safe_decimal_math::SCALE_U256,
        errors::RESERVE_FACTOR_RANGE
    );

    internal::assert_reserve_exists(@self, token);

    // Settles interest payments up until this point to prevent retrospective changes.
    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        internal::update_accumulators(
        ref self, token
    );
    internal::update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        false, // is_delta_reserve_balance_negative
        0, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        0 // abs_delta_raw_total_debt
    );

    self.reserves.write_reserve_factor(token, reserve_factor);
    self
        .emit(
            contract::Event::ReserveFactorUpdate(
                contract::ReserveFactorUpdate { token, reserve_factor }
            )
        );
}

fn set_debt_limit(ref self: ContractState, token: ContractAddress, limit: felt252) {
    ownable::assert_only_owner(@self);

    internal::assert_reserve_exists(@self, token);
    self.reserves.write_debt_limit(token, limit);
    self.emit(contract::Event::DebtLimitUpdate(contract::DebtLimitUpdate { token, limit }));
}

fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
    ownable::transfer_ownership(ref self, new_owner);
}

    fn renounce_ownership(ref self: ContractState) {
        ownable::renounce_ownership(ref self);
    }

}
mod internal {
    // Note to code readers
//
// The original codebase was written in Cairo 0 during the early days, and the code you're reading
// right now is almost the _direct translation_ of the orignal code into Cairo (1). The process
// worked by manually porting the code line by line. This is because the original code has already
// been deployed into production, and we need to carefully make sure it's backward-compatible.
//
// As such, there might be places where the implementation feels odd and non-idiomatic. It's most
// likely the legacy from the original code, as Cairo 0 was extremely limited (it didn't even have
// loops!). These can be fixed later by refactoring and optimizing the code, though it's quite
// unlike to happen. After all, if it ain't broken, don't fix it :)

use option::OptionTrait;
use traits::{Into, TryInto};
use zeroable::Zeroable;

use starknet::event::EventEmitter;
use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

// Hack to simulate the `crate` keyword


use super::interfaces::{
    IERC20Dispatcher, IERC20DispatcherTrait, IInterestRateModelDispatcher,
    IInterestRateModelDispatcherTrait, IPriceOracleDispatcher, IPriceOracleDispatcherTrait,
    IZklendFlashCallbackDispatcher, IZklendFlashCallbackDispatcherTrait, IZTokenDispatcher,
    IZTokenDispatcherTrait, ModelRates
};
use super::libraries::{math, safe_decimal_math, safe_math};

use super::{errors, view};

use super::storage::{ReservesStorageShortcuts, ReservesStorageShortcutsImpl, StorageBatch1};

use super::Market as contract;
use super::UpdatedAccumulators;

use contract::ContractState;

// These are hacks that depend on compiler implementation details :(
// But they're needed for refactoring the contract code into modules like this one.
use contract::oracleContractMemberStateTrait;
use contract::raw_user_debtsContractMemberStateTrait;
use contract::reserve_countContractMemberStateTrait;
use contract::reserve_indicesContractMemberStateTrait;
use contract::reserve_tokensContractMemberStateTrait;
use contract::reservesContractMemberStateTrait;
use contract::treasuryContractMemberStateTrait;
use contract::user_flagsContractMemberStateTrait;

const DEBT_FLAG_FILTER: u256 = 0x2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

struct UserCollateralData {
    collateral_value: felt252,
    collateral_required: felt252
}

struct DebtRepaid {
    raw_amount: felt252,
    face_amount: felt252
}

fn deposit(ref self: ContractState, token: ContractAddress, amount: felt252) {
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    let caller = get_caller_address();
    let this_address = get_contract_address();

    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        update_accumulators(
        ref self, token
    );

    assert_reserve_enabled(@self, token);
    let z_token_address = self.reserves.read_z_token_address(token);

    // Updates interest rate
    update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        false, // is_delta_reserve_balance_negative
        amount, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        0 // abs_delta_raw_total_debt
    );

    self
        .emit(
            contract::Event::Deposit(
                contract::Deposit { user: caller, token: token, face_amount: amount }
            )
        );

    // Takes token from user

    let amount_u256: u256 = amount.into();
    let transfer_success = IERC20Dispatcher { contract_address: token, }
        .transferFrom(caller, this_address, amount_u256);
    assert(transfer_success, errors::TRANSFERFROM_FAILED);

    // Mints ZToken to user
    IZTokenDispatcher { contract_address: z_token_address }.mint(caller, amount);
}

fn withdraw(ref self: ContractState, token: ContractAddress, amount: felt252) {
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    let caller = get_caller_address();
    withdraw_internal(ref self, caller, token, amount);
}

fn withdraw_all(ref self: ContractState, token: ContractAddress) {
    let caller = get_caller_address();
    withdraw_internal(ref self, caller, token, 0);
}

fn borrow(ref self: ContractState, token: ContractAddress, amount: felt252) {
    let caller = get_caller_address();

    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        update_accumulators(
        ref self, token
    );

    assert_reserve_enabled(@self, token);

    let scaled_down_amount = safe_decimal_math::div(amount, updated_debt_accumulator);
    assert(scaled_down_amount.is_non_zero(), errors::INVALID_AMOUNT);

    // Updates user debt data
    let raw_user_debt_before = self.raw_user_debts.read((caller, token));
    let raw_user_debt_after = safe_math::add(raw_user_debt_before, scaled_down_amount);
    self.raw_user_debts.write((caller, token), raw_user_debt_after);

    set_user_has_debt(ref self, caller, token, raw_user_debt_before, raw_user_debt_after);

    // Updates interest rate
    update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        true, // is_delta_reserve_balance_negative
        amount, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        scaled_down_amount // abs_delta_raw_total_debt
    );

    // Enforces token debt limit
    assert_debt_limit_satisfied(@self, token);

    self
        .emit(
            contract::Event::Borrowing(
                contract::Borrowing {
                    user: caller, token: token, raw_amount: scaled_down_amount, face_amount: amount
                }
            )
        );

    // It's easier to post-check collateralization factor
    assert_not_undercollateralized(@self, caller, true);

    let amount_u256: u256 = amount.into();
    let transfer_success = IERC20Dispatcher { contract_address: token }
        .transfer(caller, amount_u256);
    assert(transfer_success, errors::TRANSFER_FAILED);
}

fn repay(ref self: ContractState, token: ContractAddress, amount: felt252) {
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    let caller = get_caller_address();

    let DebtRepaid { raw_amount, face_amount } = repay_debt_route_internal(
        ref self, caller, caller, token, amount
    );
    self
        .emit(
            contract::Event::Repayment(
                contract::Repayment {
                    repayer: caller, beneficiary: caller, token, raw_amount, face_amount
                }
            )
        );
}

fn repay_for(
    ref self: ContractState, token: ContractAddress, amount: felt252, beneficiary: ContractAddress
) {
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    assert(beneficiary.is_non_zero(), errors::ZERO_ADDRESS);

    let caller = get_caller_address();

    let DebtRepaid { raw_amount, face_amount } = repay_debt_route_internal(
        ref self, caller, beneficiary, token, amount
    );
    self
        .emit(
            contract::Event::Repayment(
                contract::Repayment { repayer: caller, beneficiary, token, raw_amount, face_amount }
            )
        );
}

fn repay_all(ref self: ContractState, token: ContractAddress) {
    let caller = get_caller_address();

    let DebtRepaid { raw_amount, face_amount } = repay_debt_route_internal(
        ref self, caller, caller, token, 0
    );
    self
        .emit(
            contract::Event::Repayment(
                contract::Repayment {
                    repayer: caller, beneficiary: caller, token, raw_amount, face_amount
                }
            )
        );
}

fn enable_collateral(ref self: ContractState, token: ContractAddress) {
    let caller = get_caller_address();

    assert_reserve_exists(@self, token);

    set_collateral_usage(ref self, caller, token, true);

    self
        .emit(
            contract::Event::CollateralEnabled(contract::CollateralEnabled { user: caller, token })
        );
}

fn disable_collateral(ref self: ContractState, token: ContractAddress) {
    let caller = get_caller_address();

    assert_reserve_exists(@self, token);

    set_collateral_usage(ref self, caller, token, false);

    // It's easier to post-check collateralization factor
    assert_not_undercollateralized(@self, caller, true);

    self
        .emit(
            contract::Event::CollateralDisabled(
                contract::CollateralDisabled { user: caller, token }
            )
        );
}

fn liquidate(
    ref self: ContractState,
    user: ContractAddress,
    debt_token: ContractAddress,
    amount: felt252,
    collateral_token: ContractAddress
) {
    let caller = get_caller_address();

    // Validates input
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    assert_reserve_enabled(@self, debt_token);
    assert_reserve_enabled(@self, collateral_token);
    let debt_reserve_decimals = self.reserves.read_decimals(debt_token);
    let collateral_reserve = self.reserves.read(collateral_token);

    // Liquidator repays debt for user
    let DebtRepaid { raw_amount, .. } = repay_debt_route_internal(
        ref self, caller, user, debt_token, amount
    );

    // Can only take from assets being used as collateral
    let is_collateral = is_used_as_collateral(@self, user, collateral_token);
    assert(is_collateral, errors::NONCOLLATERAL_TOKEN);

    // Liquidator withdraws collateral from user
    let oracle_addr = self.oracle.read();
    let debt_token_price = IPriceOracleDispatcher { contract_address: oracle_addr }
        .get_price(debt_token);
    let collateral_token_price = IPriceOracleDispatcher { contract_address: oracle_addr }
        .get_price(collateral_token);
    let debt_value_repaid = safe_decimal_math::mul_decimals(
        debt_token_price, amount, debt_reserve_decimals
    );
    let equivalent_collateral_amount = safe_decimal_math::div_decimals(
        debt_value_repaid, collateral_token_price, collateral_reserve.decimals
    );
    let one_plus_liquidation_bonus = safe_math::add(
        safe_decimal_math::SCALE, collateral_reserve.liquidation_bonus
    );
    let collateral_amount_after_bonus = safe_decimal_math::mul(
        equivalent_collateral_amount, one_plus_liquidation_bonus
    );

    IZTokenDispatcher { contract_address: collateral_reserve.z_token_address }
        .move(user, caller, collateral_amount_after_bonus);

    // Checks user collateralization factor after liquidation
    assert_not_overcollateralized(@self, user, false);

    self
        .emit(
            contract::Event::Liquidation(
                contract::Liquidation {
                    liquidator: caller,
                    user,
                    debt_token,
                    debt_raw_amount: raw_amount,
                    debt_face_amount: amount,
                    collateral_token,
                    collateral_amount: collateral_amount_after_bonus,
                }
            )
        );
}

fn flash_loan(
    ref self: ContractState,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: felt252,
    calldata: Span::<felt252>
) {
    let this_address = get_contract_address();

    // Validates input
    assert(amount.is_non_zero(), errors::ZERO_AMOUNT);

    assert_reserve_enabled(@self, token);
    let flash_loan_fee = self.reserves.read_flash_loan_fee(token);

    // Calculates minimum balance after the callback
    let loan_fee = safe_decimal_math::mul(amount, flash_loan_fee);
    let reserve_balance_before: felt252 = IERC20Dispatcher { contract_address: token }
        .balanceOf(this_address)
        .try_into()
        .expect(errors::BALANCE_OVERFLOW);
    let min_balance = safe_math::add(reserve_balance_before, loan_fee);

    // Sends funds to receiver
    let amount_u256: u256 = amount.into();
    let transfer_success = IERC20Dispatcher { contract_address: token }
        .transfer(receiver, amount_u256);
    assert(transfer_success, errors::TRANSFER_FAILED);

    let caller = get_caller_address();

    // Calls receiver callback (which should return funds to this contract)
    IZklendFlashCallbackDispatcher { contract_address: receiver }
        .zklend_flash_callback(caller, calldata);

    // Checks if enough funds have been returned
    let reserve_balance_after: felt252 = IERC20Dispatcher { contract_address: token }
        .balanceOf(this_address)
        .try_into()
        .expect(errors::BALANCE_OVERFLOW);
    assert(
        Into::<_, u256>::into(min_balance) <= Into::<_, u256>::into(reserve_balance_after),
        errors::INSUFFICIENT_AMOUNT_REPAID
    );

    // Updates accumulators (for interest accumulation only)
    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        update_accumulators(
        ref self, token
    );

    // Distributes excessive funds (flash loan fees)
    // `updated_debt_accumulator` from above is still valid as this function does not touch debt
    settle_extra_reserve_balance(ref self, token);

    // Updates rates
    update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        false, // is_delta_reserve_balance_negative
        0, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        0, // abs_delta_raw_total_debt
    );

    let actual_fee = safe_math::sub(reserve_balance_after, reserve_balance_before);
    self
        .emit(
            contract::Event::FlashLoan(
                contract::FlashLoan { initiator: caller, receiver, token, amount, fee: actual_fee }
            )
        );
}

/// ASSUMPTION: `token` maps to a valid reserve.
fn set_collateral_usage(
    ref self: ContractState, user: ContractAddress, token: ContractAddress, used: bool
) {
    let reserve_index = self.reserve_indices.read(token);
    set_user_flag(ref self, user, reserve_index * 2, used);
}

/// ASSUMPTION: `token` maps to a valid reserve.
fn set_user_has_debt(
    ref self: ContractState,
    user: ContractAddress,
    token: ContractAddress,
    debt_before: felt252,
    debt_after: felt252
) {
    let reserve_index = self.reserve_indices.read(token);
    if debt_before == 0 && debt_after != 0 {
        set_user_flag(ref self, user, reserve_index * 2 + 1, true);
    } else if debt_before != 0 && debt_after == 0 {
        set_user_flag(ref self, user, reserve_index * 2 + 1, false);
    }
}

fn set_user_flag(ref self: ContractState, user: ContractAddress, offset: felt252, set: bool) {
    let reserve_slot: u256 = math::shl(1, offset).into();
    let existing_map: u256 = self.user_flags.read(user).into();

    let new_map: u256 = if set {
        BitOr::bitor(existing_map, reserve_slot)
    } else {
        let inverse_slot = BitNot::bitnot(reserve_slot);
        BitAnd::bitand(existing_map, inverse_slot)
    };

    // The max value produced by `math::shl` is `2 ^ 251 - 1`. Since user map values can only be
    // produced from bitwise-or results of `math::shl` outputs, they would never be larger than
    // `2 ^ 251 - 1`, ensuring that it's always a valid `felt252`. So it's safe to unwrap here.
    let new_map: felt252 = new_map.try_into().unwrap();

    self.user_flags.write(user, new_map);
}

/// Panicks if `token` does not map to a valid reserve.
///
/// ASSUMPTION: `token` maps to a valid reserve
fn is_used_as_collateral(
    self: @ContractState, user: ContractAddress, token: ContractAddress
) -> bool {
    let reserve_index = self.reserve_indices.read(token);
    let reserve_slot: u256 = math::shl(1, reserve_index * 2).into();
    let existing_map: u256 = self.user_flags.read(user).into();

    let and_result = BitAnd::bitand(existing_map, reserve_slot);
    let is_used = and_result != 0;

    is_used
}

fn user_has_debt(self: @ContractState, user: ContractAddress) -> bool {
    let map: u256 = self.user_flags.read(user).into();

    let and_result = BitAnd::bitand(map, DEBT_FLAG_FILTER);
    let has_debt = and_result != 0;

    has_debt
}

#[inline(always)]
fn assert_not_overcollateralized(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) {
    let user_overcollateralized = is_overcollateralized(self, user, apply_borrow_factor);
    assert(!user_overcollateralized, errors::INVALID_LIQUIDATION);
}

#[inline(always)]
fn assert_not_undercollateralized(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) {
    let user_not_undercollateralized = is_not_undercollateralized(self, user, apply_borrow_factor);
    assert(user_not_undercollateralized, errors::INSUFFICIENT_COLLATERAL);
}

fn is_not_undercollateralized(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) -> bool {
    // Skips expensive collateralization check if user has no debt at all
    let has_debt = user_has_debt(self, user);
    if !has_debt {
        return true;
    }

    let UserCollateralData { collateral_value, collateral_required } =
        calculate_user_collateral_data(
        self, user, apply_borrow_factor
    );
    Into::<_, u256>::into(collateral_required) <= Into::<_, u256>::into(collateral_value)
}

/// Same as `is_not_undercollateralized` but returns `false` if equal. Only used in
/// liquidations.
fn is_overcollateralized(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) -> bool {
    // Not using the skip-if-no-debt optimization here because in liquidations the user always
    // has debt left. Checking for debt flags is thus wasteful.

    let UserCollateralData { collateral_value, collateral_required } =
        calculate_user_collateral_data(
        self, user, apply_borrow_factor
    );
    Into::<_, u256>::into(collateral_required) < Into::<_, u256>::into(collateral_value)
}

// TODO: refactor the recursion away since Cairo supports loops now (see notes at the top)
fn calculate_user_collateral_data(
    self: @ContractState, user: ContractAddress, apply_borrow_factor: bool
) -> UserCollateralData {
    let reserve_cnt = self.reserve_count.read();
    if reserve_cnt.is_zero() {
        UserCollateralData { collateral_value: 0, collateral_required: 0 }
    } else {
        let flags: u256 = self.user_flags.read(user).into();

        let UserCollateralData { collateral_value, collateral_required } =
            calculate_user_collateral_data_loop(
            self, user, apply_borrow_factor, flags, reserve_cnt, 0
        );

        UserCollateralData { collateral_value, collateral_required }
    }
}

// TODO: refactor this away since Cairo supports loops now (see notes at the top)
/// ASSUMPTION: `reserve_count` is not zero.
fn calculate_user_collateral_data_loop(
    self: @ContractState,
    user: ContractAddress,
    apply_borrow_factor: bool,
    flags: u256,
    reserve_count: felt252,
    reserve_index: felt252
) -> UserCollateralData {
    if reserve_index == reserve_count {
        return UserCollateralData { collateral_value: 0, collateral_required: 0 };
    }

    let UserCollateralData { collateral_value: collateral_value_of_rest,
    collateral_required: collateral_required_of_rest } =
        calculate_user_collateral_data_loop(
        self, user, apply_borrow_factor, flags, reserve_count, reserve_index + 1
    );

    let reserve_slot: u256 = math::shl(1, reserve_index * 2).into();
    let reserve_slot_and = BitAnd::bitand(flags, reserve_slot);

    let reserve_token = self.reserve_tokens.read(reserve_index);

    let current_collateral_required = get_collateral_usd_value_required_for_token(
        self, user, reserve_token, apply_borrow_factor
    );
    let total_collateral_required = safe_math::add(
        current_collateral_required, collateral_required_of_rest
    );

    if reserve_slot_and.is_zero() {
        // Reserve not used as collateral
        UserCollateralData {
            collateral_value: collateral_value_of_rest,
            collateral_required: total_collateral_required
        }
    } else {
        let discounted_collateral_value = get_user_collateral_usd_value_for_token(
            self, user, reserve_token
        );
        let total_collateral_value = safe_math::add(
            discounted_collateral_value, collateral_value_of_rest
        );

        UserCollateralData {
            collateral_value: total_collateral_value, collateral_required: total_collateral_required
        }
    }
}

/// ASSUMPTION: `token` is a valid reserve.
#[inline(always)]
fn get_collateral_usd_value_required_for_token(
    self: @ContractState, user: ContractAddress, token: ContractAddress, apply_borrow_factor: bool
) -> felt252 {
    let debt_value = get_user_debt_usd_value_for_token(self, user, token);
    if apply_borrow_factor {
        let borrow_factor = self.reserves.read_borrow_factor(token);
        let collateral_required = safe_decimal_math::div(debt_value, borrow_factor);
        collateral_required
    } else {
        debt_value
    }
}

/// ASSUMPTION: `token` is a valid reserve.
#[inline(always)]
fn get_user_debt_usd_value_for_token(
    self: @ContractState, user: ContractAddress, token: ContractAddress
) -> felt252 {
    let raw_debt_balance = self.raw_user_debts.read((user, token));
    if raw_debt_balance.is_zero() {
        return 0;
    }

    let debt_accumulator = view::get_debt_accumulator(self, token);
    let scaled_up_debt_balance = safe_decimal_math::mul(raw_debt_balance, debt_accumulator);

    // Fetches price from oracle
    let oracle_addr = self.oracle.read();
    let debt_price = IPriceOracleDispatcher { contract_address: oracle_addr }.get_price(token);

    let decimals = self.reserves.read_decimals(token);

    let debt_value = safe_decimal_math::mul_decimals(debt_price, scaled_up_debt_balance, decimals);

    debt_value
}

/// ASSUMPTION: `token` is a valid reserve.
/// ASSUMPTION: `token` is used by `user` as collateral.
#[inline(always)]
fn get_user_collateral_usd_value_for_token(
    self: @ContractState, user: ContractAddress, token: ContractAddress
) -> felt252 {
    let reserve = self.reserves.read_for_get_user_collateral_usd_value_for_token(token);

    if reserve.collateral_factor.is_zero() {
        return 0;
    }

    // This value already reflects interests accured since last update
    let collateral_balance = IZTokenDispatcher { contract_address: reserve.z_token_address }
        .felt_balance_of(user);

    // Fetches price from oracle
    let oracle_addr = self.oracle.read();
    let collateral_price = IPriceOracleDispatcher { contract_address: oracle_addr }
        .get_price(token);

    // `collateral_value` is represented in 8-decimal USD value
    let collateral_value = safe_decimal_math::mul_decimals(
        collateral_price, collateral_balance, reserve.decimals
    );

    // Discounts value by collateral factor
    let discounted_collateral_value = safe_decimal_math::mul(
        collateral_value, reserve.collateral_factor
    );

    discounted_collateral_value
}

/// `amount` with `0` means withdrawing all.
fn withdraw_internal(
    ref self: ContractState, user: ContractAddress, token: ContractAddress, amount: felt252
) {
    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        update_accumulators(
        ref self, token
    );
    
    assert_reserve_enabled(@self, token);
    let z_token_address = self.reserves.read_z_token_address(token);

    // NOTE: it's fine to call out to external contract here before state update since it's trusted
    let amount_burnt = burn_z_token_internal(ref self, z_token_address, user, amount);
    
    // Updates interest rate
    update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        true, // is_delta_reserve_balance_negative
        amount_burnt, // abs_delta_reserve_balance
        false, // is_delta_raw_total_debt_negative
        0, // abs_delta_raw_total_debt
    );

    self
        .emit(
            contract::Event::Withdrawal(
                contract::Withdrawal { user, token, face_amount: amount_burnt }
            )
        );

    // Gives underlying tokens to user
    let amount_burnt: u256 = amount_burnt.into();
    let transfer_success = IERC20Dispatcher { contract_address: token }
        .transfer(user, amount_burnt);
    assert(transfer_success, errors::TRANSFER_FAILED);

    // It's easier to post-check collateralization factor, at the cost of making failed
    // transactions more expensive.
    let is_asset_used_as_collateral = is_used_as_collateral(@self, user, token);

    // No need to check if the asset is not used as collateral at all
    if is_asset_used_as_collateral {
        assert_not_undercollateralized(@self, user, true);
    }
}

/// `amount` with `0` means repaying all. Returns actual debt amounts repaid.
fn repay_debt_route_internal(
    ref self: ContractState,
    repayer: ContractAddress,
    beneficiary: ContractAddress,
    token: ContractAddress,
    amount: felt252
) -> DebtRepaid {
    assert_reserve_enabled(@self, token);

    let updated_debt_accumulator = view::get_debt_accumulator(@self, token);

    if amount.is_zero() {
        let user_raw_debt = self.raw_user_debts.read((beneficiary, token));
        assert(user_raw_debt.is_non_zero(), errors::NO_DEBT_TO_REPAY);

        let repay_amount = safe_decimal_math::mul(user_raw_debt, updated_debt_accumulator);

        repay_debt_internal(ref self, repayer, beneficiary, token, repay_amount, user_raw_debt);

        DebtRepaid { raw_amount: user_raw_debt, face_amount: repay_amount }
    } else {
        let raw_amount = safe_decimal_math::div(amount, updated_debt_accumulator);
        assert(raw_amount.is_non_zero(), errors::INVALID_AMOUNT);
        repay_debt_internal(ref self, repayer, beneficiary, token, amount, raw_amount);

        DebtRepaid { raw_amount, face_amount: amount }
    }
}

/// ASSUMPTION: `repay_amount` = `raw_amount` * Debt Accumulator.
/// ASSUMPTION: it's always called by `repay_debt_route_internal`.
/// ASSUMPTION: raw_amount is non zero.
fn repay_debt_internal(
    ref self: ContractState,
    repayer: ContractAddress,
    beneficiary: ContractAddress,
    token: ContractAddress,
    repay_amount: felt252,
    raw_amount: felt252
) {
    let this_address = get_contract_address();

    let UpdatedAccumulators { debt_accumulator: updated_debt_accumulator, .. } =
        update_accumulators(
        ref self, token
    );

    // No need to check if user is overpaying, as `safe_math::sub` below will fail anyways
    // No need to check collateral value. Always allow repaying even if it's undercollateralized

    // Updates user debt data
    let raw_user_debt_before = self.raw_user_debts.read((beneficiary, token));
    let raw_user_debt_after = safe_math::sub(raw_user_debt_before, raw_amount);
    self.raw_user_debts.write((beneficiary, token), raw_user_debt_after);

    set_user_has_debt(ref self, beneficiary, token, raw_user_debt_before, raw_user_debt_after);

    // Updates interest rate
    update_rates_and_raw_total_debt(
        ref self,
        token, // token
        updated_debt_accumulator, // updated_debt_accumulator
        false, // is_delta_reserve_balance_negative
        repay_amount, // abs_delta_reserve_balance
        true, // is_delta_raw_total_debt_negative
        raw_amount // abs_delta_raw_total_debt
    );

    // Takes token from user
    let repay_amount: u256 = repay_amount.into();
    let transfer_success = IERC20Dispatcher { contract_address: token }
        .transferFrom(repayer, this_address, repay_amount);
    assert(transfer_success, errors::TRANSFER_FAILED);
}

/// `amount` with `0` means burning all. Returns amount burnt.
fn burn_z_token_internal(
    ref self: ContractState, z_token: ContractAddress, user: ContractAddress, amount: felt252
) -> felt252 {
    if amount.is_zero() {
        let amount_burnt = IZTokenDispatcher { contract_address: z_token }.burn_all(user);
        amount_burnt
    } else {
        IZTokenDispatcher { contract_address: z_token }.burn(user, amount);
        amount
    }
}

fn update_accumulators(ref self: ContractState, token: ContractAddress) -> UpdatedAccumulators {
    let block_timestamp: felt252 = get_block_timestamp().into();
    let updated_lending_accumulator = view::get_lending_accumulator(@self, token);
    let updated_debt_accumulator = view::get_debt_accumulator(@self, token);
    
    self
        .emit(
            contract::Event::AccumulatorsSync(
                contract::AccumulatorsSync {
                    token,
                    lending_accumulator: updated_lending_accumulator,
                    debt_accumulator: updated_debt_accumulator
                }
            )
        );

    // It's okay to call this function here as the updated accumulators haven't been written into
    // storage yet
    let amount_to_treasury = view::get_pending_treasury_amount(@self, token);

    // No need to check reserve existence since it's done in `get_lending_accumulator` and
    // `get_debt_accumulator`
    let z_token_address = self.reserves.read_z_token_address(token);

    self
        .reserves
        .write_accumulators(
            token, block_timestamp, updated_lending_accumulator, updated_debt_accumulator
        );

    // No need to check whether treasury address is zero as amount would be zero anyways
    if amount_to_treasury.is_non_zero() {
        let treasury_addr = self.treasury.read();
        IZTokenDispatcher { contract_address: z_token_address }
            .mint(treasury_addr, amount_to_treasury);
    }

    UpdatedAccumulators {
        lending_accumulator: updated_lending_accumulator, debt_accumulator: updated_debt_accumulator
    }
}

fn update_rates_and_raw_total_debt(
    ref self: ContractState,
    token: ContractAddress,
    updated_debt_accumulator: felt252,
    is_delta_reserve_balance_negative: bool,
    abs_delta_reserve_balance: felt252,
    is_delta_raw_total_debt_negative: bool,
    abs_delta_raw_total_debt: felt252,
) {
    let this_address = get_contract_address();

    let StorageBatch1 { interest_rate_model, raw_total_debt: raw_total_debt_before } = self
        .reserves
        .read_interest_rate_model_and_raw_total_debt(token);

    // Makes sure reserve exists
    // (the caller must check it's enabled if needed since it's not validated here)
    assert(interest_rate_model.is_non_zero(), errors::RESERVE_NOT_FOUND);

    let reserve_balance_before: felt252 = IERC20Dispatcher { contract_address: token }
        .balanceOf(this_address)
        .try_into()
        .expect(errors::BALANCE_OVERFLOW);

    let reserve_balance_after = if is_delta_reserve_balance_negative {
        safe_math::sub(reserve_balance_before, abs_delta_reserve_balance)
    } else {
        safe_math::add(reserve_balance_before, abs_delta_reserve_balance)
    };

    println!("---Debt");
    let raw_total_debt_after = if is_delta_raw_total_debt_negative {
        safe_math::sub(raw_total_debt_before, abs_delta_raw_total_debt)
    } else {
        safe_math::add(raw_total_debt_before, abs_delta_raw_total_debt)
    };

    let scaled_up_total_debt_after = safe_decimal_math::mul(
        raw_total_debt_after, updated_debt_accumulator
    );
    let ModelRates { lending_rate: new_lending_rate, borrowing_rate: new_borrowing_rate } =
        IInterestRateModelDispatcher {
        contract_address: interest_rate_model
    }
        .get_interest_rates(reserve_balance_after, scaled_up_total_debt_after);

    // Writes to storage
    self.reserves.write_rates(token, new_lending_rate, new_borrowing_rate);
    if raw_total_debt_before != raw_total_debt_after {
        self.reserves.write_raw_total_debt(token, raw_total_debt_after);
    }

    self
        .emit(
            contract::Event::InterestRatesSync(
                contract::InterestRatesSync {
                    token, lending_rate: new_lending_rate, borrowing_rate: new_borrowing_rate
                }
            )
        );
}

/// Checks reserve exists.
fn assert_reserve_exists(self: @ContractState, token: ContractAddress) {
    let z_token = self.reserves.read_z_token_address(token);
    assert(z_token.is_non_zero(), errors::RESERVE_NOT_FOUND);
}

/// Checks reserve is enabled.
fn assert_reserve_enabled(self: @ContractState, token: ContractAddress) {
    let enabled = self.reserves.read_enabled(token);
    assert(enabled, errors::RESERVE_NOT_ENABLED);
}

/// Checks if the debt limit is satisfied.
fn assert_debt_limit_satisfied(self: @ContractState, token: ContractAddress) {
    let debt_limit = self.reserves.read_debt_limit(token);

    let raw_total_debt = self.reserves.read_raw_total_debt(token);

    let debt_accumulator = view::get_debt_accumulator(self, token);
    let scaled_debt = safe_decimal_math::mul(raw_total_debt, debt_accumulator);

    assert(
        Into::<_, u256>::into(scaled_debt) <= Into::<_, u256>::into(debt_limit),
        errors::DEBT_LIMIT_EXCEEDED
    );
}

/// This function is called to distribute excessive reserve assets to depositors. Such extra balance
/// can come from a variety of sources, including direct transfer of tokens into
/// this contract. However, in practice, this function is only called right after a flash loan,
/// meaning that these excessive balance would accumulate over time, but only gets settled when
/// flash loans happen.
///
/// This is a deliberate design decision:
///
/// - doing so avoids expensive settlements for small rounding errors that make little to no
///   difference to users; and
/// - it's deemed unlikely that anyone would send unsolicited funds to this contract on purpose.
///
/// An alternative implementation would be to always derive the lending accumulator from real
/// balances, and thus unifying accumulator updates. However, that would make ZToken transfers
/// unnecessarily expensive, with little benefits (same reasoning as above).
///
/// ASSUMPTION: accumulators are otherwise up to date; this function MUST only be called right after
///             `update_accumulators()`.
fn settle_extra_reserve_balance(ref self: ContractState, token: ContractAddress) {
    let this_address = get_contract_address();

    // No need to check reserve existence: deduced from assumption.
    let reserve = self.reserves.read_for_settle_extra_reserve_balance(token);

    // Accumulators are already update to date from assumption
    let scaled_up_total_debt = safe_decimal_math::mul(
        reserve.raw_total_debt, reserve.debt_accumulator
    );

    // What we _actually_ have sitting in the contract
    let reserve_balance: felt252 = IERC20Dispatcher { contract_address: token }
        .balanceOf(this_address)
        .try_into()
        .expect(errors::BALANCE_OVERFLOW);

    // The full amount if all debts are repaid
    let implicit_total_balance = safe_math::add(reserve_balance, scaled_up_total_debt);

    // What all users are _entitled_ to right now (again, accumulators are up to date)
    let raw_z_supply = IZTokenDispatcher { contract_address: reserve.z_token_address }
        .get_raw_total_supply();
    let owned_balance = safe_decimal_math::mul(raw_z_supply, reserve.lending_accumulator);

    let no_need_to_adjust = Into::<
        _, u256
        >::into(implicit_total_balance) <= Into::<
        _, u256
    >::into(owned_balance);
    if !no_need_to_adjust {
        // `implicit_total_balance > owned_balance` holds inside this branch
        let excessive_balance = safe_math::sub(implicit_total_balance, owned_balance);

        let treasury_addr = self.treasury.read();
        let effective_reserve_factor = if treasury_addr.is_zero() {
            0
        } else {
            reserve.reserve_factor
        };

        let amount_to_treasury = safe_decimal_math::mul(
            excessive_balance, effective_reserve_factor
        );
        let amount_to_depositors = safe_math::sub(excessive_balance, amount_to_treasury);

        let new_depositor_balance = safe_math::add(owned_balance, amount_to_depositors);
        let new_accumulator = safe_decimal_math::div(new_depositor_balance, raw_z_supply);

        self
            .emit(
                contract::Event::AccumulatorsSync(
                    contract::AccumulatorsSync {
                        token,
                        lending_accumulator: new_accumulator,
                        debt_accumulator: reserve.debt_accumulator
                    }
                )
            );
        self.reserves.write_lending_accumulator(token, new_accumulator);

        // Mints fee to treasury
        if amount_to_treasury.is_non_zero() {
            IZTokenDispatcher { contract_address: reserve.z_token_address }
                .mint(treasury_addr, amount_to_treasury);
        }
    }
    }

}
mod traits {
    use starknet::ContractAddress;
use starknet::event::EventEmitter;

// Hack to simulate the `crate` keyword


use super::libraries::{ownable, reentrancy_guard};

use super::Market as contract;

use contract::ContractState;

// These are hacks that depend on compiler implementation details :(
// But they're needed for refactoring the contract code into modules like this one.
use contract::Ownable_ownerContractMemberStateTrait;
use contract::enteredContractMemberStateTrait;

impl MarketOwnable of ownable::Ownable<ContractState> {
    fn read_owner(self: @ContractState) -> ContractAddress {
        self.Ownable_owner.read()
    }

    fn write_owner(ref self: ContractState, owner: ContractAddress) {
        self.Ownable_owner.write(owner);
    }

    fn emit_ownership_transferred(
        ref self: ContractState, previous_owner: ContractAddress, new_owner: ContractAddress
    ) {
        self
            .emit(
                contract::Event::OwnershipTransferred(
                    contract::OwnershipTransferred { previous_owner, new_owner }
                )
            );
    }
}

impl MarketReentrancyGuard of reentrancy_guard::ReentrancyGuard<ContractState> {
    fn read_entered(self: @ContractState) -> bool {
        self.entered.read()
    }

    fn write_entered(ref self: ContractState, entered: bool) {
        self.entered.write(entered);
    }
    }

}
mod errors {
    const BALANCE_OVERFLOW: felt252 = 'MKT_BALANCE_OVERFLOW';
const BORROW_FACTOR_RANGE: felt252 = 'MKT_BORROW_FACTOR_RANGE';
const COLLATERAL_FACTOR_RANGE: felt252 = 'MKT_COLLATERAL_FACTOR_RANGE';
const DEBT_LIMIT_EXCEEDED: felt252 = 'MKT_DEBT_LIMIT_EXCEEDED';
const INSUFFICIENT_AMOUNT_REPAID: felt252 = 'MKT_INSUFFICIENT_AMOUNT_REPAID';
const INSUFFICIENT_COLLATERAL: felt252 = 'MKT_INSUFFICIENT_COLLATERAL';
const INVALID_AMOUNT: felt252 = 'MKT_INVALID_AMOUNT';
const INVALID_LIQUIDATION: felt252 = 'MKT_INVALID_LIQUIDATION';
const INVALID_STORAGE: felt252 = 'MKT_INVALID_STORAGE';
const NONCOLLATERAL_TOKEN: felt252 = 'MKT_NONCOLLATERAL_TOKEN';
const NO_DEBT_TO_REPAY: felt252 = 'MKT_NO_DEBT_TO_REPAY';
const RESERVE_ALREADY_EXISTS: felt252 = 'MKT_RESERVE_ALREADY_EXISTS';
const RESERVE_FACTOR_RANGE: felt252 = 'MKT_RESERVE_FACTOR_RANGE';
const RESERVE_NOT_ENABLED: felt252 = 'MKT_RESERVE_NOT_ENABLED';
const RESERVE_NOT_FOUND: felt252 = 'MKT_RESERVE_NOT_FOUND';
const TOKEN_DECIMALS_MISMATCH: felt252 = 'MKT_TOKEN_DECIMALS_MISMATCH';
const TOO_MANY_RESERVES: felt252 = 'MKT_TOO_MANY_RESERVES';
const TRANSFERFROM_FAILED: felt252 = 'MKT_TRANSFERFROM_FAILED';
const TRANSFER_FAILED: felt252 = 'MKT_TRANSFER_FAILED';
const UNDERLYING_TOKEN_MISMATCH: felt252 = 'MKT_UNDERLYING_TOKEN_MISMATCH';
const ZERO_ADDRESS: felt252 = 'MKT_ZERO_ADDRESS';
    const ZERO_AMOUNT: felt252 = 'MKT_ZERO_AMOUNT';

}
mod storage {
    // Storage cheats to enable efficient access to selected fields for larges structs in storage.
//
// WARN: the code here relies on compiler implementation details :/
//
// TODO: implement a codegen tool for this to avoid human errors.

use result::ResultTrait;

use starknet::{ContractAddress, Store};

use super::errors::INVALID_STORAGE as E;

use super::Market as contract;

use contract::__member_module_reserves::ContractMemberState as Reserves;
use contract::reservesContractMemberStateTrait;

// These are hacks that depend on compiler implementation details :(
// But they're needed for refactoring the contract code into modules like this one.

// Address domain
const D: u32 = 0_u32;

#[derive(Drop)]
struct StorageBatch1 {
    interest_rate_model: ContractAddress,
    raw_total_debt: felt252
}

#[derive(Drop)]
struct StorageBatch2 {
    decimals: felt252,
    z_token_address: ContractAddress,
    collateral_factor: felt252
}

#[derive(Drop)]
struct StorageBatch3 {
    reserve_factor: felt252,
    last_update_timestamp: felt252,
    lending_accumulator: felt252,
    current_lending_rate: felt252
}

#[derive(Drop)]
struct StorageBatch4 {
    last_update_timestamp: felt252,
    debt_accumulator: felt252,
    current_borrowing_rate: felt252
}

#[derive(Drop)]
struct StorageBatch5 {
    z_token_address: ContractAddress,
    reserve_factor: felt252,
    last_update_timestamp: felt252,
    lending_accumulator: felt252,
    current_lending_rate: felt252
}

#[derive(Drop)]
struct StorageBatch6 {
    z_token_address: ContractAddress,
    reserve_factor: felt252,
    lending_accumulator: felt252,
    debt_accumulator: felt252,
    raw_total_debt: felt252
}

trait ReservesStorageShortcuts<T> {
    fn read_enabled(self: @T, token: ContractAddress) -> bool;

    fn read_decimals(self: @T, token: ContractAddress) -> felt252;

    fn read_z_token_address(self: @T, token: ContractAddress) -> ContractAddress;

    fn read_borrow_factor(self: @T, token: ContractAddress) -> felt252;

    fn read_raw_total_debt(self: @T, token: ContractAddress) -> felt252;

    fn read_flash_loan_fee(self: @T, token: ContractAddress) -> felt252;

    fn read_debt_limit(self: @T, token: ContractAddress) -> felt252;

    fn read_interest_rate_model_and_raw_total_debt(
        self: @T, token: ContractAddress
    ) -> StorageBatch1;

    fn read_for_get_user_collateral_usd_value_for_token(
        self: @T, token: ContractAddress
    ) -> StorageBatch2;

    fn read_for_get_lending_accumulator(self: @T, token: ContractAddress) -> StorageBatch3;

    fn read_for_get_debt_accumulator(self: @T, token: ContractAddress) -> StorageBatch4;

    fn read_for_get_pending_treasury_amount(self: @T, token: ContractAddress) -> StorageBatch5;

    fn read_for_settle_extra_reserve_balance(self: @T, token: ContractAddress) -> StorageBatch6;

    fn write_lending_accumulator(self: @T, token: ContractAddress, lending_accumulator: felt252);

    fn write_raw_total_debt(self: @T, token: ContractAddress, raw_total_debt: felt252);

    fn write_interest_rate_model(
        self: @T, token: ContractAddress, interest_rate_model: ContractAddress
    );

    fn write_collateral_factor(self: @T, token: ContractAddress, collateral_factor: felt252);

    fn write_borrow_factor(self: @T, token: ContractAddress, borrow_factor: felt252);

    fn write_reserve_factor(self: @T, token: ContractAddress, reserve_factor: felt252);

    fn write_debt_limit(self: @T, token: ContractAddress, debt_limit: felt252);

    fn write_accumulators(
        self: @T,
        token: ContractAddress,
        last_update_timestamp: felt252,
        lending_accumulator: felt252,
        debt_accumulator: felt252
    );

    fn write_rates(
        self: @T,
        token: ContractAddress,
        current_lending_rate: felt252,
        current_borrowing_rate: felt252
    );
}

impl ReservesStorageShortcutsImpl of ReservesStorageShortcuts<Reserves> {
    fn read_enabled(self: @Reserves, token: ContractAddress) -> bool {
        let base = self.address(token);

        let enabled = Store::<bool>::read(D, base).expect(E);

        enabled
    }

    fn read_decimals(self: @Reserves, token: ContractAddress) -> felt252 {
        let base = self.address(token);

        let decimals = Store::<felt252>::read_at_offset(D, base, 1).expect(E);

        decimals
    }

    fn read_z_token_address(self: @Reserves, token: ContractAddress) -> ContractAddress {
        let base = self.address(token);

        let z_token_address = Store::<ContractAddress>::read_at_offset(D, base, 2).expect(E);

        z_token_address
    }

    fn read_borrow_factor(self: @Reserves, token: ContractAddress) -> felt252 {
        let base = self.address(token);

        let borrow_factor = Store::<felt252>::read_at_offset(D, base, 5).expect(E);

        borrow_factor
    }

    fn read_raw_total_debt(self: @Reserves, token: ContractAddress) -> felt252 {
        let base = self.address(token);

        let raw_total_debt = Store::<felt252>::read_at_offset(D, base, 12).expect(E);

        raw_total_debt
    }

    fn read_flash_loan_fee(self: @Reserves, token: ContractAddress) -> felt252 {
        let base = self.address(token);

        let flash_loan_fee = Store::<felt252>::read_at_offset(D, base, 13).expect(E);

        flash_loan_fee
    }

    fn read_debt_limit(self: @Reserves, token: ContractAddress) -> felt252 {
        let base = self.address(token);

        let debt_limit = Store::<felt252>::read_at_offset(D, base, 15).expect(E);

        debt_limit
    }

    fn read_interest_rate_model_and_raw_total_debt(
        self: @Reserves, token: ContractAddress
    ) -> StorageBatch1 {
        let base = self.address(token);

        let interest_rate_model = Store::<ContractAddress>::read_at_offset(D, base, 3).expect(E);
        let raw_total_debt = Store::<felt252>::read_at_offset(D, base, 12).expect(E);

        StorageBatch1 { interest_rate_model, raw_total_debt }
    }

    fn read_for_get_user_collateral_usd_value_for_token(
        self: @Reserves, token: ContractAddress
    ) -> StorageBatch2 {
        let base = self.address(token);

        let decimals = Store::<felt252>::read_at_offset(D, base, 1).expect(E);
        let z_token_address = Store::<ContractAddress>::read_at_offset(D, base, 2).expect(E);
        let collateral_factor = Store::<felt252>::read_at_offset(D, base, 4).expect(E);

        StorageBatch2 { decimals, z_token_address, collateral_factor }
    }

    fn read_for_get_lending_accumulator(self: @Reserves, token: ContractAddress) -> StorageBatch3 {
        let base = self.address(token);

        let reserve_factor = Store::<felt252>::read_at_offset(D, base, 6).expect(E);
        let last_update_timestamp = Store::<felt252>::read_at_offset(D, base, 7).expect(E);
        let lending_accumulator = Store::<felt252>::read_at_offset(D, base, 8).expect(E);
        let current_lending_rate = Store::<felt252>::read_at_offset(D, base, 10).expect(E);

        StorageBatch3 {
            reserve_factor, last_update_timestamp, lending_accumulator, current_lending_rate
        }
    }

    fn read_for_get_debt_accumulator(self: @Reserves, token: ContractAddress) -> StorageBatch4 {
        let base = self.address(token);

        let last_update_timestamp = Store::<felt252>::read_at_offset(D, base, 7).expect(E);
        let debt_accumulator = Store::<felt252>::read_at_offset(D, base, 9).expect(E);
        let current_borrowing_rate = Store::<felt252>::read_at_offset(D, base, 11).expect(E);

        StorageBatch4 { last_update_timestamp, debt_accumulator, current_borrowing_rate }
    }

    fn read_for_get_pending_treasury_amount(
        self: @Reserves, token: ContractAddress
    ) -> StorageBatch5 {
        let base = self.address(token);

        let z_token_address = Store::<ContractAddress>::read_at_offset(D, base, 2).expect(E);
        let reserve_factor = Store::<felt252>::read_at_offset(D, base, 6).expect(E);
        let last_update_timestamp = Store::<felt252>::read_at_offset(D, base, 7).expect(E);
        let lending_accumulator = Store::<felt252>::read_at_offset(D, base, 8).expect(E);
        let current_lending_rate = Store::<felt252>::read_at_offset(D, base, 10).expect(E);

        StorageBatch5 {
            z_token_address,
            reserve_factor,
            last_update_timestamp,
            lending_accumulator,
            current_lending_rate
        }
    }

    fn read_for_settle_extra_reserve_balance(
        self: @Reserves, token: ContractAddress
    ) -> StorageBatch6 {
        let base = self.address(token);

        let z_token_address = Store::<ContractAddress>::read_at_offset(D, base, 2).expect(E);
        let reserve_factor = Store::<felt252>::read_at_offset(D, base, 6).expect(E);
        let lending_accumulator = Store::<felt252>::read_at_offset(D, base, 8).expect(E);
        let debt_accumulator = Store::<felt252>::read_at_offset(D, base, 9).expect(E);
        let raw_total_debt = Store::<felt252>::read_at_offset(D, base, 12).expect(E);

        StorageBatch6 {
            z_token_address, reserve_factor, lending_accumulator, debt_accumulator, raw_total_debt
        }
    }

    fn write_lending_accumulator(
        self: @Reserves, token: ContractAddress, lending_accumulator: felt252
    ) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 8, lending_accumulator).expect(E);
    }

    fn write_raw_total_debt(self: @Reserves, token: ContractAddress, raw_total_debt: felt252) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 12, raw_total_debt).expect(E);
    }

    fn write_interest_rate_model(
        self: @Reserves, token: ContractAddress, interest_rate_model: ContractAddress
    ) {
        let base = self.address(token);

        Store::<ContractAddress>::write_at_offset(D, base, 3, interest_rate_model).expect(E);
    }


    fn write_collateral_factor(
        self: @Reserves, token: ContractAddress, collateral_factor: felt252
    ) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 4, collateral_factor).expect(E);
    }

    fn write_borrow_factor(self: @Reserves, token: ContractAddress, borrow_factor: felt252) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 5, borrow_factor).expect(E);
    }

    fn write_reserve_factor(self: @Reserves, token: ContractAddress, reserve_factor: felt252) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 6, reserve_factor).expect(E);
    }

    fn write_debt_limit(self: @Reserves, token: ContractAddress, debt_limit: felt252) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 15, debt_limit).expect(E);
    }

    fn write_accumulators(
        self: @Reserves,
        token: ContractAddress,
        last_update_timestamp: felt252,
        lending_accumulator: felt252,
        debt_accumulator: felt252
    ) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 7, last_update_timestamp).expect(E);
        Store::<felt252>::write_at_offset(D, base, 8, lending_accumulator).expect(E);
        Store::<felt252>::write_at_offset(D, base, 9, debt_accumulator).expect(E);
    }

    fn write_rates(
        self: @Reserves,
        token: ContractAddress,
        current_lending_rate: felt252,
        current_borrowing_rate: felt252
    ) {
        let base = self.address(token);

        Store::<felt252>::write_at_offset(D, base, 10, current_lending_rate).expect(E);
        Store::<felt252>::write_at_offset(D, base, 11, current_borrowing_rate).expect(E);
    }
    }

}

struct UpdatedAccumulators {
    lending_accumulator: felt252,
    debt_accumulator: felt252
}


