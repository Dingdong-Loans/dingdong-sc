// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

/// @notice currently unused
contract Vault is ERC4626 {
    constructor(IERC20Metadata _asset)
        ERC20(string(abi.encodePacked(_asset.name(), " Vault")), string(abi.encodePacked("dd", _asset.symbol())))
        ERC4626(ERC20(address(_asset)))
    {}
}
