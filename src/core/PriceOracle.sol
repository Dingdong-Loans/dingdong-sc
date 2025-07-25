// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UsingTellor} from "@tellor/contracts/UsingTellor.sol";

/**
 * @dev This contract utilizes some best practices for using Tellor by implementing a dispute time buffer and a data staleness check.
 * In addition, it also seeks to mitigate back-in-time dispute attacks by caching the most recent value and timestamp.
 * Also it implements a time-weighted average price (TWAP) mechanism to provide a more stable price feed.
 */
contract PriceOracle is UsingTellor, Ownable, ReentrancyGuard {
    // ========= EVENTS ===========
    event PriceFeedSet(address indexed token, string base, string quote);
    event PriceFeedRemoved(address indexed token);

    // ========= ERRORS ===========
    error PriceOracle__InvalidAddress();
    error PriceOracle__FeedAlreadyExists();
    error PriceOracle__FeedDoesNotExist();
    error PriceOracle__InvalidPrice();
    error PriceOracle__StaleData();

    // ========= STRUCTS ==========
    struct FeedInfo {
        string base;
        string quote;
    }

    // ======== CONSTANTS =========
    uint256 public constant DISPUTE_BUFFER = 20 minutes;
    uint256 public constant STALENESS_AGE = 4 hours;
    uint256 public constant TWAP_REFRESH_INTERVAL = 1 minutes;
    uint256 public constant TWAP_INTERVAL = 1 hours;
    uint256 public constant TWAP_SAMPLE_INTERVAL = 1 minutes;

    // ========= STORAGES ==========
    mapping(address => FeedInfo) public s_priceFeeds;
    mapping(address => uint256) public s_lastStoredPrice;
    mapping(address => uint256) public s_lastStoredTimestamp;

    // ======== CONSTRUCTOR =======
    constructor(address initialOwner, address payable tellorOracle) UsingTellor(tellorOracle) Ownable(initialOwner) {}

    // ======= OWNER ONLY =========
    function setPriceFeed(address token, string memory base, string memory quote) external onlyOwner {
        if (token == address(0)) revert PriceOracle__InvalidAddress();
        if (bytes(s_priceFeeds[token].base).length != 0) revert PriceOracle__FeedAlreadyExists();

        s_priceFeeds[token] = FeedInfo(base, quote);
        emit PriceFeedSet(token, base, quote);
    }

    function removePriceFeed(address token) external onlyOwner {
        if (bytes(s_priceFeeds[token].base).length == 0) revert PriceOracle__FeedDoesNotExist();

        delete s_priceFeeds[token];
        delete s_lastStoredPrice[token];
        delete s_lastStoredTimestamp[token];

        emit PriceFeedRemoved(token);
    }

    // ========== MAIN ============
    function getValue(address token, uint256 amount) external nonReentrant returns (uint256 value) {
        FeedInfo memory feed = s_priceFeeds[token];
        if (bytes(feed.base).length == 0) revert PriceOracle__FeedDoesNotExist();

        uint256 lastTimestamp = s_lastStoredTimestamp[token];

        // 1. Use cached TWAP if fresh
        if (block.timestamp - lastTimestamp <= TWAP_REFRESH_INTERVAL) {
            if (block.timestamp - lastTimestamp > STALENESS_AGE) revert PriceOracle__StaleData();
            uint256 cachedPrice = s_lastStoredPrice[token];
            uint8 decimals = IERC20Metadata(token).decimals();
            return Math.mulDiv(amount, cachedPrice, 10 ** decimals);
        }

        // 2. Query Tellor for TWAP
        bytes memory queryData = abi.encode("SpotPrice", abi.encode(feed.base, feed.quote));
        bytes32 queryId = keccak256(queryData);

        uint256 start = block.timestamp - DISPUTE_BUFFER;
        uint256 sum;
        uint256 count;

        for (uint256 t = start; t > start - TWAP_INTERVAL; t -= TWAP_SAMPLE_INTERVAL) {
            (bytes memory data, uint256 timestamp) = getDataBefore(queryId, t);
            if (timestamp != 0 && data.length != 0) {
                sum += abi.decode(data, (uint256));
                unchecked {
                    ++count;
                }
            }
        }

        if (sum == 0 || count == 0) revert PriceOracle__InvalidPrice();
        uint256 twapPrice = sum / count;

        // 3. Cache the new price
        s_lastStoredPrice[token] = twapPrice;
        s_lastStoredTimestamp[token] = start;

        if (block.timestamp - start > STALENESS_AGE) revert PriceOracle__StaleData();

        // 4. return price to default decimals by dividing it with token decimals
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        value = Math.mulDiv(amount, twapPrice, 10 ** tokenDecimals);
    }
}
