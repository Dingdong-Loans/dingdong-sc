// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ITellorUser {
    function getSpotPrice() external returns (uint256 _value, uint256 timestamp);
    function base() external view returns (string memory);
    function quote() external view returns (string memory);
    function tokenQueryId() external view returns (bytes32);
}
