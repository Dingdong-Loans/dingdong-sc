// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract CollateralManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ========== STORAGE ==========
    address[] public s_collateralTokens;
    mapping(address => bool) public s_isCollateralTokenSupported;
    mapping(address => mapping(address => uint256)) private s_collateralBalance;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ========== MAIN FUNCTIONS ==========
    function deposit(address _user, address _token, uint256 _amount) external onlyOwner {
        s_collateralBalance[_user][_token] += _amount;
    }

    function withdraw(address _user, address _token, uint256 _amount) external onlyOwner {
        s_collateralBalance[_user][_token] -= _amount;
    }

    /**
     * @notice list new collateral token
     * @param _token address of collateral token to add
     */
    function addCollateralToken(address _token) external onlyOwner {
        s_collateralTokens.push(_token);
        s_isCollateralTokenSupported[_token] = true;
    }

    /**
     * @notice remove collateral token from list
     * @param _token address of collateral token to remove
     * @dev currently does not remove associated oracle
     */
    function removeCollateralToken(address _token) external onlyOwner {
        uint256 length = s_collateralTokens.length;
        for (uint256 i = 0; i < length;) {
            if (s_collateralTokens[i] == _token) {
                s_collateralTokens[i] = s_collateralTokens[length - 1];
                s_collateralTokens.pop();

                unchecked {
                    i++;
                }

                break;
            }
        }

        s_isCollateralTokenSupported[_token] = false;
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
}
