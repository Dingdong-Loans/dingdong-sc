// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IPriceOracle
/// @notice Interface for the Tellor-based PriceOracle
interface IPriceOracle {
    /// ======= ERRORS =========
    error PriceOracle__InvalidAddress();
    error PriceOracle__FeedAlreadyExists();
    error PriceOracle__FeedDoesNotExist();
    error PriceOracle__InvalidPrice();
    error PriceOracle__StaleData();

    /// ======= EVENTS =========
    event PriceFeedSet(address indexed token, string base, string quote);
    event PriceFeedRemoved(address indexed token);

    /// @notice Sets a price feed for a given token
    /// @param _token The address of the token
    /// @param _base The base symbol (e.g. "ETH")
    /// @param _quote The quote symbol (e.g. "USD")
    function setPriceFeed(address _token, string calldata _base, string calldata _quote) external;

    /// @notice Removes a price feed for a given token
    /// @param _token The address of the token
    function removePriceFeed(address _token) external;

    /// @notice Returns the value in USD (18 decimals) for a token and amount
    /// @param _token The address of the token
    /// @param _amount The amount to evaluate
    /// @return value The value in USD with 18 decimals
    function getValue(address _token, uint256 _amount) external returns (uint256 value);

    /// @notice Gets the base/quote pair used for the given token
    /// @param _token The address of the token
    /// @return base Base symbol
    /// @return quote Quote symbol
    function getPriceFeed(address _token) external view returns (string memory base, string memory quote);
}
