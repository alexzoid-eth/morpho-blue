// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../BaseTest.sol";

contract IntegrationAccrueInterestsTest is BaseTest {
    using MathLib for uint256;

    function testAccrueInterestsNoTimeElapsed(uint256 amountSupplied, uint256 amountBorrowed) public {
        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 1, amountSupplied);

        // Set fee parameters.
        vm.prank(OWNER);
        morpho.setFeeRecipient(OWNER);

        borrowableToken.setBalance(address(this), amountSupplied);
        morpho.supply(market, amountSupplied, 0, address(this), hex"");

        uint256 collateralPrice = IOracle(market.oracle).price();
        collateralToken.setBalance(BORROWER, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice));

        vm.startPrank(BORROWER);
        morpho.supplyCollateral(
            market, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice), BORROWER, hex""
        );
        morpho.borrow(market, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();

        uint256 totalBorrowBeforeAccrued = morpho.totalBorrow(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupply(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);

        morpho.accrueInterests(market);

        assertEq(morpho.totalBorrow(id), totalBorrowBeforeAccrued, "total borrow");
        assertEq(morpho.totalSupply(id), totalSupplyBeforeAccrued, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, OWNER), 0, "feeRecipient's supply shares");
    }

    function testAccrueInterestsNoBorrow(uint256 amountSupplied, uint256 timeElapsed) public {
        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        timeElapsed = uint32(bound(timeElapsed, 1, type(uint32).max));

        // Set fee parameters.
        vm.prank(OWNER);
        morpho.setFeeRecipient(OWNER);

        borrowableToken.setBalance(address(this), amountSupplied);
        morpho.supply(market, amountSupplied, 0, address(this), hex"");

        // New block.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timeElapsed);

        uint256 totalBorrowBeforeAccrued = morpho.totalBorrow(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupply(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);

        morpho.accrueInterests(market);

        assertEq(morpho.totalBorrow(id), totalBorrowBeforeAccrued, "total borrow");
        assertEq(morpho.totalSupply(id), totalSupplyBeforeAccrued, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, OWNER), 0, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }

    function testAccrueInterestNoFee(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed) public {
        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 1, amountSupplied);
        timeElapsed = uint32(bound(timeElapsed, 1, type(uint32).max));

        // Set fee parameters.
        vm.prank(OWNER);
        morpho.setFeeRecipient(OWNER);

        borrowableToken.setBalance(address(this), amountSupplied);
        borrowableToken.setBalance(address(this), amountSupplied);
        morpho.supply(market, amountSupplied, 0, address(this), hex"");

        uint256 collateralPrice = IOracle(market.oracle).price();
        collateralToken.setBalance(BORROWER, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice));

        vm.startPrank(BORROWER);
        morpho.supplyCollateral(
            market, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice), BORROWER, hex""
        );

        morpho.borrow(market, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // New block.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timeElapsed);

        uint256 borrowRate = (morpho.totalBorrow(id).wDivDown(morpho.totalSupply(id))) / 365 days;
        uint256 totalBorrowBeforeAccrued = morpho.totalBorrow(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupply(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);
        uint256 expectedAccruedInterests = totalBorrowBeforeAccrued.wMulDown(borrowRate.wTaylorCompounded(timeElapsed));

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.AccrueInterests(id, borrowRate, expectedAccruedInterests, 0);
        morpho.accrueInterests(market);

        assertEq(morpho.totalBorrow(id), totalBorrowBeforeAccrued + expectedAccruedInterests, "total borrow");
        assertEq(morpho.totalSupply(id), totalSupplyBeforeAccrued + expectedAccruedInterests, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, OWNER), 0, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }

    struct AccrueInterestWithFeesTestParams {
        uint256 borrowRate;
        uint256 totalBorrowBeforeAccrued;
        uint256 totalSupplyBeforeAccrued;
        uint256 totalSupplySharesBeforeAccrued;
        uint256 expectedAccruedInterests;
        uint256 feeAmount;
        uint256 feeShares;
    }

    function testAccrueInterestWithFees(
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 timeElapsed,
        uint256 fee
    ) public {
        AccrueInterestWithFeesTestParams memory params;

        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 1, amountSupplied);
        timeElapsed = uint32(bound(timeElapsed, 1, type(uint32).max));
        fee = bound(fee, 1, MAX_FEE);

        // Set fee parameters.
        vm.startPrank(OWNER);
        morpho.setFeeRecipient(OWNER);
        morpho.setFee(market, fee);
        vm.stopPrank();

        borrowableToken.setBalance(address(this), amountSupplied);
        morpho.supply(market, amountSupplied, 0, address(this), hex"");

        uint256 collateralPrice = IOracle(market.oracle).price();
        collateralToken.setBalance(BORROWER, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice));

        vm.startPrank(BORROWER);
        morpho.supplyCollateral(
            market, amountBorrowed.wDivUp(LLTV).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice), BORROWER, hex""
        );
        morpho.borrow(market, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // New block.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timeElapsed);

        params.borrowRate = (morpho.totalBorrow(id).wDivDown(morpho.totalSupply(id))) / 365 days;
        params.totalBorrowBeforeAccrued = morpho.totalBorrow(id);
        params.totalSupplyBeforeAccrued = morpho.totalSupply(id);
        params.totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);
        params.expectedAccruedInterests =
            params.totalBorrowBeforeAccrued.wMulDown(params.borrowRate.wTaylorCompounded(timeElapsed));
        params.feeAmount = params.expectedAccruedInterests.wMulDown(fee);
        params.feeShares = params.feeAmount.mulDivDown(
            params.totalSupplySharesBeforeAccrued,
            params.totalSupplyBeforeAccrued + params.expectedAccruedInterests - params.feeAmount
        );

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.AccrueInterests(id, params.borrowRate, params.expectedAccruedInterests, params.feeShares);
        morpho.accrueInterests(market);

        assertEq(
            morpho.totalBorrow(id), params.totalBorrowBeforeAccrued + params.expectedAccruedInterests, "total borrow"
        );
        assertEq(
            morpho.totalSupply(id), params.totalSupplyBeforeAccrued + params.expectedAccruedInterests, "total supply"
        );
        assertEq(
            morpho.totalSupplyShares(id),
            params.totalSupplySharesBeforeAccrued + params.feeShares,
            "total supply shares"
        );
        assertEq(morpho.supplyShares(id, OWNER), params.feeShares, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }
}
