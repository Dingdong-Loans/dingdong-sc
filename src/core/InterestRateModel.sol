// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract InterestRateModel is Ownable {
    // ========== EVENTS ==========
    event BaseRateUpdated(uint8 newRateBPS);
    event Slope1Updated(uint8 newSlope1);
    event Slope2Updated(uint8 newSlope2);
    event KinkUpdated(uint16 newKink);

    // ========== CONSTANTS ==========
    uint32 public constant DAY_DENOMINATOR = 86400; // 1 day
    uint16 public constant BPS_DENOMINATOR = 10000; // 100.00%

    // ========== PARAMETERS ==========
    uint8 public baseRatePerDayBPS; // e.g. 2 = 0.02%
    uint8 public slope1; // e.g. 4 = 0.04%
    uint8 public slope2; // e.g. 7 = 0.07%
    uint16 public kink; // e.g. 8000 = 80.00%

    // ========== CONSTRUCTOR ==========
    constructor(address initialOwner) Ownable(initialOwner) {
        // default values
        baseRatePerDayBPS = 2;
        slope1 = 4;
        slope2 = 7;
        kink = 8000;
    }

    // ========== OWNER FUNCTIONS ==========
    function setBaseRatePerDayBPS(uint8 _rate) external onlyOwner {
        baseRatePerDayBPS = _rate;
        emit BaseRateUpdated(_rate);
    }

    function setSlope1(uint8 _slope) external onlyOwner {
        slope1 = _slope;
        emit Slope1Updated(_slope);
    }

    function setSlope2(uint8 _slope) external onlyOwner {
        slope2 = _slope;
        emit Slope2Updated(_slope);
    }

    function setKink(uint16 _kink) external onlyOwner {
        require(_kink < BPS_DENOMINATOR, "Invalid kink value");
        kink = _kink;
        emit KinkUpdated(_kink);
    }

    // ========== VIEW FUNCTIONS ==========
    /**
     * @notice get borrow rate based on duration and utilization
     * @param _duration the duration of borrow in seconds
     * @param _utilizationBPS the utilization rate in basis point
     */
    function getBorrowRateBPS(uint256 _duration, uint256 _utilizationBPS) public view returns (uint256) {
        uint256 borrowDurationInDays = _duration / DAY_DENOMINATOR;

        uint256 ratePerDay;
        if (_utilizationBPS <= kink) {
            ratePerDay = baseRatePerDayBPS + ((_utilizationBPS * slope1) / kink);
        } else {
            uint256 excessUtilization = _utilizationBPS - kink;
            ratePerDay = baseRatePerDayBPS + slope1 + (excessUtilization * slope2) / (BPS_DENOMINATOR - kink);
        }

        return ratePerDay * borrowDurationInDays;
    }
}
