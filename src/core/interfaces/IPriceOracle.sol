// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IPriceOracle
/// @notice Interface for the PriceOracle contract
interface IPriceOracle {
    /// @notice Sets a price feed for a given token
    /// @param _token The address of the token
    /// @param _feed The address of the price feed contract
    function setPriceFeed(address _token, address _feed) external;

    /// @notice Removes a price feed for a given token
    /// @param _token The address of the token
    function removePriceFeed(address _token) external;

    /// @notice Returns the price feed address for a token
    /// @param _token The address of the token
    /// @return priceFeed The address of the associated price feed
    function getPriceFeed(address _token) external view returns (address priceFeed);

    /// @notice Calculates the USD value of a given token and amount
    /// @param _token The address of the token
    /// @param _amount The amount of the token to evaluate
    /// @return value The USD value (with 18 decimals)
    function getValue(address _token, uint256 _amount) external returns (uint256 value);
}
