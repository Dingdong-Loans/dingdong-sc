// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITellorUser} from "../tellor/ITellorUser.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PriceOracle is Ownable, ReentrancyGuard {
    // ========== EVENTS ==========
    event PriceFeedSet(address indexed token, address feed);
    event PriceFeedRemoved(address indexed token);

    // ========== ERRORS ==========
    error PriceOracle__InvalidAddress();
    error PriceOracle__FeedAlreadyExist();
    error PriceOracle__FeedDoesNotExist();
    error PriceOracle__InvalidFeedContract();
    error PriceOracle__InvalidPrice();

    // ========== STORAGES ==========
    mapping(address => address) public s_priceFeeds;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ========== MAIN FUNCTIONS ==========
    /**
     * @notice set token price feed
     * @param _token address of the token to add the price feed to
     * @param _feed address of price feed of the token
     */
    function setPriceFeed(address _token, address _feed) external onlyOwner {
        if (s_priceFeeds[_token] != address(0)) revert PriceOracle__FeedAlreadyExist();
        if (_token == address(0) || _feed == address(0)) revert PriceOracle__InvalidAddress();

        s_priceFeeds[_token] = _feed;
        emit PriceFeedSet(_token, _feed);
    }

    function removePriceFeed(address _token) external onlyOwner {
        if (s_priceFeeds[_token] == address(0)) revert PriceOracle__FeedDoesNotExist();
        if (_token == address(0)) revert PriceOracle__InvalidAddress();

        s_priceFeeds[_token] = address(0);
        emit PriceFeedRemoved(_token);
    }

    // ========== VIEW FUNCTIONS ==========
    function getPriceFeed(address _token) external view returns (address priceFeed) {
        return s_priceFeeds[_token];
    }

    /**
     * @notice get price of a token with desired amount
     * @param _token the address of token to get the value from
     * @param _amount the amount of token to be calculated for total value
     * @return value the value of the token calculated with amount in 1e18 format (18 decimals)
     */
    function getValue(address _token, uint256 _amount) external nonReentrant returns (uint256 value) {
        address feed = s_priceFeeds[_token];
        if (feed == address(0)) revert PriceOracle__FeedDoesNotExist();

        (uint256 price,) = ITellorUser(feed).getSpotPrice();
        if (price == 0) revert PriceOracle__InvalidPrice();

        uint8 tokenDecimals = IERC20Metadata(_token).decimals();

        value = Math.mulDiv(_amount, uint256(price), 10 ** tokenDecimals);
    }
}
