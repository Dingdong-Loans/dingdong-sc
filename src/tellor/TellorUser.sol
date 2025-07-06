// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {UsingTellor} from "@tellor/contracts/UsingTellor.sol";

/**
 * @title TellorUser
 * @dev This contract serves as an example of how to integrate the Tellor oracle for price feed-like data such as spot prices. It
 * utilizes some best practices for using Tellor by implementing a dispute time buffer and a data staleness check. In addition,
 * it also seeks to mitigate back-in-time dispute attacks by caching the most recent value and timestamp.
 * @notice Based on Tellor's original example, but generalized for arbitrary queries.
 */
contract TellorUser is UsingTellor {
    uint256 public lastStoredTimestamp;
    uint256 public lastStoredPrice;
    bytes32 public immutable tokenQueryId;
    string public base;
    string public quote;
    uint256 public constant DISPUTE_BUFFER = 20 minutes;
    uint256 public constant STALENESS_AGE = 2 hours;

    error StalePrice(uint256 price, uint256 timestamp);
    error NoValueRetrieved(uint256 timestamp);

    /**
     * @dev the constructor sets the Tellor address and the token queryId
     * @param _tellorOracle is the address of the Tellor oracle
     */
    constructor(address payable _tellorOracle, string memory _base, string memory _quote) UsingTellor(_tellorOracle) {
        // set the token queryId
        bytes memory _queryData = abi.encode("SpotPrice", abi.encode(_base, _quote));
        tokenQueryId = keccak256(_queryData);
        base = _base;
        quote = _quote;
    }

    /**
     * @dev Allows a user contract to read the token price from Tellor and perform some
     * best practice checks on the retrieved data
     * @return _value the token spot price from Tellor, with 18 decimal places
     * @return timestamp the value's timestamp
     */
    function getSpotPrice() public returns (uint256 _value, uint256 timestamp) {
        // retrieve the most recent 20+ minute old btc price.
        // the buffer allows time for a bad value to be disputed
        (bytes memory _data, uint256 _timestamp) = getDataBefore(tokenQueryId, block.timestamp - DISPUTE_BUFFER);

        // check whether any value was retrieved
        if (_timestamp == 0 || _data.length == 0) revert NoValueRetrieved(_timestamp);

        // decode the value from bytes to uint256
        _value = abi.decode(_data, (uint256));

        // prevent a back-in-time dispute attack by caching the most recent value and timestamp.
        // this stops an attacker from disputing tellor values to manupulate which price is used
        // by your protocol
        if (_timestamp > lastStoredTimestamp) {
            // if the new value is newer than the last stored value, update the cache
            lastStoredTimestamp = _timestamp;
            lastStoredPrice = _value;
        } else {
            // if the new value is older than the last stored value, use the cached value
            _value = lastStoredPrice;
            _timestamp = lastStoredTimestamp;
        }

        // check whether value is too old
        if (block.timestamp - _timestamp > STALENESS_AGE) revert StalePrice(_value, _timestamp);

        // return the value and timestamp
        return (_value, _timestamp);
    }
}
