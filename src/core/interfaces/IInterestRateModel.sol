// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IInterestRateModel
/// @notice Interface for the InterestRateModel contract
interface IInterestRateModel {
    /// @notice Sets the base interest rate per day in basis points
    /// @param _rate The new base rate in BPS
    function setBaseRatePerDayBPS(uint8 _rate) external;

    /// @notice Sets the first slope (below the kink point)
    /// @param _slope The new slope1 value
    function setSlope1(uint8 _slope) external;

    /// @notice Sets the second slope (above the kink point)
    /// @param _slope The new slope2 value
    function setSlope2(uint8 _slope) external;

    /// @notice Sets the kink utilization threshold
    /// @param _kink The new kink value in BPS (must be < 10000)
    function setKink(uint16 _kink) external;

    /// @notice Returns the borrow interest rate in BPS for a given token and duration
    /// @param _duration Borrow duration in seconds
    /// @param _utilizationBPS Utilization percentage in Basis Point
    /// @return Interest rate in basis points over the duration
    function getBorrowRateBPS(uint256 _duration, uint256 _utilizationBPS) external view returns (uint256);

    /// @notice Base rate per day in basis points (e.g. 2 = 0.02%)
    function baseRatePerDayBPS() external view returns (uint8);

    /// @notice Slope 1 interest rate multiplier (used below kink)
    function slope1() external view returns (uint8);

    /// @notice Slope 2 interest rate multiplier (used above kink)
    function slope2() external view returns (uint8);

    /// @notice Utilization threshold for changing interest curve
    function kink() external view returns (uint16);

    /// @notice Denominator constant for BPS calculations (10000 = 100%)
    function BPS_DENOMINATOR() external pure returns (uint16);

    /// @notice Denominator constant for seconds per day (86400)
    function DAY_DENOMINATOR() external pure returns (uint32);
}
