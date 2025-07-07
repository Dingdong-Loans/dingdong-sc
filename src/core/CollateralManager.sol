// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LendingCore} from "./LendingCoreV1.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CollateralManager is Ownable, ReentrancyGuard {
    // ========== IMMUTABLES ==========
    PriceOracle public immutable i_oracle;

    // ========== STORAGE ==========
    mapping(address => mapping(address => uint256)) s_collateralBalance;

    constructor(address initialOwner, address _oracle) Ownable(initialOwner) {
        i_oracle = PriceOracle(_oracle);
    }

    // ========== MAIN FUNCTIONS ==========
    function deposit(address _user, address _token, uint256 _amount) external onlyOwner {
        s_collateralBalance[_user][_token] += _amount;
    }

    function withdraw(address _user, address _token, uint256 _amount) external onlyOwner {
        s_collateralBalance[_user][_token] -= _amount;
    }

    // ========== VIEW FUNCTIONS ==========
    /**
     * @notice get user deposited collateral amount
     * @param _user address of user to get the balance from
     * @param _token address of token to get the balance from
     */
    function getDepositedCollateral(address _user, address _token) public view returns (uint256) {
        return s_collateralBalance[_user][_token];
    }

    /**
     * @notice get user token value in usd
     * @param _user address of user to get the balance from
     * @param _token address of token to check the value
     */
    function getTotalTokenValueInUsd(address _user, address _token) public nonReentrant returns (uint256) {
        uint256 assetAmount = getDepositedCollateral(_user, _token);
        return i_oracle.getValue(_token, assetAmount);
    }
}
