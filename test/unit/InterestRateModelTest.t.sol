// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel interestRateModel;
    address owner = makeAddr("OWNER");

    function setUp() public {
        interestRateModel = new InterestRateModel(owner);
    }

    function test_setBaseRatePerDayBPS() public {
        uint8 newRate = 5;

        vm.startPrank(owner);
        interestRateModel.setBaseRatePerDayBPS(newRate);
        vm.stopPrank();

        assertEq(interestRateModel.baseRatePerDayBPS(), newRate);
    }

    function test_setSlope1() public {
        uint8 newSlope = 6;

        vm.startPrank(owner);
        interestRateModel.setSlope1(newSlope);
        vm.stopPrank();

        assertEq(interestRateModel.slope1(), newSlope);
    }

    function test_setSlope2() public {
        uint8 newSlope = 9;

        vm.startPrank(owner);
        interestRateModel.setSlope1(newSlope);
        vm.stopPrank();

        assertEq(interestRateModel.slope1(), newSlope);
    }

    function test_setKink() public {
        uint16 newKink = 7500;

        vm.startPrank(owner);
        interestRateModel.setKink(newKink);
        vm.stopPrank();

        assertEq(interestRateModel.kink(), newKink);
    }

    function test_getBorrowRateBPS() public view {
        uint32 duration = 86400; // 1 day
        uint16 utilizationBPS = 5000; // 50%

        // Calculate expected rate
        uint8 baseRate = interestRateModel.baseRatePerDayBPS();
        uint8 slope1 = interestRateModel.slope1();
        uint8 slope2 = interestRateModel.slope2();
        uint16 kink = interestRateModel.kink();

        uint256 borrowRateBPS;
        if (utilizationBPS <= kink) {
            borrowRateBPS = baseRate + (slope1 * utilizationBPS) / 10000;
        } else {
            borrowRateBPS = baseRate + (slope1 * kink) / 10000 + (slope2 * (utilizationBPS - kink)) / 10000;
        }

        // Call the function and assert
        uint256 calculatedRate = interestRateModel.getBorrowRateBPS(duration, utilizationBPS);
        assertEq(calculatedRate, borrowRateBPS);
    }
}
