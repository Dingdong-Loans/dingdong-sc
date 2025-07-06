// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LendingCore} from "./LendingCoreV1.sol";

contract InterestRateModel {
    // ==============================================
    // Events
    // ==============================================

    // ==============================================
    // Constants
    // ==============================================
    uint32 public constant DAY_DENOMINATOR = 86400; // 1 days
    uint16 public constant BPS_DENOMINATOR = 10000; // 100.00%
    uint8 public constant BASE_RATE_PERDAY_BPS = 2; // 0.02%
    uint8 public constant SLOPE1 = 4; // 0.04%
    uint8 public constant SLOPE2 = 7; // 0.07%
    uint16 public constant KINK = 8000; // 80.00%
    LendingCore public immutable i_core;

    constructor(address _core) {
        i_core = LendingCore(_core);
    }

    // ==============================================
    // Main Functions
    // ==============================================

    // ==============================================
    // View Functions
    // ==============================================
    function getBorrowRateBPS(address _token, uint256 _duration) public view returns (uint256) {
        uint256 utilization = i_core.getUtilizationBPS(_token);
        uint256 borrowDurationInDays = _duration / DAY_DENOMINATOR;

        uint256 ratePerDay;

        if (utilization <= KINK) {
            ratePerDay = BASE_RATE_PERDAY_BPS + ((utilization * SLOPE1) / KINK);
        } else {
            uint256 excessUtilization = utilization - KINK;
            ratePerDay = BASE_RATE_PERDAY_BPS + SLOPE1 + (excessUtilization * SLOPE2) / (BPS_DENOMINATOR - KINK);
        }

        return ratePerDay * borrowDurationInDays;
    }
}
